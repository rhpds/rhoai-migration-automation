# Resolver — AI Pipelines (DataSciencePipelinesApplication)

**rhai-cli signal:** `component / datasciencepipelines / *`.

## Why

Pipelines themselves keep running across the 2→3 upgrade, but the DSPA schema changed between 2.25 and 3.x. Deprecated fields (the old `instructLab` block) and legacy v1alpha1 DSPA CRs must be detected before upgrade. Custom RBAC that predates the 2.25 permission refactor also needs review.

No architectural change driver here — this is a schema-deprecation scan (migration guide §2.4).

## Run the pre-upgrade helper

The rhai-cli container ships a script that enumerates every issue in your DSPAs:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  bash /opt/rhai-upgrade-helpers/ai_pipelines/check_before_upgrade.sh
```

It prints one of:

- **OK** → re-run rhai-cli and move on.
- **Warning: deprecated `instructLab` field** → safe to ignore; the field is removed in 3.x but the DSPA reconciler tolerates its presence during upgrade.
- **Deprecated v1alpha1 DSPA found** → upgrade the CRs to v1 (below).
- **Custom RBAC roles detected** → review each listed Role/ClusterRole. The migration doc lists the 3.x role names; if your custom Role grants a verb on a resource the new role also grants, you can leave it. If it grants access to a resource that was removed in 3.x, delete it.

## Upgrade v1alpha1 DSPA CRs to v1

If the helper flags any `apiVersion: datasciencepipelinesapplications.opendatahub.io/v1alpha1` DSPAs:

```
# List them
oc get dspa.v1alpha1.datasciencepipelinesapplications.opendatahub.io -A 2>/dev/null \
  || oc get dspa -A -o json | jq -r '.items[] | select(.apiVersion | endswith("v1alpha1")) | "\(.metadata.namespace)/\(.metadata.name)"'

# For each, export, patch the apiVersion + dspVersion, and re-apply.
# The spec fields are compatible — only the apiVersion changes.
NS=<namespace>; NAME=<dspa>
oc get dspa "$NAME" -n "$NS" -o yaml > /tmp/dspa-$NAME.yaml
# Hand-edit /tmp/dspa-$NAME.yaml:
#   apiVersion: datasciencepipelinesapplications.opendatahub.io/v1
#   spec.dspVersion: v2
oc apply -f /tmp/dspa-$NAME.yaml
```

## Patch the DSPA CRD's storedVersions

Even after every DSPA *resource* is at `v1`, the CRD itself may still list `v1alpha1` in `.status.storedVersions` — a leftover from the days the cluster did serve v1alpha1. The 3.3.2 operator's CRD bump refuses to apply when storedVersions includes a removed version (same class of OLM error as `risk of data loss updating "<crd>": new CRD removes version v1alpha1 that is listed as a stored version`).

Check + patch:

```
oc get crd datasciencepipelinesapplications.datasciencepipelinesapplications.opendatahub.io \
  -o jsonpath='{.status.storedVersions}'; echo
# Expected: ["v1"]   — proceed.
# If you see ["v1alpha1","v1"]: patch.

oc patch crd datasciencepipelinesapplications.datasciencepipelinesapplications.opendatahub.io \
  --subresource=status --type=merge -p '{"status":{"storedVersions":["v1"]}}'
```

Only safe to do this once `oc get dspa -A | grep -c v1alpha1` returns `0`.

## ArgoCD-managed roles — advisory only

`check_before_upgrade.sh` flags any `Role` / `ClusterRole` granting `update` on `datasciencepipelinesapplications/api` that doesn't match the 3.x role name list. On clusters where DSPA-related roles are deployed by ArgoCD (or any other GitOps tool), you'll see lines like:

```
WARNING: Role pipeline-runner in namespace mlops-prod has unexpected verbs on dspa/api
```

**Don't try to fix these by hand.** Patches you apply will be immediately reverted by ArgoCD's reconciliation. Two valid responses:

1. **Leave them.** The 3.x operator auto-creates the 3.x roles in addition; your old ArgoCD-managed roles continue to work or quietly become no-ops. Confirmed advisory on real clusters with 12+ such roles.
2. **Update the GitOps source-of-truth.** If you'd rather have a clean `check_before_upgrade.sh` run, update the role definitions in your ArgoCD application repo to match the 3.x verb list, then sync.

Either way, this isn't a migration blocker.

## Verify

```
# All DSPAs on v1 and v2 pipelines
oc get dspa -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,API:.apiVersion,DSP:.spec.dspVersion'

# No more instructLab deprecation warnings
oc exec -n rhai-migration rhai-cli-0 -- bash /opt/rhai-upgrade-helpers/ai_pipelines/check_before_upgrade.sh
```

## Callouts

- Pipelines themselves (runs, Argo workflows) continue across the upgrade — you don't need to stop them. But pipeline *endpoint URLs* change because of the Route → Gateway API shift (architectural-changes.md § *Networking*), so any external CI/CD that triggers pipelines will need URL updates post-upgrade.
- The DSPA's `objectStorage.minio.deploy: true` option still works in 3.x for dev environments, but production-scale DSPAs should plan to migrate to external S3 per Red Hat guidance.
