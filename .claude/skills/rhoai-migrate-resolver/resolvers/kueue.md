# Resolver — Kueue

**rhai-cli signal:** `component / kueue / *` with impact `critical` or `prohibited`.

## Why

> **Critical:** The Kueue component management state must be set to "Removed" *before* upgrading. Leaving it as "Managed" causes **unrecoverable cluster instability**.
>
> — architectural-changes.md § *Workload Scheduling: Kueue Transition*

RHOAI 2.25 deprecated the embedded Kueue distribution; RHOAI 3.3 removes it. The failure mode if Kueue is left `Managed` at upgrade time is **cluster-wide, not RHOAI-scoped**: the Kueue admission webhook intercepts Job creation across every namespace. During the OLM-managed operator upgrade, the running webhook server and the new Kueue CRDs fall out of schema-version sync, and the webhook then rejects or mangles Job submissions for any workload on the cluster — RHOAI or otherwise. That includes OLM bundle unpacks, image builds, CronJobs, and other tenants' batch workloads. The only documented recovery once this is in progress is an etcd restore (see [BACKUP-RESTORE.md](../../../../BACKUP-RESTORE.md) Scenario B). After migration, Kueue features can be re-enabled via the **Red Hat Build of Kueue** (RHBoK) operator — but that's a post-upgrade step.

**Upstream fix tracking:** RHOAIENG-48690 (root cause — Closed), RHOAIENG-52872 (webhook fix re-enable — Unassigned at the time of writing), RHAISTRAT-1711 (overall strategy: 2.25.x webhook backport + 3.5 top-level Kueue integration for InferenceService / LLMInferenceService / Notebooks). Until the 2.25.x backport ships, the manual `Removed` step below is the only safeguard.

## Step 0 — gate on prior `managementState`

Per migration guide §2.2, the procedure branches on the current `kueue.managementState`. Read it first:

```
oc get datasciencecluster -A \
  -o jsonpath='{.items[0].spec.components.kueue.managementState}{"\n"}'
```

Branches:

- **`Removed`** or **`Unmanaged`** → migration is already complete. Skip the rest of this resolver; nothing to do.
- **`Managed`** → you have embedded Kueue and **must migrate to Red Hat Build of Kueue (RHBoK) first**. The expected end state is `Unmanaged`, not `Removed`. Do **not** skip ahead and patch directly to `Removed` — that destroys embedded Kueue without installing RHBoK, leaving any Kueue-using workload broken. Follow the *Managed → Unmanaged via RHBoK* section below.
- Anything else (empty / `Failed`) → DSC is mid-reconcile; let it settle or open a support case before continuing.

## Managed → Unmanaged via Red Hat Build of Kueue

### Preserve your queue frameworks (required if you have workloads)

Annotate the embedded Kueue config map before the migration so the framework list survives into RHBoK:

```
oc annotate configmap kueue-manager-config -n redhat-ods-applications \
  opendatahub.io/managed=false --overwrite
```

The guide explicitly warns that without this annotation the enabled-framework list changes — `batch/job`, `kubeflow.org/{mpi,pytorch,tf,xgboost,paddle}job`, `ray.io/{raycluster,rayjob}`, `jobset.x-k8s.io/jobset`, `workload.codeflare.dev/appwrapper` get replaced with the smaller default set `Deployment`, `Pod`, `PyTorchJob`, `RayCluster`, `RayJob`, `StatefulSet`. Annotate first; you almost certainly want the broader set.

### Run the official RHBoK migration procedure

Follow the steps in [Migrating to the Red Hat build of Kueue Operator](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2.25/html/managing_openshift_ai/managing-workloads-with-kueue#migrating-to-the-rhbok-operator_kueue).

> **Important** (from guide §2.2 step 4): do **not** follow the "Next steps" section in the Operator migration guide. Return to this resolver after completing the operator migration steps.

### Verify the migration

Expected end state after RHBoK migration:

```
oc get datasciencecluster -A \
  -o jsonpath='{.items[0].spec.components.kueue.managementState}{"\n"}{.items[0].status.conditions[?(@.type=="KueueReady")].status}{"\n"}'
```

Expected output:

```
Unmanaged
True
```

`Unmanaged` plus `KueueReady=True` means the lint blocker is cleared and the cluster is upgrade-ready.

> **Do NOT patch `kueue.managementState` to `Removed` after RHBoK migration.** `Unmanaged` is the documented end state — `Removed` would tell the RHOAI operator to tear down resources RHBoK is now managing.

## Edge cases

- **The `Managed → Unmanaged` transition stalls.** Known issue (RHOAIENG-61489). Confirm the DSC `KueueReady` condition has settled before installing RHBoK. If `Unmanaged` won't complete, open a support case — don't proceed.
- **The cluster has *external* RHBoK already, with `kueue.managementState: Removed` in the DSC.** Nothing to do — you're already past the migration.
- **The cluster has *no* Kueue users.** Going from `Managed` straight to `Removed` (skipping RHBoK install) is technically possible *if* no workload depends on Kueue. Verify with `oc get -A workloads.kueue.x-k8s.io,localqueues.kueue.x-k8s.io,clusterqueues.kueue.x-k8s.io 2>/dev/null` first — any output means there are real users and you must install RHBoK.

## After

Re-run `rhai-cli lint --target-version 3.3.2 --checks "*kueue*"` to confirm the check passes.
