# Resolver — OpenShift AI Operator (post-upgrade)

*Covers migration guide §4.1 — citation only; user-facing label is `[operator]`.*

Verify the 3.3.2 operator, DSC/DSCI, pods, and Gateway. Covers the platform-level health check that every other post-upgrade task assumes is green.

## Why

The 2.25.4 operator and 3.3.2 operator have fundamentally different reconcile models — chapter 3's in-place upgrade uninstalls the old CSV and installs the new one in the same namespace. If the DSC is not `Ready` after the upgrade, every other component resolver will hit transient failures as the operator replays its reconcile loop. Validate the operator first, then move on.

Kueue and OSSM3 get a specific callout below because both are known to block the operator from reaching `Ready` if the pre-upgrade step was skipped.

## Verify

```
# Operator + CSV
oc get csv -n redhat-ods-operator -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,DISPLAY:.spec.displayName'
# expect: rhods-operator.3.3.2, Succeeded. No rhods-operator.2.* CSV should remain.

# DSC + DSCI phases — both Ready
oc get dsc -o custom-columns='NAME:.metadata.name,STATUS:.status.phase'
oc get dsci -o custom-columns='NAME:.metadata.name,STATUS:.status.phase'

# Operator-namespace pods
oc get pods -n redhat-ods-operator -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,STATUS:.status.phase'

# Applications-namespace pods
oc get pods -n redhat-ods-applications -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,STATUS:.status.phase'

# Gateway API readiness (3.x routes via Gateway API, not Routes)
oc get gatewayconfigs --all-namespaces -o wide
# expect: default-gateway READY=True
```

## Switch the subscription channel off the migration channel

Once the upgrade is complete (CSV `rhods-operator.3.3.2` Succeeded, DSC + DSCI `Ready`), the subscription is still pointed at `support-required-upgrade` — the verbose, gated channel whose only job is to trigger the 2→3 migration. Leaving it there means **no ongoing z-stream updates**: the migration channel doesn't advance to 3.3.3, 3.3.4, etc. Move the subscription onto the stable 3.3 channel so the cluster receives 3.3.x patch releases normally.

```
# Confirm you're on 3.3.2 first
oc get csv -n redhat-ods-operator -o jsonpath='{range .items[?(@.spec.displayName=="Red Hat OpenShift AI")]}{.metadata.name} {.status.phase}{"\n"}{end}'
# expect: rhods-operator.3.3.2 Succeeded

# See which channels the catalog offers (stable-3.3 stays on the 3.3 z-stream;
# stable-3.x / fast-3.x would track forward into 3.4+)
oc get packagemanifest rhods-operator -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}  {.currentCSV}{"\n"}{end}'

# Switch to the stable 3.3 channel
oc patch subscription rhods-operator -n redhat-ods-operator --type=merge \
  -p '{"spec":{"channel":"stable-3.3"}}'
```

Verify:

```
oc get subscription rhods-operator -n redhat-ods-operator \
  -o jsonpath='channel={.spec.channel}  state={.status.state}  installedCSV={.status.installedCSV}{"\n"}'
# expect: channel=stable-3.3  state=AtLatestKnown  installedCSV=rhods-operator.3.3.2
```

> Keep `installPlanApproval: Manual` if the customer wants to gate future z-stream bumps; flip it to `Automatic` only if they want unattended patching. `stable-3.3` will surface 3.3.x patch InstallPlans; `stable-3.x` would eventually offer a 3.4 minor upgrade, which is a separate planning decision, not a patch — pick `stable-3.3` unless the customer explicitly wants to ride the latest minor.

## Kueue recovery (if pre-upgrade Kueue step was skipped)

If `KueueReady=False` with message `Kueue managementState Managed is not supported, please use Removed or Unmanaged`:

```
oc get dsc -o jsonpath='{.items[0].status.conditions[?(@.type=="KueueReady")].status}{"\n"}{.items[0].status.conditions[?(@.type=="KueueReady")].message}{"\n"}'
```

Recover by flipping Kueue to `Removed` post-upgrade — same patch as in the pre-upgrade resolver:

```
oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{
  "spec": { "components": { "kueue": { "managementState": "Removed" } } }
}'
```

Then verify:

```
oc get dsc -o jsonpath='{range .items[0].status.conditions[?(@.type=="KueueReady")]}{.status} {.reason}{"\n"}{end}'
# expect: True  OR  False Removed
```

Kueue features can be re-enabled post-upgrade via the Red Hat Build of Kueue operator (see architectural-changes.md § *Workload Scheduling: Kueue Transition*) — that's a separate setup step after the migration.

## GatewayConfig stuck "Not Ready" — NetworkPolicy webhook blocks it

**Symptom:** post-upgrade, `oc get gatewayconfig default-gateway --all-namespaces -o wide` shows `READY: False`, and the dashboard URL doesn't resolve.

**Cause:** the RHOAI 3.x GatewayConfig reconciler creates a NetworkPolicy in the `openshift-ingress` namespace to allow ingress traffic to `data-science-gateway`. On clusters with an SRE-managed admission webhook (typical name: `sre-networkpolicies-validation`) restricting NetworkPolicy creation in `openshift-*` namespaces, that POST gets rejected → GatewayConfig sits Not Ready forever.

This has been observed on multiple managed-OpenShift clusters with SRE-managed admission webhooks. Reproducible enough to call a known issue rather than environment-specific — if your cluster has any webhook restricting NetworkPolicy creation in `openshift-*` namespaces, expect to need this fix.

**Fix:** disable the operator-managed NetworkPolicy for the GatewayConfig. The cluster's ingress isolation continues to be enforced by whatever the SRE webhook set up; you're just opting RHOAI out of also writing one.

```
oc patch gatewayconfig default-gateway --type=merge \
  -p '{"spec":{"networkPolicy":{"ingress":{"enabled":false}}}}'
```

Verify:

```
oc get gatewayconfig default-gateway -o jsonpath='phase={.status.phase}  ingressMode={.status.ingressMode}{"\n"}'
# expect: phase=Ready  ingressMode=OcpRoute
```

If you don't run an SRE webhook (most non-managed-OpenShift clusters), the default `networkPolicy.ingress.enabled=true` is fine and you don't need this patch.

## Disconnected-cluster OSSM3 failure

> After upgrading on a disconnected cluster, the `servicemeshoperator3` subscription can fail, leaving DSCI stuck `<not Ready>` and `data-science-gateway` with `Unknown` status.

This is a known issue with a KB article — do not try to resolve inline:

- Confirm the symptom:
  ```
  oc get subscription servicemeshoperator3 -n openshift-operators -o jsonpath='{.status.state}{"\n"}'
  oc get dsci -o jsonpath='{.items[0].status.phase}{"\n"}'
  oc get gateway data-science-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}{"\n"}'
  ```
- Follow the KB: [OpenShift Service Mesh 3.x fails to deploy on a disconnected cluster during Red Hat OpenShift AI installation](https://access.redhat.com/solutions/7141146).

## Service Mesh Operator 3.4.0 breaks the gateway on OCP 4.19–4.21

> **Do not approve the `servicemeshoperator3` upgrade to 3.4.0.** After the RHOAI migration, OLM parks an "upgrade available" InstallPlan in front of the Service Mesh Operator 3 subscription. Approving it (fresh installs hit this too) breaks the OpenShift Gateway API.

**Symptom:** the `openshift-gateway` Istio resource enters a permanent `ReconcileError`:

```
validation error: version "v1.26.2" is end-of-life and cannot be installed; use a supported version
```

Deleting the resource recreates it with the same error; manually editing the version to a supported one (e.g. `v1.30.1`) is reverted within seconds.

**Cause:** on OCP 4.19–4.21 the `cluster-ingress-operator` **hardcodes** the Gateway API Istio version to `v1.26.2` and continuously reconciles the `openshift-gateway` resource back to it. OSSM **3.4.0** added a validation gate that rejects `v1.26.2` as end-of-life. So the version the ingress operator insists on is the version the mesh operator refuses — and the ingress operator always wins the reconcile race. This is **not** an RHOAI bug and **not** a migration limitation; RHOAI validates against Service Mesh **3.2** and does not require 3.4.0. There is **no supported OSSM downgrade**, so prevention is the only clean path.

**Prevent (recommended):** keep the Service Mesh Operator 3 subscription on `installPlanApproval: Manual` and pin it ≤ 3.3.x — do **not** approve the 3.4.0 InstallPlan until the fix ships.

```
# Confirm the installed OSSM3 version and that approval is gated
oc get csv -A -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' | grep servicemeshoperator3
oc get subscription servicemeshoperator3 -n openshift-operators -o jsonpath='approval={.spec.installPlanApproval} channel={.spec.channel}{"\n"}'
# If an unapproved 3.4.0 InstallPlan is waiting, leave it unapproved:
oc get installplan -n openshift-operators -o custom-columns='NAME:.metadata.name,CSV:.spec.clusterServiceVersionNames[*],APPROVED:.spec.approved'
```

**Already on 3.4.0:** the gateway cannot be repaired in place and OSSM cannot be safely downgraded — this is a restore-from-backup support situation, not an inline patch. Do not attempt the `startingCSV` / manual-downgrade workarounds circulating informally; they have broken clusters in testing.

**Tracking:** OSSM-14917 and OCPBUGS-92038 (the actual defect, affecting OCP 4.19/4.20/4.21 — a fixed z-stream, not a minor bump, is the resolution); RHOAIENG-76376 (RHOAI-side doc update). Note the affected-versions list includes 4.21, so "upgrade OCP to 4.21" is **not** a workaround.

## Dashboard URL 404 after upgrade

3.x uses Gateway API — the old 2.x Route URL is gone. Users with bookmarks will get 404. Fix:

1. Get the new dashboard URL:
   ```
   oc get gatewayconfigs -A -o jsonpath='{range .items[*]}{.spec.hostname}{"\n"}{end}'
   ```
2. Communicate the new URL to users. See [Resolving dashboard URL 404 errors after upgrading from 2.x to 3.x](https://access.redhat.com/solutions/7137771) for the redirect option.
