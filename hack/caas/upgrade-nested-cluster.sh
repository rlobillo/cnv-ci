#!/usr/bin/env bash
# Upgrade the nested (tenant) cluster to the farthest published OpenShift
# release reachable through the CVO update graphs — or to UPGRADE_VERSION
# when pinned. The CVO pulls and verifies the release payload itself
# (graph-validated 'oc adm upgrade --to'), so no image/digest handling is
# needed, unlike the openshift-ir-plugin "upgrade" Ansible role this
# replaces (which upgrades to unreleased CI payloads).
#
# Flow:
#   1. preflight: every nested node Ready, control plane settled
#   2. resolve the target:
#        - UPGRADE_VERSION set: use it (channel: UPGRADE_CHANNEL, default
#          fast-<major.minor>)
#        - otherwise: fetch the update graph of every channel the CVO knows,
#          compute the versions reachable from the current one and pick the
#          farthest (ties: prefer the current channel, then stable > fast >
#          eus > candidate)
#   3. optional handholding: UPGRADE_ADMIN_ACKS="key=value ..." entries
#      merged into openshift-config/admin-acks
#   4. oc adm upgrade channel <channel> && oc adm upgrade --to <version>
#      (requires the OACP upgradePolicy Unrestricted — nested-cluster.yaml
#      creates it that way; CAPOA's Managed default would revert the
#      upgrade)
#   5. wait for the rollout (ClusterVersion at the target version, not
#      Progressing, not Failing — failing fast when the CVO gives up), then
#      every node Ready again and the control plane settled
#   6. acknowledge the upgrade on the OACP (spec.distributionVersion = the
#      target, as the controller's VersionDriftDetected message requests)
#      and verify it settled: status.distributionVersion = target and
#      UpgradeCompleted=True (CAPOA syncs status from the nested
#      ClusterVersion on its own; the spec update is the designed
#      acknowledgment that clears the drift)
#
# Scope: this script exercises ONLY the external upgrade path — upgrading
# the nested cluster from within (oc adm upgrade) under
# upgradePolicy: Unrestricted. CAPOA also supports the hub-driven Managed
# flow — update OACP spec.distributionVersion and let the controller drive
# the rollout on the nested cluster (actively reverting any external
# attempt meanwhile) — which is OUT OF SCOPE here and NOT covered by this
# script. The spec.distributionVersion update this script performs after
# the rollout is only the drift acknowledgment, not a hub-driven upgrade.
#
# On exit (success or failure) the nested-cluster state and the OACP are
# collected into ARTIFACT_DIR.
#
# Env vars:
#   ARTIFACT_DIR, NESTED_CLUSTER_KUBECONFIG, INFRA_PROJECT_ADMIN_KUBECONFIG
#   (defaults under ARTIFACT_DIR)
# Tunables (env var, defaults in-script): UPGRADE_VERSION, UPGRADE_CHANNEL,
#   UPGRADE_ADMIN_ACKS, UPGRADE_TIMEOUT_MIN, UPGRADE_SETTLE_TIMEOUT_MIN.
#   NESTED_CLUSTER_NAME and TENANT_NAMESPACE come from caas.yaml (env wins).
#   Poll interval: POLL_INTERVAL_SECONDS (env only).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # consumed by read_config (lib.sh)
CONFIG_FILE="${SCRIPT_DIR}/caas.yaml"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

UPGRADE_VERSION=${UPGRADE_VERSION:-}
UPGRADE_CHANNEL=${UPGRADE_CHANNEL:-}
UPGRADE_ADMIN_ACKS=${UPGRADE_ADMIN_ACKS:-}
UPGRADE_TIMEOUT_MIN=${UPGRADE_TIMEOUT_MIN:-180}
UPGRADE_SETTLE_TIMEOUT_MIN=${UPGRADE_SETTLE_TIMEOUT_MIN:-30}
NESTED_CLUSTER_NAME=$(read_config NESTED_CLUSTER_NAME)
TENANT_NAMESPACE=$(read_config TENANT_NAMESPACE)

ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/artifacts}
NESTED_CLUSTER_KUBECONFIG=${NESTED_CLUSTER_KUBECONFIG:-${ARTIFACT_DIR}/nested-cluster-kubeconfig}
INFRA_PROJECT_ADMIN_KUBECONFIG=${INFRA_PROJECT_ADMIN_KUBECONFIG:-${ARTIFACT_DIR}/infra-project-admin-kubeconfig}
POLL=${POLL_INTERVAL_SECONDS:-60}
GRAPH_API="https://api.openshift.com/api/upgrades_info/v1/graph"
nested_oc=(oc --kubeconfig "${NESTED_CLUSTER_KUBECONFIG}")
infra_oc=(oc --kubeconfig "${INFRA_PROJECT_ADMIN_KUBECONFIG}")
mkdir -p "${ARTIFACT_DIR}"

[ -f "${NESTED_CLUSTER_KUBECONFIG}" ] || { echo "ERROR: nested-cluster kubeconfig not found: ${NESTED_CLUSTER_KUBECONFIG}" >&2; exit 1; }
[ -f "${INFRA_PROJECT_ADMIN_KUBECONFIG}" ] || { echo "ERROR: infra project-admin kubeconfig not found: ${INFRA_PROJECT_ADMIN_KUBECONFIG}" >&2; exit 1; }
[ -n "${NESTED_CLUSTER_NAME}" ] || { echo "ERROR: NESTED_CLUSTER_NAME is not set and was not found in ${CONFIG_FILE}" >&2; exit 1; }
[ -n "${TENANT_NAMESPACE}" ] || { echo "ERROR: TENANT_NAMESPACE is not set and was not found in ${CONFIG_FILE}" >&2; exit 1; }

# Always dump state for the report, on success or failure.
trap '
    "${nested_oc[@]}" get clusterversion version -o yaml >"${ARTIFACT_DIR}/upgrade-clusterversion.yaml" 2>&1 || true
    "${nested_oc[@]}" get clusteroperators >"${ARTIFACT_DIR}/upgrade-clusteroperators.txt" 2>&1 || true
    "${nested_oc[@]}" get nodes -o wide >"${ARTIFACT_DIR}/upgrade-nodes.txt" 2>&1 || true
    "${nested_oc[@]}" get machineconfigpools >"${ARTIFACT_DIR}/upgrade-machineconfigpools.txt" 2>&1 || true
    "${nested_oc[@]}" get events -A --sort-by=.lastTimestamp >"${ARTIFACT_DIR}/upgrade-events.txt" 2>&1 || true
    "${infra_oc[@]}" get openshiftassistedcontrolplane "${NESTED_CLUSTER_NAME}" -n "${TENANT_NAMESPACE}" -o yaml >"${ARTIFACT_DIR}/upgrade-oacp.yaml" 2>&1 || true
' EXIT

# ClusterVersion condition status ("" when the API is unreachable).
cv() { "${nested_oc[@]}" get clusterversion version -o jsonpath="{.status.conditions[?(@.type==\"$1\")].status}" 2>/dev/null || true; }

# The rollout is complete: the CVO reports the target version and is
# neither Progressing nor Failing.
upgrade_done() {
    [ "$("${nested_oc[@]}" get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)" = "${TARGET_VERSION}" ] \
        && [ "$(cv Progressing)" = False ] && [ "$(cv Failing)" = False ]
}

# Returns 0 if version $1 > $2.
version_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]; }

# Channels the CVO knows about (not exposed as a status field).
available_channels() {
    "${nested_oc[@]}" adm upgrade 2>/dev/null | grep -oE 'available channels: [^)]+' | cut -d: -f2- | tr , ' '
}

# Every version reachable from $2 in the update graph of channel $1
# (transitive closure over the unconditional .edges; conditional edges are
# not followed). Empty when the graph is unreachable or does not contain $2.
reachable() {
    local edges reached changed a b
    edges=$(curl -fsSL "${GRAPH_API}?channel=$1" \
        | jq -r '.nodes as $n | .edges[] | "\($n[.[0]].version) \($n[.[1]].version)"') || return 0
    reached=" $2 "
    changed=1
    while (( changed )); do
        changed=0
        while read -r a b; do
            if [[ "${reached}" == *" ${a} "* && "${reached}" != *" ${b} "* ]]; then
                reached+="${b} "
                changed=1
            fi
        done <<< "${edges}"
    done
    # shellcheck disable=SC2086
    printf '%s\n' ${reached} | grep -vx "$2" || true
}

# Channel preference when the same farthest version is reachable in several
# channels: keep the current channel, then stable > fast > eus > candidate.
channel_rank() {
    case "$1" in
        "${CURRENT_CHANNEL}") echo 0 ;;
        stable-*) echo 1 ;;
        fast-*) echo 2 ;;
        eus-*) echo 3 ;;
        *) echo 4 ;;
    esac
}

# Sets TARGET_VERSION/TARGET_CHANNEL to the farthest reachable version.
discover_target() {
    local channel max rank
    TARGET_VERSION="" TARGET_CHANNEL="" rank_best=99
    # shellcheck disable=SC2046
    for channel in $(available_channels); do
        max=$(reachable "${channel}" "${CURRENT_VERSION}" | sort -V | tail -n1)
        [ -n "${max}" ] || continue
        rank=$(channel_rank "${channel}")
        if [ -z "${TARGET_VERSION}" ] || version_gt "${max}" "${TARGET_VERSION}" \
            || { [ "${max}" = "${TARGET_VERSION}" ] && [ "${rank}" -lt "${rank_best}" ]; }; then
            TARGET_VERSION="${max}" TARGET_CHANNEL="${channel}" rank_best="${rank}"
        fi
    done
}

echo "=== Nested-cluster upgrade ==="
CURRENT_VERSION=$("${nested_oc[@]}" get clusterversion version -o jsonpath='{.status.desired.version}')
CURRENT_CHANNEL=$("${nested_oc[@]}" get clusterversion version -o jsonpath='{.spec.channel}')
# shellcheck disable=SC2034  # consumed by nodes_ready (lib.sh)
NODE_COUNT=$("${nested_oc[@]}" get nodes -o json | jq '.items | length')

# Preflight: healthy, idle and every node Ready.
[ "$(cv Available)" = True ] && [ "$(cv Progressing)" = False ] && [ "$(cv Failing)" = False ] \
    || { echo "ERROR: the nested cluster is not healthy (Available/Progressing/Failing != True/False/False)" >&2; "${nested_oc[@]}" get clusterversion version >&2; exit 1; }
nodes_ready || { echo "ERROR: not every nested node is Ready" >&2; "${nested_oc[@]}" get nodes >&2; exit 1; }
cos_settled || { echo "ERROR: the control plane is not settled" >&2; "${nested_oc[@]}" get clusteroperators >&2; exit 1; }

# CAPOA's Managed upgradePolicy would actively revert the external upgrade;
# nested-cluster.yaml creates the OACP as Unrestricted.
[ "$("${infra_oc[@]}" get openshiftassistedcontrolplane "${NESTED_CLUSTER_NAME}" \
    -n "${TENANT_NAMESPACE}" -o jsonpath='{.spec.upgradePolicy}' 2>/dev/null)" = Unrestricted ] \
    || { echo "ERROR: OACP upgradePolicy is not Unrestricted — CAPOA would revert the upgrade" >&2
         echo "       (patch it: oc patch oacp ${NESTED_CLUSTER_NAME} -n ${TENANT_NAMESPACE} --type merge -p '{\"spec\":{\"upgradePolicy\":\"Unrestricted\"}}', or recreate the cluster with the current nested-cluster.yaml)" >&2
         exit 1; }

# Resolve the target: pinned version or farthest reachable.
if [ -n "${UPGRADE_VERSION}" ]; then
    TARGET_VERSION="${UPGRADE_VERSION}"
    TARGET_CHANNEL=${UPGRADE_CHANNEL:-fast-$(echo "${UPGRADE_VERSION}" | cut -d. -f1,2)}
else
    discover_target
    if [ -z "${TARGET_VERSION}" ]; then
        echo "No updates available: ${CURRENT_VERSION} is already the farthest reachable version"
        exit 0
    fi
fi

# Optional handholding: admin acks.
if [ -n "${UPGRADE_ADMIN_ACKS}" ]; then
    echo "Applying admin acks: ${UPGRADE_ADMIN_ACKS}"
    "${nested_oc[@]}" -n openshift-config get cm admin-acks &>/dev/null \
        || "${nested_oc[@]}" -n openshift-config create cm admin-acks
    for ack in ${UPGRADE_ADMIN_ACKS}; do
        "${nested_oc[@]}" -n openshift-config patch cm admin-acks --type merge \
            -p "{\"data\":{\"${ack%%=*}\":\"${ack#*=}\"}}"
    done
fi

# Pre-upgrade ingress baseline: ensure the nginx route exists before starting
# the upgrade so we can verify it survives the rollout.
pre_route_host=$("${nested_oc[@]}" -n test get route nginx-test \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [ -z "${pre_route_host}" ]; then
    "${nested_oc[@]}" create namespace test --dry-run=client -o yaml | "${nested_oc[@]}" apply -f -
    "${nested_oc[@]}" -n test new-app nginxinc/nginx-unprivileged:stable-alpine --name=nginx 2>/dev/null || true
    "${nested_oc[@]}" -n test rollout status deployment/nginx --timeout=5m
    "${nested_oc[@]}" -n test create route edge nginx-test --service=nginx
    pre_route_host=$("${nested_oc[@]}" -n test get route nginx-test -o jsonpath='{.spec.host}')
fi
echo "=== Pre-upgrade ingress check ==="
smoke_check_route "https://${pre_route_host}"

echo "Upgrading FROM '${CURRENT_VERSION}' TO '${TARGET_VERSION}' via channel ${TARGET_CHANNEL}"
start=$SECONDS
"${nested_oc[@]}" adm upgrade channel "${TARGET_CHANNEL}"
# The CVO fetches the new channel's graph asynchronously; poll until the
# target appears in availableUpdates before issuing --to (empirically seen
# to take up to ~60s in CI even when the edge exists in the graph).
cvo_advertises_target() { "${nested_oc[@]}" adm upgrade 2>/dev/null | grep -q "${TARGET_VERSION}"; }
echo "Waiting for CVO to advertise ${TARGET_VERSION} as available..."
poll 2 cvo_advertises_target
"${nested_oc[@]}" adm upgrade --to "${TARGET_VERSION}"

# Rollout: poll upgrade_done, printing the ClusterVersion status and failing
# fast when the CVO gives up (persistent Failing=True).
deadline=$(( SECONDS + UPGRADE_TIMEOUT_MIN * 60 ))
failing=0
until upgrade_done; do
    echo "  [$(date -u +%H:%M:%S)] $("${nested_oc[@]}" get clusterversion version -o jsonpath='{.status.desired.version} (Progressing={.status.conditions[?(@.type=="Progressing")].status} Failing={.status.conditions[?(@.type=="Failing")].status})' 2>/dev/null || true)"
    [ "$(cv Failing)" = True ] && failing=$(( failing + 1 )) || failing=0
    if [ "${failing}" -ge 3 ]; then
        echo "ERROR: the ClusterVersion keeps Failing — the upgrade is not going to complete" >&2
        "${nested_oc[@]}" get clusterversion version -o yaml >&2 || true
        exit 1
    fi
    (( SECONDS < deadline )) || { echo "ERROR: the upgrade did not complete within ${UPGRADE_TIMEOUT_MIN}m" >&2; exit 1; }
    sleep "${POLL}"
done

# Post-rollout: every node Ready again, then the control plane settled.
poll "${UPGRADE_SETTLE_TIMEOUT_MIN}" nodes_ready
poll "${UPGRADE_SETTLE_TIMEOUT_MIN}" cos_settled

# Acknowledge the upgrade on the OACP: CAPOA syncs status.distributionVersion
# from the nested ClusterVersion on its own, but an external upgrade leaves
# UpgradeCompleted=False (VersionDriftDetected) until spec.distributionVersion
# is updated — the controller's drift message asks exactly for that. CAPOA
# reconciles the acknowledgment asynchronously: poll until the OACP reports
# the target version with UpgradeCompleted=True.
"${infra_oc[@]}" patch openshiftassistedcontrolplane "${NESTED_CLUSTER_NAME}" \
    -n "${TENANT_NAMESPACE}" --type merge \
    -p "{\"spec\":{\"distributionVersion\":\"${TARGET_VERSION}\"}}"

oacp_at_target() {
    local oacp_json
    oacp_json=$("${infra_oc[@]}" get openshiftassistedcontrolplane "${NESTED_CLUSTER_NAME}" \
        -n "${TENANT_NAMESPACE}" -o json 2>/dev/null) || return 1
    [ "$(jq -r '.status.distributionVersion // ""' <<<"${oacp_json}")" = "${TARGET_VERSION}" ] \
        && jq -e '.status.conditions[]?
              | select(.type == "UpgradeCompleted" and .status == "True")' \
              <<<"${oacp_json}" >/dev/null
}
poll "${UPGRADE_SETTLE_TIMEOUT_MIN}" oacp_at_target
echo "Infra side verified: OACP status at ${TARGET_VERSION}, UpgradeCompleted=True"
wait_for_cluster_operators "${NESTED_CLUSTER_KUBECONFIG}"

echo "Cluster successfully upgraded from '${CURRENT_VERSION}' to '${TARGET_VERSION}' in $(( (SECONDS - start) / 60 )) minutes"
"${nested_oc[@]}" get clusterversion version
"${nested_oc[@]}" get nodes

# Post-upgrade ingress check: the route must still exist and serve after the upgrade.
post_route_host=$("${nested_oc[@]}" -n test get route nginx-test \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)
[ -n "${post_route_host}" ] || { echo "ERROR: nginx-test route missing after upgrade" >&2; exit 1; }
echo "=== Post-upgrade ingress check ==="
smoke_check_route "https://${post_route_host}"
