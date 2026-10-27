#!/usr/bin/env bash
# Deploy CAPOA providers + CAPK + assisted-service in standalone mode on an OCP+CNV hub cluster.
#
# Runs in Prow CI without root. oc/kubectl are provided by the CI environment.
# clusterctl is downloaded at runtime to /tmp/bin.
#
# All versions and external references are centralized in
# hack/caas.yaml. Every key defined there can be overridden
# through a same-named environment variable:
#   CAPI_VERSION, CAPK_VERSION, CERT_MANAGER_VERSION, ASSISTED_SERVICE_TAG,
#   ASSISTED_SERVICE_CRD_PATHS, ASSISTED_SERVICE_KUSTOMIZE_PATH,
#   CAPOA_REPO_REF, CAPOA_CONTROLPLANE_MANIFEST, CAPOA_BOOTSTRAP_MANIFEST,
#   AGENTSERVICECONFIG_MANIFEST, CAPOA_CTRL_IMAGE, CAPOA_BOOT_IMAGE
#
# CAPOA is installed with oc apply from git manifests, NOT via clusterctl:
# CAPOA releases ship a stale metadata.yaml (releaseSeries only covers the
# old 0.1 series) that makes "clusterctl init" fail for any newer release.
# See hack/caas.yaml for details.

set -euxo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
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

CAPI_VERSION=$(read_config CAPI_VERSION)
CAPK_VERSION=$(read_config CAPK_VERSION)
CERT_MANAGER_VERSION=$(read_config CERT_MANAGER_VERSION)
ASSISTED_SERVICE_TAG=$(read_config ASSISTED_SERVICE_TAG)
ASSISTED_SERVICE_CRD_PATHS=$(read_config ASSISTED_SERVICE_CRD_PATHS)
ASSISTED_SERVICE_KUSTOMIZE_PATH=$(read_config ASSISTED_SERVICE_KUSTOMIZE_PATH)
CAPOA_REPO_REF=$(read_config CAPOA_REPO_REF)
CAPOA_CONTROLPLANE_MANIFEST=$(read_config CAPOA_CONTROLPLANE_MANIFEST)
CAPOA_BOOTSTRAP_MANIFEST=$(read_config CAPOA_BOOTSTRAP_MANIFEST)
AGENTSERVICECONFIG_MANIFEST=$(read_config AGENTSERVICECONFIG_MANIFEST)
CAPOA_CTRL_IMAGE=$(read_config CAPOA_CTRL_IMAGE)
CAPOA_BOOT_IMAGE=$(read_config CAPOA_BOOT_IMAGE)

for _key in CAPI_VERSION CAPK_VERSION CERT_MANAGER_VERSION ASSISTED_SERVICE_TAG \
    ASSISTED_SERVICE_CRD_PATHS ASSISTED_SERVICE_KUSTOMIZE_PATH \
    CAPOA_REPO_REF CAPOA_CONTROLPLANE_MANIFEST CAPOA_BOOTSTRAP_MANIFEST \
    AGENTSERVICECONFIG_MANIFEST CAPOA_CTRL_IMAGE CAPOA_BOOT_IMAGE; do
    if [ -z "${!_key}" ]; then
        echo "ERROR: ${_key} is not set and was not found in ${CONFIG_FILE}" >&2
        exit 1
    fi
done
unset _key

command -v oc &>/dev/null || { echo "ERROR: 'oc' client not found in PATH" >&2; exit 1; }

# clusterctl — download to /tmp/bin (no root required)
mkdir -p /tmp/bin
export PATH="${PATH}:/tmp/bin"
if ! command -v clusterctl &>/dev/null; then
    case "$(uname -m)" in
        x86_64) clusterctl_arch=amd64 ;;
        aarch64|arm64) clusterctl_arch=arm64 ;;
        *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
    esac
    echo "Downloading clusterctl ${CAPI_VERSION} (${clusterctl_arch})"
    curl -fsSL \
        "https://github.com/kubernetes-sigs/cluster-api/releases/download/${CAPI_VERSION}/clusterctl-linux-${clusterctl_arch}" \
        -o /tmp/bin/clusterctl
    chmod +x /tmp/bin/clusterctl
fi
clusterctl version

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

    # Bootstrap (-) and control-plane (-) are skipped: CAPOA provides them,
    # but it is installed with oc apply in the next step (not via clusterctl).
    clusterctl init \
        --config "${CONFIG_FILE}" \
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
# Step 3: Install CAPOA providers (git manifests, not via clusterctl)
# ---------------------------------------------------------------------------
function install_capoa() {
    echo "Installing CAPOA providers (ref: ${CAPOA_REPO_REF})"
    echo "  controlplane: ${CAPOA_CTRL_IMAGE}"
    echo "  bootstrap:    ${CAPOA_BOOT_IMAGE}"

    local capoa_raw="https://raw.githubusercontent.com/openshift-assisted/cluster-api-provider-openshift-assisted/${CAPOA_REPO_REF}"
    local orig_ctrl="quay.io/edge-infrastructure/cluster-api-controlplane-provider-openshift-assisted:latest"
    local orig_boot="quay.io/edge-infrastructure/cluster-api-bootstrap-provider-openshift-assisted:latest"

    curl -fsSL "${capoa_raw}/${CAPOA_CONTROLPLANE_MANIFEST}" \
        | sed "s|${orig_ctrl}|${CAPOA_CTRL_IMAGE}|g" \
        | oc apply -f -

    curl -fsSL "${capoa_raw}/${CAPOA_BOOTSTRAP_MANIFEST}" \
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
    echo "Installing assisted-service ${ASSISTED_SERVICE_TAG}"

    local assisted_raw="https://raw.githubusercontent.com/openshift/assisted-service/${ASSISTED_SERVICE_TAG}"

    # Required CRDs not bundled in the infrastructure-operator itself
    local crd_path crd_paths
    read -ra crd_paths <<< "${ASSISTED_SERVICE_CRD_PATHS}"
    for crd_path in "${crd_paths[@]}"; do
        oc apply -f "${assisted_raw}/${crd_path}"
    done

    # infrastructure-operator with default upstream images (no digest pinning)
    oc apply -k "github.com/openshift/assisted-service/${ASSISTED_SERVICE_KUSTOMIZE_PATH}?ref=${ASSISTED_SERVICE_TAG}"

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
    oc apply -f "${REPO_DIR}/${AGENTSERVICECONFIG_MANIFEST}"

    oc wait deployment assisted-service \
        -n assisted-installer \
        --for=condition=Available \
        --timeout=10m

    # CAPOA bootstrap controller reads the assisted-service TLS CA from this
    # secret. On OCP, assisted-service is exposed via a reencrypt Route: the
    # router presents the Ingress CA cert to external clients, then re-encrypts
    # to the pod using the Service CA. Both CAs must be trusted.
    local ingress_ca service_ca
    ingress_ca=$(oc get secret router-ca -n openshift-ingress-operator \
        -o jsonpath='{.data.tls\.crt}' | base64 -d)
    service_ca=$(oc get configmap openshift-service-ca.crt \
        -n openshift-config-managed \
        -o jsonpath='{.data.service-ca\.crt}')
    oc create secret generic assisted-installer-ca \
        -n assisted-installer \
        --from-literal=ca.crt="${ingress_ca}"$'\n'"${service_ca}" \
        --dry-run=client -o yaml | oc apply -f -
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "=== CAPOA+KubeVirt standalone deployment ==="
echo "CAPI: ${CAPI_VERSION} | CAPK: ${CAPK_VERSION} | CAPOA ref: ${CAPOA_REPO_REF} | assisted-service: ${ASSISTED_SERVICE_TAG}"

install_cert_manager
install_capi_and_capk
install_capoa
install_assisted_service

echo "=== CAPOA+KubeVirt standalone deployment complete ==="
