#!/usr/bin/env bash
# Uninstall everything deployed by deploy-caas-standalone.sh and
# create-caas-tenant.sh.
#
# Removes: standalone assisted-service (AgentServiceConfig and the
# infrastructure-operator namespace), CAPOA providers, CAPK, standalone
# CAPI, cert-manager.
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
    # The standalone install also leaves the infrastructure-operator and its
    # namespace behind (the kustomize hardcodes assisted-installer) — remove
    # them too so the teardown matches what deploy-caas-standalone.sh
    # installed.
    oc delete namespace assisted-installer --ignore-not-found --wait=false
fi

# ---------------------------------------------------------------------------
# Manager-role aggregation — undo what deploy-caas-standalone.sh applied
# ---------------------------------------------------------------------------
# The standalone deploy labels the provider manager ClusterRoles with
# rbac.authorization.k8s.io/aggregate-to-admin (workaround so project-admin
# users can manage CAPI/CAPOA resources). Remove the label so namespace
# admins do not keep the over-granted manager permissions after teardown.
# Tolerates roles already deleted by the steps below.
echo "=== Removing manager-role aggregation ==="
for role in capi-manager-role capk-manager-role \
    capoa-controlplane-manager-role capoa-bootstrap-manager-role; do
    oc label clusterrole "${role}" rbac.authorization.k8s.io/aggregate-to-admin- \
        2>/dev/null || true
done

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

# ---------------------------------------------------------------------------
# CAPI-related CRDs — clean leftovers and restore CVO/payload ownership
# ---------------------------------------------------------------------------
# The OCP payload ships its own copies of some CAPI CRDs (the ipam ones:
# ipaddressclaims, ipaddresses — feature-gated ClusterAPIMachineManagement).
# The standalone clusterctl install overwrote them with CAPI v1.11.x
# versions where v1beta2 is the storage version. The API server then
# refuses to let the CVO reconcile its payload version back:
#   status.storedVersions[0]: Invalid value: "v1beta2": missing from
#   spec.versions; v1beta2 was previously a storage version, and must
#   remain in spec.versions until a storage migration...
# which permanently blocks hub upgrades ("Could not update
# customresourcedefinition ipaddressclaims..." in clusterversion).
#
# Deleting the empty CRDs resolves the conflict: the CVO recreates the
# payload-owned ones on its next sync; CRDs installed only by
# clusterctl/CAPK/CAPOA simply stay deleted.
#
# Only CRDs installed by this deployment are considered: clusterctl-labeled
# CRDs (CAPI core/ipam/addons/runtime + CAPK) and the CAPOA provider CRDs.
# Payload-owned CRDs never touched here (e.g. metal3 remediation ones) are
# left alone. CRDs that still have instances are skipped with a warning.
echo "=== Removing CAPI-related CRDs (empty ones only) ==="
for crd in $(oc get crd -o name | grep -E '\.cluster\.x-k8s\.io$'); do
    name="${crd#*/}"

    # Skip CRDs this deployment never installed.
    if ! oc get crd "${name}" -o jsonpath='{.metadata.labels}' | grep -q 'clusterctl\.cluster\.x-k8s\.io' \
        && ! [[ "${name}" == openshiftassisted* ]]; then
        continue
    fi

    # Never delete a CRD that still has instances.
    if [ -n "$(oc get "${name}" -A -o name 2>/dev/null)" ]; then
        echo "WARNING: ${name} still has instances — skipping"
        continue
    fi

    oc delete crd "${name}" --ignore-not-found --wait=false
done

echo "=== CAPOA+KubeVirt undeployment complete ==="
echo "Note: MCE and its managed components (CAPI in multicluster-engine) are untouched."
echo "      The CVO will recreate the payload-owned CAPI CRDs on its next sync;"
echo "      check with: oc get clusterversion (Failing should clear within minutes)."
