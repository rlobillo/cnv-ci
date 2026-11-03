#!/usr/bin/env bash
# Add the day-2 KubeVirt worker pool to an installed tenant cluster.
# The hub kubeconfig applies CAPI resources; the tenant admin kubeconfig
# checks Node readiness and updates the cluster Scheduler after all workers
# have joined. Masters remain schedulable if the worker readiness gate times out.
# The tenant kubeconfig must be cluster-admin because Scheduler is cluster-scoped.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
CONFIG_FILE="${SCRIPT_DIR}/caas.yaml"

# Read a config key, with a same-named environment variable taking precedence.
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
STORAGE_CLASS=${STORAGE_CLASS:-$(read_config CSI_STORAGE_CLASS)}
DAY2_WORKERS_COUNT=$(read_config DAY2_WORKERS_COUNT)
DAY2_WORKERS_READY_TIMEOUT_MIN=$(read_config DAY2_WORKERS_READY_TIMEOUT_MIN)

HUB_KUBECONFIG=${HUB_KUBECONFIG:-${KUBECONFIG:-}}
ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/artifacts}
TENANT_KUBECONFIG=${TENANT_KUBECONFIG:-${ARTIFACT_DIR}/tenant-kubeconfig}
WORKERS_MANIFEST="${REPO_DIR}/manifests/capoa/kubevirt-tenant-workers.yaml"
POLL_INTERVAL_SECONDS=${POLL_INTERVAL_SECONDS:-30}

for command in oc envsubst jq; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "ERROR: required command '${command}' was not found" >&2
        exit 1
    fi
done

if [ -z "${HUB_KUBECONFIG}" ] || [ ! -f "${HUB_KUBECONFIG}" ]; then
    echo "ERROR: set HUB_KUBECONFIG (or KUBECONFIG) to the hub admin kubeconfig" >&2
    exit 1
fi
if [ ! -f "${TENANT_KUBECONFIG}" ]; then
    echo "ERROR: tenant kubeconfig not found at ${TENANT_KUBECONFIG}; set TENANT_KUBECONFIG or ARTIFACT_DIR" >&2
    exit 1
fi
if [ ! -f "${WORKERS_MANIFEST}" ]; then
    echo "ERROR: worker manifest not found: ${WORKERS_MANIFEST}" >&2
    exit 1
fi
if ! [[ "${DAY2_WORKERS_COUNT}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: DAY2_WORKERS_COUNT must be a positive integer (got '${DAY2_WORKERS_COUNT}')" >&2
    exit 1
fi
if ! [[ "${DAY2_WORKERS_READY_TIMEOUT_MIN}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: DAY2_WORKERS_READY_TIMEOUT_MIN must be a positive integer (got '${DAY2_WORKERS_READY_TIMEOUT_MIN}')" >&2
    exit 1
fi

# The Scheduler is cluster-scoped. Fail before creating workers if the tenant
# kubeconfig cannot make the final mastersSchedulable change.
can_patch_scheduler=$(oc --kubeconfig="${TENANT_KUBECONFIG}" \
    auth can-i patch schedulers.config.openshift.io/cluster)
if [ "${can_patch_scheduler}" != "yes" ]; then
    echo "ERROR: tenant kubeconfig must be authorized to patch schedulers.config.openshift.io/cluster" >&2
    exit 1
fi

OCP_VERSION=$(oc --kubeconfig="${TENANT_KUBECONFIG}" get clusterversion version \
    -o jsonpath='{.status.desired.version}')
if [ -z "${OCP_VERSION}" ]; then
    echo "ERROR: could not read the tenant OpenShift version" >&2
    exit 1
fi
OCP_MAJOR_MINOR=$(cut -d. -f1,2 <<<"${OCP_VERSION}")

GOLDEN_PVC="rhcos-golden-${OCP_MAJOR_MINOR}"
oc --kubeconfig="${HUB_KUBECONFIG}" get storageclass "${STORAGE_CLASS}" >/dev/null
oc --kubeconfig="${HUB_KUBECONFIG}" get pvc "${GOLDEN_PVC}" -n "${TENANT_NAMESPACE}" >/dev/null

echo "Applying ${WORKERS_MANIFEST} to hub cluster ${CLUSTER_NAME}"
echo "Tenant: ${TENANT_NAMESPACE}; OpenShift: ${OCP_VERSION}; workers: ${DAY2_WORKERS_COUNT}; storage: ${STORAGE_CLASS}"

export CLUSTER_NAME TENANT_NAMESPACE OCP_MAJOR_MINOR STORAGE_CLASS DAY2_WORKERS_COUNT
# The format string is intentionally single-quoted for envsubst.
# shellcheck disable=SC2016
envsubst '${CLUSTER_NAME} ${TENANT_NAMESPACE} ${OCP_MAJOR_MINOR} ${STORAGE_CLASS} ${DAY2_WORKERS_COUNT}' \
    < "${WORKERS_MANIFEST}" \
    | oc --kubeconfig="${HUB_KUBECONFIG}" apply -f -

function count_ready_day2_workers() {
    oc --kubeconfig="${TENANT_KUBECONFIG}" get nodes -o json \
        | jq --arg prefix "${CLUSTER_NAME}-workers-" \
            '[.items[]
             | select(.metadata.name | startswith($prefix))
             | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))]
             | length'
}

deadline=$((SECONDS + DAY2_WORKERS_READY_TIMEOUT_MIN * 60))
while true; do
    ready_workers=$(count_ready_day2_workers)
    echo "Ready day-2 worker Nodes: ${ready_workers}/${DAY2_WORKERS_COUNT}"
    if (( ready_workers >= DAY2_WORKERS_COUNT )); then
        break
    fi
    if (( SECONDS >= deadline )); then
        echo "ERROR: timed out after ${DAY2_WORKERS_READY_TIMEOUT_MIN}m waiting for day-2 workers to become Ready" >&2
        oc --kubeconfig="${TENANT_KUBECONFIG}" get nodes -o wide >&2 || true
        exit 1
    fi
    sleep "${POLL_INTERVAL_SECONDS}"
done

masters_schedulable=$(oc --kubeconfig="${TENANT_KUBECONFIG}" \
    get schedulers.config.openshift.io/cluster -o jsonpath='{.spec.mastersSchedulable}')
if [ "${masters_schedulable}" != "false" ]; then
    echo "All day-2 workers are Ready; disabling scheduling on control-plane nodes"
    oc --kubeconfig="${TENANT_KUBECONFIG}" \
        patch schedulers.config.openshift.io/cluster --type=merge \
        -p '{"spec":{"mastersSchedulable":false}}'
fi

masters_schedulable=$(oc --kubeconfig="${TENANT_KUBECONFIG}" \
    get schedulers.config.openshift.io/cluster -o jsonpath='{.spec.mastersSchedulable}')
if [ "${masters_schedulable}" != "false" ]; then
    echo "ERROR: Scheduler did not report mastersSchedulable=false" >&2
    exit 1
fi

echo "Day-2 workers are Ready; tenant control-plane scheduling is disabled."
oc --kubeconfig="${TENANT_KUBECONFIG}" get nodes -o wide
