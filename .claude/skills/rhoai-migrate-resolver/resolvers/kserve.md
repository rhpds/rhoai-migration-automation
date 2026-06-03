# Resolver — KServe / Model Serving

This is the largest migration section. It covers every `component / kserve`, `component / modelmeshserving`, `workload / kserve`, and `dependency / {servicemesh-operator-v2, serverless-operator, authorino-operator}` check from rhai-cli.

## Why

> The model serving architecture is evolving to support advanced LLM inference topologies through LLM-d. Neither KServe Serverless nor ModelMesh were designed for the routing and scaling patterns that distributed LLM inference requires. Additionally, KServe Serverless depends on Knative, which is incompatible with OpenShift Service Mesh 3 (embedded in OCP 4.19+).
>
> — architectural-changes.md § *Model Serving: Removal of ModelMesh and KServe Serverless*

> All model serving workloads must be converted to RawDeployment (Standard) mode before the migration. […] Models left unconverted will return HTTP 503 errors after the upgrade.
>
> — architectural-changes.md § *Model Serving Migration*

## The migration sequence matters

Per migration guide §2.8.3, in this order. Skipping ahead leaves the cluster in a half-migrated state where the RHOAI operator reconciler fights against workloads.

1. **Back up** the `inferenceservice-config` ConfigMap (§2.8.6)
2. **Convert** every Serverless `InferenceService` to RawDeployment via `serverless-to-raw.sh` (§2.8.7.1)
3. **Convert** every ModelMesh `InferenceService` to RawDeployment via `modelmesh-to-raw.sh`, including its multi-model `ServingRuntime` (§2.8.7.2)
4. **Verify** InferenceServices are healthy on the new mode (§2.8.7.3)
5. **Update** the `inferenceservice-config` ConfigMap with the hardware-profile ignorelist via `hardwareprofiles-ignorelist.sh` (§2.8.8)
6. Set `kserve.serving.managementState: Removed` on the DSC (§2.8.9)
7. Set `modelmeshserving.managementState: Removed` on the DSC
8. Set `serviceMesh.managementState: Removed` on the DSCI
9. Uninstall the three operators: OpenShift Serverless, Service Mesh v2, standalone Authorino

Re-run `rhai-cli lint --checks "*kserve*" --checks "*modelmesh*"` after each major step.

---

## § Convert Serverless InferenceServices to RawDeployment

**rhai-cli signal:** `workload / kserve / impacted-workloads` referencing Serverless ISVCs.

Migration guide §2.8.7.1 ships `serverless-to-raw.sh` as the **official** conversion path. Earlier revisions of this resolver claimed no helper scripts exist in the shipped image — that was wrong. The helper is at `/opt/rhai-upgrade-helpers/model-serving/before-upgrade/serverless-to-raw.sh` inside the rhai-cli container.

Enumerate first via rhai-cli (matches the guide's discovery step):

```
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli lint --target-version 3.3.2 --verbose \
  --checks "*kserve*" --isvc-deployment-mode serverless
```

Per namespace, dry-run then apply. The script is interactive — it has **two prompts** to step through:

1. *Selection prompt*: choose which ISVCs to migrate. Type `all` (or specific numbers like `1 3 5`).
2. *Naming prompt*: option `1` for original names (in-place replacement) or `2` for `-raw` suffix (side-by-side). Choose `1` if the original name matters for downstream callers (workshop default); choose `2` if you want side-by-side validation before retiring the originals.

```
NS=<namespace>

oc exec -n rhai-migration rhai-cli-0 -it -- \
  /opt/rhai-upgrade-helpers/model-serving/before-upgrade/serverless-to-raw.sh \
  --dry-run -n "$NS"

# Once the dry-run looks right, apply for real. With option 1 (in-place),
# pass --delete-existing so the script deletes the legacy ISVC + ServingRuntime
# + auth resources + Istio route before applying the rewritten YAML:
oc exec -n rhai-migration rhai-cli-0 -it -- \
  /opt/rhai-upgrade-helpers/model-serving/before-upgrade/serverless-to-raw.sh \
  --delete-existing -n "$NS"
```

Generated files land under `/tmp/rhoai-upgrade-backup/model-serving/serverless-to-raw/<isvc>/` inside the pod (an `original/` snapshot for rollback + a `raw-original-names/` rewrite). The script handles auth resources automatically based on the ISVC's `security.opendatahub.io/enable-auth` annotation.

If you ran with option `2` (`-raw` suffix), the legacy resources are not touched by the script — delete them by hand once you're satisfied the `-raw` copies serve correctly (guide §2.8.7.1 step 5):

```
oc get isvc -n "$NS" -o json | jq -r '.items[]
  | select(.status.deploymentMode == "Serverless"
        or .metadata.annotations["serving.kserve.io/deploymentMode"] == "Serverless")
  | .metadata.name' \
  | while read -r name; do oc delete isvc "$name" -n "$NS"; done
```

### Fallback — manual recreate

Only if the helper script is unavailable or fails on a workload it can't handle. The KServe admission webhook refuses in-place `deploymentMode` changes (`update rejected: deploymentMode cannot be changed from 'Serverless' to 'RawDeployment'`), so the manual path is back-up, delete, recreate. Full procedure: https://access.redhat.com/articles/7134025.

```
NS=<namespace>; NAME=<isvc>
oc get isvc "$NAME" -n "$NS" -o yaml \
  | yq eval 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .metadata.managedFields, .status)' - \
  > "/tmp/isvc-${NS}-${NAME}.yaml"
yq -i '.metadata.annotations."serving.kserve.io/deploymentMode" = "RawDeployment"' "/tmp/isvc-${NS}-${NAME}.yaml"
oc delete isvc "$NAME" -n "$NS"
oc apply -f "/tmp/isvc-${NS}-${NAME}.yaml"
```

### Verify

```
oc get isvc -n "$NS" -o json \
  | jq -r '["NAME","DEPLOYMENT_MODE","READY"], (.items[] | [.metadata.name, .status.deploymentMode, (.status.conditions[] | select(.type=="Ready") | .status)]) | @tsv' \
  | column -t
```

All converted ISVCs should show `DEPLOYMENT_MODE=RawDeployment`, `READY=True`.

---

## § Convert ModelMesh InferenceServices to RawDeployment

**rhai-cli signal:** `workload / kserve / impacted-workloads` referencing ModelMesh ISVCs (multi-model serving).

Migration guide §2.8.7.2 ships `modelmesh-to-raw.sh` as the **official** path. The helper discovers ModelMesh ISVCs in `--from-ns`, prompts you to select models and a runtime template, configures storage, and creates the new single-model RawDeployment ServingRuntime + InferenceService.

> **Two flag combinations — they don't compose:**
>
> - `--from-ns <A> --target-ns <B>` (source ≠ target) supports `--dry-run` for safe preview. Source and target equal produces `✗ Error: --from-ns and --target-ns cannot be the same`.
> - `--from-ns <A> --preserve-namespace` runs *in-place*. It is destructive and cannot be combined with `--dry-run` (`✗ Error: --dry-run and --preserve-namespace cannot be used together`). The interactive prompts (which ISVCs / which runtime template) are the safety net.

> **Known script bug — PVC-backed models.** When the original ModelMesh ISVC used PVC storage (`storage: { key: pvc-models, path: ... }`), `modelmesh-to-raw.sh` transcribes that block verbatim into the new RawDeployment ISVC. The KServe admission webhook rejects it with `storage type must be one of [s3, hdfs, webhdfs]. storage type [pvc] is not supported`, and the ReplicaSet stays at 0. Patch the ISVC to the KServe `storageUri` form post-script:
>
> ```
> oc patch isvc <name> -n <ns> --type=json -p='[
>   {"op":"remove","path":"/spec/predictor/model/storage"},
>   {"op":"add","path":"/spec/predictor/model/storageUri","value":"pvc://<pvc-name>/<path>"}
> ]'
> ```
>
> S3-backed ModelMesh ISVCs migrate cleanly (S3 is a supported KServe storage type) — only PVC-backed ones hit this gap.

Enumerate first:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli lint --target-version 3.3.2 --verbose \
  --checks "*kserve*" --isvc-deployment-mode modelmesh
```

**Cross-namespace** (preview-friendly):

```
oc exec -n rhai-migration rhai-cli-0 -it -- \
  /opt/rhai-upgrade-helpers/model-serving/before-upgrade/modelmesh-to-raw.sh \
  --from-ns <source-namespace> --target-ns <target-namespace> --dry-run

oc exec -n rhai-migration rhai-cli-0 -it -- \
  /opt/rhai-upgrade-helpers/model-serving/before-upgrade/modelmesh-to-raw.sh \
  --from-ns <source-namespace> --target-ns <target-namespace>
```

**Same-namespace in-place** (keeps the original name, no cross-namespace storage permission setup; no dry-run):

```
oc exec -n rhai-migration rhai-cli-0 -it -- \
  /opt/rhai-upgrade-helpers/model-serving/before-upgrade/modelmesh-to-raw.sh \
  --from-ns <namespace> --preserve-namespace
```

To inspect generated YAML *before* an in-place run, dry-run against a scratch target namespace, review the files inside the rhai-cli pod, then drop the scratch namespace and execute `--preserve-namespace`:

```
oc create ns mm-preview 2>/dev/null || true
oc exec -n rhai-migration rhai-cli-0 -it -- \
  /opt/rhai-upgrade-helpers/model-serving/before-upgrade/modelmesh-to-raw.sh \
  --from-ns <namespace> --target-ns mm-preview --dry-run
oc delete ns mm-preview
```

> **Storage-class gotcha (RWO PVCs):** if the ModelMesh runtime mounts a `ReadWriteOnce` PVC (common with `gp3-csi`), scale the ModelMesh `ServingRuntime` to `replicas: 0` and wait for its pod to terminate *before* applying the new ISVC. Otherwise the new pod can land on a different node and hang with `Multi-Attach error`. On RWX storage this is unnecessary.

Once the new RawDeployment is `Ready=True`, delete the legacy ModelMesh ISVCs and multi-model ServingRuntimes per guide §2.8.7.2 step 5:

```
oc get isvc -n <source-namespace> -o json | jq -r '.items[]
  | select(.status.deploymentMode == "ModelMesh"
        or .metadata.annotations["serving.kserve.io/deploymentMode"] == "ModelMesh")
  | .metadata.name' \
  | while read -r name; do oc delete isvc "$name" -n <source-namespace>; done

oc get servingruntimes.serving.kserve.io -n <source-namespace> -o json \
  | jq -r '.items[] | select(.spec.multiModel==true) | .metadata.name' \
  | while read -r name; do oc delete servingruntime "$name" -n <source-namespace>; done
```

### Verify

```
oc get servingruntime -A -o json \
  | jq -r '.items[] | select(.spec.multiModel==true) | "\(.metadata.namespace)/\(.metadata.name)"'
```

No `multiModel=true` ServingRuntime should remain.

#### Stale ModelMesh resources are common

Even after every active ModelMesh ISVC is converted, **leftover** ServingRuntimes (`multiModel: true`) and unreferenced ISVCs are easy to miss — they live in user namespaces and don't show up in dashboards once dashboards switch from "Multi-model serving" to KServe-only. Sweep:

```
# ServingRuntimes with multiModel=true and no ISVC referencing them
oc get servingruntime -A -o json | jq -r '
  .items[]
  | select(.spec.multiModel==true)
  | "\(.metadata.namespace)/\(.metadata.name)  (age: \((now - (.metadata.creationTimestamp | fromdateiso8601)) / 86400 | floor) days)"
'

# ModelMesh ISVCs (annotation OR status mode) — even if 0 from the active sweep above,
# also check status.deploymentMode in case rhai-cli only matched one source
oc get isvc -A -o json | jq -r '
  .items[]
  | select((.metadata.annotations."serving.kserve.io/deploymentMode" // "") == "ModelMesh"
           or (.status.deploymentMode // "") == "ModelMesh")
  | "\(.metadata.namespace)/\(.metadata.name)  status.ready=\((.status.conditions[]? | select(.type=="Ready") | .status) // "unknown")"
'
```

Real-world counts: long-lived 2.x clusters often carry forgotten ModelMesh test resources from years prior — 1 stale ISVC and 3 multi-model ServingRuntimes 200+ days old is a typical sweep result, sometimes older. None are active workloads, but the deprecated CRDs need clearing before upgrade. Delete with `oc delete isvc <name> -n <ns>` and `oc delete servingruntime <name> -n <ns>`.

> **Don't confuse v1alpha1 ServingRuntime with ModelMesh.** Several KServe single-model ServingRuntimes (`multiModel: false`) ship at `serving.kserve.io/v1alpha1` — that's just the API version, not a sign of ModelMesh. They're safe to leave untouched. The only signal for ModelMesh is `spec.multiModel: true`.

---

## § Back up and update the inferenceservice-config ConfigMap

**rhai-cli signal:** `component / kserve / configmap` (wording varies).

Two steps from migration guide §2.8.6 and §2.8.8. **Run these AFTER every ISVC is converted to RawDeployment**, not before — the guide's order is back up → convert ISVCs → update ConfigMap.

Back up first (per §2.8.6):

```
mkdir -p /tmp/rhoai-upgrade-backup
oc get configmap inferenceservice-config -n redhat-ods-applications -o yaml \
  > /tmp/rhoai-upgrade-backup/inferenceservice-config-backup.yaml
```

Then apply the hardware-profile ignorelist via the official helper (per §2.8.8). The helper marks the ConfigMap `opendatahub.io/managed=false` *and* adds the hardware-profile annotations to `serviceAnnotationDisallowedList` in one shot:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-upgrade-helpers/model-serving/before-upgrade/hardwareprofiles-ignorelist.sh \
  -n redhat-ods-applications
```

Verify:

```
oc get configmap inferenceservice-config -n redhat-ods-applications \
  -o yaml | grep "hardware" -B 2 -A 2
oc get configmap inferenceservice-config -n redhat-ods-applications \
  -o jsonpath='managed={.metadata.annotations.opendatahub\.io/managed}{"\n"}'
```

`managed=false` and the ignorelist should both be present.

### Restore post-upgrade

After the upgrade, run the after-upgrade helper to restore `managed=true` (per §4.9.1):

```
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-upgrade-helpers/model-serving/after-upgrade/managed-inferenceservice-config.sh \
  -n redhat-ods-applications
```

> The `managed=false` annotation prevents the upgrade from redeploying ISVCs. If a workload owner wanted fresh runtime images post-upgrade (newer vLLM build etc.), they restart their own predictors after this step.

---

## § Disable Serverless mode on the DSC

**rhai-cli signal:** `component / kserve / serving-removal` or `serverless-removal` with impact `critical`.

```
oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{
  "spec": {
    "components": {
      "kserve": {
        "defaultDeploymentMode": "RawDeployment",
        "serving": { "managementState": "Removed" }
      }
    }
  }
}'
```

### Verify

```
oc get dsc -o jsonpath='{.items[0].spec.components.kserve.defaultDeploymentMode}'; echo
oc get dsc -o jsonpath='{.items[0].spec.components.kserve.serving.managementState}'; echo
# expect: RawDeployment / Removed
```

---

## § Disable ModelMesh on the DSC

**rhai-cli signal:** `component / modelmeshserving / removal` with impact `critical`.

```
oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{
  "spec": { "components": { "modelmeshserving": { "managementState": "Removed" } } }
}'
```

### Verify

```
oc get dsc -o jsonpath='{.items[0].spec.components.modelmeshserving.managementState}'; echo
# expect: Removed
# ModelMesh controllers should disappear from redhat-ods-applications
oc get pods -n redhat-ods-applications | grep -i modelmesh || echo "no modelmesh pods — good"
```

---

## § Disable Service Mesh on the DSCI

**rhai-cli signal:** `dependency / servicemesh-operator-v2 / upgrade` or the DSCI check.

```
oc patch $(oc get dsci -o name | head -n1) --type=merge -p '{
  "spec": { "serviceMesh": { "managementState": "Removed" } }
}'
```

### Verify

```
oc get dsci -o jsonpath='{.items[0].spec.serviceMesh.managementState}'; echo
# expect: Removed
# SMCP should be removed or transitioning
oc get smcp -n istio-system
```

---

## § Uninstall OpenShift Serverless

**rhai-cli signal:** `dependency / serverless-operator / uninstall`.

```
# Remove KNativeServing CR first (if present)
oc delete knativeserving knative-serving -n knative-serving --ignore-not-found

# Then remove the operator subscription + CSV
oc get subscription -n openshift-serverless serverless-operator -o jsonpath='{.status.installedCSV}{"\n"}' \
  | xargs -I{} oc delete csv {} -n openshift-serverless --ignore-not-found
oc delete subscription serverless-operator -n openshift-serverless --ignore-not-found

# Clean up the namespace if unused
oc delete namespace knative-serving --ignore-not-found
oc delete namespace openshift-serverless --ignore-not-found
```

---

## § Uninstall Service Mesh v2

**rhai-cli signal:** `dependency / servicemesh-operator-v2 / uninstall`.

**Callout:** if any non-RHOAI workload on the cluster depends on Service Mesh v2, upgrade them to v3 first. Do NOT uninstall v2 and leave v2-dependent workloads stranded.

```
# Delete the SMCP (if not already gone from the DSCI change above)
oc delete servicemeshcontrolplane data-science-smcp -n istio-system --ignore-not-found

# Delete any leftover SMMR — DSCI's serviceMesh=Removed deletes the SMCP but does NOT
# delete the SMMR; it lingers with a maistra.io/istio-operator finalizer and is invisible
# to the upgrade until you trigger it explicitly. Do this WHILE the SM v2 operator is
# still installed so the operator can process the finalizer:
oc delete smmr -n istio-system default --ignore-not-found

# Uninstall operator (SMMR must be gone first or this hangs)
oc get subscription -n openshift-operators servicemeshoperator -o jsonpath='{.status.installedCSV}{"\n"}' \
  | xargs -I{} oc delete csv {} -n openshift-operators --ignore-not-found
oc delete subscription servicemeshoperator -n openshift-operators --ignore-not-found

# Kiali / Jaeger if installed for v2:
oc delete subscription kiali-ossm -n openshift-operators --ignore-not-found
oc delete subscription jaeger-product -n openshift-operators --ignore-not-found
```

> The SM v2 operator pod (named `istio-operator-*`) runs in `openshift-operators`, not in `istio-system`. The `istio-system` namespace only hosts the SMCP-controlled workloads (Galley, Pilot, ingress/egress gateways) — when the SMCP is gone, that namespace empties out but the operator that processes finalizers is still alive elsewhere. Order matters: SMMR delete → SMMR finalizer fires → operator uninstall.

---

## § Uninstall standalone Authorino

**rhai-cli signal:** `dependency / authorino-operator / uninstall`.

Standalone Authorino is replaced by Red Hat Connectivity Link (RHCL) in 3.x. Uninstalling is safe once no LLMInferenceService or other KServe auth workload depends on the standalone install — but **only delete the Subscription**. RHCL also installs into `openshift-operators` (AllNamespaces) and depends on the same `authorino-operator` package; OLM dedupes them to a single shared CSV. Deleting the CSV tears down RHCL's Authorino too.

```
# Subscription-only delete. The CSV stays alive because rhcl-operator's Subscription
# still depends on the same authorino-operator package.
oc delete subscription authorino-operator -n openshift-operators --ignore-not-found
```

Verify the shared CSV is still healthy after the Subscription delete:

```
oc get csv -n openshift-operators | grep authorino-operator
# Expected: authorino-operator.v1.x.y   Authorino Operator   ...   Succeeded
```

> **Earlier revisions** of this resolver had the cleanup capture `installedCSV` from the standalone Subscription and `oc delete csv` it, on the rationale that RHCL lived in a separate namespace (`kuadrant-system`) with its own bundled Authorino CSV. That was only correct when RHCL was installed into `kuadrant-system`. The RHCL v1.3.3 install mode requirement (AllNamespaces / `openshift-operators` — see *§ Install Red Hat Connectivity Link*) shares the CSV with the standalone install. Drop the CSV delete to avoid breaking RHCL.

---

## After

Re-run:

```
oc exec -n rhai-migration rhai-cli-0 -- /opt/rhai-cli/bin/rhai-cli lint --target-version 3.3.2 --verbose --checks "*kserve*" --checks "*modelmesh*"
```

All `critical` / `prohibited` rows in this group should now be gone.
