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
#
# This script execute such test flow:
#
# 1. Provision testing environment using 'kind'(kubernetes-in-docker)
# 2. Install Service Catalog in version 0.2.x
# 3. Create a sample resources (broker, instances, bindings etc)
# 4. Upgrade Service Catalog to version build from sources
# 5. Execute tests to check if everything still working
#

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
export SC_APISERVER="${SC_CHART_NAME}-catalog-apiserver"
export SC_CONTROLLER="${SC_CHART_NAME}-catalog-controller-manager"

TB_CHART_NAME="test-broker"
export TB_NAME="${TB_CHART_NAME}-test-broker"
export TB_NAMESPACE="test-broker"

cleanup() {
    kind::delete_cluster || true
#    rm -rf "${TMP_DIR}" || true
}

trap cleanup EXIT

upgrade::cluster::service_catalog() {
    shout "- Building Service Catalog image from sources..."
    pushd ${CURRENT_DIR}/../..
    make service-catalog-image
    popd

    shout "- Load Service Catalog image into cluster..."
    kind::load_image service-catalog:canary

    shout "- Upgrade Service Catalog..."
    helm upgrade ${SC_CHART_NAME} ${CURRENT_DIR}/../../charts/catalog \
        --set imagePullPolicy=IfNotPresent \
        --set image=service-catalog:canary \
        --namespace ${SC_NAMESPACE} \
        --wait
}

examiner::prepare_resources() {
    shout "- Installing Test broker..."
    helm install svc-cat/test-broker --name ${TB_CHART_NAME} --namespace ${TB_NAMESPACE} --wait

    shout "- Create sample resources for testing purpose..."
    go run ${CURRENT_DIR}/examiner/main.go --action prepareData
}

examiner::execute_test() {
    shout "- Execute upgrade tests..."
    # Required environment variable:
    # SC_APISERVER, SC_CONTROLLER, SC_NAMESPACE, TB_NAME, TB_NAMESPACE
    go run ${CURRENT_DIR}/examiner/main.go --action executeTests
}

main() {
    shout "Starting migration test"

    export INSTALL_DIR=${TMP_DIR} KIND_VERSION=${STABLE_KIND_VERSION} HELM_VERSION=${STABLE_HELM_VERSION}
    install::local::kind_and_helm
    kind::create_cluster

    install::cluster::tiller
    install::cluster::service_catalog_v2

    examiner::prepare_resources

    upgrade::cluster::service_catalog

    examiner::execute_test

    shout "Migration test completed successfully."
}

main
