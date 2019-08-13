#!/usr/bin/env bash
# Copyright 2019 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -u
set -o errexit

CURRENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
# set a fixed version so that users of this script manually upgrade kind
# in a controlled fashion along with the script contents (config, flags...)
STABLE_KIND_VERSION=v0.4.0

#cleanup() {
#    # KIND_IS_UP is true once we: kind create
#    if [[ "${KIND_IS_UP:-}" = true ]]; then
#        kind delete cluster || true
#    fi
#    # remove our tempdir
#    # NOTE: this needs to be last, or it will prevent kind delete
#    if [[ -n "${TMP_DIR:-}" ]]; then
#        rm -rf "${TMP_DIR}"
#    fi
#}
#
#trap cleanup EXIT

# install kind to a tempdir GOPATH from this script's kind checkout
install_kind() {
    # KIND has also a golang client API
    # install `kind` to tempdir
    TMP_DIR=$(mktemp -d)
    # ensure bin dir
    mkdir -p "${TMP_DIR}/bin"
    pushd "${TMP_DIR}"
    env "GOPATH=${TMP_DIR}" GO111MODULE="on" go get -u "sigs.k8s.io/kind@${STABLE_KIND_VERSION}"
    popd
    PATH="${TMP_DIR}/bin:${PATH}"
    export PATH
}

# up a cluster with kind
create_cluster() {
    # mark the cluster as up for cleanup
    # even if kind create fails, kind delete can clean up after it
    KIND_IS_UP=true
    # actually create, with:
    # - wait up to one minute for the nodes to be "READY"
    kind create cluster \
        --wait=1m

    # TODO: check if needed
    export KUBECONFIG="$(kind get kubeconfig-path)"
    export APP_KUBECONFIG_PATH="$(kind get kubeconfig-path)"
}

build_and_load_svcat_image() {
    echo "- Building Service Catalog image from sources..."
    pushd ${CURRENT_DIR}/../..
    make service-catalog-image
    popd

    echo "- Load Service Catalog image into cluster..."
    kind load docker-image service-catalog:canary
}


upgrade_service_catalog() {
    echo "- Upgrade ServiceCatalog"
    helm upgrade ${SC_CHART_NAME} ${CURRENT_DIR}/../../charts/catalog --set image=service-catalog-amd64:canary --namespace ${SC_NAMESPACE} --wait
}

export SC_NAMESPACE="catalog"
SC_CHART_NAME="catalog"
export SC_APISERVER="${SC_CHART_NAME}-catalog-apiserver"
export SC_CONTROLLER="${SC_CHART_NAME}-catalog-controller-manager"

TB_CHART_NAME="test-broker"
export TB_NAME="${TB_CHART_NAME}-test-broker"
export TB_NAMESPACE="test-broker"

#install_kind
create_cluster

echo "- Installing Tiller..."
kubectl create -f ${CURRENT_DIR}/scripts/tiller-rbac-config.yaml
helm init --service-account tiller --wait

echo "- Installing ServiceCatalog"
helm repo add svc-cat https://svc-catalog-charts.storage.googleapis.com
# TODO: After https://github.com/kyma-project/kyma/issues/5217, change `helm install svc-cat/catalog` to `helm install svc-cat/catalog-apiserver`
# install always the newest service catalog with apiserver
helm install svc-cat/catalog --name ${SC_CHART_NAME} --namespace ${SC_NAMESPACE} --wait

echo "- Installing Test broker"
helm install svc-cat/test-broker --name ${TB_CHART_NAME} --namespace ${TB_NAMESPACE} --wait

echo "- Prepare test resources"
go run ${CURRENT_DIR}/examiner/main.go --action prepareData


build_and_load_svcat_image
upgrade_service_catalog

echo "- Execute upgrade tests"
# Required environment variable:
# SC_APISERVER, SC_CONTROLLER, SC_NAMESPACE, TB_NAME, TB_NAMESPACE
go run ${CURRENT_DIR}/examiner/main.go --action executeTests
