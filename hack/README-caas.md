# CAAS — CAPOA + KubeVirt tenant clusters on OpenShift

Scripts to deploy and tear down OpenShift *tenant* clusters provisioned by
CAPOA (Cluster API Provider OpenShift Assisted) on top of a KubeVirt-enabled
hub cluster.

The tenant clusters are compact (three schedulable masters) and run as
KubeVirt VMs on the hub pod network.

## Prerequisites

- An OpenShift hub cluster with OpenShift Virtualization (CNV) installed and
  healthy
- A block-mode RWO StorageClass with enough capacity for the tenant VM root
  disks — mind that, with replicated storage, a three-master tenant needs
  several times the data its nodes write
- `oc` with cluster-admin access to the hub
- `envsubst` (gettext) and `python3` for manifest rendering and discovery

## Scripts

| Script | Purpose |
|---|---|
| `caas.yaml` | Shared configuration (versions, namespaces, timeouts, manifest paths). Every key can be overridden through a same-named environment variable |
| `deploy-caas-standalone.sh` | **Phase 1** — install the CAAS infrastructure directly on the hub: cert-manager, CAPI core, CAPK, the CAPOA control-plane and bootstrap providers, and a standalone assisted-service |
| `deploy-caas-mce.sh` | **Phase 2** (placeholder, not implemented yet) — will install the same infrastructure managed by MCE |
| `create-caas-tenant.sh` | Deploy the tenant cluster: apply the manifests, wait for the installation to complete, extract the tenant kubeconfig into `ARTIFACT_DIR` and smoke-check it (`oc get nodes`) |
| `delete-caas-tenant.sh` | Delete the tenant cluster by removing its namespace and waiting for the Kubernetes garbage collection to complete; verifies that the tenant PVs were reclaimed — exits non-zero if anything is left behind. Never intervenes in the teardown |
| `undeploy-caas-standalone.sh` | **Phase 1** — remove everything `deploy-caas-standalone.sh` installed (providers, standalone assisted-service, cert-manager). Run `delete-caas-tenant.sh` first |

## Typical flow

```sh
export KUBECONFIG=<hub-kubeconfig>

./hack/deploy-caas-standalone.sh
./hack/create-caas-tenant.sh   # tenant kubeconfig lands in $ARTIFACT_DIR/tenant-kubeconfig

# validate the tenant with its kubeconfig, e.g.
oc --kubeconfig "$ARTIFACT_DIR/tenant-kubeconfig" get nodes

./hack/delete-caas-tenant.sh
./hack/undeploy-caas-standalone.sh   # optional: full teardown of the hub-side infra
```

The tenant installs the same OpenShift version the hub runs; override with
`OCP_VERSION` only when running against a pre-release hub.

## Artifacts

`create-caas-tenant.sh` writes to `ARTIFACT_DIR` (default `/tmp/artifacts`):

- `tenant-kubeconfig` — admin kubeconfig of the tenant cluster
