# Cluster backup and restore — for migration rehearsals

This guide walks through backing up an RHOAI 2.25 test cluster (deployed via [rhoai-2254-install/](rhoai-2254-install/)) and restoring it. The intended workflow:

1. Deploy a fresh 2.25 cluster.
2. **Take a backup.**
3. Run migration prep (per the [rhoai-migrate-resolver skill](.claude/skills/rhoai-migrate-resolver/)) and/or the chapter-3 upgrade.
4. If the rehearsal goes sideways, **restore from the backup**, fix what you learned, retry.

This is rehearsal infrastructure, not a production DR posture. It uses a three-layer approach: the etcd snapshot covers the full cluster control plane (including RHOAI's operator state and dependent operators), OADP covers user-namespace workloads and PVC contents, and the rhai-cli helper PVC preserves component-specific migration artefacts. The structure follows the [OCP 4.20 backup-and-restore docs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/backup_and_restore/backup-restore-overview) so the same operational muscle memory applies later in production.

## What goes in each layer

| Layer | Protects | Mechanism | Granularity |
|---|---|---|---|
| **1. etcd snapshot** | Cluster control plane (OCP) + RHOAI operator state + every dependent-operator state (Serverless, Service Mesh, etc.) + every CR, Secret, and CRD instance | OCP-shipped `cluster-backup.sh` on a control-plane node | Whole cluster |
| **2. OADP (Velero)** | RHOAI user-namespace workloads + PVC contents | OpenShift API for Data Protection Operator | Per-namespace |
| **3. rhai-cli helper artefacts** | Per-component pre/post-migration backups (TrustyAI metrics, Llama Stack data, Ray cluster YAMLs, inferenceservice-config) | `/tmp/rhoai-upgrade-backup` PVC inside the rhai-cli pod | Per-component, generated during migration |

For migration rehearsals, **Layers 1 + 2 are the baseline**: Layer 1 alone restores the entire cluster to a known-good point-in-time including operator state, and Layer 2 surgically restores user namespaces / PVC contents without disturbing the rest. Layer 3 is migration-window-specific and only matters once you've started running rhai-cli helpers.

> **Why not a YAML config export?** Earlier drafts of this procedure included a fourth layer that exported the DSC, DSCI, dashboard config, and similar objects to local YAML. That layer was removed on review: it duplicates content already inside the etcd snapshot, it's an incomplete subset of what RHOAI actually owns, and operators reconcile their own state — so the export isn't a usable restore mechanism either. Use Layer 1 for the operator-state safety net.

## Prerequisites

- A 2.25 cluster deployed via [rhoai-2254-install/install.sh](rhoai-2254-install/install.sh) (or any RHOAI 2.25.x cluster).
- `oc whoami` returns a user with cluster-admin.
- For Layer 2 (OADP): an off-cluster S3-compatible bucket. AWS S3, Ceph RGW, MinIO running outside the test cluster, or a NooBaa instance on a different cluster all work. **Never** point OADP at storage inside the cluster you're backing up — if the cluster dies, the backups die with it.
- ~30 min for the first-time backup, ~15–20 min for a restore drill.

## Layer 1 — etcd snapshot

Reference: [Backing up etcd data](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/backup_and_restore/control-plane-backup-and-restore#backing-up-etcd_backing-up-etcd) (OCP 4.20 docs).

This is the **canonical full-state backup**. It captures the RHOAI operator, its DSC/DSCI, dashboard config, dependent operators (Serverless, Service Mesh, cert-manager, etc.), every namespaced resource, every Secret, and every CRD instance. It's the only mechanism that fully restores the whole cluster (control plane + operator state) to a known-good point in time.

### Take the snapshot

```sh
# Pick any control-plane node
MASTER=$(oc get nodes -l node-role.kubernetes.io/control-plane= -o jsonpath='{.items[0].metadata.name}')
echo "snapshotting on $MASTER"

# Run the OCP-shipped backup script — it bundles etcd snapshot + static pod manifests + Kubernetes resources
oc debug node/"$MASTER" -- chroot /host /usr/local/bin/cluster-backup.sh /home/core/backup
```

The script writes two files to `/home/core/backup` on the node:

- `snapshot_<DATETIME>.db` — the etcd snapshot
- `static_kuberesources_<DATETIME>.tar.gz` — bundled static pod / kube manifests

### Copy off-cluster

```sh
# Use oc debug to read the files back to your workstation
mkdir -p ./backups/$(date +%Y-%m-%d-%H%M)/etcd
oc debug node/"$MASTER" -- bash -c "cat /host/home/core/backup/snapshot_*.db" \
  > ./backups/$(date +%Y-%m-%d-%H%M)/etcd/snapshot.db
oc debug node/"$MASTER" -- bash -c "cat /host/home/core/backup/static_kuberesources_*.tar.gz" \
  > ./backups/$(date +%Y-%m-%d-%H%M)/etcd/static_kuberesources.tar.gz
```

(`oc debug` won't `cp` directly; the `cat` over stdout is the standard workaround.)

### Caveats

- Single-node OCP / SNO: the snapshot is taken on the only master.
- Multi-master HA: the snapshot reflects whichever master ran the script; etcd's Raft consistency means any healthy member works.
- Snapshot is **point-in-time**. Workloads created after the snapshot won't be in it.
- Restoring etcd is a **whole-cluster** operation — see *Restore drill* below. You can't selectively roll back a single namespace from etcd.

## Layer 2 — OADP (Velero) backup of user namespaces

Reference: [OADP application backup and restore](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/backup_and_restore/oadp-application-backup-and-restore) (OCP 4.20 docs).

Layer 2 protects user-generated work — data science projects, workbenches, pipeline state, model serving config, PVC contents — so you can selectively roll back a single namespace without disturbing the rest of the cluster.

### Install OADP

```sh
oc create namespace openshift-adp 2>/dev/null || true

oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: redhat-oadp-operator
  namespace: openshift-adp
spec:
  targetNamespaces:
    - openshift-adp
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: redhat-oadp-operator
  namespace: openshift-adp
spec:
  channel: stable
  name: redhat-oadp-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

Wait for the CSV:

```sh
oc get csv -n openshift-adp -w
# Ctrl-C once you see oadp-operator.* phase=Succeeded
```

### Configure DataProtectionApplication with an off-cluster bucket

Replace `<bucket>`, `<region>`, and credential values with your real off-cluster S3 settings.

```sh
# Cloud credentials secret (OADP expects it under the key `cloud`)
cat > /tmp/credentials-velero <<EOF
[default]
aws_access_key_id=<ACCESS_KEY>
aws_secret_access_key=<SECRET_KEY>
EOF
oc create secret generic cloud-credentials -n openshift-adp \
  --from-file cloud=/tmp/credentials-velero
shred -u /tmp/credentials-velero    # remove the temp file with creds

oc apply -f - <<'EOF'
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: dpa-default
  namespace: openshift-adp
spec:
  configuration:
    velero:
      defaultPlugins:
        - openshift
        - aws
        - csi    # only include if your StorageClass supports CSI snapshots
    nodeAgent:
      enable: true
      uploaderType: kopia    # filesystem-level backup; works with any RWO PVC
  backupLocations:
    - name: default
      velero:
        provider: aws
        default: true
        objectStorage:
          bucket: <bucket>
          prefix: rhoai-2254-rehearsal
        config:
          region: <region>
          s3ForcePathStyle: "true"          # set true for MinIO/Ceph; false for AWS
          s3Url: https://<endpoint>          # MinIO/Ceph; omit for AWS
        credential:
          name: cloud-credentials
          key: cloud
EOF
```

Verify the BackupStorageLocation reaches `Available`:

```sh
oc get backupstoragelocation -n openshift-adp
# expect: PHASE=Available
```

### Discover RHOAI workload namespaces

Discovery is by **CRD type**, not by namespace label. The `opendatahub.io/dashboard=true` label was a past limitation of the dashboard's project-listing UI; any namespace can host RHOAI workloads now and the label is unreliable for backup discovery.

Use the customer-facing Kubernetes CRD types listed in the OpenShift AI API Tiers KB (article 7047935 — Tier 1 and Tier 2 only) as the sweep set. REST APIs, SDKs, and Python client tiers in that KB are not Kubernetes resources and are excluded automatically. Alpha and Beta APIs are not Red Hat–supported and so are not part of the recommended baseline — add them by hand if your workload actually uses them (see the optional sweep below).

```sh
# Tier 1 + Tier 2 customer-facing CRDs (the supported baseline)
TIER_1_2=(
  notebooks.kubeflow.org
  pytorchjobs.kubeflow.org
  rayclusters.ray.io
  rayjobs.ray.io
  inferenceservices.serving.kserve.io
  llminferenceservices.serving.kserve.io
  llminferenceserviceconfigs.serving.kserve.io
  servingruntimes.serving.kserve.io
  trustyaiservices.trustyai.opendatahub.io
  mlflows.opendatahub.io
  modelregistries.modelregistry.opendatahub.io
  hardwareprofiles.infrastructure.opendatahub.io
)

{
  for kind in "${TIER_1_2[@]}"; do
    oc get "$kind" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null
  done

  # rhods-notebooks is operator-managed but may contain dashboard-launched Notebooks
  # or their PVCs — include it if so. (Operator-managed != exclude from user data.)
  if [[ -n $(oc get notebook,pvc -n rhods-notebooks -o name 2>/dev/null) ]]; then
    echo rhods-notebooks
  fi
} | sort -u | grep -v '^$' | tee /tmp/rhoai-backup-namespaces.txt
```

#### Optional — extend discovery for Alpha/Beta/Tier-4 workloads you actually use

These are not in Red Hat's recommended baseline (no compatibility guarantees), but if your workload actually relies on them, sweep them too:

```sh
# Examples of common-but-unsupported-tier kinds. Add only the ones your cluster uses.
EXTRAS=(
  datasciencepipelinesapplications.opendatahub.io     # Tier 4
  llamastackdistributions.llamastack.io               # Beta
  guardrailsorchestrators.trustyai.opendatahub.io     # not yet tiered
  featurestores.feast.dev                             # not in the API-tier KB
)
for kind in "${EXTRAS[@]}"; do
  oc get "$kind" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null \
    | grep -v '^$' >> /tmp/rhoai-backup-namespaces.txt
done
sort -u -o /tmp/rhoai-backup-namespaces.txt /tmp/rhoai-backup-namespaces.txt
```

Review `/tmp/rhoai-backup-namespaces.txt` and remove any namespaces you don't want backed up before proceeding. The list typically also picks up the operator-namespace cluster-scoped instances (`rhoai-model-registries`, etc.) — that's fine, OADP backs them up as namespaces too.

### Take the backup

```sh
NS_LIST=$(awk 'NF { printf "    - %s\n", $0 }' /tmp/rhoai-backup-namespaces.txt)

cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: rhoai-pre-migration-$(date +%Y%m%d-%H%M)
  namespace: openshift-adp
spec:
  includedNamespaces:
$NS_LIST
  includedResources:
    - "*"
  includeClusterResources: false
  defaultVolumesToFsBackup: true       # filesystem-level — works on any RWO PVC
  storageLocation: default
  ttl: 720h                            # backup expires in 30 days
EOF
```

### Verify

```sh
# Watch the backup go from InProgress → Completed
NAME=$(oc get backup -n openshift-adp -o jsonpath='{.items[-1].metadata.name}')
oc get backup -n openshift-adp "$NAME" -o jsonpath='phase={.status.phase} errors={.status.errors} warnings={.status.warnings}{"\n"}' -w

# Once Completed:
oc describe backup -n openshift-adp "$NAME" | grep -E 'Phase|Errors|Warnings|Total Items|Items Backed Up'
```

`Phase=Completed` with `Errors=0` and a non-zero `Items Backed Up` is the green light. **Confirm PVC contents are actually in the backup** before declaring it usable:

```sh
oc get podvolumebackup -n openshift-adp -l velero.io/backup-name="$NAME" \
  -o custom-columns='POD:.spec.pod,PVC:.spec.volume,PHASE:.status.phase,BYTES:.status.progress.bytesDone'
```

Every PodVolumeBackup row should show `PHASE=Completed` with a non-zero `BYTES`.

If the backup is `PartiallyFailed`:

```sh
oc logs -n openshift-adp -l app.kubernetes.io/name=velero --tail=200 | grep -i error
oc get podvolumebackup -n openshift-adp \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,PVC:.spec.pod' | grep -v Completed
```

Common causes: a PVC's pod isn't running (filesystem backup needs the pod scheduled to read its files), or the StorageClass doesn't support CSI snapshots and you're using `defaultVolumesToFsBackup: false`. Stick with `defaultVolumesToFsBackup: true` for filesystem-level backup; it works on any `ReadWriteOnce` PVC.

## Layer 3 — rhai-cli helper artefacts (during migration only)

Once you start migration prep with the rhai-cli pod (per the [rhoai-migrate-resolver skill](.claude/skills/rhoai-migrate-resolver/)), per-component helpers write artefacts to `/tmp/rhoai-upgrade-backup` inside the pod — RayCluster YAML backups, TrustyAI metrics dumps, Llama Stack data archives, the original `inferenceservice-config` ConfigMap, etc.

The PVC mounted at `/tmp/rhoai-upgrade-backup` must be **preserved across pod restarts** (the rhai-cli pod restarts during migration); use a PVC, not an emptyDir, and don't delete it until the migration is fully validated.

After running the helpers, copy the directory off-cluster:

```sh
oc cp rhai-migration/rhai-cli-0:/tmp/rhoai-upgrade-backup \
  ./backups/$(date +%Y-%m-%d-%H%M)/rhai-cli-helpers
```

### Expected sequence around the helpers

1. Take the Layer 1 (etcd) and Layer 2 (OADP) baselines.
2. Deploy the rhai-cli pod and its PVC.
3. Run `rhai-cli lint --target-version 3.3.2` for assessment.
4. Run only the component-specific helper scripts that match the components actually enabled on your cluster (see the [rhoai-migrate-resolver skill](.claude/skills/rhoai-migrate-resolver/) for which helpers map to which migration step). Some helpers are pre-upgrade, some are post-upgrade — follow the skill's order.
5. After every helper run, copy `/tmp/rhoai-upgrade-backup` off-cluster.

## Restore drill — rolling back a botched migration rehearsal

Choose the scenario that matches what went wrong.

### Scenario A — restore one or more namespaces (Layer 2 / Velero)

Used when migration prep mangled a single namespace's resources but the cluster as a whole is fine. Fast, surgical.

```sh
# List available backups
oc get backup -n openshift-adp

NAME=<backup-name>          # e.g. rhoai-pre-migration-20260511-1430

# Wipe the affected namespaces FIRST. Velero won't overwrite live resources.
oc delete ns ml-project-a ml-project-b workbenches-regular --wait=true

# Then restore
cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${NAME}-restore
  namespace: openshift-adp
spec:
  backupName: $NAME
  includedNamespaces:
    - ml-project-a
    - ml-project-b
    - workbenches-regular
  restorePVs: true
EOF

# Watch
oc get restore -n openshift-adp ${NAME}-restore -w
# Phase=Completed = done. Verify:
oc get all,pvc -n ml-project-a
```

PVC contents are restored from the filesystem backup taken with `defaultVolumesToFsBackup: true`. Pods will recreate when their owning resources (Notebook, ISVC, etc.) reconcile.

### Scenario B — restore the whole cluster (Layer 1 / etcd)

Used when something fundamental broke at the operator/CRD level — failed RHOAI 3.x install plan, deleted a CRD storedVersion, etcd corruption. Heavyweight: takes the cluster offline.

> **Warning:** etcd restore is a destructive, multi-step OCP procedure. Reference: [Restoring to a previous cluster state](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/backup_and_restore/control-plane-backup-and-restore#dr-restoring-cluster-state). On a single-node cluster you'll be SSH-ing into the node and running `cluster-restore.sh`. On an HA cluster you stop kubelet on the non-recovery masters, restore on one, restart static pods, then re-join the others. This is exactly the OCP-DR procedure — RHOAI does not customize it.

The condensed flow on a sandbox:

```sh
# Copy the etcd snapshot files BACK to the master
SNAP=./backups/<dir>/etcd/snapshot.db
KUBE=./backups/<dir>/etcd/static_kuberesources.tar.gz
MASTER=$(oc get nodes -l node-role.kubernetes.io/control-plane= -o jsonpath='{.items[0].metadata.name}')

# Push the files to /home/core/assets on the master via debug pod (cumbersome
# but no-prereq); for repeat drills, scp via a bastion is faster.
oc debug node/"$MASTER" -- bash -c '
  mkdir -p /host/home/core/assets/backup
'
# … (file transfer step depends on your environment — see the OCP doc) …

# SSH into the master
ssh core@<master-host>
sudo /usr/local/bin/cluster-restore.sh /home/core/assets/backup
# Reboots the node; static pods start with the restored etcd
```

After restore, the cluster is back to the snapshot point in time **including** the RHOAI operator version, its DSC/DSCI, every CR, and every dependent operator's state. Re-run [scripts/prereqs.sh](.claude/skills/rhoai-migrate-resolver/scripts/prereqs.sh) and [scripts/validate.sh](.claude/skills/rhoai-migrate-resolver/scripts/validate.sh) to confirm RHOAI is in the expected pre-migration state.

### Scenario C — easiest of all: throw the cluster away

For RHDP sandboxes or any disposable test cluster, the cheapest "restore" is requesting a fresh cluster and re-running [`./install.sh`](rhoai-2254-install/install.sh). It's slower in wall-clock time (~15–20 min for the install) but zero operational complexity. Worth comparing before investing in OADP / etcd-snapshot tooling for a *throwaway* cluster.

## Verifying the restore

After any restore scenario:

```sh
# Cluster basics
oc get nodes
oc get co | grep -v 'True .* False .* False'         # all ClusterOperators Available, not Progressing/Degraded

# RHOAI state
oc get dsc default-dsc -o jsonpath='{.status.phase}{"\n"}'         # expect: Ready
oc get dsci default-dsci -o jsonpath='{.status.phase}{"\n"}'       # expect: Ready
oc get csv -n redhat-ods-operator | grep rhods-operator             # expect: 2.25.4 Succeeded

# Cross-check against the migration-readiness baseline
bash .claude/skills/rhoai-migrate-resolver/scripts/prereqs.sh
bash .claude/skills/rhoai-migrate-resolver/scripts/validate.sh
```

Once `validate.sh` reports `15 PASS / 0 FAIL`, the cluster is back to the same pre-migration state the original install left it in, and you can re-run the migration rehearsal from a clean baseline.

## Iterating: rehearsing a migration multiple times

Typical rehearsal loop:

```
+----------------------------+
|  Fresh 2.25 cluster        |
|  (./install.sh)            |
+-------------+--------------+
              |
              v
+----------------------------+
|  Take Layer 1 + Layer 2    |
|  baseline backup           |
+-------------+--------------+
              |
              v
+----------------------------+
|  Run pre-migration prep    |
|  (skill walks you through; |
|   Layer 3 fills up as      |
|   helpers run)             |
+-------------+--------------+
              |
              v
+----------------------------+
|  Hit issue?                |
+--+---------+---------------+
   | yes     | no
   v         v
+-------+ +----------------+
|Restore| | Run chapter-3  |
|namespc| | upgrade        |
|or full| +-------+--------+
|cluster|         |
+---+---+         v
    |        +----------------+
    +------> | post-upgrade   |
             | validation     |
             +----------------+
```

Track what you changed between rehearsals (the resolver commands you ran, in what order) so you can shorten the loop next time.

## Cleanup when you're done

```sh
# Remove the OADP Backup CRs (the bucket contents stay until ttl expires or you delete them manually)
oc get backup -n openshift-adp -o name | xargs -r oc delete -n openshift-adp

# Uninstall OADP if you don't need it for further drills
oc delete dataprotectionapplication dpa-default -n openshift-adp
oc delete subscription redhat-oadp-operator -n openshift-adp
CSV=$(oc get csv -n openshift-adp -o name | grep oadp-operator)
[[ -n "$CSV" ]] && oc delete "$CSV" -n openshift-adp
oc delete namespace openshift-adp

# Or just throw the cluster away (RHDP sandbox)
```

## What this does NOT do

- **It is not a supported RHOAI rollback path.** An etcd snapshot of a 2.25 state cannot selectively roll back a botched 2.x→3.x migration once operator versions, CRD schemas, and component states have changed — restoring etcd brings *everything* back to the snapshot point. For the 2→3 transition specifically, the migration guide is explicit that the only supported "rollback" is restoring the entire cluster from a verified backup.
- **OADP doesn't back up cluster-scoped resources by design.** `includeClusterResources: false` in the Backup spec is intentional; cluster-scoped resources (CRDs, ClusterRoles, the DSC, etc.) are owned by operators and shouldn't be replayed from a Velero archive. Layer 1 (etcd) covers cluster-scoped state.
- **OADP is not for operator state.** Don't try to back up the RHOAI operator's namespace (`redhat-ods-operator`) via OADP and replay it — operators self-reconcile and a partial restore can put OLM into an inconsistent state. The etcd snapshot is the right tool for operator state.

## Reference links

- [OCP 4.20 backup & restore overview](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/backup_and_restore/backup-restore-overview)
- [OCP 4.20 control-plane backup & restore](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/backup_and_restore/control-plane-backup-and-restore)
- [OCP 4.20 OADP application backup & restore](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/backup_and_restore/oadp-application-backup-and-restore)
- [OpenShift AI API Tiers — KB article 7047935](https://access.redhat.com/articles/7047935) (Tier 1 + Tier 2 monospaced K8s CRDs are the recommended Layer-2 discovery set)
- [Velero upstream docs](https://velero.io/docs/v1.14/) (OADP packages Velero)
