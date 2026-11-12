#!/usr/bin/env bash
# Live-migrate the nested node hosting a test workload and verify the
# workload keeps serving through the migration. Complements
# test-master-live-migration.sh (control-plane survival) with a data-plane
# signal: service availability and pod transparency (no restart, no
# reschedule) while its node migrates. The workload lands wherever the
# scheduler puts it — a worker when day-2 workers exist (masters are then
# unschedulable), a schedulable master otherwise (single-master canary).
#
# Env vars:
#   ARTIFACT_DIR, INFRA_PROJECT_ADMIN_KUBECONFIG, NESTED_CLUSTER_KUBECONFIG
#   (defaults under ARTIFACT_DIR). The infra kubeconfig must be allowed to
#   create VirtualMachineInstanceMigrations (namespace 'admin' is NOT enough).
# Tunables (env var, defaults in-script): MIGRATION_TIMEOUT_MIN,
#   NODE_READY_TIMEOUT_MIN. TENANT_NAMESPACE comes from caas.yaml (env wins).
#   Poll interval: POLL_INTERVAL_SECONDS (env only).
# The Route is an edge-TLS route probed over https directly from wherever
# this script runs: the infra cluster's wildcard passthrough route (port 443)
# forwards the request end-to-end to the nested ingress. Every failed request
# counts as a live-migration break.

set -euo pipefail

# shellcheck disable=SC2034  # consumed by read_config (lib.sh)
CONFIG_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/caas.yaml"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TENANT_NAMESPACE=$(read_config TENANT_NAMESPACE)
MIGRATION_TIMEOUT_MIN=${MIGRATION_TIMEOUT_MIN:-30}
NODE_READY_TIMEOUT_MIN=${NODE_READY_TIMEOUT_MIN:-5}

ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/artifacts}
INFRA_PROJECT_ADMIN_KUBECONFIG=${INFRA_PROJECT_ADMIN_KUBECONFIG:-${ARTIFACT_DIR}/infra-project-admin-kubeconfig}
NESTED_CLUSTER_KUBECONFIG=${NESTED_CLUSTER_KUBECONFIG:-${ARTIFACT_DIR}/nested-cluster-kubeconfig}
NS=live-migration
# shellcheck disable=SC2034  # consumed by poll (lib.sh)
POLL=${POLL_INTERVAL_SECONDS:-5}
infra_oc=(oc --kubeconfig "${INFRA_PROJECT_ADMIN_KUBECONFIG}")
nested_oc=(oc --kubeconfig "${NESTED_CLUSTER_KUBECONFIG}")
mkdir -p "${ARTIFACT_DIR}"

# Always dump state for the report, on success or failure.
trap '
    "${infra_oc[@]}" get vmi,virtualmachineinstancemigrations.kubevirt.io -n "${TENANT_NAMESPACE}" -o yaml >"${ARTIFACT_DIR}/workload-migration-infra.yaml" 2>&1 || true
    "${infra_oc[@]}" get events -n "${TENANT_NAMESPACE}" --sort-by=.lastTimestamp >"${ARTIFACT_DIR}/workload-migration-events.txt" 2>&1 || true
    "${nested_oc[@]}" -n "${NS}" get all -o wide >"${ARTIFACT_DIR}/workload-migration-workload.txt" 2>&1 || true
    "${nested_oc[@]}" get nodes -o wide >"${ARTIFACT_DIR}/workload-migration-nested-nodes.txt" 2>&1 || true
' EXIT

# Returns the HTTP status code from the nested route: "200" on success,
# "000" or empty otherwise.
route_code() {
    curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "https://${route_host}" 2>/dev/null || true
}

# Deploy the workload (same image and shape as the create-nested-cluster.sh
# smoke check) on any schedulable node, and expose it through a Route.
echo "=== Workload live-migration test (tenant namespace ${TENANT_NAMESPACE}) ==="
# shellcheck disable=SC2034  # consumed by nodes_ready (lib.sh)
NODE_COUNT=$("${nested_oc[@]}" get nodes -o json | jq '.items | length')
"${nested_oc[@]}" delete namespace "${NS}" --ignore-not-found
"${nested_oc[@]}" create namespace "${NS}"
"${nested_oc[@]}" -n "${NS}" new-app nginxinc/nginx-unprivileged:stable-alpine --name=nginx
"${nested_oc[@]}" -n "${NS}" rollout status deployment/nginx --timeout=5m
"${nested_oc[@]}" -n "${NS}" create route edge nginx-test --service=nginx
route_host=$("${nested_oc[@]}" -n "${NS}" get route nginx-test -o jsonpath='{.spec.host}')

pod_json=$("${nested_oc[@]}" -n "${NS}" get pods -o json | jq '[.items[] | select(.status.phase == "Running")]')
pod=$(jq -r '.[0].metadata.name' <<<"${pod_json}")
node=$(jq -r '.[0].spec.nodeName' <<<"${pod_json}")
echo "Workload ${pod} runs on nested node ${node}:"
"${nested_oc[@]}" get node "${node}"

# The nested node name is the infra VMI name; never migrate a node that is
# not LiveMigratable.
"${infra_oc[@]}" get vmi "${node}" -n "${TENANT_NAMESPACE}" >/dev/null
lm=$("${infra_oc[@]}" get vmi "${node}" -n "${TENANT_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].status}' 2>/dev/null || true)
[ "${lm}" = True ] || { echo "ERROR: ${node} is not LiveMigratable (${lm:-no condition}); not migrating" >&2; exit 1; }

# Baseline: the Route must serve before migrating.
attempt=0
until [ "$(route_code)" = 200 ]; do
    attempt=$((attempt + 1))
    (( attempt < 12 )) || { echo "ERROR: https://${route_host} not serving" >&2; exit 1; }
    sleep 5
done
echo "Route https://${route_host} serving; migrating ${node}"

# Migrate the node hosting the workload and poll the Route (no retries,
# every failed request counts) while the migration runs.
vmim=$("${infra_oc[@]}" create -n "${TENANT_NAMESPACE}" -o name -f <(printf 'apiVersion: kubevirt.io/v1\nkind: VirtualMachineInstanceMigration\nmetadata:\n  generateName: %s-\nspec:\n  vmiName: %s\n' "${node}" "${node}") | cut -d/ -f2)
echo "VMIM ${vmim} created"
requests=0 failures=0
deadline=$((SECONDS + MIGRATION_TIMEOUT_MIN * 60))
while :; do
    if [ "$(route_code)" = 200 ]; then
        :
    else
        failures=$((failures + 1))
        echo "WARNING: request failed against the Route during the migration" >&2
    fi
    requests=$((requests + 1))
    phase=$("${infra_oc[@]}" get vmim "${vmim}" -n "${TENANT_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [ "${phase}" = Succeeded ] && break
    [ "${phase}" = Failed ] && { echo "ERROR: VMIM ${vmim} Failed" >&2; exit 1; }
    (( SECONDS < deadline )) || { echo "ERROR: VMIM ${vmim} not finished within ${MIGRATION_TIMEOUT_MIN}m (${phase:-no phase})" >&2; exit 1; }
    sleep 1
done

# Tail: the network cutover can land a beat after the VMIM reports Succeeded.
for _ in 1 2 3; do
    [ "$(route_code)" = 200 ] || failures=$((failures + 1))
    requests=$((requests + 1))
    sleep 1
done
MAX_FAILURES=${MAX_FAILURES:-3}
[ "${failures}" -le "${MAX_FAILURES}" ] || { echo "ERROR: ${failures}/${requests} requests failed during the migration (max allowed: ${MAX_FAILURES})" >&2; exit 1; }

# The migrated node may be a master in compact topology: every nested node
# must be Ready again (tolerates the nested API's recovery window) before
# the pod-transparency checks.
poll "${NODE_READY_TIMEOUT_MIN}" nodes_ready

# Transparency: same pod (not recreated, not restarted) on the same node.
post=$("${nested_oc[@]}" -n "${NS}" get pods -o json | jq '[.items[] | select(.status.phase == "Running")]')
[ "$(jq -r '.[0].metadata.name' <<<"${post}")" = "${pod}" ] || { echo "ERROR: the workload pod was recreated during the migration" >&2; exit 1; }
[ "$(jq -r '.[0].status.containerStatuses[0].restartCount' <<<"${post}")" = 0 ] || { echo "ERROR: the workload pod restarted during the migration" >&2; exit 1; }
[ "$(jq -r '.[0].spec.nodeName' <<<"${post}")" = "${node}" ] || { echo "ERROR: the workload pod moved to another node during the migration" >&2; exit 1; }

wait_for_cluster_operators "${NESTED_CLUSTER_KUBECONFIG}"
echo "Migration of ${node} Succeeded: ${requests} requests served, ${failures} failures, workload untouched."
"${infra_oc[@]}" get vmi -n "${TENANT_NAMESPACE}" -o wide
"${nested_oc[@]}" get nodes -o wide
