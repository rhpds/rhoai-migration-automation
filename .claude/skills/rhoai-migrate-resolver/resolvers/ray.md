# Resolver — Ray / CodeFlare

**rhai-cli signal:** `component / ray / *` or `component / codeflare / *`.

> **CodeFlare flips to `Removed`, not Ray.** Earlier revisions of this resolver patched **both** `codeflare` and `ray` to `Removed`. That was wrong — flipping `ray` to `Removed` tears down KubeRay, which is the controller that continues to manage RayClusters in 3.x. Per migration guide §2.7 the `ray_cluster_migration.py pre-upgrade` helper sets **only** `codeflare.managementState: Removed`. Do not touch `ray`.

If you need to make the change by hand (e.g. the helper script isn't available):

```
oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{"spec":{"components":{"codeflare":{"managementState":"Removed"}}}}'
```

## Why

> The upstream Codeflare project is no longer under active development. KubeRay now handles all Ray cluster management independently.
>
> — architectural-changes.md § *Training: Removal of Codeflare Operator*

RHOAI 2.x used CodeFlare to wrap Ray; 3.x drops CodeFlare entirely. KubeRay continues to manage Ray clusters directly. RayCluster CRs survive the upgrade intact, but you should back up each RayCluster YAML first in case reconciliation loses fields during the controller swap.

## Back up all RayCluster YAMLs

```
oc exec -n rhai-migration rhai-cli-0 -- \
  python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py pre-upgrade
```

This:

- Writes each RayCluster CR to `/tmp/rhoai-upgrade-backup/ray/Rhoai-2.x/<ns>_<name>.yaml`
- Also writes the 3.x-equivalent shape to `/tmp/rhoai-upgrade-backup/ray/Rhoai-3.x/<ns>_<name>.yaml`
- Sets `codeflare.managementState: Removed` on the DataScienceCluster — the RHOAI operator then tears down CodeFlare pods (and unsubscribes the operator) as a reaction. The helper does *not* call `oc delete subscription` or `oc delete csv` directly. Earlier revisions of this resolver described it as "uninstalls the CodeFlare Operator (destructive side effect)" — that misstated the mechanism, even though the end result is the same.

**Callout:** only run this when you're ready to commit to the upgrade. Once CodeFlare is gone, automation that depends on its APIs will break.

To enumerate RayClusters without touching CodeFlare:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py list
```

Or directly:

```
oc get raycluster -A
```

## Copy the backup to your workstation

```
oc cp rhai-migration/rhai-cli-0:/tmp/rhoai-upgrade-backup/ray ./ray-backup
```

## Verify

```
# CodeFlare subscription should be gone
oc get subscription -A | grep -i codeflare || echo "codeflare uninstalled — good"

# RayClusters still exist, KubeRay managing them
oc get raycluster -A
oc get pods -n redhat-ods-applications -l app.kubernetes.io/name=kuberay-operator
```

## Callouts

- RayJobs/RayServices are managed by the same KubeRay operator; same backup applies.
- User Ray workloads keep running through the controller swap — no pod restarts are triggered by the CodeFlare removal alone.
