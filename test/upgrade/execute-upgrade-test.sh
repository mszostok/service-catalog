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

# standard bash error handling
set -o nounset # treat unset variables as an error and exit immediately.
set -o errexit # exit immediately when a command fails.
set -E         # needs to be set if we want the ERR trap

readonly CURRENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
readonly TMP_DIR=$(mktemp -d)

# Upgrade binary versions in a controlled fashion
# along with the script contents (config, flags...)
readonly STABLE_KIND_VERSION=v0.4.0
readonly STABLE_HELM_VERSION=v2.14.3

SC_CHART_NAME="catalog"
export SC_NAMESPACE="catalog"
export SC_APISERVER="${SC_CHART_NAME}-catalog-apiserver"
export SC_CONTROLLER="${SC_CHART_NAME}-catalog-controller-manager"

TB_CHART_NAME="test-broker"
export TB_NAME="${TB_CHART_NAME}-test-broker"
export TB_NAMESPACE="test-broker"

cleanup() {
    kind delete cluster || true
    rm -rf "${TMP_DIR}" || true
}

trap cleanup EXIT

function shout() {
    echo -e "
#################################################################################################
# $(date)
# $1
#################################################################################################
"
}

install_kind_and_helm() {
    shout "- Install kind ${STABLE_KIND_VERSION} locally to a tempdir GOPATH..."
    mkdir -p "${TMP_DIR}/bin"
    pushd "${TMP_DIR}"
    env "GOPATH=${TMP_DIR}" GO111MODULE="on" go get "sigs.k8s.io/kind@${STABLE_KIND_VERSION}"

    shout "- Install helm ${STABLE_HELM_VERSION} locally to a tempdir GOPATH..."
    wget -q https://storage.googleapis.com/kubernetes-helm/helm-${STABLE_HELM_VERSION}-linux-amd64.tar.gz -O - | tar -xzO linux-amd64/helm > ${TMP_DIR}/bin/helm \
    && chmod +x ${TMP_DIR}/bin/helm

    popd
    PATH="${TMP_DIR}/bin:${PATH}"
    export PATH
}

create_cluster() {
    shout "- Create k8s cluster..."
    kind create cluster --wait=1m
    export KUBECONFIG="$(kind get kubeconfig-path)"
}

setup_tiller() {
    shout "- Installing Tiller..."
    kubectl create -f ${CURRENT_DIR}/assets/tiller-rbac-config.yaml
    helm init --service-account tiller --wait
}

install_service_catalog_v2() {
    shout "- Installing Service Catalog in version 0.2.x"
    helm repo add svc-cat https://svc-catalog-charts.storage.googleapis.com
    # TODO: After https://github.com/kyma-project/kyma/issues/5217, change `helm install svc-cat/catalog` to `helm install svc-cat/catalog-apiserver`
    # install always the newest service catalog with apiserver
    helm install svc-cat/catalog --name ${SC_CHART_NAME} --namespace ${SC_NAMESPACE} --wait
}

prepare_test_resources() {
    shout "- Installing Test broker..."
    helm install svc-cat/test-broker --name ${TB_CHART_NAME} --namespace ${TB_NAMESPACE} --wait

    shout "- Create sample resources for testing purpose..."
    go run ${CURRENT_DIR}/examiner/main.go --action prepareData
}

upgrade_service_catalog() {
    shout "- Building Service Catalog image from sources..."
    pushd ${CURRENT_DIR}/../..
    make service-catalog-image
    popd

    shout "- Load Service Catalog image into cluster..."
    kind load docker-image service-catalog:canary

    shout "- Upgrade Service Catalog..."
    helm upgrade ${SC_CHART_NAME} ${CURRENT_DIR}/../../charts/catalog \
        --set imagePullPolicy=IfNotPresent \
        --set image=service-catalog:canary \
        --namespace ${SC_NAMESPACE} \
        --wait
}

execute_upgrade_test() {
    shout "- Execute upgrade tests..."
    # Required environment variable:
    # SC_APISERVER, SC_CONTROLLER, SC_NAMESPACE, TB_NAME, TB_NAMESPACE
    go run ${CURRENT_DIR}/examiner/main.go --action executeTests
}

main() {
    install_kind_and_helm
    create_cluster
    setup_tiller
    install_service_catalog_v2
    prepare_test_resources
    upgrade_service_catalog
    execute_upgrade_test
}

main
