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


# This script provisions testing environment using 'kind'(kubernetes-in-docker)
# and execute end-to-end Service Catalog tests.
#
# It requires TBD to be installed.

# standard bash error handling
set -o nounset # treat unset variables as an error and exit immediately.
set -o errexit # exit immediately when a command fails.
set -E         # needs to be set if we want the ERR trap

readonly CURRENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
readonly TMP_DIR=$(mktemp -d)

source "${CURRENT_DIR}/lib/utilities.sh" || { echo 'Cannot load CI utilities.'; exit 1; }
source "${CURRENT_DIR}/deps_ver.sh" || { echo 'Cannot load dependencies versions.'; exit 1; }


SC_CHART_NAME="catalog"
export SC_NAMESPACE="catalog"

cleanup() {
    kind::delete_cluster || true
#    rm -rf "${TMP_DIR}" || true
}

#trap cleanup EXIT

install::cluster::service_catalog_latest() {
    shout "- Building Service Catalog image from sources..."
    pushd ${CURRENT_DIR}/../..
    make service-catalog-image
    popd

    shout "- Load Service Catalog image into cluster..."
    kind::load_image service-catalog:canary

    shout "- Install Service Catalog via helm chart from sources..."
    helm install ${CURRENT_DIR}/../../charts/catalog \
        --set imagePullPolicy=IfNotPresent \
        --set image=service-catalog:canary \
        --namespace ${SC_NAMESPACE} \
        --name ${SC_CHART_NAME} \
        --wait
}

test::prepare_data() {
    shout "- Building User Broker image from sources..."
    pushd ${CURRENT_DIR}/../..
    make user-broker-image
    popd

    shout "- Load User Broker image into cluster..."
    kind::load_image user-broker:canary
}

test::execute() {
    shout "- Execute e2e test..."
    pushd ${CURRENT_DIR}/../../test/e2e/
    env SERVICECATALOGCONFIG="${KUBECONFIG}" go test -v ./... -broker-image="user-broker:canary"
    popd
}

main() {
    shout "Starting E2E test."

    export INSTALL_DIR=${TMP_DIR} KIND_VERSION=${STABLE_KIND_VERSION} HELM_VERSION=${STABLE_HELM_VERSION}
    install::local::kind_and_helm
    kind::create_cluster

    install::cluster::tiller
    install::cluster::service_catalog_latest

    test::prepare_data
    test::execute

    shout "E2E test completed successfully."
}

main
