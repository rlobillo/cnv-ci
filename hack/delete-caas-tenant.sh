#!/usr/bin/env bash
# Delete a CAAS tenant cluster and verify that the hub cleaned up after it.
#
# Deleting the tenant namespace alone is not enough. Guests that hang (e.g.
# when the hub storage pool goes full) leave kernel RBD clients (krbd)
# mapped with a leaked open_count; the CSI plugin then cannot delete the
# backing RBD images and the pool fills up across runs. No component in the
# stack owns the reclamation of images whose PV is already gone — so this
# script makes the outcome explicit: either everything is reclaimed, or it
# exits non-zero with a list of what was left behind.
#
# Default behaviour (safe — no ODF data is modified):
#   1. Capture the tenant PV volume handles (before anything is deleted).
#   2. Delete the tenant VMs and namespace, force-delete leftover pods and
#      strip the finalizers that block namespace termination (Agent,
#      InfraEnv, AgentClusterInstall, OACP, MachineDeployment,
#      KubevirtCluster, Cluster).
#   3. Wait for the namespace and the tenant PVs to disappear.
#   4. Force-unmap stale krbd devices backing the tenant images (sysfs
#      remove_single_major with "force" — this is node-kernel state, not an
#      ODF operation; it is what unblocks the CSI to finish the deletion).
#   5. Give the CSI time to reclaim the tenant images (DeleteVolume).
#   6. VERIFY (read-only): no tenant image remains in the pool AND no
#      orphaned csi-vol-*/csi-snap-* image exists without a live PV or
#      VolumeSnapshotContent backing it. Anything left → exit 1.
#
# Requires: oc with cluster-admin access to the hub cluster. A ceph toolbox
# is needed for steps 5-6: a ready rook-ceph-tools pod is reused if
# present, otherwise a temporary toolbox pod is created from the
# rook-ceph-admin-keyring secret and deleted on exit. The toolbox is used
# read-only — the script never modifies ODF data.
#
# Optional env vars (defaults from hack/caas.yaml, env var wins):
#   TENANT_NAMESPACE, ODF_NAMESPACE, RBD_POOL, CEPH_TOOLBOX_IMAGE,
#   NAMESPACE_DELETE_TIMEOUT_MIN, PV_DELETE_TIMEOUT_MIN,
#   RBD_RECLAIM_TIMEOUT_MIN

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
ODF_NAMESPACE=$(read_config ODF_NAMESPACE)
RBD_POOL=$(read_config RBD_POOL)
CEPH_TOOLBOX_IMAGE=$(read_config CEPH_TOOLBOX_IMAGE)
NAMESPACE_DELETE_TIMEOUT_MIN=$(read_config NAMESPACE_DELETE_TIMEOUT_MIN)
PV_DELETE_TIMEOUT_MIN=$(read_config PV_DELETE_TIMEOUT_MIN)
RBD_RECLAIM_TIMEOUT_MIN=$(read_config RBD_RECLAIM_TIMEOUT_MIN)

for _key in TENANT_NAMESPACE ODF_NAMESPACE RBD_POOL \
    NAMESPACE_DELETE_TIMEOUT_MIN PV_DELETE_TIMEOUT_MIN RBD_RECLAIM_TIMEOUT_MIN; do
    if [ -z "${!_key}" ]; then
        echo "ERROR: ${_key} is not set and was not found in ${CONFIG_FILE}" >&2
        exit 1
    fi
done
unset _key

command -v oc &>/dev/null || { echo "ERROR: 'oc' client not found in PATH" >&2; exit 1; }

TOOLBOX_NAME="caas-cleanup-toolbox"
TOOLBOX_CREATED=false
WORK_DIR=$(mktemp -d)
ORPHANS=""

function teardown() {
    if [ "${TOOLBOX_CREATED}" = true ]; then
        oc delete pod "${TOOLBOX_NAME}" -n "${ODF_NAMESPACE}" \
            --ignore-not-found --wait=false &>/dev/null || true
    fi
    rm -rf "${WORK_DIR}"
}
trap teardown EXIT

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
# Step 1: capture tenant PV names and RBD volume handles
# ---------------------------------------------------------------------------
function capture_tenant_volumes() {
    echo "=== Capturing tenant PV volume handles ==="
    local ns_filter=".spec.claimRef.namespace==\"${TENANT_NAMESPACE}\""
    oc get pv -o jsonpath="{range .items[?(@${ns_filter})]}{.metadata.name}{\"\n\"}{end}" \
        2>/dev/null | grep -v '^$' > "${WORK_DIR}/tenant-pvs.txt" || true
    oc get pv -o jsonpath="{range .items[?(@${ns_filter})]}{.spec.csi.volumeHandle}{\"\n\"}{end}" \
        2>/dev/null | grep -v '^$' > "${WORK_DIR}/tenant-handles.txt" || true
    echo "Tenant PVs: $(wc -l < "${WORK_DIR}/tenant-pvs.txt") | volume handles: $(wc -l < "${WORK_DIR}/tenant-handles.txt")"
}

# ---------------------------------------------------------------------------
# Step 2: delete tenant VMs, namespace, pods and blocking finalizers
# ---------------------------------------------------------------------------
# Resources whose finalizers commonly block namespace termination. Leaf
# resources first, Cluster last (CAPI re-adds Cluster finalizers while its
# dependents are still alive).
STRIP_RESOURCES=(
    agents.agent-install.openshift.io
    infraenvs.agent-install.openshift.io
    agentclusterinstalls.extensions.hive.openshift.io
    openshiftassistedcontrolplanes.controlplane.cluster.x-k8s.io
    machinedeployments.cluster.x-k8s.io
    machines.cluster.x-k8s.io
    kubevirtmachines.infrastructure.cluster.x-k8s.io
    kubevirtmachinetemplates.infrastructure.cluster.x-k8s.io
    kubevirtclusters.infrastructure.cluster.x-k8s.io
    clusters.cluster.x-k8s.io
)

function strip_finalizers() {
    local pass res name stripped=false
    for pass in 1 2; do
        for res in "${STRIP_RESOURCES[@]}"; do
            while read -r name; do
                [ -z "${name}" ] && continue
                echo "  stripping finalizers: ${name}"
                oc patch "${name}" -n "${TENANT_NAMESPACE}" --type=merge \
                    -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
                stripped=true
            done < <(oc get "${res}" -n "${TENANT_NAMESPACE}" -o name 2>/dev/null || true)
        done
        [ "${stripped}" = false ] && break
        sleep 15
    done
}

function delete_tenant() {
    if ! oc get namespace "${TENANT_NAMESPACE}" &>/dev/null; then
        echo "=== Namespace ${TENANT_NAMESPACE} not found — nothing to delete ==="
        return 0
    fi

    echo "=== Deleting tenant VMs and namespace ==="
    oc delete vm -n "${TENANT_NAMESPACE}" --all --ignore-not-found --wait=false 2>/dev/null || true
    oc delete namespace "${TENANT_NAMESPACE}" --ignore-not-found --wait=false

    # Give controllers a chance to shut the guests down cleanly, then force.
    sleep 60

    echo "=== Force-deleting leftover pods ==="
    local pods
    pods=$(oc get pods -n "${TENANT_NAMESPACE}" --no-headers 2>/dev/null \
        | awk '$3 != "Completed" && $3 != "Succeeded" && $3 != "Failed" {print $1}' || true)
    local pod
    for pod in ${pods}; do
        echo "  force deleting pod ${pod}"
        oc delete pod "${pod}" -n "${TENANT_NAMESPACE}" \
            --grace-period=0 --force --ignore-not-found 2>/dev/null || true
    done

    echo "=== Stripping finalizers from CAPOA/CAPI resources ==="
    strip_finalizers

    echo "=== Waiting for namespace to disappear ==="
    if ! wait_until $(( NAMESPACE_DELETE_TIMEOUT_MIN * 60 )) "namespace deletion" \
        bash -c "! oc get namespace ${TENANT_NAMESPACE} &>/dev/null"; then
        echo "WARN: namespace ${TENANT_NAMESPACE} is still terminating. Resources still alive:"
        oc get "${STRIP_RESOURCES[@]}" -n "${TENANT_NAMESPACE}" --no-headers 2>/dev/null || true
        echo "WARN: continuing anyway"
    fi
}

# ---------------------------------------------------------------------------
# Step 3: wait for tenant PVs to disappear
# ---------------------------------------------------------------------------
function wait_tenant_pvs_gone() {
    echo "=== Waiting for tenant PVs to disappear ==="
    local pv
    while read -r pv; do
        [ -z "${pv}" ] && continue
        if ! wait_until $(( PV_DELETE_TIMEOUT_MIN * 60 )) "deletion of PV ${pv}" \
            bash -c "! oc get pv ${pv} &>/dev/null"; then
            echo "WARN: PV ${pv} still around — deleting it directly"
            oc delete pv "${pv}" --wait=false --ignore-not-found 2>/dev/null || true
        fi
    done < "${WORK_DIR}/tenant-pvs.txt"
}

# ---------------------------------------------------------------------------
# Step 4: force-unmap stale krbd devices (node kernel state, not ODF)
# ---------------------------------------------------------------------------
function unmap_stale_krbd() {
    local images="$1"
    [ -n "${images}" ] || return 0
    # Flatten to a single line: the list is inlined into a remote bash -c
    # script below and embedded newlines break its parsing.
    images=$(tr '\n' ' ' <<< "${images}")
    echo "=== Force-unmapping stale krbd devices ==="
    local node
    while read -r node; do
        [ -z "${node}" ] && continue
        node=${node#node/}
        oc debug "node/${node}" -- nsenter -t 1 -m -- bash -c "
            for d in /sys/bus/rbd/devices/*; do
                [ -e \"\$d\" ] || continue
                id=\${d##*/}
                name=\$(cat \"\$d/name\" 2>/dev/null) || continue
                for o in ${images}; do
                    if [ \"\$name\" = \"\$o\" ]; then
                        echo \"  ${node}: unmapping rbd\${id} (\${name})\"
                        if [ -e /sys/bus/rbd/remove_single_major ]; then
                            printf '%s force' \"\$id\" > /sys/bus/rbd/remove_single_major 2>/dev/null || true
                        else
                            printf '%s force' \"\$id\" > /sys/bus/rbd/remove 2>/dev/null || true
                        fi
                    fi
                done
            done
            echo \"  ${node}: remaining devices: \$(ls /sys/bus/rbd/devices/ 2>/dev/null | tr '\n' ' ')\"
        " 2>&1 | grep -vE "Starting pod|Pod IP|If you don't see|Removing debug|To use host" || true
    done < <(oc get nodes -o name 2>/dev/null || true)
}

# Handles of the tenant images, including possible CSI clone-in-progress
# volumes (csi-vol-<uuid>-temp).
function tenant_unmap_list() {
    awk '{print $1; print $1 "-temp"}' "${WORK_DIR}/tenant-handles.txt" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Ceph toolbox access (reuse rook-ceph-tools, else create a temporary pod)
# ---------------------------------------------------------------------------
function toolbox_cmd() {
    oc exec -n "${ODF_NAMESPACE}" "${TOOLBOX_NAME}" -- bash -c "$1"
}

function setup_toolbox() {
    local toolbox_pod
    toolbox_pod=$(oc get pods -n "${ODF_NAMESPACE}" -l app=rook-ceph-tools \
        -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null || true)
    if [ -n "${toolbox_pod}" ]; then
        echo "Reusing rook-ceph-tools pod: ${toolbox_pod}"
        TOOLBOX_NAME="${toolbox_pod}"
        TOOLBOX_CREATED=false
        return 0
    fi

    if ! oc get secret rook-ceph-admin-keyring -n "${ODF_NAMESPACE}" &>/dev/null; then
        echo "ERROR: no rook-ceph-tools pod and no rook-ceph-admin-keyring secret in ${ODF_NAMESPACE}" >&2
        return 1
    fi

    echo "Creating temporary ceph toolbox pod"
    # Reuse the exact image the ceph mons run when CEPH_TOOLBOX_IMAGE is not
    # set: it is guaranteed to be pullable on the hub. A digest pinned in the
    # config gets purged from the registry over time, leaving the pull
    # hanging forever without any error event.
    local toolbox_image="${CEPH_TOOLBOX_IMAGE}"
    if [ -z "${toolbox_image}" ]; then
        toolbox_image=$(oc get pods -n "${ODF_NAMESPACE}" -l app=rook-ceph-mon \
            -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)
    fi
    if [ -z "${toolbox_image}" ]; then
        echo "ERROR: could not determine a ceph toolbox image" >&2
        return 1
    fi
    echo "  toolbox image: ${toolbox_image}"
    oc delete pod "${TOOLBOX_NAME}" -n "${ODF_NAMESPACE}" \
        --ignore-not-found --wait=false &>/dev/null || true

    # ceph.conf pointing at the mon ClusterIPs (stable across pod restarts).
    local mon_hosts="" svc ip
    while read -r svc; do
        [ -z "${svc}" ] && continue
        ip=$(oc get svc "${svc}" -n "${ODF_NAMESPACE}" \
            -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
        [ -n "${ip}" ] && mon_hosts+="v2:${ip}:3300,"
    done < <(oc get svc -n "${ODF_NAMESPACE}" -o name 2>/dev/null \
        | sed 's|^service/||' | grep '^rook-ceph-mon-' || true)
    mon_hosts=${mon_hosts%,}
    if [ -z "${mon_hosts}" ]; then
        echo "ERROR: could not discover ceph mon services in ${ODF_NAMESPACE}" >&2
        return 1
    fi

    oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${TOOLBOX_NAME}
  namespace: ${ODF_NAMESPACE}
  labels:
    app: caas-cleanup-toolbox
spec:
  restartPolicy: Never
  containers:
  - name: toolbox
    image: ${toolbox_image}
    command: ["sleep", "7200"]
    volumeMounts:
    - name: admin-keyring
      mountPath: /etc/ceph/admin
  volumes:
  - name: admin-keyring
    secret:
      secretName: rook-ceph-admin-keyring
EOF
    TOOLBOX_CREATED=true
    # First pull of the rhceph toolbox image (~1.2 GiB) can take several
    # minutes on a fresh cluster — give it room before failing.
    oc wait pod "${TOOLBOX_NAME}" -n "${ODF_NAMESPACE}" \
        --for=condition=Ready --timeout=600s

    toolbox_cmd "printf '[global]\nmon_host = ${mon_hosts}\n[client.admin]\nkeyring = /etc/ceph/admin/keyring\n' > /etc/ceph/ceph.conf"
    toolbox_cmd "ceph -s" >/dev/null
}

# ---------------------------------------------------------------------------
# Step 5: wait for the CSI to reclaim the tenant images
# ---------------------------------------------------------------------------
function tenant_images_remaining() {
    local pool_images handle img remaining=""
    pool_images=$(toolbox_cmd "rbd ls -p ${RBD_POOL}" 2>/dev/null || true)
    while read -r handle; do
        [ -z "${handle}" ] && continue
        for img in ${pool_images}; do
            case "${img}" in
                "${handle}"|"${handle}-temp") remaining+=" ${img}" ;;
            esac
        done
    done < "${WORK_DIR}/tenant-handles.txt"
    echo "${remaining# }"
}

function wait_for_reclaim() {
    echo "=== Waiting for the CSI to reclaim the tenant images ==="
    local deadline=$(( $(date +%s) + RBD_RECLAIM_TIMEOUT_MIN * 60 ))
    while true; do
        local remaining
        remaining=$(tenant_images_remaining)
        if [ -z "${remaining}" ]; then
            echo "All tenant images reclaimed"
            return 0
        fi
        if [ "$(date +%s)" -ge "${deadline}" ]; then
            echo "WARN: tenant images still present after ${RBD_RECLAIM_TIMEOUT_MIN}m:${remaining}"
            return 1
        fi
        sleep 30
    done
}

# ---------------------------------------------------------------------------
# Step 6: verify the hub is clean (read-only) — the whole point of the
# script: if anything is left behind, fail loudly.
# ---------------------------------------------------------------------------
function detect_orphans() {
    # Volume handles backed by live PVs outside the tenant namespace — these
    # are in use by someone else and are never orphans.
    local protected
    protected=$(oc get pv -o json 2>/dev/null | python3 -c '
import sys, json
tenant = sys.argv[1]
for pv in json.load(sys.stdin).get("items", []):
    claim = (pv.get("spec", {}).get("claimRef") or {}).get("namespace")
    if claim == tenant:
        continue
    handle = (pv.get("spec", {}).get("csi") or {}).get("volumeHandle")
    if handle:
        print(handle)
' "${TENANT_NAMESPACE}" || true)

    # Snapshot handles backed by live VolumeSnapshotContents.
    local snaps
    snaps=$(oc get volumesnapshotcontent -A -o json \
        '{range .items[*]}{.status.snapshotHandle}{"\n"}{.spec.source.snapshotHandle}{"\n"}{end}' \
        2>/dev/null | grep '^csi-snap-' | sort -u || true)

    local images img base
    images=$(toolbox_cmd "rbd ls -p ${RBD_POOL}" 2>/dev/null || true)
    ORPHANS=""
    for img in ${images}; do
        case "${img}" in
            csi-vol-*-temp)
                # CSI clone-in-progress volume; orphaned when the target PV
                # (csi-vol-<uuid>) no longer exists outside the tenant.
                base="${img%-temp}"
                grep -qx "${base}" <<< "${protected}" || ORPHANS+=" ${img}"
                ;;
            csi-vol-*)
                # Regular volume; orphaned when no live PV outside the
                # tenant namespace references its handle.
                grep -qx "${img}" <<< "${protected}" || ORPHANS+=" ${img}"
                ;;
            csi-snap-*)
                # CSI snapshot; orphaned when no live VolumeSnapshotContent
                # references its handle.
                grep -qx "${img}" <<< "${snaps}" || ORPHANS+=" ${img}"
                ;;
            *)
                # Not managed by CSI (e.g. cephfs/rgw internals) — skip.
                ;;
        esac
    done
    ORPHANS="${ORPHANS# }"
}

function verify_hub_clean() {
    echo "=== Verifying that everything was reclaimed ==="
    local failed=false

    local remaining
    remaining=$(tenant_images_remaining)
    if [ -n "${remaining}" ]; then
        echo "ERROR: tenant images were not reclaimed:${remaining}" >&2
        failed=true
    fi

    detect_orphans
    if [ -n "${ORPHANS}" ]; then
        echo "ERROR: orphaned RBD images detected (no live PV/VolumeSnapshotContent):" >&2
        echo "${ORPHANS}" | tr ' ' '\n' | grep -v '^$' | sed 's/^/  /' >&2
        failed=true
    fi

    if [ "${failed}" = true ]; then
        echo "" >&2
        echo "The hub did not clean up after the tenant — the orphaned images" >&2
        echo "need manual cleanup (rbd lock remove / rbd rm from a ceph toolbox)." >&2
        echo "See the script header for background." >&2
        return 1
    fi
    echo "Hub is clean — no tenant or orphaned RBD images remain"
}

# ---------------------------------------------------------------------------
# Final report
# ---------------------------------------------------------------------------
function report() {
    echo "=== Final pool state ==="
    toolbox_cmd "ceph df | sed -n '1,8p'" 2>/dev/null || true
    toolbox_cmd "ceph -s | sed -n '2,8p'" 2>/dev/null || true
    echo "Remaining images:"
    toolbox_cmd "rbd ls -p ${RBD_POOL}" 2>/dev/null | sed 's/^/  /' || true
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "=== CAAS tenant deletion ==="
echo "Tenant namespace: ${TENANT_NAMESPACE} | ODF pool: ${RBD_POOL}"

capture_tenant_volumes
delete_tenant

# Unmap the tenant krbd devices first: stale mappings are what keeps the
# CSI from deleting the tenant PVs and images.
unmap_stale_krbd "$(tenant_unmap_list)"

wait_tenant_pvs_gone

if ! setup_toolbox; then
    echo "ERROR: no ceph toolbox available — cannot verify the cleanup" >&2
    exit 1
fi

# Give the CSI its chance to reclaim the tenant images.
wait_for_reclaim || true

verify_hub_clean
report

echo "=== CAAS tenant deletion complete — hub is clean ==="
