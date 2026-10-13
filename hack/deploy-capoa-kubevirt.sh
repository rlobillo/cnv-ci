#!/usr/bin/env bash
# Deploy CAPOA providers + CAPK + assisted-service in standalone mode on an OCP+CNV hub cluster.
#
# Runs in Prow CI without root. oc/kubectl are provided by the CI environment.
# clusterctl is downloaded at runtime to /tmp/bin.
#
# Required env vars:
#   ARTIFACT_DIR               - directory for JUnit results (set automatically by Prow)
#
# Optional env vars:
#   CAPI_VERSION               - Cluster API version (default: v1.11.3)
#   CAPK_VERSION               - CAPK version (default: v0.1.9)
#   CERT_MANAGER_VERSION       - cert-manager version (default: v1.16.2)
#   CAPOA_REPO_REF             - CAPOA git ref to pull manifests from (default: master)
#   CAPOA_CTRL_IMAGE           - override CAPOA controlplane image (default: upstream latest)
#   CAPOA_BOOT_IMAGE           - override CAPOA bootstrap image (default: upstream latest)
#   ASSISTED_SERVICE_TAG       - assisted-service git tag for CRDs and manifests (default: v2.40.0)
#   INFRA_OPERATOR_IMAGE       - infrastructure-operator image (default: upstream latest)

set -euxo pipefail

CAPI_VERSION=${CAPI_VERSION:-v1.11.3}
CAPK_VERSION=${CAPK_VERSION:-v0.1.9}
CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION:-v1.16.2}
CAPOA_REPO_REF=${CAPOA_REPO_REF:-master}
CAPOA_RAW_BASE="https://raw.githubusercontent.com/openshift-assisted/cluster-api-provider-openshift-assisted/${CAPOA_REPO_REF}"

CAPOA_CTRL_IMAGE=${CAPOA_CTRL_IMAGE:-"quay.io/edge-infrastructure/cluster-api-controlplane-provider-openshift-assisted:latest"}
CAPOA_BOOT_IMAGE=${CAPOA_BOOT_IMAGE:-"quay.io/edge-infrastructure/cluster-api-bootstrap-provider-openshift-assisted:latest"}


ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/artifacts}
mkdir -p "${ARTIFACT_DIR}"

# clusterctl — download to /tmp/bin (no root required)
mkdir -p /tmp/bin
export PATH="${PATH}:/tmp/bin"
if ! command -v clusterctl &>/dev/null; then
    echo "Downloading clusterctl ${CAPI_VERSION}"
    curl -fsSL \
        "https://github.com/kubernetes-sigs/cluster-api/releases/download/${CAPI_VERSION}/clusterctl-linux-amd64" \
        -o /tmp/bin/clusterctl
    chmod +x /tmp/bin/clusterctl
fi
clusterctl version

TOTAL=0
FAILURES=0
TESTCASES_XML=""

function add_testcase() {
    local test_name="$1"
    local test_passed="$2"

    TOTAL=$((TOTAL + 1))

    if [[ "$test_passed" == "false" ]]; then
        FAILURES=$((FAILURES + 1))
        TESTCASES_XML+="  <testcase name=\"${test_name}\"><failure message=\"Failed step\"/></testcase>\n"
        exit 1
    else
        TESTCASES_XML+="  <testcase name=\"${test_name}\"/>\n"
    fi
}

function generateResultFile() {
    local results_file="${1}"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n' > "${results_file}"
    printf '<testsuite name="capoa-kubevirt-deploy" tests="%s" failures="%s">\n' \
        "${TOTAL}" "${FAILURES}" >> "${results_file}"
    printf "${TESTCASES_XML}" >> "${results_file}"
    printf '</testsuite>\n' >> "${results_file}"
}

function cleanup() {
    rv=$?
    if [ "x$rv" != "x0" ]; then
        echo "Error during CAPOA+KubeVirt deployment: exit status: $rv"
        echo "*** CAPOA+KubeVirt deployment failed ***"
    fi
    generateResultFile "${ARTIFACT_DIR}/junit_capoa_kubevirt_deploy.xml"
    exit $rv
}

trap "cleanup" INT TERM EXIT

# ---------------------------------------------------------------------------
# Step 1: cert-manager (required for CAPOA webhooks)
# ---------------------------------------------------------------------------
function install_cert_manager() {
    echo "Installing cert-manager ${CERT_MANAGER_VERSION}"
    oc apply -f "https://github.com/jetstack/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
    oc wait deployment cert-manager-webhook \
        -n cert-manager \
        --for=condition=Available \
        --timeout=5m
}

# ---------------------------------------------------------------------------
# Step 2: CAPI core + CAPK via clusterctl
# ---------------------------------------------------------------------------
function install_capi_and_capk() {
    echo "Installing CAPI ${CAPI_VERSION} + CAPK ${CAPK_VERSION}"

    # Bootstrap (-) and control-plane (-) are skipped: CAPOA provides them.
    clusterctl init \
        --core "cluster-api:${CAPI_VERSION}" \
        --bootstrap - \
        --control-plane - \
        --infrastructure "kubevirt:${CAPK_VERSION}"

    # OCP SCC: upstream controllers use UID 65532 + seccomp annotations incompatible
    # with restricted/anyuid SCCs on OCP. privileged SCC is required.
    oc adm policy add-scc-to-user privileged -z capi-manager -n capi-system
    oc adm policy add-scc-to-user privileged -z capk-manager -n capk-system

    oc rollout restart deployment/capi-controller-manager -n capi-system

    oc wait deployment capi-controller-manager \
        -n capi-system \
        --for=condition=Available \
        --timeout=5m

    oc wait deployment capk-controller-manager \
        -n capk-system \
        --for=condition=Available \
        --timeout=5m
}

# ---------------------------------------------------------------------------
# Step 3: Install CAPOA providers
# ---------------------------------------------------------------------------
function install_capoa() {
    echo "Installing CAPOA providers"
    echo "  controlplane: ${CAPOA_CTRL_IMAGE}"
    echo "  bootstrap:    ${CAPOA_BOOT_IMAGE}"

    local orig_ctrl="quay.io/edge-infrastructure/cluster-api-controlplane-provider-openshift-assisted:latest"
    local orig_boot="quay.io/edge-infrastructure/cluster-api-bootstrap-provider-openshift-assisted:latest"

    curl -fsSL "${CAPOA_RAW_BASE}/test/e2e/manifests/capcoa/controlplane_install.yaml" \
        | sed "s|${orig_ctrl}|${CAPOA_CTRL_IMAGE}|g" \
        | oc apply -f -

    curl -fsSL "${CAPOA_RAW_BASE}/test/e2e/manifests/capboa/bootstrap_install.yaml" \
        | sed "s|${orig_boot}|${CAPOA_BOOT_IMAGE}|g" \
        | oc apply -f -

    oc wait deployment capoa-controlplane-controller-manager \
        -n capoa-controlplane-system \
        --for=condition=Available \
        --timeout=5m

    oc wait deployment capoa-bootstrap-controller-manager \
        -n capoa-bootstrap-system \
        --for=condition=Available \
        --timeout=5m
}

# ---------------------------------------------------------------------------
# Step 4: Install assisted-service (infrastructure-operator) standalone
# ---------------------------------------------------------------------------
function install_assisted_service() {
    echo "Installing assisted-service (upstream latest)"

    local assisted_raw="https://raw.githubusercontent.com/openshift/assisted-service/master"

    # Required CRDs not bundled in the infrastructure-operator itself
    oc apply -f "${assisted_raw}/hack/crds/hive/hive.openshift.io_clusterdeployments.yaml"
    oc apply -f "${assisted_raw}/hack/crds/hive/hive.openshift.io_clusterimagesets.yaml"
    oc apply -f "${assisted_raw}/hack/crds/mce/managedclusters.cluster.open-cluster-management.io.yaml"

    # infrastructure-operator with default upstream images (no digest pinning)
    oc apply -k "github.com/openshift/assisted-service/config/default"

    # OCP RBAC: infrastructure-operator needs read access to OpenShift-specific APIs
    # (e.g. apiservers.config.openshift.io) not covered by its upstream ClusterRole
    oc adm policy add-cluster-role-to-user cluster-reader \
        system:serviceaccount:assisted-installer:assisted-service

    # OCP SCC: infrastructure-operator uses UIDs outside OCP restricted range
    oc adm policy add-scc-to-user privileged \
        -z infrastructure-operator -n assisted-installer 2>/dev/null || true
    oc adm policy add-scc-to-user privileged \
        -z default -n assisted-installer 2>/dev/null || true

    oc wait deployment infrastructure-operator \
        -n assisted-installer \
        --for=condition=Available \
        --timeout=5m

    # AgentServiceConfig — triggers assisted-service deployment
    oc apply -f - <<'EOF'
apiVersion: agent-install.openshift.io/v1beta1
kind: AgentServiceConfig
metadata:
  name: agent
  annotations:
    agent-install.openshift.io/enable-image-service: "false"
spec:
  databaseStorage:
    accessModes:
    - ReadWriteOnce
    resources:
      requests:
        storage: 10Gi
  filesystemStorage:
    accessModes:
    - ReadWriteOnce
    resources:
      requests:
        storage: 10Gi
  osImages: []
EOF

    oc wait deployment assisted-service \
        -n assisted-installer \
        --for=condition=Available \
        --timeout=10m
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "=== CAPOA+KubeVirt standalone deployment ==="
echo "CAPI: ${CAPI_VERSION} | CAPK: ${CAPK_VERSION} | CAPOA ref: ${CAPOA_REPO_REF}"

install_cert_manager     || add_testcase "install_cert_manager"     "false"
add_testcase "install_cert_manager" "true"

install_capi_and_capk    || add_testcase "install_capi_and_capk"    "false"
add_testcase "install_capi_and_capk" "true"

install_capoa            || add_testcase "install_capoa"            "false"
add_testcase "install_capoa" "true"

install_assisted_service || add_testcase "install_assisted_service" "false"
add_testcase "install_assisted_service" "true"

echo "=== CAPOA+KubeVirt standalone deployment complete ==="
