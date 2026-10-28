#!/usr/bin/env bash
# Deploy a CAAS tenant cluster on the hub and smoke-check it.
#
# Assumes deploy-caas-standalone.sh already ran successfully
# (CAPI+CAPK+CAPOA ready).
#
# What it does:
#   1. ensure AgentServiceConfig + assisted-service ready
#   2. apply the tenant cluster manifest
#   3. wait for the AgentClusterInstall to reach "installed"
#   4. extract the tenant kubeconfig into ARTIFACT_DIR
#   5. smoke-check the tenant cluster (oc get nodes)
#
# Nothing else: conformance runs and tenant deletion are driven by separate
# Prow steps (see delete-caas-tenant.sh).
#
# Required env vars:
#   ARTIFACT_DIR        - directory for the tenant kubeconfig and logs (set by Prow)
#
# Optional env vars (auto-discovered from the hub cluster if not set):
#   PULL_SECRET         - pull secret JSON (default: extracted from hub openshift-config/pull-secret)
#   BASE_DOMAIN         - base domain for the tenant cluster (default: from hub ingress)
#   STORAGE_CLASS       - storage class for VM root disks (default: from hub default SC)
#   OCP_VERSION         - OpenShift version to install (default: hub version,
#                         fallback defined in hack/caas.yaml)
#
# Defaults for all other tunables (cluster name, namespaces, timeouts, SSH
# key, manifest paths) are centralized in hack/caas.yaml.
# Every key defined there can be overridden through a same-named
# environment variable:
#   CLUSTER_NAME, TENANT_NAMESPACE, ASSISTED_NAMESPACE, SSH_AUTHORIZED_KEY,
#   INSTALL_TIMEOUT_MIN, FINALIZING_TIMEOUT_MIN

set -euxo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
REPO_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
CONFIG_FILE="${SCRIPT_DIR}/caas.yaml"

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
AGENTSERVICECONFIG_MANIFEST=$(read_config AGENTSERVICECONFIG_MANIFEST)
TENANT_CLUSTER_MANIFEST=$(read_config TENANT_CLUSTER_MANIFEST)

# OpenShift version to install: env var > caas.yaml > hub cluster version.
# caas.yaml takes precedence over hub autodiscovery so that a hub running a
# pre-release (e.g. 5.0-rc) does not silently override an explicit config.
OCP_VERSION=${OCP_VERSION:-$(read_config OCP_VERSION)}
OCP_VERSION=${OCP_VERSION:-$(oc get clusterversion version \
    -o jsonpath='{.status.desired.version}' 2>/dev/null || true)}

for _key in CLUSTER_NAME TENANT_NAMESPACE ASSISTED_NAMESPACE OCP_VERSION \
    SSH_AUTHORIZED_KEY INSTALL_TIMEOUT_MIN FINALIZING_TIMEOUT_MIN \
    AGENTSERVICECONFIG_MANIFEST TENANT_CLUSTER_MANIFEST; do
    if [ -z "${!_key}" ]; then
        echo "ERROR: ${_key} is not set and was not found in ${CONFIG_FILE}" >&2
        exit 1
    fi
done
unset _key

OCP_MAJOR_MINOR=$(echo "${OCP_VERSION}" | cut -d. -f1,2)

ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/artifacts}
mkdir -p "${ARTIFACT_DIR}"

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

    oc create namespace "${TENANT_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

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

    # The generated kubeconfig points at the tenant API on port 6443, but in
    # pod-networking mode the API is exposed through a hub Route, served on
    # port 443 (SNI passthrough to the service port 6443). Strip the port so
    # the kubeconfig also works from outside the hub.
    sed -i 's|:6443$||' "${kubeconfig_path}"

    echo "${kubeconfig_path}"
}

# ---------------------------------------------------------------------------
# Step 5: smoke-check the tenant cluster through its kubeconfig
# ---------------------------------------------------------------------------
function smoke_check_tenant() {
    local tenant_kubeconfig="${1}"
    echo "Smoke-checking tenant cluster via ${tenant_kubeconfig}"
    oc --kubeconfig "${tenant_kubeconfig}" get nodes
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "=== CAAS tenant cluster deployment ==="
echo "Cluster: ${CLUSTER_NAME} | OCP: ${OCP_VERSION} | Namespace: ${TENANT_NAMESPACE}"

ensure_assisted_service
deploy_tenant_cluster
wait_for_installation
TENANT_KUBECONFIG=$(get_tenant_kubeconfig)
smoke_check_tenant "${TENANT_KUBECONFIG}"

echo "Tenant kubeconfig: ${TENANT_KUBECONFIG}"
echo "=== CAAS tenant cluster ready ==="
