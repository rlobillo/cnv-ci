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
# CAPI_VERSION and CAPK_VERSION support three specifier forms, resolved at
# deploy time (see resolve_version below):
#   v1.11.3   exact release tag, used as-is
#   v1.11     series track: latest patch release of the v1.11 series
#   latest    newest stable release tag (pre-release tags excluded)
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

# Compares two version tags (e.g. v0.11.2): returns 0 if $1 >= $2.
# Uses sort -V, which orders v0.1.10 < v0.11.2 < v0.12.0 correctly.
function version_ge() {
    [ "$1" = "$2" ] || [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# Resolves a version specifier to a concrete GitHub release tag:
#   v1.11.3   exact tag, returned as-is
#   v1.11     series track: latest patch release of the v1.11 series
#   latest    newest stable release tag ( vX.Y.Z, pre-release tags excluded)
#
# Tags are discovered with "git ls-remote" so no GitHub API tokens are
# needed and API rate limits do not apply (requires git). Resolution is
# done at deploy time, so a run is always traceable via the echoed/resolved
# versions (also written to ${ARTIFACT_DIR}/caas-versions.txt when set).
function resolve_version() {
    local repo="$1" spec="$2"

    # Exact version tags are used as-is.
    if [[ "${spec}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s\n' "${spec}"
        return 0
    fi

    if ! command -v git &>/dev/null; then
        echo "ERROR: 'git' is required to resolve version specifier '${spec}' for ${repo}" >&2
        return 1
    fi

    # Series tracks match only tags of that series; "latest" matches all.
    local filter="."
    if [ "${spec}" != "latest" ]; then
        filter="^${spec//./\\.}\\."
    fi

    local tag
    tag=$(git ls-remote --tags "https://github.com/${repo}.git" \
        | grep -oE 'refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' \
        | sed 's|refs/tags/||' \
        | grep -E "${filter}" \
        | sort -V \
        | tail -n1 || true)
    if [ -z "${tag}" ]; then
        echo "ERROR: could not resolve '${spec}' to a release tag of ${repo}" >&2
        return 1
    fi
    printf '%s\n' "${tag}"
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

# Resolve CAPI/CAPK version specifiers ("latest" or series tracks like
# "v1.11") to concrete release tags. Exact tags pass through unchanged.
CAPI_VERSION=$(resolve_version kubernetes-sigs/cluster-api "${CAPI_VERSION}") \
    || { echo "ERROR: failed to resolve CAPI_VERSION" >&2; exit 1; }
CAPK_VERSION=$(resolve_version kubernetes-sigs/cluster-api-provider-kubevirt "${CAPK_VERSION}") \
    || { echo "ERROR: failed to resolve CAPK_VERSION" >&2; exit 1; }

echo "Resolved versions: CAPI ${CAPI_VERSION} | CAPK ${CAPK_VERSION}"
if [ -n "${ARTIFACT_DIR:-}" ]; then
    mkdir -p "${ARTIFACT_DIR}"
    printf 'CAPI_VERSION=%s\nCAPK_VERSION=%s\n' "${CAPI_VERSION}" "${CAPK_VERSION}" \
        > "${ARTIFACT_DIR}/caas-versions.txt"
fi

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
# Step 5: aggregate the provider manager roles into the built-in 'admin'
# ---------------------------------------------------------------------------
# STANDALONE-ONLY workaround: nobody (CAPI core, CAPK, CAPOA) publishes
# aggregate-to-admin ClusterRoles for their custom resources, so a
# project-admin user cannot create Cluster/OACP/KubevirtCluster objects in
# their namespace (PoC findings 5.1). Labeling the manager roles with the
# aggregation label merges their permissions into the built-in 'admin'
# ClusterRole, which create-caas-tenant.sh binds to the project-admin user.
#
# The MCE integration is expected to provide this properly instead (MCE
# already ships multicluster-engine:assisted-installer:admin-aggregate for
# the assisted-service resources); when it does, this step becomes
# redundant but harmless (the label is idempotent and re-applied on every
# deployment).
#
# NOTE: this over-grants by design — the manager roles carry cluster-scoped
# and sensitive permissions that namespace admins should not have.
# Acceptable on disposable QE hubs only.
function aggregate_manager_roles() {
    echo "=== Aggregating provider manager roles into 'admin' ==="
    for role in capi-manager-role capk-manager-role \
        capoa-controlplane-manager-role capoa-bootstrap-manager-role; do
        oc label clusterrole "${role}" \
            rbac.authorization.k8s.io/aggregate-to-admin=true --overwrite
    done
}

# ---------------------------------------------------------------------------
# Step 6: ensure the KubevirtMachine CRD has the v1beta2 status field
# ---------------------------------------------------------------------------
# CAPK v0.11.x declares the v1beta2 contract in its metadata.yaml but ships
# v1beta1-only CRDs: status.initialization is missing from the schema while
# clusterctl/CAPOA label the CRD as v1beta2-capable. The CAPI machine
# controller then waits for status.initialization.provisioned forever and
# Machines stay in Provisioning (verified with CAPI v1.14.3 + CAPK v0.11.2).
# CAPOA's reconcileInfraMachineStatus already patches this field after
# install, but the API server drops it while the schema lacks it. Adding
# the field makes CAPOA's patch stick and unblocks machine reconciliation
# (validated: Machines go Provisioning -> Provisioned with providerID set
# immediately after the CRD patch). Skipped when the CRD already has the
# field (future CAPK releases with real v1beta2 CRDs).
function patch_kubevirtmachine_crd() {
    echo "=== Ensuring KubevirtMachine CRD has status.initialization (CAPK v1beta2 gap) ==="

    # The gap is fixed in CAPK main (PR #394/#395, Aug 2026) and expected in
    # the first release after the v0.11.x series (v0.12.0+). Only patch for
    # affected versions — including any hypothetical v0.11.x patch release,
    # since the v1beta2 migration is too large to be cherry-picked into a
    # release branch.
    if version_ge "${CAPK_VERSION}" "v0.12.0"; then
        echo "CAPK ${CAPK_VERSION} >= v0.12.0 — v1beta2 status fix assumed present, skipping CRD patch"
        return 0
    fi

    # Safety net: also skip when the CRD already has the field (e.g. a
    # downstream build from main carrying a pre-release version tag).
    local has_init
    has_init=$(oc get crd kubevirtmachines.infrastructure.cluster.x-k8s.io \
        -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.status.properties.initialization}' 2>/dev/null)
    if [ -n "${has_init}" ]; then
        echo "KubevirtMachine CRD already has status.initialization — nothing to do"
        return 0
    fi
    oc patch crd kubevirtmachines.infrastructure.cluster.x-k8s.io --type json \
        -p '[{"op":"add","path":"/spec/versions/0/schema/openAPIV3Schema/properties/status/properties/initialization","value":{"type":"object","properties":{"provisioned":{"type":"boolean"}}}}]' \
        || echo "WARNING: could not patch KubevirtMachine CRD — machines may stay in Provisioning"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "=== CAPOA+KubeVirt standalone deployment ==="
echo "CAPI: ${CAPI_VERSION} | CAPK: ${CAPK_VERSION} | CAPOA ref: ${CAPOA_REPO_REF} | assisted-service: ${ASSISTED_SERVICE_TAG}"

install_cert_manager
install_capi_and_capk
patch_kubevirtmachine_crd
install_capoa
install_assisted_service
aggregate_manager_roles

echo "=== CAPOA+KubeVirt standalone deployment complete ==="
