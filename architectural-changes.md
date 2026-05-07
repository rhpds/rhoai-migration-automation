# Going from RHOAI 2 to RHOAI 3: Migration Guide

**Last updated:** April 22, 2026

## Why RHOAI 3 Matters for Your Organization

Red Hat OpenShift AI 3 is a generational platform shift. It replaces aging components with modern, standards-based infrastructure designed to support the next wave of AI workloads: distributed LLM inference, agentic AI, model governance, and enterprise-grade observability.

Concretely, RHOAI 3 gives you:

- **Models-as-a-Service (MaaS):** Centralized LLM governance with role-based access, token quotas, API key management, and usage tracking — so platform teams can offer AI as a managed internal service.  
- **Distributed inference with LLM-d:** Intelligent routing, KV cache offloading, and prefix-aware scheduling that dramatically improve GPU utilization and response latency for large models.  
- **Agentic AI infrastructure (3.4):** Deploy and manage autonomous agents with cryptographic identity (SPIFFE/SPIRE), execution tracing, and an MCP Gateway for tool access control.  
- **Unified observability:** Zero-config GPU monitoring and native vLLM metrics, embedded directly in the RHOAI console — no external dashboards to configure.  
- **Modern training with Kubeflow Trainer v2:** A single TrainJob API replacing fragmented training operators, with native Kueue integration for elastic scheduling.  
- **Future-proofed authentication:** External Identity Provider (IdP) support, replacing the maintenance-only oauth-proxy with kube-rbac-proxy.

These capabilities are only available on the 3.x release stream. RHOAI 2.25 will continue to receive security patches until April 2027, but no new features.

## Before You Start: Key Facts

There are a few things you should know upfront:

1. **There is no rush.** RHOAI 2.25 (EUS) is fully supported until April 2027\. You have time to plan this properly.  
2. **This is a migration, not an upgrade.** Unlike previous version bumps (2.19 to 2.22, 2.22 to 2.25), moving to 3.x involves architectural changes that require hands-on preparation and artifact modification.  
3. **There is no automated rollback.** Once the migration begins, the only way back is a full restore from backup. This is why planning matters.  
4. **Red Hat is here to help.** This is not something you should attempt alone. Run the assessment tool, open a support case, and let us help you build a migration plan tailored to your environment.

## What's New in RHOAI 3

### RHOAI 3.3

The 3.3 release establishes foundational governance, streamlines integrations, and optimizes inference hardware.

| Feature | Status | What It Does |
| :---- | :---- | :---- |
| Models-as-a-Service (MaaS) | Tech Preview | Multi-tenant LLM governance: RBAC policies, token quotas, API key distribution, usage tracking |
| Kubeflow Trainer v2 | GA | Unified TrainJob API and Python SDK for distributed PyTorch, JAX, and DeepSpeed with native Kueue integration |
| MLServer for Predictive AI | Tech Preview | Out-of-the-box KServe runtime for scikit-learn, XGBoost, and LightGBM — no ONNX conversion needed |
| AI Hub & Model Catalog | GA | Hugging Face integration, performance-based filtering, catalog governance for admins |
| Unified Observability | GA | Centralized platform metrics via Cluster Observability Operator, zero-config GPU monitoring, native vLLM metrics |
| GenAI Studio Guardrails | GA | AI playground for prompt experimentation, MCP tools, and safety filter testing before production |
| Inference & Hardware Optimizations | GA | LLM-d with KV cache CPU offloading, prefix-aware routing. Support for NVIDIA Blackwell Ultra, AMD MI325X, Intel CPU inference |

### RHOAI 3.4

The 3.4 release expands economic controls, introduces evaluation platforms, and provides enterprise infrastructure for agentic AI.

| Feature | Status | What It Does |
| :---- | :---- | :---- |
| Models-as-a-Service (MaaS) | GA | Enhanced admin UI, showback dashboards, automated API key lifecycle, external OIDC authentication |
| Agentic AI & AgentOps | Dev Preview | Platform to deploy and manage autonomous agents with execution tracing and SPIFFE/SPIRE secure identities |
| MCP Gateway & Catalog | Dev Preview | Enterprise control plane for MCP tools with identity-based access control |
| Speculative Decoding (EAGLE3) | GA | 1.5-3x faster responses using draft-model prediction, no accuracy loss |
| Inference-Aware Autoscaling | Tech Preview | Scales on KV cache pressure and request patterns, not just CPU/memory |
| llm-d on xKS | GA | Distributed inference on CoreWeave and AKS, beyond OpenShift |
| Eval Hub | Tech Preview | Unified benchmarking for models, RAG pipelines, and agents using LM-Eval |
| Llama Stack Integration | GA | Activate the operator for OpenAI-compatible RAG APIs |
| AutoRAG / AutoML | Dev Preview / Tech Preview | Automated RAG configuration testing and predictive model selection |
| Prompt Management & MLflow | GA | Versioned, auditable prompt and agent instruction management |
| Unified Observability Dashboards | GA | Native console dashboards for cluster admins (GPU health) and data scientists (latency, throughput) |

*Feature status (Tech Preview / Dev Preview / GA) is provided for planning purposes and may shift in upcoming releases.*

## What's Changing Architecturally (and Why)

Each architectural change in RHOAI 3 is driven by a specific need. Understanding the *why* will help you plan your migration and communicate changes to your teams.

### Networking: Routes to Kubernetes Gateway API

**Why:** LLM-d's intelligent routing is built on the Kubernetes Gateway API. This is also the foundation for MaaS, MCP Gateway, and guardrails integration. The Kubernetes community has feature-frozen the Ingress mechanism in favor of Gateway API, and CNCF AI platform conformance requires it.

**What it means for you:**

- URLs for accessing RHOAI services will change. Bookmarks, scripts, and external integrations pointing to old Route-based URLs will need updating.  
- Bare metal environments may require MetalLB for load balancing.  
- The RHOAI Dashboard remains accessible via both a Gateway and a legacy Route during transition.

### Authentication: oauth-proxy to kube-rbac-proxy

**Why:** oauth-proxy is tightly coupled to the internal OpenShift OAuth Server and cannot support external Identity Providers — a long-standing customer request. oauth-proxy is in maintenance-only mode with no plans for external OIDC support.

**What it means for you:**

- External IdP authentication becomes possible.  
- Better single sign-on experience from Dashboard into workbenches.  
- Custom workbench images built for the oauth-proxy flow will need to be rebuilt.

### Model Serving: Removal of ModelMesh and KServe Serverless

**Why:** The model serving architecture is evolving to support advanced LLM inference topologies through LLM-d. Neither KServe Serverless nor ModelMesh were designed for the routing and scaling patterns that distributed LLM inference requires. Additionally, KServe Serverless depends on Knative, which is incompatible with OpenShift Service Mesh 3 (embedded in OCP 4.19+).

**What it means for you:**

- All model serving workloads must be converted to RawDeployment (Standard) mode before the migration.  
- The resulting model serving stack is actually simpler: RawDeployment has no external dependencies, and distributed inference via LLM-d requires only Red Hat Connectivity Link and LeaderWorkerSet.  
- Models left unconverted will return HTTP 503 errors after the upgrade.

### Authorization: Adoption of Red Hat Connectivity Link (RHCL)

**Why:** RHCL (upstream: Kuadrant) consolidates security (Authorino), rate limiting (Limitador), and policy management with the Gateway API. It is required by LLM-d and is the foundation for MaaS governance.

**What it means for you:**

- Standalone Authorino operators must be uninstalled.  
- RHCL becomes a dependency for distributed inference and MaaS workloads.

### Training: Removal of Codeflare Operator

**Why:** The upstream Codeflare project is no longer under active development. KubeRay now handles all Ray cluster management independently.

**What it means for you:**

- If you use Ray-based workloads, KubeRay manages them directly. No action required beyond the operator removal.

### Workload Scheduling: Kueue Transition

**Why:** The OCP team now provides official operators and support for Kueue (Red Hat Build of Kueue). The embedded Kueue distribution in RHOAI was deprecated in 2.25 and removed in 3.3.

**What it means for you:**

- **Critical:** The Kueue component management state must be set to "Removed" *before* upgrading. Leaving it as "Managed" causes unrecoverable cluster instability.  
- After migration, Kueue features can be re-enabled via the Red Hat Build of Kueue (RHBoK) operator.

## Choosing Your Migration Path

### Side-by-Side Migration (Strongly Recommended)

Deploy a fresh RHOAI 3.3 cluster alongside your existing 2.25 environment, then migrate workloads over.

**Choose this if:**

- You have available infrastructure for a second cluster (even temporarily)  
- You want to minimize risk to your production environment  
- You need a gradual migration with both environments running in parallel  
- You have diverse workloads across many teams

**Advantages:**

- Your 2.25 environment stays completely untouched — no risk of unrecoverable state  
- Longer migration window — move workloads at your own pace  
- Opportunity to redesign workloads for 3.x capabilities rather than just porting them  
- A full cluster backup of the 2.25 environment is recommended but not critical

**Infrastructure cost consideration:** Running two environments temporarily means additional infrastructure. For GPU-heavy environments, work with your Red Hat account team to plan the overlap window and minimize the duration. Consider migrating non-GPU workloads first to free up resources.

### In-Place Migration

Upgrade your existing 2.25 cluster directly to 3.3.

**Choose this if:**

- Infrastructure constraints make a second cluster impractical  
- You have a small, well-understood workload footprint  
- You can schedule a maintenance window with acceptable downtime

**Requirements:**

- A complete, verified backup of your entire environment and PVCs is **mandatory** — this is your only rollback mechanism.  
- You must use the restricted upgrade channel `support-required-upgrade` (this prevents accidental upgrades).  
- You must open a pre-emptive support case with Red Hat before starting.

**Risk factors:**

- No rollback once initiated — restore from backup is the only path back, and may require rebuilding the entire cluster.  
- No zero-downtime — users must be notified and active workbenches must be stopped.  
- Higher coordination effort — all artifact modifications must be completed in sequence.

### Decision Framework

| Factor | Side-by-Side | In-Place |
| :---- | :---- | :---- |
| Risk to production | Low | High |
| Infrastructure cost | Higher (temporary) | Lower |
| Migration window | Flexible (weeks/months) | Fixed (maintenance window) |
| Rollback path | Keep 2.25 running | Restore from backup only |
| Best for | Large/complex environments | Small/simple environments |
| Red Hat recommendation | **Preferred** | Supported with caveats |

## Planning Your Migration

### Step 1: Assess Your Environment

Before choosing a migration method or scheduling any work, you need a complete picture of your environment.

**Run the assessment tool:** The `rhai-cli` tool scans your cluster and generates a report identifying every artifact that needs modification. It flags issues as "critical" (must fix before upgrade) or "prohibited" (will block the upgrade). The tool reports only — it does not modify anything.

Your Cluster Administrator should run this tool across all namespaces to capture the full scope.

**Consult your users:** The Cluster Admin can see all projects, but only end users know which workloads are actively used, which can be retired, and which are business-critical. Survey your users to understand:

- Which workbenches, pipelines, and served models are in active use  
- Which custom workbench images exist and who maintains them  
- Which external systems integrate with RHOAI endpoints (CI/CD, monitoring, security tooling)  
- Which workloads use ModelMesh, Serverless, or distributed inference

### Step 2: Estimate the Effort

Use the rhai-cli report and user survey to size the work. Key variables that drive effort:

| Workload Type | Effort Driver |
| :---- | :---- |
| Custom workbench images | Each image needs Dockerfile updates and a rebuild for the new auth mechanism |
| ModelMesh / Serverless models | Each must be converted to RawDeployment — configuration changes \+ validation |
| Pipelines | Review for endpoint URL references that will change |
| Distributed inference (LLM-d) | Requires RHCL deployment and template pinning |
| External integrations | Each script, bookmark, DNS entry, or firewall rule pointing to old URLs needs updating |
| Llama Stack data | Must be manually archived — data is lost during the SQLite to PostgreSQL transition |

For rough sizing: plan for **1-2 days per workload type per team** for preparation and testing, plus the migration window itself. Complex environments with many custom images and external integrations will be on the higher end. Your Red Hat support case will help refine this estimate.

### Step 3: Engage Red Hat

**Open a pre-emptive support case.** Share your rhai-cli report and workload inventory. Red Hat Support will help you:

- Identify risks specific to your environment  
- Sequence the migration steps correctly  
- Troubleshoot issues during execution

**For complex environments** with many teams, custom integrations, or strict compliance requirements, Red Hat Consulting can provide hands-on migration assistance. Discuss this option with your account team early — Consulting engagements require lead time to schedule.

### Step 4: Plan the Execution

Regardless of your migration method, plan for these phases:

**Pre-migration (days to weeks before):**

- Upgrade OCP to 4.19.9+  
- Install cert-manager Operator  
- Set Kueue component management to "Removed"  
- Rebuild custom workbench images for v3.x compatibility  
- Convert all ModelMesh/Serverless models to RawDeployment  
- Uninstall deprecated operators (OpenShift Serverless, Service Mesh v2, standalone Authorino)  
- If other applications on your cluster depend on Service Mesh v2, they must be upgraded to Service Mesh v3 first  
- Archive any Llama Stack data you need to preserve  
- For in-place: capture and verify full cluster backup

**Migration window:**

- Stop all running workbenches  
- Notify users of the maintenance window and expected duration  
- Execute the migration (in-place) or begin workload transfer (side-by-side)  
- Validate each workload type as it comes up

**Post-migration:**

- Re-enable Kueue via Red Hat Build of Kueue (RHBoK) if needed  
- Deploy RHCL if using distributed inference or MaaS  
- Update external references: URLs, DNS entries, firewall rules, monitoring targets, CI/CD pipelines  
- Communicate new access points to users  
- Recreate Llama Stack resources if applicable

**Test before you commit:** Run the full migration process on a small set of projects first. This gives you realistic timing data for your maintenance window and surfaces issues before they affect production workloads.

### Step 5: Communicate to Stakeholders

Your users will experience changes. Prepare them:

- **Before migration:** What's happening, when, and what they need to do (stop workbenches, note new URLs)  
- **During migration:** Status updates and expected completion time  
- **After migration:** New access points, changed URLs, any UI differences (especially significant if migrating from versions earlier than 2.25), and where to get help

## Detailed Technical Reference

### Platform Prerequisites

These must be in place before any migration work begins.

| Prerequisite | Details |
| :---- | :---- |
| OCP Version | 4.19.9 or higher |
| Kueue State | Must be set to "Removed" — leaving it as "Managed" causes unrecoverable cluster instability |
| cert-manager Operator | Mandatory for JobSet, LeaderWorkerSet, Kueue, and KubeRay |
| MetalLB (bare metal only) | May be required for Gateway-based traffic handling |

### Operator Changes

**Remove before migration:**

- OpenShift Serverless  
- OpenShift Service Mesh v2 (if no other applications depend on it; otherwise upgrade to v3 first)  
- Standalone Authorino operator

**New requirements in RHOAI 3.x:**

- cert-manager (mandatory)  
- JobSet (required for Trainer v2)  
- LeaderWorkerSet (optional, enables specific LLM-d functionality)  
- Kueue via Red Hat Build of Kueue (replaces the embedded distribution)  
- Red Hat Connectivity Link (required for distributed inference and MaaS)

### Networking and Authentication Changes

- All Route-based URLs are replaced by Gateway/HTTPRoute-based URLs  
- The RHOAI Dashboard is accessible via both Gateway and legacy Route during transition  
- kube-rbac-proxy replaces oauth-proxy for authentication  
- Existing custom workbench images and RStudio images will fail due to routing conflicts with the new auth mechanism — they must be rebuilt  
- All running workbenches must be stopped before migration; unmigrated workbenches will experience redirection loops

### Model Serving Migration

- ModelMesh (multi-model deployment) and KServe Serverless are removed in 3.x  
- All models must be converted to RawDeployment (Standard) mode before the upgrade  
- Unconverted models will return HTTP 503 errors  
- RawDeployment has no external dependencies  
- Distributed inference via LLMInferenceService requires RHCL for security and policy management  
- Pin LLM configurations to 2.25 templates during migration to prevent scheduler failures

### Data Considerations

- **Llama Stack:** Transitioning from SQLite to PostgreSQL. All existing data (agent state, telemetry, vector databases) will be lost. Manually archive before migration and recreate resources afterward.  
- **Persistent Volume Claims:** Include PVCs in your backup strategy — they contain workbench data and model artifacts.  
- **Artifact naming:** Some artifacts (workbenches, inference servers) may be renamed during migration. Audit any automation, monitoring, reporting, or security tooling that references artifact names.

## Key Roles in the Migration

| Role | Responsibilities | Visibility |
| :---- | :---- | :---- |
| **Cluster Administrator** | Runs rhai-cli, executes platform-level migration steps, manages backups | Full access to all projects and namespaces |
| **OpenShift AI Administrator** | Manages custom runtimes, workbench images, and RHOAI configuration | RHOAI-level access; no visibility into user projects |
| **End Users** | Own workbenches, pipelines, served models, and other project artifacts | Own project only |

Establishing clear responsibilities across these roles early in the planning process is critical. The Cluster Admin has the broadest visibility but needs input from end users about which artifacts are in active use.

## Reference Documents

### Migration

- [Official migration documentation: Assess and plan for migration from RHOAI 2.25.4 to 3.3.2](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html-single/assess_and_plan_for_migration_from_openshift_ai_2.25.4_to_3.3.2/index)

### RHOAI 3

- [Supported Configurations for RHOAI 3.x](https://access.redhat.com/articles/rhoai-supported-configs-3.x)  
- [RHOAI Lifecycle Policy](https://access.redhat.com/support/policy/updates/rhoai-sm/lifecycle)  
- [RHOAI Product Life Cycles](https://access.redhat.com/product-life-cycles?product=Red%20Hat%20OpenShift%20AI%20Self-Managed)

### OpenShift

- [OpenShift Update Policy](https://access.redhat.com/support/policy/updates/openshift)

## Summary

Moving from RHOAI 2 to RHOAI 3 is a significant undertaking, but it positions your organization on a platform built for the next generation of AI workloads. You have time — RHOAI 2.25 is supported until April 2027 — and Red Hat is committed to helping you through this transition.

**Your next steps:**

1. Run `rhai-cli` to assess your environment  
2. Survey your users to understand active workloads  
3. Open a pre-emptive support case with Red Hat  
4. Choose your migration path (side-by-side recommended)  
5. Build your migration plan with Red Hat Support

Questions? Contact your Red Hat account team or open a support case at [access.redhat.com](https://access.redhat.com).

---

*Version: April 22, 2026*

