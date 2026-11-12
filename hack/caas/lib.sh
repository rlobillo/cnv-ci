#!/usr/bin/env bash
# Shared helpers for the CAAS tenant scripts. Sourced, not executed; the
# sourcing script must define beforehand:
#   CONFIG_FILE - path to hack/caas/caas.yaml (read_config)
#   nested_oc   - oc invocation for the nested cluster, as an array
#   POLL        - poll interval, seconds (poll/nodes_ready/cos_settled)
#   NODE_COUNT  - number of nested nodes (nodes_ready)
# shellcheck disable=SC2154  # the contract above makes these "unassigned"

# Read a config key, with a same-named environment variable taking precedence.
read_config() {
    if [ -n "${!1:-}" ]; then printf '%s\n' "${!1}"
    else sed -n "s/^$1:[[:space:]]*//p" "${CONFIG_FILE}" | tr -d "\"'" | head -n1; fi
}

# Number of Ready nested nodes; 0 (retry) when the nested API is briefly
# unreachable (e.g. right after the masters migrated or rebooted).
ready_nodes() {
    "${nested_oc[@]}" get nodes -o json 2>/dev/null \
        | jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' || echo 0
}
nodes_ready() { [ "$(ready_nodes)" -eq "${NODE_COUNT}" ]; }

# No degraded ClusterOperators and the ClusterVersion not Failing; API errors
# retry (transient unreachability while the control plane settles).
cos_settled() {
    local operators failing
    operators=$("${nested_oc[@]}" get clusteroperators -o json 2>/dev/null) || return 1
    failing=$("${nested_oc[@]}" get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Failing")].status}' 2>/dev/null) || return 1
    [ -z "$(jq -r '[.items[] | select(any(.status.conditions[]?; .type == "Degraded" and .status == "True")) | .metadata.name] | join(",")' <<<"${operators}")" ] \
        && [ "${failing}" != True ]
}

# Smoke-check a nested cluster route. The route is reachable from outside via
# the infra cluster's wildcard passthrough route (port 443); use https:// and
# -k (the nested ingress uses a self-signed cert).
# Usage: smoke_check_route <url>
smoke_check_route() {
    local url="$1"
    echo "Checking route: ${url}"
    curl --fail --show-error --silent --insecure \
        --retry 12 --retry-delay 5 --retry-all-errors \
        --max-time 10 \
        "${url}"
}

# Wait for all ClusterOperators to be Available.
# Usage: wait_for_cluster_operators <kubeconfig> [timeout]
# timeout defaults to 15m.
wait_for_cluster_operators() {
    local kubeconfig="$1" timeout="${2:-15m}"
    echo "Waiting for all ClusterOperators to be Available (timeout: ${timeout})..."
    oc --kubeconfig "${kubeconfig}" wait clusteroperator --all \
        --for=condition=Available --timeout="${timeout}"
}

# Poll a predicate until it succeeds or the timeout (minutes) expires.
poll() {
    local deadline=$((SECONDS + $1 * 60)); shift
    until "$@"; do
        (( SECONDS < deadline )) || { echo "ERROR: timed out waiting for: $*" >&2; return 1; }
        sleep "${POLL}"
    done
}
