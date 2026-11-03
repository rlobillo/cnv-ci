#!/usr/bin/env bash
# Delete a CAAS tenant cluster from the hub.
#
# Deleting the tenant namespace is all it should take: the Kubernetes
# garbage collector and the CAPI/assisted controllers tear down the whole
# chain (VMs -> VMIs -> launcher pods, Cluster -> control plane ->
# machines), and the CSI reclaims the storage backing the tenant volumes.
# This script does exactly that and verifies the outcome:
#
#   1. Delete the tenant namespace and wait for the cascade to complete.
#   2. Wait for the tenant PVs to be reclaimed.
#
# Anything left behind -> exit 1. The script never intervenes in the
# teardown (no finalizer stripping, no forced deletions, no storage
# operations): a stuck cleanup means something upstream did not work, and
# how to handle it is a human decision.
#
# Optional env vars (defaults from hack/caas.yaml, env var wins):
#   TENANT_NAMESPACE, NAMESPACE_DELETE_TIMEOUT_MIN, PV_DELETE_TIMEOUT_MIN

set -euo pipefail

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

TENANT_NAMESPACE=$(read_config TENANT_NAMESPACE)
NAMESPACE_DELETE_TIMEOUT_MIN=$(read_config NAMESPACE_DELETE_TIMEOUT_MIN)
PV_DELETE_TIMEOUT_MIN=$(read_config PV_DELETE_TIMEOUT_MIN)

for _key in TENANT_NAMESPACE NAMESPACE_DELETE_TIMEOUT_MIN PV_DELETE_TIMEOUT_MIN; do
    if [ -z "${!_key}" ]; then
        echo "ERROR: ${_key} is not set and was not found in ${CONFIG_FILE}" >&2
        exit 1
    fi
done
unset _key

command -v oc &>/dev/null || { echo "ERROR: 'oc' client not found in PATH" >&2; exit 1; }

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

# wait_until <timeout_seconds> <description> <command...>
# Returns 0 as soon as the command succeeds, 1 on timeout.
function wait_until() {
    local timeout_s="$1"; shift
    local desc="$1"; shift
    local deadline=$(( $(date +%s) + timeout_s ))
    echo "Waiting up to $(( timeout_s / 60 ))m for ${desc} (polling every 10s)"
    while true; do
        if "$@" >/dev/null 2>&1; then
            echo "  done"
            return 0
        fi
        if [ "$(date +%s)" -ge "${deadline}" ]; then
            echo ""
            echo "WARN: timed out waiting for ${desc}"
            return 1
        fi
        printf '.'
        sleep 10
    done
}

# ---------------------------------------------------------------------------
# Step 0: capture the tenant PV names (before the namespace goes away)
# ---------------------------------------------------------------------------
function capture_tenant_pvs() {
    echo "=== Capturing tenant PVs ==="
    local ns_filter=".spec.claimRef.namespace==\"${TENANT_NAMESPACE}\""
    oc get pv -o jsonpath="{range .items[?(@${ns_filter})]}{.metadata.name}{\"\n\"}{end}" \
        2>/dev/null | grep -v '^$' > "${WORK_DIR}/tenant-pvs.txt" || true
    echo "Tenant PVs: $(wc -l < "${WORK_DIR}/tenant-pvs.txt")"
}

# ---------------------------------------------------------------------------
# Step 1: delete the tenant namespace and wait for the cascade
# ---------------------------------------------------------------------------
function delete_tenant() {
    if ! oc get namespace "${TENANT_NAMESPACE}" &>/dev/null; then
        echo "=== Namespace ${TENANT_NAMESPACE} not found — nothing to delete ==="
        return 0
    fi

    echo "=== Deleting tenant namespace ==="
    oc delete namespace "${TENANT_NAMESPACE}" --ignore-not-found --wait=false

    if ! wait_until $(( NAMESPACE_DELETE_TIMEOUT_MIN * 60 )) "namespace deletion" \
        bash -c "! oc get namespace ${TENANT_NAMESPACE} &>/dev/null"; then
        echo "ERROR: namespace ${TENANT_NAMESPACE} is stuck in Terminating — the deletion cascade did not complete (check resources with finalizers in the namespace)" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Step 2: wait for the tenant PVs to be reclaimed
# ---------------------------------------------------------------------------
function wait_tenant_pvs_gone() {
    echo "=== Waiting for tenant PVs to be reclaimed ==="
    local pv failed=0
    while read -r pv; do
        [ -z "${pv}" ] && continue
        if ! wait_until $(( PV_DELETE_TIMEOUT_MIN * 60 )) "deletion of PV ${pv}" \
            bash -c "! oc get pv ${pv} &>/dev/null"; then
            echo "ERROR: PV ${pv} was not reclaimed — stuck in Terminating (its backing volume could not be deleted)" >&2
            failed=1
        fi
    done < "${WORK_DIR}/tenant-pvs.txt"
    [ "${failed}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "=== CAAS tenant deletion ==="
echo "Tenant namespace: ${TENANT_NAMESPACE}"

capture_tenant_pvs
delete_tenant
wait_tenant_pvs_gone

echo "=== CAAS tenant deletion complete ==="
