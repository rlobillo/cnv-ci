#!/usr/bin/env bash
# Uninstall everything deployed by deploy-caas-standalone.sh and
# create-caas-tenant.sh.
#
# Removes: CAPOA providers, CAPK, standalone CAPI, cert-manager.
# Does NOT touch MCE or any MCE-managed components.
#
# The tenant cluster itself (namespace, VMs, RBD images) is removed by
# delete-caas-tenant.sh — run that first; this script only tears down the
# hub-side providers.
#
# Optional env vars:
#   TENANT_NAMESPACE    - tenant namespace checked for leftovers (default: capoa-kubevirt-test)
#   SKIP_CERT_MANAGER   - set to "true" to keep cert-manager (default: false)

set -euxo pipefail

TENANT_NAMESPACE=${TENANT_NAMESPACE:-capoa-kubevirt-test}
SKIP_CERT_MANAGER=${SKIP_CERT_MANAGER:-false}

# ---------------------------------------------------------------------------
# Tenant cluster — must be removed by delete-caas-tenant.sh first
# ---------------------------------------------------------------------------
if oc get namespace "${TENANT_NAMESPACE}" &>/dev/null; then
    echo "WARNING: tenant namespace ${TENANT_NAMESPACE} still exists."
    echo "         Run hack/delete-caas-tenant.sh first — it also verifies that the"
    echo "         RBD images backing the tenant VM disks were reclaimed."
fi

# ---------------------------------------------------------------------------
# AgentServiceConfig (only if we created it — skip if MCE owns it)
# ---------------------------------------------------------------------------
echo "=== Removing AgentServiceConfig (if standalone) ==="
# Only delete if assisted-service is NOT in multicluster-engine (i.e. standalone install)
if ! oc get deployment assisted-service -n multicluster-engine &>/dev/null; then
    oc delete agentserviceconfig agent --ignore-not-found
fi

# ---------------------------------------------------------------------------
# CAPOA providers
# ---------------------------------------------------------------------------
echo "=== Removing CAPOA controlplane provider ==="
oc delete namespace capoa-controlplane-system --ignore-not-found --wait=false
oc delete clusterrole capoa-controlplane-manager-role --ignore-not-found
oc delete clusterrolebinding capoa-controlplane-manager-rolebinding --ignore-not-found
oc delete mutatingwebhookconfiguration capoa-controlplane-mutating-webhook-configuration --ignore-not-found 2>/dev/null || true
oc delete validatingwebhookconfiguration capoa-controlplane-validating-webhook-configuration --ignore-not-found 2>/dev/null || true

echo "=== Removing CAPOA bootstrap provider ==="
oc delete namespace capoa-bootstrap-system --ignore-not-found --wait=false
oc delete clusterrole capoa-bootstrap-manager-role --ignore-not-found
oc delete clusterrolebinding capoa-bootstrap-manager-rolebinding --ignore-not-found
oc delete validatingwebhookconfiguration capoa-bootstrap-validating-webhook-configuration --ignore-not-found 2>/dev/null || true

# ---------------------------------------------------------------------------
# CAPK (cluster-api-provider-kubevirt)
# ---------------------------------------------------------------------------
echo "=== Removing CAPK ==="
oc delete namespace capk-system --ignore-not-found --wait=false

# ---------------------------------------------------------------------------
# Standalone CAPI (capi-system) — NOT MCE CAPI in multicluster-engine
# ---------------------------------------------------------------------------
echo "=== Removing standalone CAPI ==="
oc delete namespace capi-system --ignore-not-found --wait=false

# ---------------------------------------------------------------------------
# cert-manager
# ---------------------------------------------------------------------------
if [[ "${SKIP_CERT_MANAGER}" != "true" ]]; then
    echo "=== Removing cert-manager ==="
    oc delete namespace cert-manager --ignore-not-found --wait=false
    oc delete clusterrole \
        cert-manager-cainjector \
        cert-manager-controller-issuers \
        cert-manager-controller-clusterissuers \
        cert-manager-controller-certificates \
        cert-manager-controller-orders \
        cert-manager-controller-challenges \
        cert-manager-controller-ingress-shim \
        cert-manager-cluster-view \
        cert-manager-view \
        cert-manager-edit \
        "cert-manager-controller-approve:cert-manager-io" \
        cert-manager-controller-certificatesigningrequests \
        "cert-manager-webhook:subjectaccessreviews" \
        --ignore-not-found 2>/dev/null || true
    oc delete clusterrolebinding \
        cert-manager-cainjector \
        cert-manager-controller-issuers \
        cert-manager-controller-clusterissuers \
        cert-manager-controller-certificates \
        cert-manager-controller-orders \
        cert-manager-controller-challenges \
        cert-manager-controller-ingress-shim \
        "cert-manager-controller-approve:cert-manager-io" \
        cert-manager-controller-certificatesigningrequests \
        "cert-manager-webhook:subjectaccessreviews" \
        --ignore-not-found 2>/dev/null || true
    oc delete mutatingwebhookconfiguration cert-manager-webhook --ignore-not-found 2>/dev/null || true
    oc delete validatingwebhookconfiguration cert-manager-webhook --ignore-not-found 2>/dev/null || true
fi

echo "=== CAPOA+KubeVirt undeployment complete ==="
echo "Note: MCE and its managed components (CAPI in multicluster-engine) are untouched."
echo "      CRDs (Cluster, KubevirtCluster, etc.) may remain — remove manually if needed."
