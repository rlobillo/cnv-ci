# CAAS — CAPOA + KubeVirt tenant clusters on OpenShift

Scripts to deploy and tear down nested OpenShift clusters provisioned by
CAPOA (Cluster API Provider OpenShift Assisted) on top of a KubeVirt-enabled
infra cluster.

By default, `NESTED_CLUSTER_NAME` is `caas-cluster` and `TENANT_NAMESPACE` is
`caas-project`; these values are configured separately.

The manifests are in `manifests/caas/`: `nested-cluster.yaml`,
`nested-cluster-workers.yaml`, and `agentserviceconfig.yaml`.

## Prerequisites

- An OpenShift infra cluster with OpenShift Virtualization (CNV) installed and
  healthy with at least 200G of disk available.
- A shared block StorageClass (ReadWriteMany, `volumeMode: Block`) with enough
  capacity for the tenant VM root disks — required for KubeVirt live migration
  of the masters: RWO root disks leave the VMIs `LiveMigratable=False`
  (`DisksNotLiveMigratable`). Mind that, with replicated storage, a
  three-master tenant needs several times the data its nodes write
- `oc` with infra-cluster access and a cluster-admin kubeconfig for the nested cluster
- `envsubst` (gettext), `jq`, and `python3` for manifest rendering and discovery

## Scripts

| Script | Purpose |
|---|---|
| `caas.yaml` | Shared configuration (versions, namespaces, timeouts, manifest paths, storage classes). Every key can be overridden through a same-named environment variable |
| `deploy-caas-infra-standalone.sh` | **Phase 1** — install the CAAS infrastructure directly on the infra cluster: cert-manager, CAPI core, CAPK, the CAPOA control-plane and bootstrap providers, and a standalone assisted-service |
| `deploy-caas-infra-mce.sh` | **Phase 2** (placeholder, not implemented yet) — will install the same infrastructure managed by MCE |
| `create-nested-cluster.sh` | Create the nested cluster on the infra cluster and wait for installation. In project-admin mode, writes `infra-project-admin-kubeconfig`; after installation, extracts the nested cluster's cluster-admin kubeconfig as `nested-cluster-kubeconfig`, smoke-checks it (`oc get nodes`, routed workload) and verifies live-migration readiness on the infra cluster (root-disk PVCs `RWX`/`Block`, VMIs `LiveMigratable=True`) |
| `add-workers-to-nested-cluster.sh` | Apply the day-2 worker pool with the infra project-admin kubeconfig, wait until the requested nested-cluster worker Nodes are `Ready`, then set `Scheduler.spec.mastersSchedulable=false` so workloads stop scheduling on masters |
| `upgrade-nested-cluster.sh` | Upgrade the nested cluster through the CVO update graph: discover the farthest published release reachable from the current one (or upgrade to a pinned `UPGRADE_VERSION`), run `oc adm upgrade`, wait for the rollout and the control plane to settle, then re-align the OACP `distributionVersion`; requires the OACP `upgradePolicy: Unrestricted` (created that way by `nested-cluster.yaml` — CAPOA's `Managed` default reverts externally-initiated upgrades); collects the nested-cluster state and the OACP into `ARTIFACT_DIR` |
| `test-master-live-migration.sh` | Live-migrate the master VMIs, selected by the CAPK role label `cluster.x-k8s.io/role=control-plane` (one `VirtualMachineInstanceMigration` per VMI, all concurrent — a bash port of origin's `test/extended/kubevirt/migration.go`), verify every nested Node stays Ready through the migrations and the control plane settles afterwards (no degraded ClusterOperators, ClusterVersion not `Failing`); collects VMIs/VMIMs/events and nested-cluster state into `ARTIFACT_DIR` |
| `test-workload-live-migration.sh` | Live-migrate the nested node hosting a test workload and verify the workload keeps serving through the migration: zero HTTPS failures against a Route (probed end-to-end from the runner via the infra wildcard passthrough route), pod not restarted or rescheduled (data-plane signal complementing `test-master-live-migration.sh`). The workload lands on a worker when day-2 workers exist (masters unschedulable), on a schedulable master otherwise |
| `run-kubevirt-csi-tests.sh` | Run the upstream kubevirt/csi-driver storage e2e suite against the nested cluster, fetching `hack/test-driver.yaml` verbatim from kubevirt/csi-driver (only the tenant StorageClass name is patched); applies upstream's ginkgo skips, runs the OCP LUNStressTest (`manifests/caas/kubevirt-csi-ocp.yaml`) and a second RWX pass with `test-driver-rwx.yaml` |
| `run-cloud-provider-kubevirt-e2e.sh` | Run the upstream kubevirt/cloud-provider-kubevirt e2e suite against the nested cluster: creates a LoadBalancer Service in the tenant cluster, verifies the KubeVirt CCM creates a corresponding Service in the infra namespace, and waits for external IP assignment. The curl step is expected to fail with the current CAAS CCM configuration (CNV-100829). Accepts the tenant kubeconfig as `$1` or falls back to `${ARTIFACT_DIR}/nested-cluster-kubeconfig` |
| `delete-nested-cluster.sh` | Delete the nested cluster by removing its infra project namespace and waiting for the Kubernetes garbage collection to complete; verifies that its PVs were reclaimed — exits non-zero if anything is left behind. Never intervenes in the teardown |
| `undeploy-caas-infra-standalone.sh` | **Phase 1** — remove everything `deploy-caas-infra-standalone.sh` installed (providers, standalone assisted-service, cert-manager). Run `delete-nested-cluster.sh` first |

## Typical flow

```sh
export ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
export KUBECONFIG=<infra-cluster-admin-kubeconfig>
export INFRA_PROJECT_ADMIN_KUBECONFIG="${ARTIFACT_DIR}/infra-project-admin-kubeconfig"
export NESTED_CLUSTER_KUBECONFIG="${ARTIFACT_DIR}/nested-cluster-kubeconfig"

./hack/caas/deploy-caas-infra-standalone.sh
./hack/caas/create-nested-cluster.sh   # writes both kubeconfigs to ARTIFACT_DIR
./hack/caas/test-master-live-migration.sh  # optional: live-migrate the masters
./hack/caas/add-workers-to-nested-cluster.sh  # uses infra project-admin and nested-cluster kubeconfigs

# optional: live-migrate a worker node while a workload runs (data-plane signal)
./hack/caas/test-workload-live-migration.sh

# optional: upgrade the nested cluster to the farthest reachable published release
./hack/caas/upgrade-nested-cluster.sh
# (or pinned: UPGRADE_VERSION=5.0.1 ./hack/caas/upgrade-nested-cluster.sh)

# validate the nested cluster, e.g.
oc --kubeconfig "$ARTIFACT_DIR/nested-cluster-kubeconfig" get nodes
./hack/caas/run-kubevirt-csi-tests.sh  # upstream kubevirt-csi storage e2e suite

./hack/caas/delete-nested-cluster.sh
```

The nested cluster installs the same OpenShift version the infra cluster runs;
override with `OCP_VERSION` only when running against a pre-release infra cluster.

## Artifacts

`create-nested-cluster.sh` writes to `ARTIFACT_DIR` (default `/tmp/artifacts`):

- `infra-project-admin-kubeconfig` — project-admin kubeconfig for the CAAS project on the infra cluster
- `nested-cluster-kubeconfig` — cluster-admin kubeconfig of the nested cluster
