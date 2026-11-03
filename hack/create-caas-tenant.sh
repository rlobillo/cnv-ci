#!/usr/bin/env bash
# Deploy a CAAS tenant cluster on the hub and smoke-check it.
#
# Assumes deploy-caas-standalone.sh already ran successfully
# (CAPI+CAPK+CAPOA ready).
#
# What it does:
#   1. ensure AgentServiceConfig + assisted-service ready
#   2. apply the tenant cluster manifest
#   3. wait for the AgentClusterInstall to reach "installed"
#   4. extract the tenant kubeconfig into ARTIFACT_DIR
#   5. smoke-check the tenant cluster (oc get nodes)
#
# Nothing else: conformance runs and tenant deletion are driven by separate
# Prow steps (see delete-caas-tenant.sh).
#
# Required env vars:
#   ARTIFACT_DIR        - directory for the tenant kubeconfig and logs (set by Prow)
#
# Optional env vars (auto-discovered from the hub cluster if not set):
#   PULL_SECRET         - pull secret JSON (default: extracted from hub openshift-config/pull-secret)
#   BASE_DOMAIN         - base domain for the tenant cluster (default: from hub ingress)
#   STORAGE_CLASS       - storage class for VM root disks (default: from hub default SC)
#   OCP_VERSION         - OpenShift version to install (default: the exact
#                         version the hub runs; set it explicitly only when
#                         running against a pre-release hub)
#
# Defaults for all other tunables (cluster name, namespaces, timeouts, SSH
# key, manifest paths) are centralized in hack/caas.yaml.
# Every key defined there can be overridden through a same-named
# environment variable:
#   CLUSTER_NAME, TENANT_NAMESPACE, ASSISTED_NAMESPACE, SSH_AUTHORIZED_KEY,
#   INSTALL_TIMEOUT_MIN, FINALIZING_TIMEOUT_MIN, CSI_STORAGE_CLASS,
#   TENANT_ADMIN_USER, TENANT_ADMIN_PASSWORD
#
# Project-admin mode (default, TENANT_ADMIN_USER != ""): the script creates
# an htpasswd user, binds the built-in 'admin' role to it in the tenant
# namespace, generates a kubeconfig for it and performs the whole tenant
# deployment as that user — including the infra-cluster-credentials secret,
# which then carries the project-admin kubeconfig (the topology promised by
# the epic's first user story). Hub-level discovery and the assisted-service
# readiness check still run with the original (cluster-admin) kubeconfig
# before switching. Set TENANT_ADMIN_USER="" for the legacy cluster-admin
# flow. Requires the 'htpasswd' binary.
#
# NOTE: this script assumes the deployment already made the CAPI/CAPOA
# custom resources available to namespace admins (standalone:
# deploy-caas-standalone.sh aggregates the provider manager roles as a
# workaround; MCE is expected to ship proper aggregate roles). A fail-fast
# check verifies it after switching to the user kubeconfig. Known product
# gaps this mode is meant to validate: CAPOA resolves the CDI importer
# image from the openshift-cnv namespace and patches the IngressController
# wildcard policy in openshift-ingress-operator using the infra
# credentials — a project-admin kubeconfig can do neither, so golden-PVC
# provisioning is expected to stall on the former.

set -euxo pipefail

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

CLUSTER_NAME=$(read_config CLUSTER_NAME)
TENANT_NAMESPACE=$(read_config TENANT_NAMESPACE)
ASSISTED_NAMESPACE=$(read_config ASSISTED_NAMESPACE)
SSH_AUTHORIZED_KEY=$(read_config SSH_AUTHORIZED_KEY)
INSTALL_TIMEOUT_MIN=$(read_config INSTALL_TIMEOUT_MIN)
FINALIZING_TIMEOUT_MIN=$(read_config FINALIZING_TIMEOUT_MIN)
AGENTSERVICECONFIG_MANIFEST=$(read_config AGENTSERVICECONFIG_MANIFEST)
TENANT_CLUSTER_MANIFEST=$(read_config TENANT_CLUSTER_MANIFEST)
CSI_STORAGE_CLASS=$(read_config CSI_STORAGE_CLASS)
TENANT_ADMIN_USER=$(read_config TENANT_ADMIN_USER)
TENANT_ADMIN_PASSWORD=$(read_config TENANT_ADMIN_PASSWORD)

# OpenShift version to install: env var > hub cluster version. The tenant
# always installs the exact version the hub runs (payload and RHCOS
# stream); set OCP_VERSION explicitly only when running against a
# pre-release hub.
OCP_VERSION=${OCP_VERSION:-$(oc get clusterversion version \
    -o jsonpath='{.status.desired.version}' 2>/dev/null || true)}
if [ -z "${OCP_VERSION}" ]; then
    echo "ERROR: could not discover the hub OpenShift version — set OCP_VERSION explicitly" >&2
    exit 1
fi

for _key in CLUSTER_NAME TENANT_NAMESPACE ASSISTED_NAMESPACE \
    SSH_AUTHORIZED_KEY INSTALL_TIMEOUT_MIN FINALIZING_TIMEOUT_MIN \
    AGENTSERVICECONFIG_MANIFEST TENANT_CLUSTER_MANIFEST CSI_STORAGE_CLASS; do
    if [ -z "${!_key}" ]; then
        echo "ERROR: ${_key} is not set and was not found in ${CONFIG_FILE}" >&2
        exit 1
    fi
done
unset _key

OCP_MAJOR_MINOR=$(echo "${OCP_VERSION}" | cut -d. -f1,2)

ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp/artifacts}
mkdir -p "${ARTIFACT_DIR}"

# ---------------------------------------------------------------------------
# Discover hub cluster parameters
# ---------------------------------------------------------------------------
BASE_DOMAIN=${BASE_DOMAIN:-$(oc get ingresscontroller default -n openshift-ingress-operator \
    -o jsonpath='{.status.domain}' 2>/dev/null)}
STORAGE_CLASS=${STORAGE_CLASS:-$(oc get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null)}
set +x
PULL_SECRET=${PULL_SECRET:-$(oc get secret pull-secret -n openshift-config \
    -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)}
set -x

echo "OCP_VERSION:   ${OCP_VERSION}"
echo "BASE_DOMAIN:   ${BASE_DOMAIN}"
echo "STORAGE_CLASS: ${STORAGE_CLASS}"

# ---------------------------------------------------------------------------
# Step 1: ensure AgentServiceConfig + assisted-service ready
# ---------------------------------------------------------------------------
function ensure_assisted_service() {
    if ! oc get agentserviceconfig agent &>/dev/null; then
        echo "Creating AgentServiceConfig"
        oc apply -f "${REPO_DIR}/${AGENTSERVICECONFIG_MANIFEST}"
    else
        echo "AgentServiceConfig already exists"
    fi

    oc wait deployment assisted-service \
        -n "${ASSISTED_NAMESPACE}" \
        --for=condition=Available \
        --timeout=10m
}

# Ensures the tenant namespace exists and is Active. A leftover namespace
# from a previous run may be stuck in Terminating (e.g. a KubevirtCluster
# finalizer that cannot complete because CAPK errors out looking for its
# owner Cluster); objects created in a Terminating namespace are silently
# swept away when it finally dies — seen in practice: the manifest apply
# landed on a dying namespace and the KubevirtCluster vanished mid-install.
function ensure_namespace_active() {
    if oc get namespace "${TENANT_NAMESPACE}" &>/dev/null; then
        local phase
        phase=$(oc get namespace "${TENANT_NAMESPACE}" -o jsonpath='{.status.phase}')
        if [ "${phase}" != "Active" ]; then
            echo "Namespace ${TENANT_NAMESPACE} is ${phase} (leftover from a previous run)"
            echo "Waiting up to 5m for it to disappear before re-creating it..."
            oc wait namespace "${TENANT_NAMESPACE}" --for=delete --timeout=300s || {
                echo "ERROR: namespace still ${phase} after 5m." >&2
                echo "       Check for stuck finalizers: oc get ns ${TENANT_NAMESPACE} -o yaml" >&2
                exit 1
            }
        fi
    fi
    oc get namespace "${TENANT_NAMESPACE}" &>/dev/null \
        || oc create namespace "${TENANT_NAMESPACE}"
}

# ---------------------------------------------------------------------------
# Step 2: project-admin user for the tenant namespace
# ---------------------------------------------------------------------------
# The epic's user story: a namespace admin (no cluster-admin rights)
# provisions the tenant. This step runs with the original cluster-admin
# kubeconfig and:
#   1. creates the tenant namespace (a project admin cannot create one)
#   2. ensures an htpasswd user exists (TENANT_ADMIN_USER)
#   3. binds the built-in 'admin' role to the user in the namespace
#   4. generates a kubeconfig for the user and switches KUBECONFIG to it,
#      so every subsequent step — including the infra-cluster-credentials
#      secret baked from ${KUBECONFIG} — runs as the project-admin
#
# The CAPI/CAPOA custom resources must already be part of the namespace
# 'admin' role by the time this runs — that is the DEPLOYMENT's job, not
# this script's: deploy-caas-standalone.sh aggregates the provider manager
# roles as a standalone-only workaround, and the MCE integration is
# expected to ship proper aggregate roles (as it already does for the
# assisted-service resources). A fail-fast check below verifies it.
#
# Set TENANT_ADMIN_USER to "" to keep the legacy cluster-admin flow.
function setup_tenant_admin_user() {
    if [ -z "${TENANT_ADMIN_USER}" ]; then
        echo "TENANT_ADMIN_USER is empty — deploying as the current (cluster-admin) user"
        return 0
    fi

    command -v htpasswd &>/dev/null || {
        echo "ERROR: 'htpasswd' binary not found (httpd-tools package); required" >&2
        echo "       to create the project-admin user. Install it or set TENANT_ADMIN_USER=\"\"" >&2
        exit 1
    }

    echo "=== Setting up project-admin user '${TENANT_ADMIN_USER}' ==="

    # The namespace must be created (and Active) with cluster-admin rights.
    ensure_namespace_active

    # Auto-generate a password when none was provided.
    if [ -z "${TENANT_ADMIN_PASSWORD}" ]; then
        set +x
        TENANT_ADMIN_PASSWORD=$(openssl rand -hex 12 2>/dev/null \
            || tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 20)
        set -x
    fi

    # htpasswd secret: append/replace this user's entry, keep other users.
    local idp_name="capoa-htpasswd"
    local htpasswd_file
    htpasswd_file=$(mktemp)
    if oc get secret "${idp_name}" -n openshift-config &>/dev/null; then
        oc get secret "${idp_name}" -n openshift-config \
            -o jsonpath='{.data.htpasswd}' | base64 -d > "${htpasswd_file}" || true
        sed -i "/^${TENANT_ADMIN_USER}:/d" "${htpasswd_file}"
    fi
    # The password must not leak into the trace (CI build logs).
    set +x
    htpasswd -bnBC 10 "${TENANT_ADMIN_USER}" "${TENANT_ADMIN_PASSWORD}" >> "${htpasswd_file}"
    set -x
    oc create secret generic "${idp_name}" -n openshift-config \
        --from-file=htpasswd="${htpasswd_file}" \
        --dry-run=client -o yaml | oc apply -f -
    rm -f "${htpasswd_file}"

    # Register the htpasswd identity provider if missing.
    if ! oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' | tr ' ' '\n' | grep -qx "${idp_name}"; then
        oc get oauth cluster -o jsonpath='{.spec.identityProviders}' | grep -q '\[' \
            || oc patch oauth cluster --type merge -p '{"spec":{"identityProviders":[]}}'
        oc patch oauth cluster --type json \
            -p "[{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":{\"name\":\"${idp_name}\",\"mappingMethod\":\"claim\",\"type\":\"HTPasswd\",\"htpasswd\":{\"fileData\":{\"name\":\"${idp_name}\"}}}}]"
    fi

    # Namespace-scoped admin for the user. The CAPI/CAPOA custom resources
    # must be part of the built-in 'admin' ClusterRole by now — the
    # deployment is responsible for that (standalone: manager-role
    # aggregation in deploy-caas-standalone.sh; MCE: proper aggregate
    # roles, still a product gap). Verified right after switching to the
    # user kubeconfig, below.
    oc adm policy add-role-to-user admin "${TENANT_ADMIN_USER}" -n "${TENANT_NAMESPACE}"

    # kubeconfig for the user (CA taken from the current kubeconfig).
    local api_url ca_file user_kubeconfig
    api_url=$(oc whoami --show-server)
    user_kubeconfig="${ARTIFACT_DIR}/tenant-admin-kubeconfig"
    ca_file=$(mktemp)
    oc config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
        | base64 -d > "${ca_file}" 2>/dev/null || true

    local login_args=(--server "${api_url}")
    if [ -s "${ca_file}" ]; then
        login_args+=(--certificate-authority "${ca_file}")
    else
        echo "WARNING: no CA found in the current kubeconfig — using insecure login"
        login_args+=(--insecure-skip-tls-verify)
    fi

    # The OAuth pods may need a moment to pick up the new identity provider.
    # set +x: the oc login command line carries the password in plaintext.
    local attempt logged_in=false
    set +x
    for attempt in 1 2 3 4 5 6; do
        if oc login --kubeconfig "${user_kubeconfig}" "${login_args[@]}" \
            --username "${TENANT_ADMIN_USER}" --password "${TENANT_ADMIN_PASSWORD}"; then
            logged_in=true
            break
        fi
        echo "oc login attempt ${attempt} failed — retrying in 10s"
        sleep 10
    done
    set -x
    if [ "${logged_in}" != "true" ]; then
        echo "ERROR: could not log in as ${TENANT_ADMIN_USER} (IDP propagation?)" >&2
        exit 1
    fi

    # oc login stores a PATH reference to --certificate-authority; embed the
    # CA contents so the kubeconfig stays self-contained once the temp file
    # is removed (prow artifacts, copying the file elsewhere, ...).
    if [ -s "${ca_file}" ]; then
        local cluster_name
        cluster_name=$(oc config view --kubeconfig "${user_kubeconfig}" \
            -o jsonpath='{.clusters[0].name}')
        oc config --kubeconfig "${user_kubeconfig}" set-cluster "${cluster_name}" \
            --server "${api_url}" \
            --certificate-authority "${ca_file}" --embed-certs=true
    fi
    rm -f "${ca_file}"
    oc --kubeconfig "${user_kubeconfig}" whoami

    set +x
    echo "Project-admin credentials (also in ${ARTIFACT_DIR}/tenant-admin-credentials.txt):"
    echo "  user:     ${TENANT_ADMIN_USER}"
    echo "  password: ${TENANT_ADMIN_PASSWORD}"
    printf 'user: %s\npassword: %s\n' "${TENANT_ADMIN_USER}" "${TENANT_ADMIN_PASSWORD}" \
        > "${ARTIFACT_DIR}/tenant-admin-credentials.txt"
    chmod 600 "${ARTIFACT_DIR}/tenant-admin-credentials.txt"
    set -x

    # From here on, everything runs as the project-admin user.
    echo "Switching KUBECONFIG to the project-admin user: ${user_kubeconfig}"
    export KUBECONFIG="${user_kubeconfig}"

    # Fail fast if the deployment did not make the CAPI resources available
    # to namespace admins (otherwise the manifest apply fails later with a
    # confusing Forbidden error).
    if ! oc get clusters.cluster.x-k8s.io -n "${TENANT_NAMESPACE}" &>/dev/null; then
        echo "ERROR: ${TENANT_ADMIN_USER} cannot list clusters.cluster.x-k8s.io:" >&2
        echo "       the CAPI/CAPOA resources are not aggregated into the 'admin'" >&2
        echo "       role. The DEPLOYMENT must provide that:" >&2
        echo "         - standalone: deploy-caas-standalone.sh aggregates the manager roles" >&2
        echo "         - MCE: proper aggregate roles (product gap, pending upstream)" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Step 2: deploy tenant cluster
# ---------------------------------------------------------------------------
function deploy_tenant_cluster() {
    set +x
    PULL_SECRET_B64=$(echo "${PULL_SECRET}" | base64 -w0)
    INFRA_KUBECONFIG_B64=$(base64 -w0 < "${KUBECONFIG}")
    set -x

    ensure_namespace_active

    export CLUSTER_NAME TENANT_NAMESPACE OCP_VERSION OCP_MAJOR_MINOR BASE_DOMAIN \
           STORAGE_CLASS CSI_STORAGE_CLASS SSH_AUTHORIZED_KEY PULL_SECRET_B64 INFRA_KUBECONFIG_B64

    oc apply -f <(envsubst < "${REPO_DIR}/${TENANT_CLUSTER_MANIFEST}")
}

# ---------------------------------------------------------------------------
# Step 3: wait for installation
# ---------------------------------------------------------------------------
# All CAPI machines must reach the Running phase: the AgentClusterInstall
# can report installed while the machines are still stuck in Provisioning,
# which leaves the tenant cluster half-deployed.
function machines_running() {
    local total running
    total=$(oc get machines.cluster.x-k8s.io -n "${TENANT_NAMESPACE}" \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')
    running=$(oc get machines.cluster.x-k8s.io -n "${TENANT_NAMESPACE}" \
        -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | wc -w)
    [ "${total}" -gt 0 ] && [ "${total}" -eq "${running}" ]
}

# Dumps the Machine -> KubevirtMachine -> VMI chain so a stuck wait shows
# exactly which link broke: Machine -> KubevirtMachine -> VMI/pod on the
# hub -> VM -> node in the tenant.
function machines_status() {
    echo "machines:"
    oc get machines.cluster.x-k8s.io -n "${TENANT_NAMESPACE}" \
        -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,READY:.status.ready \
        --no-headers 2>/dev/null || true
    echo "kubevirtmachines:"
    oc get kubevirtmachines.infrastructure.cluster.x-k8s.io -n "${TENANT_NAMESPACE}" \
        -o custom-columns=NAME:.metadata.name,READY:.status.ready,ADDRESS:.status.addresses[0].address \
        --no-headers 2>/dev/null || true
    echo "vmis:"
    oc get vmis.kubevirt.io -n "${TENANT_NAMESPACE}" \
        -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,NODE:.status.nodeName \
        --no-headers 2>/dev/null || true
}

function wait_for_installation() {
    echo "Waiting for AgentClusterInstall to reach installed state"

    local deadline=$(( $(date +%s) + INSTALL_TIMEOUT_MIN * 60 ))
    local finalizing_extended=false

    while true; do
        local state
        state=$(oc get agentclusterinstall "${CLUSTER_NAME}" \
            -n "${TENANT_NAMESPACE}" \
            -o jsonpath='{.status.debugInfo.state}' 2>/dev/null || echo "")

        if [[ "${state}" == "installed" || "${state}" == "adding-hosts" ]]; then
            if machines_running; then
                echo "Installation complete (ACI: ${state}, all machines Running)"
                return 0
            fi
            echo "ACI state: ${state} — machines not Running yet:"
            machines_status | sed 's/^/  /'
        else
            echo "ACI state: ${state}"
        fi

        if [[ "${state}" == "finalizing" && "${finalizing_extended}" == "false" ]]; then
            echo "Cluster finalizing (operators deploying) — extending deadline by ${FINALIZING_TIMEOUT_MIN}m"
            deadline=$(( deadline + FINALIZING_TIMEOUT_MIN * 60 ))
            finalizing_extended=true
        fi

        if [[ "${state}" == "error" ]]; then
            echo "ERROR: Installation failed"
            oc get agentclusterinstall "${CLUSTER_NAME}" \
                -n "${TENANT_NAMESPACE}" \
                -o jsonpath='{.status.debugInfo.stateInfo}' 2>/dev/null || true
            return 1
        fi

        if [[ $(date +%s) -gt ${deadline} ]]; then
            echo "ERROR: Timed out waiting for installation"
            echo "Machines:"
            machines_status | sed 's/^/  /'
            return 1
        fi

        sleep 60
    done
}

# ---------------------------------------------------------------------------
# Step 4: extract tenant kubeconfig
# ---------------------------------------------------------------------------
function get_tenant_kubeconfig() {
    local kubeconfig_path="${ARTIFACT_DIR}/tenant-kubeconfig"

    # The CAPI kubeconfig (key "value", maintained by the control plane
    # provider) authenticates as system:admin and carries the correct Route
    # endpoint on port 443. The ACI-generated admin-kubeconfig instead
    # points to the apiserver port 6443, which the hub router does not
    # serve, making it unusable from outside the hub.
    oc get secret "${CLUSTER_NAME}-kubeconfig" \
        -n "${TENANT_NAMESPACE}" \
        -o jsonpath='{.data.value}' \
        | base64 -d > "${kubeconfig_path}"

    echo "${kubeconfig_path}"
}

# ---------------------------------------------------------------------------
# Step 5: smoke-check the tenant cluster through its kubeconfig
# ---------------------------------------------------------------------------
function smoke_check_tenant() {
    local tenant_kubeconfig="${1}"
    echo "Smoke-checking tenant cluster via ${tenant_kubeconfig}"
    oc --kubeconfig "${tenant_kubeconfig}" get nodes
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "=== CAAS tenant cluster deployment ==="
echo "Cluster: ${CLUSTER_NAME} | OCP: ${OCP_VERSION} | Namespace: ${TENANT_NAMESPACE}"

ensure_assisted_service
setup_tenant_admin_user
deploy_tenant_cluster
wait_for_installation
TENANT_KUBECONFIG=$(get_tenant_kubeconfig)
smoke_check_tenant "${TENANT_KUBECONFIG}"

echo "Tenant kubeconfig: ${TENANT_KUBECONFIG}"
echo "=== CAAS tenant cluster ready ==="
