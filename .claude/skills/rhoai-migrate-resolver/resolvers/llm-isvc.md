# Resolver — LLMInferenceService (distributed inference)

**rhai-cli signal:** `workload / llminferenceservice / *`.

## Why

> Distributed inference via LLMInferenceService requires RHCL for security and policy management. Pin LLM configurations to 2.25 templates during migration to prevent scheduler failures.
>
> — architectural-changes.md § *Model Serving Migration*

> Authorization: Adoption of Red Hat Connectivity Link (RHCL). RHCL (upstream: Kuadrant) consolidates security (Authorino), rate limiting (Limitador), and policy management with the Gateway API. It is required by LLM-d and is the foundation for MaaS governance.
>
> — architectural-changes.md § *Authorization: Adoption of Red Hat Connectivity Link*

LLM-d's router and scheduler templates evolved between 2.25 and 3.x. During the upgrade the templates in the `inferenceservice-config` ConfigMap get rewritten; if an LLMInferenceService was relying on a specific template version (directly or implicitly), the scheduler will drop its pods. Pinning the template annotations freezes the 2.25 behaviour across the upgrade.

RHCL replaces the standalone Authorino operator and becomes the auth/policy control plane for every LLM endpoint.

## Four sub-steps

1. Install Red Hat Connectivity Link (§2.8.10.1 of the migration guide)
2. For disconnected clusters, mirror the RHCL images (§2.8.10.2)
3. Configure authentication for each LLMInferenceService — annotation or RBAC (§2.8.10.3)
4. Freeze LLMInferenceService template annotations (§2.8.10.4)

### 1. Install Red Hat Connectivity Link

Skip this if you do not use LLMInferenceService. Otherwise:

**Confirmed subscription fields** (cross-checked against migration guide §2.8.10.1):

| Field | Value |
| --- | --- |
| Display name | Red Hat Connectivity Link |
| Package name | `rhcl-operator` |
| Catalog source | `redhat-operators` |
| Channel | `stable` |
| Install mode | **"A specific namespace on the cluster"** into `kuadrant-system` (single-namespace; *not* AllNamespaces) |

The **community** edition lives at `kuadrant-operator` in `community-operators`. **Do not** install that one — it is not supported for RHOAI 3.x and its CRD versions may not match what KServe LLM-d expects. Always use `rhcl-operator` from `redhat-operators`.

> **Earlier revisions of this resolver claimed `AllNamespaces` was the only supported install mode and pointed it at `openshift-operators`. That was wrong.** Migration guide §2.8.10.1 explicitly directs OperatorHub installation into `kuadrant-system` with mode "A specific namespace on the cluster." The OperatorHub UI handles namespace creation + OperatorGroup; the `oc apply` equivalent is below.

```
oc create ns kuadrant-system 2>/dev/null || true

oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata: { name: kuadrant-system, namespace: kuadrant-system }
spec:
  targetNamespaces:
    - kuadrant-system
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata: { name: rhcl-operator, namespace: kuadrant-system }
spec:
  channel: stable
  name: rhcl-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

Wait for the CSV in `kuadrant-system`:

```
oc get csv -n kuadrant-system | grep rhcl
```

After the CSV reaches `Succeeded`, create the Kuadrant CR so RHCL provisions Authorino and Limitador, and wait for `Ready`:

```
oc apply -f - <<'EOF'
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata: { name: kuadrant, namespace: kuadrant-system }
EOF

oc wait Kuadrant -n kuadrant-system kuadrant --for=condition=Ready --timeout=10m
```

> **Gateway API provider:** the OCP Cluster Ingress Operator installs `servicemeshoperator3` automatically as the cluster's Gateway API provider — admin does **not** create `Istio` / `IstioCNI` CRs or subscribe to `servicemeshoperator3` by hand. Earlier revisions of this resolver instructed both; that was wrong and contradicted migration guide §2.8.10.1 (which says nothing about Sail or Istio CRs). On a *connected* cluster the SMv3 CSV appears in `openshift-operators` and reaches `Succeeded` without intervention. On a *disconnected* cluster, follow guide §2.8.10.2 to mirror the SMv3 image the Cluster Ingress Operator needs. If Kuadrant is stuck at `Ready=False / MissingDependency` on a connected cluster, the Cluster Ingress Operator itself is unhealthy — diagnose there, do not create Sail CRs by hand.

### 1b. Enable TLS on the Authorino listener

Per migration guide §2.8.10.1, use OpenShift's built-in service signer to mint the listener cert — no cert-manager needed. The Authorino CR enables TLS on the **listener only**; `oidcServer.tls.enabled` stays `false`. Earlier revisions of this resolver instructed cert-manager `ClusterIssuer` + two `Certificate` CRs and TLS on the OIDC server; both were wrong.

```
# Annotate the Authorino service so OpenShift's service signer issues the cert
oc annotate svc/authorino-authorino-authorization \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
  -n kuadrant-system
sleep 2

# Apply the Authorino CR with TLS on the listener only
oc apply -f - <<'EOF'
apiVersion: operator.authorino.kuadrant.io/v1beta1
kind: Authorino
metadata:
  name: authorino
  namespace: kuadrant-system
spec:
  replicas: 1
  clusterWide: true
  listener:
    tls:
      enabled: true
      certSecretRef:
        name: authorino-server-cert
  oidcServer:
    tls:
      enabled: false
EOF

oc wait --for=condition=ready pod -l authorino-resource=authorino -n kuadrant-system --timeout=150s
```

Verify:

```
oc get secret authorino-server-cert -n kuadrant-system
oc get authorino authorino -n kuadrant-system -o jsonpath='listener={.spec.listener.tls.enabled} oidc={.spec.oidcServer.tls.enabled}'; echo
oc get pods -n kuadrant-system -l authorino-resource=authorino
```

### 2. Disconnected environments

If this is a disconnected cluster, mirror the RHCL images into your registry using `oc-mirror`. See migration guide §2.8.10.2 for the exact image list (it spans RHCL operator, Authorino, Limitador, and dependencies). Consult Red Hat Support — the list changes per RHCL version.

### 3. Configure authentication for each LLMInferenceService

> **Not Kuadrant `AuthPolicy`.** An earlier version of this resolver recommended creating a `kuadrant.io/v1* AuthPolicy` with `targetRef.kind: LLMInferenceService`. The RHCL webhook rejects that — AuthPolicy only accepts `group: gateway.networking.k8s.io` with `kind: HTTPRoute` or `Gateway`. Per migration guide §2.8.10.3, LLMInferenceService authentication is configured via annotation (dev/test) or plain Kubernetes RBAC (recommended). Both paths below are documented by Red Hat and work pre-upgrade.

Pick **one** of the following methods per LLMInferenceService.

#### Method 1 — Disable auth (dev/test only)

Fastest path. Makes the model reachable with no token. Not for production.

```
NS=<llm-namespace>; NAME=<llm-isvc-name>
oc annotate llminferenceservice "$NAME" -n "$NS" \
  security.opendatahub.io/enable-auth=false --overwrite
```

Verify:

```
oc get llminferenceservice "$NAME" -n "$NS" -o jsonpath='{.metadata.annotations.security\.opendatahub\.io/enable-auth}'; echo
# expect: false
```

#### Method 2 — RBAC with ServiceAccount + Role + RoleBinding (recommended)

Keeps the model secure. Clients authenticate with a bearer token minted for the ServiceAccount.

```
NS=<llm-namespace>; NAME=<llm-isvc-name>
oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${NAME}-sa
  namespace: ${NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${NAME}-role
  namespace: ${NS}
rules:
  - apiGroups: ["serving.kserve.io"]
    resources: ["llminferenceservices"]
    resourceNames: ["${NAME}"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${NAME}-rolebinding
  namespace: ${NS}
subjects:
  - kind: ServiceAccount
    name: ${NAME}-sa
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${NAME}-role
EOF
```

Clients then include a bearer token:

```
TOKEN=$(oc create token "${NAME}-sa" -n "$NS")
curl -H "Authorization: Bearer $TOKEN" https://<model-url>/v2/models/...
```

> **Why this isn't Kuadrant/AuthPolicy on 2.x:** on the pre-upgrade 2.25.4 cluster, LLMInferenceService routes through Service Mesh v2 + Knative, not Gateway API — there are no HTTPRoutes/Gateways for AuthPolicy to target. Gateway API-based auth is a 3.x-era concern handled post-upgrade. The RBAC path here works on both 2.25.4 pre-upgrade and 3.3.2 post-upgrade.

### 4. Freeze the LLMInferenceService template annotations

Pin every LLMInferenceService to the 2.25.4 template set so the chapter-3 upgrade doesn't rewrite templates under a running scheduler. The pins go on `.status.annotations` (via the status subresource), **not** `.metadata.annotations` — and the values are the literal `kserve-config-llm-*` strings the 2.25 scheduler reads, not version labels.

Enumerate:

```
oc get llmisvc -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name'
```

Patch each one (`llmisvc` is the short kind name the guide uses for `LLMInferenceService`):

```
NS=<ns>; NAME=<llm-isvc>
oc patch llmisvc "$NAME" -n "$NS" \
  --subresource=status --type=merge -p '{
    "status": {
      "annotations": {
        "serving.kserve.io/config-llm-template":                        "kserve-config-llm-template",
        "serving.kserve.io/config-llm-decode-template":                 "kserve-config-llm-decode-template",
        "serving.kserve.io/config-llm-worker-data-parallel":            "kserve-config-llm-worker-data-parallel",
        "serving.kserve.io/config-llm-decode-worker-data-parallel":     "kserve-config-llm-decode-worker-data-parallel",
        "serving.kserve.io/config-llm-prefill-template":                "kserve-config-llm-prefill-template",
        "serving.kserve.io/config-llm-prefill-worker-data-parallel":    "kserve-config-llm-prefill-worker-data-parallel",
        "serving.kserve.io/config-llm-scheduler":                       "kserve-config-llm-scheduler",
        "serving.kserve.io/config-llm-router-route":                    "kserve-config-llm-router-route"
      }
    }
  }'
```

Verify:

```
oc get llmisvc "$NAME" -n "$NS" -o jsonpath='{.status.annotations}' | jq '.'
```

All eight `serving.kserve.io/config-llm-*` keys should be present.

> **Gotcha — scheduler arg changes for 3.x compatibility:** if you *override* the LLMInferenceService scheduler's `args` or `env` (i.e. you have a `spec.router.scheduler.containers[*]` block), the 3.x breaking changes below apply. If you haven't overridden the scheduler (most users), skip this.
>
> - `camelCase` → `kebab-case` args (e.g. `--certPath` → `--cert-path`)
> - TLS cert path moved from `/etc/ssl/certs` to `/var/run/kserve/tls`
> - Signed TLS certs via OpenShift service signer are mandatory
> - Must include `--cert-path` arg and `SSL_CERT_DIR` env var
>
> Migration guide §2.8.10.4 has the diff of the updated scheduler block.

## Verify

```
# RHCL operator installed
oc get csv -n kuadrant-system | grep rhcl-operator

# Every LLMInferenceService has the eight freeze annotations
oc get llminferenceservice -A -o json \
  | jq -r '.items[] | {ns:.metadata.namespace, name:.metadata.name, pins: [.metadata.annotations | to_entries[] | select(.key | startswith("serving.kserve.io/config-llm-")) | .key]}'
```

Each LLMInferenceService should list all eight `config-llm-*` annotations.

## Callouts

- Do not uninstall the standalone Authorino operator (covered in [kserve.md](kserve.md)) until RHCL is up and AuthPolicies are in place — you'll drop auth entirely for a window otherwise.
- The template versions (`v2.25` above) are placeholders — the actual values are shipped in the rhai-cli helper. Copy them from the tool's output rather than guessing.
