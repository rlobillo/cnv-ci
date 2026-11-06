#!/usr/bin/env bash
# Run the upstream kubevirt/csi-driver storage e2e suite against a nested
# (CAAS) cluster, fetching the upstream test-driver manifests verbatim.
#
# The test-driver YAMLs are downloaded from kubevirt/csi-driver at
# CSI_DRIVER_REF (default "main") so the tested capabilities stay in sync
# with the driver. The only on-the-fly adaptation is the StorageClass name:
# upstream deploys the tenant class as 'kubevirt' while the OCP operator
# names it TENANT_CSI_STORAGE_CLASS (default 'kubevirt-csi').
#
# Class-less VolumeSnapshots (upstream 'SnapshotClass: FromName') rely on the
# infra-side default VolumeSnapshotClass marked by create-nested-cluster.sh
# (CSI_SNAPSHOT_CLASS) — nothing to do here.
#
# Upstream drives the suite with vanilla e2e.test and ginkgo skips
# (hack/run-k8s-e2e.sh); the equivalent skips are applied by filtering the
# openshift-tests dry-run list:
#   - 'CSI Ephemeral-volume*'         (inline ephemeral volumes)
#   - 'SELinuxMountReadWriteOncePod*'
# A second pass with test-driver-rwx.yaml covers the RWX tests (RWX is
# block-only in the driver), focused on 'concurrently access the single
# volume from pods on different node' and skipping filesystem volmode
# patterns, like upstream.
#
# Usage:
#   run-kubevirt-csi-tests.sh [tenant-kubeconfig]
#
# The tenant kubeconfig defaults to ${ARTIFACT_DIR}/nested-cluster-kubeconfig
# as written by create-nested-cluster.sh.
#
# Optional env:
#   ARTIFACT_DIR             output dir for junit, test lists and fetched
#                            manifests (default: /tmp/artifacts)
#   CSI_DRIVER_REF           kubevirt/csi-driver git ref (default: main)
#   TENANT_CSI_STORAGE_CLASS tenant StorageClass patched into the manifests
#                            (default: kubevirt-csi)
#   SKIP_RWX_PASS            set to skip the RWX pass
#   LIST_ONLY                set to only build the test lists, not run them
#   MAX_PARALLEL_TESTS       tests running in parallel (default: 5). The suite
#                            default is 10, but the kubevirt-csi driver's infra
#                            clients run at client-go defaults (QPS 5/burst 10)
#                            and the per-attach polling (1s VMI polls for up to
#                            2m) saturates the token bucket at 10 parallel
#                            tests: FailedAttachVolume DeadlineExceeded
#   OPENSHIFT_TESTS          openshift-tests binary (default: from PATH)
set -euxo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
REPO_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd)

ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/artifacts}
CSI_DRIVER_REF=${CSI_DRIVER_REF:-main}
TENANT_CSI_STORAGE_CLASS=${TENANT_CSI_STORAGE_CLASS:-kubevirt-csi}
MAX_PARALLEL_TESTS=${MAX_PARALLEL_TESTS:-5}
OPENSHIFT_TESTS=${OPENSHIFT_TESTS:-openshift-tests}
OCP_CSI_MANIFEST="${REPO_DIR}/manifests/caas/kubevirt-csi-ocp.yaml"

TENANT_KUBECONFIG="${1:-${ARTIFACT_DIR}/nested-cluster-kubeconfig}"
mkdir -p "${ARTIFACT_DIR}"

if [ ! -f "${TENANT_KUBECONFIG}" ]; then
    echo "ERROR: tenant kubeconfig '${TENANT_KUBECONFIG}' not found — pass it as \$1 or run after create-nested-cluster.sh" >&2
    exit 1
fi

# Fail fast on the prerequisite the manifests are patched against.
oc --kubeconfig "${TENANT_KUBECONFIG}" get storageclass "${TENANT_CSI_STORAGE_CLASS}" > /dev/null

# Operators may still be rolling out right after installation, which the
# monitor tests flag as mass failures; let them settle first.
oc --kubeconfig "${TENANT_KUBECONFIG}" wait clusteroperator --all \
    --for=condition=Available --timeout=15m

# Fetch an upstream test-driver manifest into ARTIFACT_DIR, patching only
# the StorageClass name (upstream 'kubevirt' vs the OCP operator's name).
function fetch_test_driver() {
    local out="${ARTIFACT_DIR}/$1"
    curl -fsSL "https://raw.githubusercontent.com/kubevirt/csi-driver/${CSI_DRIVER_REF}/hack/$1" \
        | sed "s/^\( *\)FromExistingClassName: kubevirt$/\1FromExistingClassName: ${TENANT_CSI_STORAGE_CLASS}/" \
        > "${out}"
    grep -q "FromExistingClassName: ${TENANT_CSI_STORAGE_CLASS}" "${out}" || {
        echo "ERROR: $1 does not reference ${TENANT_CSI_STORAGE_CLASS} — upstream format change?" >&2
        exit 1
    }
    echo "Fetched ${out} (ref: ${CSI_DRIVER_REF})"
}

# Prints the dry-run test list (one quoted name per line) for a driver
# manifest; the second argument optionally loads an OCP-specific manifest.
function dry_run() {
    KUBECONFIG="${TENANT_KUBECONFIG}" \
    TEST_CSI_DRIVER_FILES="$1" \
    TEST_OCP_CSI_DRIVER_FILES="${2:-}" \
        "${OPENSHIFT_TESTS}" run openshift/csi --dry-run 2>/dev/null \
        | grep '^"'
}

fetch_test_driver test-driver.yaml

echo "=== Building the main test list ==="
dry_run "${ARTIFACT_DIR}/test-driver.yaml" "${OCP_CSI_MANIFEST}" \
    | grep -vE 'CSI Ephemeral-volume|SELinuxMountReadWriteOncePod' \
    > "${ARTIFACT_DIR}/csi-tests.txt" || true
[ -s "${ARTIFACT_DIR}/csi-tests.txt" ] || { echo "ERROR: empty main test list" >&2; exit 1; }
echo "Main pass: $(wc -l < "${ARTIFACT_DIR}/csi-tests.txt") tests"

MAIN_RC=0
if [ -z "${LIST_ONLY:-}" ]; then
    KUBECONFIG="${TENANT_KUBECONFIG}" \
    TEST_CSI_DRIVER_FILES="${ARTIFACT_DIR}/test-driver.yaml" \
    TEST_OCP_CSI_DRIVER_FILES="${OCP_CSI_MANIFEST}" \
        "${OPENSHIFT_TESTS}" run -f "${ARTIFACT_DIR}/csi-tests.txt" \
            --max-parallel-tests "${MAX_PARALLEL_TESTS}" \
            --junit-dir "${ARTIFACT_DIR}/junit-csi" || MAIN_RC=$?
fi

RWX_RC=0
if [ -z "${SKIP_RWX_PASS:-}" ]; then
    echo "=== Building the RWX test list ==="
    fetch_test_driver test-driver-rwx.yaml
    dry_run "${ARTIFACT_DIR}/test-driver-rwx.yaml" \
        | grep 'concurrently access the single volume from pods on different node' \
        | grep -vE 'CSI Ephemeral-volume|SELinuxMountReadWriteOncePod|\((xfs|filesystem volmode|ntfs|ext4)\)' \
        > "${ARTIFACT_DIR}/csi-rwx-tests.txt" || true
    if [ -s "${ARTIFACT_DIR}/csi-rwx-tests.txt" ]; then
        echo "RWX pass: $(wc -l < "${ARTIFACT_DIR}/csi-rwx-tests.txt") tests"
        if [ -z "${LIST_ONLY:-}" ]; then
            KUBECONFIG="${TENANT_KUBECONFIG}" \
            TEST_CSI_DRIVER_FILES="${ARTIFACT_DIR}/test-driver-rwx.yaml" \
                "${OPENSHIFT_TESTS}" run -f "${ARTIFACT_DIR}/csi-rwx-tests.txt" \
                    --max-parallel-tests "${MAX_PARALLEL_TESTS}" \
                    --junit-dir "${ARTIFACT_DIR}/junit-csi-rwx" || RWX_RC=$?
        fi
    else
        echo "WARNING: empty RWX test list — skipping the RWX pass (upstream focus pattern change?)" >&2
    fi
fi

echo "Main pass rc=${MAIN_RC} | RWX pass rc=${RWX_RC}"
[ "${MAIN_RC}" -eq 0 ] && [ "${RWX_RC}" -eq 0 ]
