#!/usr/bin/env bash
# Live-migrate the nested cluster's master VMIs (CAPK role label
# cluster.x-k8s.io/role=control-plane) and verify the nested cluster stays
# healthy: every Node keeps (or recovers) Ready state and the control plane
# settles (no degraded ClusterOperators, ClusterVersion not Failing). Bash
# port of origin's test/extended/kubevirt/migration.go. Keep conformance/CSI
# tests out of the nested cluster while this script runs.
#
# Env vars:
#   ARTIFACT_DIR, INFRA_PROJECT_ADMIN_KUBECONFIG, NESTED_CLUSTER_KUBECONFIG
#   (defaults under ARTIFACT_DIR). The infra kubeconfig must be allowed to
#   create VirtualMachineInstanceMigrations: cluster-admin, or a user with
#   kubevirt.io migration rights (the namespace 'admin' role is NOT enough).
# Tunables (env var, defaults in-script): MIGRATION_TIMEOUT_MIN,
#   NODE_READY_TIMEOUT_MIN, READINESS_STABLE_MIN, CO_SETTLED_TIMEOUT_MIN.
#   TENANT_NAMESPACE comes from caas.yaml (env var wins).
#   Poll interval: POLL_INTERVAL_SECONDS (env only).

set -euo pipefail

# shellcheck disable=SC2034  # consumed by read_config (lib.sh)
CONFIG_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/caas.yaml"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TENANT_NAMESPACE=$(read_config TENANT_NAMESPACE)
MIGRATION_TIMEOUT_MIN=${MIGRATION_TIMEOUT_MIN:-30}
NODE_READY_TIMEOUT_MIN=${NODE_READY_TIMEOUT_MIN:-5}
READINESS_STABLE_MIN=${READINESS_STABLE_MIN:-2}
CO_SETTLED_TIMEOUT_MIN=${CO_SETTLED_TIMEOUT_MIN:-10}

ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/artifacts}
INFRA_PROJECT_ADMIN_KUBECONFIG=${INFRA_PROJECT_ADMIN_KUBECONFIG:-${ARTIFACT_DIR}/infra-project-admin-kubeconfig}
NESTED_CLUSTER_KUBECONFIG=${NESTED_CLUSTER_KUBECONFIG:-${ARTIFACT_DIR}/nested-cluster-kubeconfig}
POLL=${POLL_INTERVAL_SECONDS:-5}
SELECTOR="cluster.x-k8s.io/role=control-plane"
infra_oc=(oc --kubeconfig "${INFRA_PROJECT_ADMIN_KUBECONFIG}")
nested_oc=(oc --kubeconfig "${NESTED_CLUSTER_KUBECONFIG}")
mkdir -p "${ARTIFACT_DIR}"

# Always dump state for the report, on success or failure.
trap '
    "${infra_oc[@]}" get vmi,virtualmachineinstancemigrations.kubevirt.io -n "${TENANT_NAMESPACE}" -o yaml >"${ARTIFACT_DIR}/live-migration-infra.yaml" 2>&1 || true
    "${infra_oc[@]}" get events -n "${TENANT_NAMESPACE}" --sort-by=.lastTimestamp >"${ARTIFACT_DIR}/live-migration-events.txt" 2>&1 || true
    "${nested_oc[@]}" get nodes -o wide >"${ARTIFACT_DIR}/live-migration-nested-nodes.txt" 2>&1 || true
    "${nested_oc[@]}" get clusteroperators >"${ARTIFACT_DIR}/live-migration-nested-clusteroperators.txt" 2>&1 || true
' EXIT

echo "=== Master live-migration test (namespace ${TENANT_NAMESPACE}) ==="
# shellcheck disable=SC2034  # consumed by nodes_ready (lib.sh)
NODE_COUNT=$("${nested_oc[@]}" get nodes -o json | jq '.items | length')
mapfile -t vmis < <("${infra_oc[@]}" get vmi -n "${TENANT_NAMESPACE}" -l "${SELECTOR}" -o name)
[ "${#vmis[@]}" -gt 0 ] || { echo "ERROR: no control-plane VMIs in ${TENANT_NAMESPACE}" >&2; exit 1; }

# Preflight: every master VMI LiveMigratable (never migrate otherwise) and
# every nested node Ready.
"${infra_oc[@]}" get vmi -n "${TENANT_NAMESPACE}" -l "${SELECTOR}" -o wide
for vmi in "${vmis[@]}"; do
    lm=$("${infra_oc[@]}" get "${vmi}" -n "${TENANT_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].status}' 2>/dev/null || true)
    [ "${lm}" = True ] || { echo "ERROR: ${vmi##*/} is not LiveMigratable (${lm:-no condition}); not migrating" >&2; exit 1; }
done
poll "${NODE_READY_TIMEOUT_MIN}" nodes_ready

# One VMIM per master VMI, all started before waiting on any of them.
vmims=()
for vmi in "${vmis[@]}"; do
    name=${vmi##*/}
    vmims+=("$("${infra_oc[@]}" create -n "${TENANT_NAMESPACE}" -o name -f <(printf 'apiVersion: kubevirt.io/v1\nkind: VirtualMachineInstanceMigration\nmetadata:\n  generateName: %s-\nspec:\n  vmiName: %s\n' "${name}" "${name}") | cut -d/ -f2)")
    echo "VMI ${name}: migrating (${vmims[-1]})"
done

for vmim in "${vmims[@]}"; do
    deadline=$((SECONDS + MIGRATION_TIMEOUT_MIN * 60))
    while :; do
        phase=$("${infra_oc[@]}" get vmim "${vmim}" -n "${TENANT_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        [ "${phase}" = Succeeded ] && { echo "VMIM ${vmim}: Succeeded"; break; }
        [ "${phase}" = Failed ] && { echo "ERROR: VMIM ${vmim} Failed" >&2; exit 1; }
        (( SECONDS < deadline )) || { echo "ERROR: VMIM ${vmim} not finished within ${MIGRATION_TIMEOUT_MIN}m (${phase:-no phase})" >&2; exit 1; }
        sleep "${POLL}"
    done
done

# Post-migration: nodes Ready again (Eventually), stay Ready (Consistently),
# then the control plane settles.
poll "${NODE_READY_TIMEOUT_MIN}" nodes_ready
deadline=$((SECONDS + READINESS_STABLE_MIN * 60))
while (( SECONDS < deadline )); do
    nodes_ready || { echo "ERROR: nested nodes lost readiness during the stability window" >&2; exit 1; }
    sleep "${POLL}"
done
poll "${CO_SETTLED_TIMEOUT_MIN}" cos_settled

wait_for_cluster_operators "${NESTED_CLUSTER_KUBECONFIG}"
echo "All migrations Succeeded, every nested node stayed Ready and the control plane settled."
"${infra_oc[@]}" get vmi -n "${TENANT_NAMESPACE}" -l "${SELECTOR}" -o wide
"${nested_oc[@]}" get nodes -o wide
