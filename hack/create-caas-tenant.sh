#!/usr/bin/env bash
# Deploy a compact KubeVirt tenant cluster via CAPOA and run OpenShift conformance on it.
#
# Assumes deploy-capoa-kubevirt.sh already ran successfully (CAPI+CAPK+CAPOA ready).
#
# Required env vars:
#   ARTIFACT_DIR        - directory for JUnit results and logs (set by Prow)
#
# Optional env vars (auto-discovered from the hub cluster if not set):
#   PULL_SECRET         - pull secret JSON (default: extracted from hub openshift-config/pull-secret)
#   BASE_DOMAIN         - base domain for the tenant cluster (default: from hub ingress)
#   STORAGE_CLASS       - storage class for VM root disks (default: from hub default SC)
#   OCP_VERSION         - OpenShift version to install (default: hub version,
#                         fallback defined in hack/deploy-capoa-kubevirt.yaml)
#
# Defaults for all other tunables (cluster name, namespaces, timeouts, SSH
# key, manifest paths) are centralized in hack/deploy-capoa-kubevirt.yaml.
# Every key defined there can be overridden through a same-named
# environment variable:
#   CLUSTER_NAME, TENANT_NAMESPACE, ASSISTED_NAMESPACE, SSH_AUTHORIZED_KEY,
#   INSTALL_TIMEOUT_MIN, FINALIZING_TIMEOUT_MIN, CONFORMANCE_TIMEOUT

set -euxo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
REPO_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
CONFIG_FILE="${SCRIPT_DIR}/deploy-capoa-kubevirt.yaml"

# Reads a configuration key from ${CONFIG_FILE}; an environment variable
# with the same name takes precedence.
function read_config() {
    local key="$1"
    if [ -n "${!key:-}" ]; then
        printf '%s\n' "${!key}"
        return
    fi
    sed -n "s/^${key}:[[:space:]]*//p" "${CONFIG_FILE}" | tr -d "\"'" | head -n1
}

CLUSTER_NAME=$(read_config CLUSTER_NAME)
TENANT_NAMESPACE=$(read_config TENANT_NAMESPACE)
ASSISTED_NAMESPACE=$(read_config ASSISTED_NAMESPACE)
SSH_AUTHORIZED_KEY=$(read_config SSH_AUTHORIZED_KEY)
INSTALL_TIMEOUT_MIN=$(read_config INSTALL_TIMEOUT_MIN)
FINALIZING_TIMEOUT_MIN=$(read_config FINALIZING_TIMEOUT_MIN)
CONFORMANCE_TIMEOUT=$(read_config CONFORMANCE_TIMEOUT)
AGENTSERVICECONFIG_MANIFEST=$(read_config AGENTSERVICECONFIG_MANIFEST)
TENANT_CLUSTER_MANIFEST=$(read_config TENANT_CLUSTER_MANIFEST)

# OpenShift version to install: env var > hub cluster version > config
# fallback (matches the hub RHCOS stream → reuse coreos-bootimages URL).
OCP_VERSION=${OCP_VERSION:-$(oc get clusterversion version \
    -o jsonpath='{.status.desired.version}' 2>/dev/null || true)}
OCP_VERSION=${OCP_VERSION:-$(read_config OCP_VERSION)}

for _key in CLUSTER_NAME TENANT_NAMESPACE ASSISTED_NAMESPACE OCP_VERSION \
    SSH_AUTHORIZED_KEY INSTALL_TIMEOUT_MIN FINALIZING_TIMEOUT_MIN \
    CONFORMANCE_TIMEOUT AGENTSERVICECONFIG_MANIFEST TENANT_CLUSTER_MANIFEST; do
    if [ -z "${!_key}" ]; then
        echo "ERROR: ${_key} is not set and was not found in ${CONFIG_FILE}" >&2
        exit 1
    fi
done
unset _key

OCP_MAJOR_MINOR=$(echo "${OCP_VERSION}" | cut -d. -f1,2)

ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/artifacts}
mkdir -p "${ARTIFACT_DIR}"

TOTAL=0
FAILURES=0
TESTCASES_XML=""

function add_testcase() {
    local test_name="$1"
    local test_passed="$2"

    TOTAL=$((TOTAL + 1))

    if [[ "$test_passed" == "false" ]]; then
        FAILURES=$((FAILURES + 1))
        TESTCASES_XML+="  <testcase name=\"${test_name}\"><failure message=\"Failed step\"/></testcase>\n"
        exit 1
    else
        TESTCASES_XML+="  <testcase name=\"${test_name}\"/>\n"
    fi
}

function generateResultFile() {
    local results_file="${1}"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n' > "${results_file}"
    printf '<testsuite name="capoa-kubevirt-test" tests="%s" failures="%s">\n' \
        "${TOTAL}" "${FAILURES}" >> "${results_file}"
    printf "${TESTCASES_XML}" >> "${results_file}"
    printf '</testsuite>\n' >> "${results_file}"
}

function cleanup() {
    rv=$?
    if [ "x$rv" != "x0" ]; then
        echo "*** Test failed — collecting diagnostics ***"
        oc get cluster,kubevirtcluster,oacp,agentclusterinstall -n "${TENANT_NAMESPACE}" 2>/dev/null || true
        oc get agents -n "${TENANT_NAMESPACE}" 2>/dev/null || true
        oc describe agentclusterinstall -n "${TENANT_NAMESPACE}" 2>/dev/null \
            > "${ARTIFACT_DIR}/agentclusterinstall.txt" || true
        oc logs -n "${ASSISTED_NAMESPACE}" deployment/assisted-service --tail=200 2>/dev/null \
            > "${ARTIFACT_DIR}/assisted-service.log" || true
    fi
    generateResultFile "${ARTIFACT_DIR}/junit_capoa_kubevirt_test.xml"
    exit $rv
}

trap "cleanup" INT TERM EXIT

# ---------------------------------------------------------------------------
# Discover hub cluster parameters
# ---------------------------------------------------------------------------
BASE_DOMAIN=${BASE_DOMAIN:-$(oc get ingresscontroller default -n openshift-ingress-operator \
    -o jsonpath='{.status.domain}' 2>/dev/null)}
STORAGE_CLASS=${STORAGE_CLASS:-$(oc get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null)}
set +x
PULL_SECRET=${PULL_SECRET:-$(oc get secret pull-secret -n openshift-config \
    -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)}
set -x

echo "OCP_VERSION:   ${OCP_VERSION}"
echo "BASE_DOMAIN:   ${BASE_DOMAIN}"
echo "STORAGE_CLASS: ${STORAGE_CLASS}"

# ---------------------------------------------------------------------------
# Step 1: ensure AgentServiceConfig + assisted-service ready
# ---------------------------------------------------------------------------
function ensure_assisted_service() {
    if ! oc get agentserviceconfig agent &>/dev/null; then
        echo "Creating AgentServiceConfig"
        oc apply -f "${REPO_DIR}/${AGENTSERVICECONFIG_MANIFEST}"
    else
        echo "AgentServiceConfig already exists"
    fi

    oc wait deployment assisted-service \
        -n "${ASSISTED_NAMESPACE}" \
        --for=condition=Available \
        --timeout=10m
}

# ---------------------------------------------------------------------------
# Step 2: deploy tenant cluster
# ---------------------------------------------------------------------------
function deploy_tenant_cluster() {
    set +x
    PULL_SECRET_B64=$(echo "${PULL_SECRET}" | base64 -w0)
    INFRA_KUBECONFIG_B64=$(base64 -w0 < "${KUBECONFIG}")
    set -x

    # Pre-create RHCOS URL ConfigMap from hub's coreos-bootimages to bypass
    # the private image resolution job (ocp-v4.0-art-dev is Red Hat internal only).
    local rhcos_url
    rhcos_url=$(oc get configmap coreos-bootimages \
        -n openshift-machine-config-operator \
        -o jsonpath='{.data.stream}' \
        | python3 -c "import sys,json; d=json.load(sys.stdin); \
          print(d['architectures']['x86_64']['artifacts']['kubevirt']['formats']['ociarchive']['disk']['location'])")

    echo "RHCOS kubevirt URL: ${rhcos_url}"

    oc create namespace "${TENANT_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

    oc create configmap "capoa-rhcos-url-${OCP_MAJOR_MINOR}" \
        -n "${TENANT_NAMESPACE}" \
        --from-literal="qcow2-url=${rhcos_url}" \
        --dry-run=client -o yaml | oc apply -f -

    export CLUSTER_NAME TENANT_NAMESPACE OCP_VERSION OCP_MAJOR_MINOR BASE_DOMAIN \
           STORAGE_CLASS SSH_AUTHORIZED_KEY PULL_SECRET_B64 INFRA_KUBECONFIG_B64

    oc apply -f <(envsubst < "${REPO_DIR}/${TENANT_CLUSTER_MANIFEST}")
}

# ---------------------------------------------------------------------------
# Step 3: wait for installation
# ---------------------------------------------------------------------------
function wait_for_installation() {
    echo "Waiting for AgentClusterInstall to reach installed state"

    local deadline=$(( $(date +%s) + INSTALL_TIMEOUT_MIN * 60 ))
    local finalizing_extended=false

    while true; do
        local state
        state=$(oc get agentclusterinstall "${CLUSTER_NAME}" \
            -n "${TENANT_NAMESPACE}" \
            -o jsonpath='{.status.debugInfo.state}' 2>/dev/null || echo "")

        echo "ACI state: ${state}"

        if [[ "${state}" == "installed" || "${state}" == "adding-hosts" ]]; then
            echo "Installation complete"
            return 0
        fi

        if [[ "${state}" == "finalizing" && "${finalizing_extended}" == "false" ]]; then
            echo "Cluster finalizing (operators deploying) — extending deadline by ${FINALIZING_TIMEOUT_MIN}m"
            deadline=$(( deadline + FINALIZING_TIMEOUT_MIN * 60 ))
            finalizing_extended=true
        fi

        if [[ "${state}" == "error" ]]; then
            echo "ERROR: Installation failed"
            oc get agentclusterinstall "${CLUSTER_NAME}" \
                -n "${TENANT_NAMESPACE}" \
                -o jsonpath='{.status.debugInfo.stateInfo}' 2>/dev/null || true
            return 1
        fi

        if [[ $(date +%s) -gt ${deadline} ]]; then
            echo "ERROR: Timed out waiting for installation"
            return 1
        fi

        sleep 60
    done
}

# ---------------------------------------------------------------------------
# Step 4: extract tenant kubeconfig
# ---------------------------------------------------------------------------
function get_tenant_kubeconfig() {
    local kubeconfig_path="${ARTIFACT_DIR}/tenant-kubeconfig"

    oc get secret "${CLUSTER_NAME}-admin-kubeconfig" \
        -n "${TENANT_NAMESPACE}" \
        -o jsonpath='{.data.kubeconfig}' \
        | base64 -d > "${kubeconfig_path}"

    echo "${kubeconfig_path}"
}

# ---------------------------------------------------------------------------
# Step 5: smoke-check the tenant cluster through its kubeconfig
# ---------------------------------------------------------------------------
function smoke_check_tenant() {
    local tenant_kubeconfig="${1}"
    echo "Smoke-checking tenant cluster via ${tenant_kubeconfig}"
    oc --kubeconfig "${tenant_kubeconfig}" get nodes
    oc --kubeconfig "${tenant_kubeconfig}" get clusteroperators
}

# ---------------------------------------------------------------------------
# Step 6: run conformance (TODO: enable once cluster deployment is validated)
# ---------------------------------------------------------------------------
# function run_conformance() {
#     local tenant_kubeconfig="${1}"
#     echo "Running openshift conformance on tenant cluster"
#     oc --kubeconfig "${tenant_kubeconfig}" get nodes
#     openshift-tests run openshift/conformance/minimal \
#         --kubeconfig "${tenant_kubeconfig}" \
#         --junit-dir "${ARTIFACT_DIR}" \
#         --timeout "${CONFORMANCE_TIMEOUT}" \
#         2>&1 | tee "${ARTIFACT_DIR}/conformance.log"
# }

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "=== CAPOA+KubeVirt tenant cluster test ==="
echo "Cluster: ${CLUSTER_NAME} | OCP: ${OCP_VERSION} | Namespace: ${TENANT_NAMESPACE}"

ensure_assisted_service  || add_testcase "ensure_assisted_service" "false"
add_testcase "ensure_assisted_service" "true"

deploy_tenant_cluster    || add_testcase "deploy_tenant_cluster"   "false"
add_testcase "deploy_tenant_cluster" "true"

wait_for_installation    || add_testcase "wait_for_installation"   "false"
add_testcase "wait_for_installation" "true"

TENANT_KUBECONFIG=$(get_tenant_kubeconfig) || add_testcase "get_tenant_kubeconfig" "false"
add_testcase "get_tenant_kubeconfig" "true"

smoke_check_tenant "${TENANT_KUBECONFIG}" || add_testcase "smoke_check_tenant" "false"
add_testcase "smoke_check_tenant" "true"

# TODO: run conformance once cluster deployment is validated end-to-end
# run_conformance "${TENANT_KUBECONFIG}"     || add_testcase "run_conformance"        "false"
# add_testcase "run_conformance" "true"

echo "=== CAPOA+KubeVirt tenant cluster test complete ==="
