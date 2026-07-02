#!/usr/bin/env bash
# Ordered teardown of the GitOps install so we don't orphan finalizers.
#
# The wrong order (bulk delete Applications + operators + namespaces at once)
# leaves finalizers with no controller left to process them — namespaces then
# sit in Terminating forever and require manual finalizer strips. This script
# does it in the order the finalizers actually need:
#
#   1. Pause ArgoCD automation so it stops recreating things mid-teardown
#   2. Delete workload CRs (ISVC, Notebook, RayCluster, DSPA, LSD, FeatureStore,
#      PyTorchJob, TrustyAIService, GuardrailsOrchestrator, ModelRegistry) and
#      wait for their operators to process finalizers naturally
#   3. Delete DSC + DSCI (their controllers own most of the RHOAI namespace state)
#   4. Delete ArgoCD Applications (finalizer-strip first so they don't hang)
#   5. Delete the RHOAI operator (subscription + CSV)
#   6. Delegate to top-level uninstall.sh for SM v2, Serverless, Authorino
#      operator teardown and namespace cleanup
#   7. Delete OpenShift GitOps operator + instance
#
# Best-effort: keeps going on failure so a partial state gets fully cleaned up.

set -Euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log()  { echo "[gitops-uninstall] $*"; }
warn() { echo "[gitops-uninstall] WARN: $*" >&2; }

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }

# ---------------------------------------------------------------------------
# 1. Pause ArgoCD automation
# ---------------------------------------------------------------------------
log "=== 1. pausing Argo CD automated sync (so it stops recreating things) ==="
for app in $(oc -n openshift-gitops get applications.argoproj.io -o name 2>/dev/null); do
  oc -n openshift-gitops patch "$app" --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}' 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# 2. Delete workload CRs first, let the operators drain their finalizers.
#    A short bounded wait per kind — if the operator can't finish in that
#    window we strip the finalizer and move on.
# ---------------------------------------------------------------------------
log "=== 2. deleting workload CRs (ISVC, Notebook, RayCluster, etc.) ==="

# Kinds that live in sample namespaces
WORKLOAD_KINDS=(
  inferenceservice.serving.kserve.io
  servingruntime.serving.kserve.io
  notebook.kubeflow.org
  raycluster.ray.io
  pytorchjob.kubeflow.org
  llamastackdistribution.llamastack.io
  datasciencepipelinesapplication.datasciencepipelinesapplications.opendatahub.io
  trustyaiservice.trustyai.opendatahub.io
  guardrailsorchestrator.trustyai.opendatahub.io
  featurestore.feast.dev
  modelregistry.modelregistry.opendatahub.io
)

for kind in "${WORKLOAD_KINDS[@]}"; do
  # Fire off a background delete for every instance
  for res in $(oc get "$kind" -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    ns="${res%%/*}"; name="${res##*/}"
    log "  delete $kind $ns/$name"
    oc -n "$ns" delete "$kind" "$name" --ignore-not-found --wait=false --timeout=30s 2>/dev/null || true
  done
done

log "  waiting up to 60s for operator finalizers to drain..."
sleep 60

log "  force-stripping any finalizers still hanging on workload CRs..."
for kind in "${WORKLOAD_KINDS[@]}"; do
  for res in $(oc get "$kind" -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    ns="${res%%/*}"; name="${res##*/}"
    oc -n "$ns" patch "$kind" "$name" --type=merge \
      -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
  done
done

# ---------------------------------------------------------------------------
# 3. Delete DSC + DSCI (they own most of the RHOAI namespace state).
# ---------------------------------------------------------------------------
log "=== 3. deleting DSC + DSCI ==="
oc delete dsc --all --ignore-not-found --wait=false --timeout=60s 2>/dev/null || true
oc delete dsci --all --ignore-not-found --wait=false --timeout=60s 2>/dev/null || true
sleep 20
# Strip finalizers if they're still around
for r in $(oc get dsc,dsci -A -o name 2>/dev/null); do
  oc patch "$r" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# 4. Strip finalizers and delete Argo CD Applications.
# ---------------------------------------------------------------------------
log "=== 4. deleting Argo CD Applications ==="
for app in $(oc -n openshift-gitops get applications.argoproj.io -o name 2>/dev/null); do
  oc -n openshift-gitops patch "$app" --type=json \
    -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
done
oc -n openshift-gitops delete applications.argoproj.io --all \
  --wait=false --ignore-not-found 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. Delete RHOAI operator subscription + CSV before the namespaces so
#    the operator's own webhooks come down cleanly.
# ---------------------------------------------------------------------------
log "=== 5. deleting RHOAI operator ==="
oc -n redhat-ods-operator delete subscription rhods-operator --ignore-not-found 2>/dev/null || true
oc get csv -n redhat-ods-operator -o name 2>/dev/null \
  | grep -i rhods-operator \
  | xargs -r -I{} oc -n redhat-ods-operator delete {} --ignore-not-found 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6. Delegate to top-level uninstall.sh for SM v2, Serverless, Authorino,
#    NFD/GPU operators, and sample namespace cleanup.
# ---------------------------------------------------------------------------
log "=== 6. delegating to top-level uninstall.sh (SM v2, Serverless, Authorino, namespaces) ==="
"${REPO_ROOT}/uninstall.sh" || true

# ---------------------------------------------------------------------------
# 6b. Belt-and-braces namespace cleanup — force-finalize anything still stuck.
# ---------------------------------------------------------------------------
log "=== 6b. force-finalizing any namespaces still Terminating ==="
sleep 10
for ns in $(oc get ns -o jsonpath='{range .items[?(@.status.phase=="Terminating")]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  # Skip cluster/system namespaces
  case "$ns" in
    kube-*|openshift-*|default) continue ;;
  esac
  warn "  force-finalizing stuck namespace: $ns"
  oc get ns "$ns" -o json 2>/dev/null | \
    jq '.spec.finalizers = []' 2>/dev/null | \
    oc replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# 7. OpenShift GitOps operator + instance.
# ---------------------------------------------------------------------------
log "=== 7. deleting OpenShift GitOps operator + instance ==="
oc -n openshift-gitops delete argocd openshift-gitops --ignore-not-found --wait=false 2>/dev/null || true
oc -n openshift-operators delete subscription openshift-gitops-operator --ignore-not-found 2>/dev/null || true
oc get csv -n openshift-operators -o name 2>/dev/null \
  | grep -i openshift-gitops \
  | xargs -r -I{} oc -n openshift-operators delete {} --ignore-not-found 2>/dev/null || true
oc delete clusterrolebinding openshift-gitops-cluster-admin --ignore-not-found 2>/dev/null || true
oc delete ns openshift-gitops --wait=false --ignore-not-found 2>/dev/null || true

log ""
log "GitOps uninstall dispatched. Give the cluster 1-2 minutes for the async"
log "namespace deletes to finish. Verify with:"
log "  oc get ns | grep -E 'openshift-gitops|redhat-ods|istio-system|knative|serverless|ml-project|raytest|pytorch-training|workbenches|dspa-sample|project-alpha|test-trustyai|test-guardrails|ldap-user17|rhoai-model-registries'"
