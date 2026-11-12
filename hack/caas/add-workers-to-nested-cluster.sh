#!/usr/bin/env bash
# Add the day-2 KubeVirt worker pool to an installed tenant cluster.
# The infra project-admin kubeconfig applies CAPI resources; the nested-cluster
# admin kubeconfig checks Node readiness and updates the nested-cluster
# Scheduler after all workers have joined, then smoke-checks ingress from
# outside the nested cluster. Masters remain schedulable if the worker
# readiness gate times out. The nested-cluster kubeconfig must be cluster-admin
# because Scheduler is cluster-scoped.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd)
# shellcheck disable=SC2034  # consumed by read_config (lib.sh)
CONFIG_FILE="${SCRIPT_DIR}/caas.yaml"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

NESTED_CLUSTER_NAME=$(read_config NESTED_CLUSTER_NAME)
TENANT_NAMESPACE=$(read_config TENANT_NAMESPACE)
ROOTDISK_STORAGE_CLASS=${ROOTDISK_STORAGE_CLASS:-$(read_config CSI_STORAGE_CLASS)}
DAY2_WORKERS_COUNT=$(read_config DAY2_WORKERS_COUNT)
DAY2_WORKERS_READY_TIMEOUT_MIN=$(read_config DAY2_WORKERS_READY_TIMEOUT_MIN)
WORKERS_MANIFEST=$(read_config WORKERS_MANIFEST)

ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/artifacts}
INFRA_PROJECT_ADMIN_KUBECONFIG=${INFRA_PROJECT_ADMIN_KUBECONFIG:-${ARTIFACT_DIR}/infra-project-admin-kubeconfig}
NESTED_CLUSTER_KUBECONFIG=${NESTED_CLUSTER_KUBECONFIG:-${ARTIFACT_DIR}/nested-cluster-kubeconfig}
case "${WORKERS_MANIFEST}" in
    /*) ;;
    *) WORKERS_MANIFEST="${REPO_DIR}/${WORKERS_MANIFEST}" ;;
esac
POLL_INTERVAL_SECONDS=${POLL_INTERVAL_SECONDS:-30}

for command in oc envsubst jq curl; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "ERROR: required command '${command}' was not found" >&2
        exit 1
    fi
done

if [ ! -f "${INFRA_PROJECT_ADMIN_KUBECONFIG}" ]; then
    echo "ERROR: infra project-admin kubeconfig not found at ${INFRA_PROJECT_ADMIN_KUBECONFIG}; set INFRA_PROJECT_ADMIN_KUBECONFIG or ARTIFACT_DIR" >&2
    exit 1
fi
if [ ! -f "${NESTED_CLUSTER_KUBECONFIG}" ]; then
    echo "ERROR: nested-cluster kubeconfig not found at ${NESTED_CLUSTER_KUBECONFIG}; set NESTED_CLUSTER_KUBECONFIG or ARTIFACT_DIR" >&2
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

# The Scheduler is cluster-scoped. Fail before creating workers if the nested
# cluster kubeconfig cannot make the final mastersSchedulable change.
can_patch_scheduler=$(oc --kubeconfig="${NESTED_CLUSTER_KUBECONFIG}" \
    auth can-i patch schedulers.config.openshift.io/cluster)
if [ "${can_patch_scheduler}" != "yes" ]; then
    echo "ERROR: nested-cluster kubeconfig must be authorized to patch schedulers.config.openshift.io/cluster" >&2
    exit 1
fi

OCP_VERSION=$(oc --kubeconfig="${NESTED_CLUSTER_KUBECONFIG}" get clusterversion version \
    -o jsonpath='{.status.desired.version}')
if [ -z "${OCP_VERSION}" ]; then
    echo "ERROR: could not read the nested-cluster OpenShift version" >&2
    exit 1
fi
OCP_MAJOR_MINOR=$(cut -d. -f1,2 <<<"${OCP_VERSION}")

GOLDEN_PVC="rhcos-golden-${OCP_MAJOR_MINOR}"
# Keep this preflight namespace-scoped: the infra credential is intentionally
# project-admin and should not need cluster-scoped StorageClass read access.
oc --kubeconfig="${INFRA_PROJECT_ADMIN_KUBECONFIG}" get pvc "${GOLDEN_PVC}" -n "${TENANT_NAMESPACE}" >/dev/null

echo "Applying ${WORKERS_MANIFEST} to infra project ${TENANT_NAMESPACE} for nested cluster ${NESTED_CLUSTER_NAME}"
echo "Tenant: ${TENANT_NAMESPACE}; OpenShift: ${OCP_VERSION}; workers: ${DAY2_WORKERS_COUNT}; storage: ${ROOTDISK_STORAGE_CLASS}"

export NESTED_CLUSTER_NAME TENANT_NAMESPACE OCP_MAJOR_MINOR ROOTDISK_STORAGE_CLASS DAY2_WORKERS_COUNT
# The format string is intentionally single-quoted for envsubst.
# shellcheck disable=SC2016
envsubst '${NESTED_CLUSTER_NAME} ${TENANT_NAMESPACE} ${OCP_MAJOR_MINOR} ${ROOTDISK_STORAGE_CLASS} ${DAY2_WORKERS_COUNT}' \
    < "${WORKERS_MANIFEST}" \
    | tee "${ARTIFACT_DIR}/applied-workers-manifest.yaml" \
    | oc --kubeconfig="${INFRA_PROJECT_ADMIN_KUBECONFIG}" apply -f -

function count_ready_day2_workers() {
    oc --kubeconfig="${NESTED_CLUSTER_KUBECONFIG}" get nodes -o json \
        | jq --arg prefix "${NESTED_CLUSTER_NAME}-workers-" \
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
        oc --kubeconfig="${NESTED_CLUSTER_KUBECONFIG}" get nodes -o wide >&2 || true
        exit 1
    fi
    sleep "${POLL_INTERVAL_SECONDS}"
done

masters_schedulable=$(oc --kubeconfig="${NESTED_CLUSTER_KUBECONFIG}" \
    get schedulers.config.openshift.io/cluster -o jsonpath='{.spec.mastersSchedulable}')
if [ "${masters_schedulable}" != "false" ]; then
    echo "All day-2 workers are Ready; disabling scheduling on control-plane nodes"
    oc --kubeconfig="${NESTED_CLUSTER_KUBECONFIG}" \
        patch schedulers.config.openshift.io/cluster --type=merge \
        -p '{"spec":{"mastersSchedulable":false}}'
fi

masters_schedulable=$(oc --kubeconfig="${NESTED_CLUSTER_KUBECONFIG}" \
    get schedulers.config.openshift.io/cluster -o jsonpath='{.spec.mastersSchedulable}')
if [ "${masters_schedulable}" != "false" ]; then
    echo "ERROR: Scheduler did not report mastersSchedulable=false" >&2
    exit 1
fi

echo "Day-2 workers are Ready; tenant control-plane scheduling is disabled."
oc --kubeconfig="${NESTED_CLUSTER_KUBECONFIG}" get nodes -o wide

echo "Smoke-checking tenant ingress after adding day-2 workers"
worker_smoke_namespace="test-workers"
tenant_oc=(oc --kubeconfig="${NESTED_CLUSTER_KUBECONFIG}")
"${tenant_oc[@]}" create namespace "${worker_smoke_namespace}" --dry-run=client -o yaml \
    | "${tenant_oc[@]}" apply -f -
"${tenant_oc[@]}" -n "${worker_smoke_namespace}" \
    new-app nginxinc/nginx-unprivileged:stable-alpine --name=nginx
"${tenant_oc[@]}" -n "${worker_smoke_namespace}" \
    rollout status deployment/nginx --timeout=5m
"${tenant_oc[@]}" -n "${worker_smoke_namespace}" \
    create route edge nginx-test --service=nginx
route_host=$("${tenant_oc[@]}" -n "${worker_smoke_namespace}" \
    get route nginx-test -o jsonpath='{.spec.host}')
smoke_check_route "https://${route_host}"
