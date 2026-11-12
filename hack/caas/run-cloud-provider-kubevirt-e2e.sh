#!/usr/bin/env bash
# Run the upstream kubevirt/cloud-provider-kubevirt e2e suite against a CAAS
# nested (tenant) cluster.
#
# The suite creates a LoadBalancer Service in the tenant cluster, verifies that
# the KubeVirt CCM creates a corresponding Service in the infra cluster
# namespace, waits for an external IP assignment, then curls it.
#
# Usage:
#   run-cloud-provider-kubevirt-e2e.sh [tenant-kubeconfig]
#
# The tenant kubeconfig defaults to ${ARTIFACT_DIR}/nested-cluster-kubeconfig
# as written by create-nested-cluster.sh (the CAPI kubeconfig, port 443).
#
# Optional env:
#   ARTIFACT_DIR       output dir for the binary, logs, and JUnit XML
#                      (default: /tmp/artifacts)
#   CPK_REPO_REF       cloud-provider-kubevirt git ref to test against
#                      (default: main)
#   LB_IP_TIMEOUT_SEC  seconds to wait for the infra LB Service external IP
#                      (default: 120; upstream hardcodes 10s, too tight for
#                      Azure-backed infra clusters under load)
set -euxo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
# shellcheck disable=SC2034
CONFIG_FILE="${SCRIPT_DIR}/caas.yaml"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/artifacts}
CPK_REPO_REF=${CPK_REPO_REF:-v0.6.0}
LB_IP_TIMEOUT_SEC=${LB_IP_TIMEOUT_SEC:-120}

NESTED_CLUSTER_NAME=$(read_config NESTED_CLUSTER_NAME)
TENANT_NAMESPACE=$(read_config TENANT_NAMESPACE)

INFRA_PROJECT_ADMIN_KUBECONFIG=${INFRA_PROJECT_ADMIN_KUBECONFIG:-${ARTIFACT_DIR}/infra-project-admin-kubeconfig}
TENANT_KUBECONFIG="${1:-${ARTIFACT_DIR}/nested-cluster-kubeconfig}"
mkdir -p "${ARTIFACT_DIR}"

if [ ! -f "${INFRA_PROJECT_ADMIN_KUBECONFIG}" ]; then
    echo "ERROR: infra project-admin kubeconfig '${INFRA_PROJECT_ADMIN_KUBECONFIG}' not found — set INFRA_PROJECT_ADMIN_KUBECONFIG or ARTIFACT_DIR" >&2
    exit 1
fi
if [ ! -f "${TENANT_KUBECONFIG}" ]; then
    echo "ERROR: tenant kubeconfig '${TENANT_KUBECONFIG}' not found — pass it as \$1 or run after create-nested-cluster.sh" >&2
    exit 1
fi

# Clone cloud-provider-kubevirt. Reuse an existing clone in ARTIFACT_DIR when
# CPK_REPO_REF matches; re-clone otherwise (e.g. different ref on retry).
CPK_DIR="${ARTIFACT_DIR}/cloud-provider-kubevirt"
if [ -d "${CPK_DIR}/.git" ]; then
    CURRENT_REF=$(git -C "${CPK_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [ "${CURRENT_REF}" != "${CPK_REPO_REF}" ]; then
        rm -rf "${CPK_DIR}"
    fi
fi
if [ ! -d "${CPK_DIR}/.git" ]; then
    git clone --depth=1 \
        https://github.com/kubevirt/cloud-provider-kubevirt.git \
        --branch "${CPK_REPO_REF}" \
        "${CPK_DIR}" \
        2>/dev/null \
        || git clone --depth=1 \
            https://github.com/kubevirt/cloud-provider-kubevirt.git \
            "${CPK_DIR}"
fi

# The upstream suite waits only 10 s for the infra LB Service to get an
# external IP; Azure-backed infra clusters can take 30-60 s under load.
LB_TEST="${CPK_DIR}/test/e2e/cloud_provider_kubevirt/load_balancer_test.go"
LB_TIMEOUT_PATTERN='}, 10\*time\.Second, time\.Second)\.Should(HaveLen(1))'
grep -q "${LB_TIMEOUT_PATTERN}" "${LB_TEST}" \
    || { echo "ERROR: LB timeout pattern not found in ${LB_TEST} — upstream changed the test, update this script" >&2; exit 1; }
sed -i "s/${LB_TIMEOUT_PATTERN}/}, ${LB_IP_TIMEOUT_SEC}*time.Second, time.Second).Should(HaveLen(1))/" \
    "${LB_TEST}"

echo "Building e2e binary (ref: ${CPK_REPO_REF})..."
(cd "${CPK_DIR}" && go test ./test/e2e/cloud_provider_kubevirt/ -c -o bin/e2e.test)

echo "Running cloud-provider-kubevirt e2e suite"
echo "  infra kubeconfig : ${INFRA_PROJECT_ADMIN_KUBECONFIG}"
echo "  tenant kubeconfig: ${TENANT_KUBECONFIG}"
echo "  infra namespace  : ${TENANT_NAMESPACE}"

JUNIT_FILE="${ARTIFACT_DIR}/junit-cloud-provider-kubevirt.xml"
E2E_RC=0
# TENANT_CLUSTER_NAME controls the namespace where the curl Job runs in the
# infra cluster. Must be "default": OVN does not route service VIPs correctly
# for pods in the infra tenant namespace (caas-project). The LB service lookup
# is label-based across all namespaces, so this does not affect service discovery.
TENANT_CLUSTER_NAME="default" \
INFRA_KUBECONFIG="${INFRA_PROJECT_ADMIN_KUBECONFIG}" \
TENANT_KUBECONFIG="${TENANT_KUBECONFIG}" \
    "${CPK_DIR}/bin/e2e.test" \
        --ginkgo.v \
        --ginkgo.junit-report="${JUNIT_FILE}" \
    || E2E_RC=$?

echo "JUnit report: ${JUNIT_FILE}"
echo "Suite exit code: ${E2E_RC}"
exit "${E2E_RC}"
