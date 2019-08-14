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
# Library of useful utilities for CI purposes.
#

readonly LIB_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

# Exit with a message and an exit code.
# Arguments:
#   $1 - string with an error message
#   $2 - exit code, defaults to 1
error_exit() {
  # ${BASH_SOURCE[1]} is the file name of the caller.
  echo "${BASH_SOURCE[1]}: line ${BASH_LINENO[0]}: ${1:-Unknown Error.} (exit ${2:-1})" 1>&2
  exit ${2:-1}
}


shout() {
    echo -e "
#################################################################################################
# $(date)
# $1
#################################################################################################
"
}


# Retries a command with an exponential back-off.
# The back-off base is a constant 3/2
# Options:
#   -n Maximum total attempts (0 for infinite, default 10)
#   -t Maximum time to sleep between retries (default 60)
#   -s Initial time to sleep between retries. Subsequent retries
#      subject to exponential back-off up-to the maximum time.
#      (default 5)
retry() {
  local OPTIND OPTARG ARG
  local COUNT=10
  local SLEEP=5 MAX_SLEEP=60
  local MUL=3 DIV=2 # Exponent base multiplier and divisor
                    # (Bash doesn't do floats)

  while getopts ":n:s:t:" ARG; do
    case ${ARG} in
      n) COUNT=${OPTARG};;
      s) SLEEP=${OPTARG};;
      t) MAX_SLEEP=${OPTARG};;
      *) echo "Unrecognized argument: -${OPTARG}";;
    esac
  done

  shift $((OPTIND-1))

  # If there is no command, abort early.
  [[ ${#} -le 0 ]] && { echo "No command specified, aborting."; return 1; }

  local N=1 S=${SLEEP}  # S is the current length of sleep.
  while : ; do
    echo "${N}. Executing ${@}"
    "${@}" && { echo "Command succeeded."; return 0; }

    [[ (( COUNT -le 0 || N -lt COUNT )) ]] \
      || { echo "Command '${@}' failed ${N} times, aborting."; return 1; }

    if [[ (( S -lt MAX_SLEEP )) ]] ; then
      # Must always count full exponent due to integer rounding.
      ((S=SLEEP * (MUL ** (N-1)) / (DIV ** (N-1))))
    fi

    ((S=(S < MAX_SLEEP) ? S : MAX_SLEEP))

    echo "Command failed. Will retry in ${S} seconds."
    sleep ${S}

    ((N++))
  done
}

# Installs kind and helm dependencies locally.
# Required envs:
#  - KIND_VERSION
#  - HELM_VERSION
#  - INSTALL_DIR
install::local::kind_and_helm() {
    mkdir -p "${INSTALL_DIR}/bin"
    pushd "${INSTALL_DIR}"

    shout "- Install kind ${STABLE_KIND_VERSION} locally to a tempdir GOPATH..."
    env "GOPATH=${INSTALL_DIR}" GO111MODULE="on" go get "sigs.k8s.io/kind@${STABLE_KIND_VERSION}"

    shout "- Install helm ${STABLE_HELM_VERSION} locally to a tempdir GOPATH..."
    wget -q https://storage.googleapis.com/kubernetes-helm/helm-${STABLE_HELM_VERSION}-linux-amd64.tar.gz -O - | tar -xzO linux-amd64/helm > ${INSTALL_DIR}/bin/helm \
    && chmod +x ${INSTALL_DIR}/bin/helm

    popd
    export PATH="${INSTALL_DIR}/bin:${PATH}"
}

# Installs tiller on cluster
install::cluster::tiller() {
    shout "- Installing Tiller..."
    kubectl create -f ${LIB_DIR}/tiller-rbac-config.yaml
    helm init --service-account tiller --wait
}

# Installs Service Catalog from newest 0.2.x release on k8s cluster.
# Required envs:
#  - SC_CHART_NAME
#  - SC_NAMESPACE
install::cluster::service_catalog_v2() {
    shout "- Installing Service Catalog in version 0.2.x"
    helm repo add svc-cat https://svc-catalog-charts.storage.googleapis.com
    # TODO: After https://github.com/kyma-project/kyma/issues/5217, change `helm install svc-cat/catalog` to `helm install svc-cat/catalog-apiserver`
    # install always the newest service catalog with apiserver
    helm install svc-cat/catalog --name ${SC_CHART_NAME} --namespace ${SC_NAMESPACE} --wait
}

#
# 'kind'(kubernetes-in-docker) functions
#
readonly KIND_CLUSTER_NAME="kind-ci"

kind::create_cluster() {
    shout "- Create k8s cluster..."
    kind create cluster --name=${KIND_CLUSTER_NAME} --wait=1m
    export KUBECONFIG="$(kind get kubeconfig-path --name=${KIND_CLUSTER_NAME})"
}

kind::delete_cluster() {
    kind delete cluster --name=${KIND_CLUSTER_NAME}
}

# Arguments:
#   $1 - image name to copy into cluster nodes
kind::load_image() {
    kind load docker-image $1 --name=${KIND_CLUSTER_NAME}
}