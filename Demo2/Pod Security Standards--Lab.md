# Pod Security Standards (PSS) on Azure Kubernetes Service (AKS)
### Hands-on Lab Guide for Classroom Delivery



> **Why this guide is different from the upstream Kubernetes tutorial:** the official tutorial uses `kind` and mounts a custom `AdmissionConfiguration` file directly on the API server. That approach needs control-plane file access, which AKS (a managed service) does **not** expose to you. On AKS you enforce Pod Security Standards using **namespace labels** instead — this is the officially supported pattern for any managed Kubernetes service. This guide walks through that path end-to-end on a real AKS cluster.

---

## 1. Concept Recap (5-minute refresher before the demo)

| Term | What it means |
|---|---|
| **Pod Security Standards (PSS)** | Three built-in, predefined security profiles for Pods: `Privileged`, `Baseline`, `Restricted`. |
| **Pod Security Admission (PSA)** | The built-in admission controller (GA since v1.25) that checks new Pods against whichever PSS profile a namespace declares. Replaced the old, removed `PodSecurityPolicy`. |
| **Profile: Privileged** | No restrictions. Reserved for trusted system/infra components (CNI, CSI drivers, monitoring agents). |
| **Profile: Baseline** | Blocks the most dangerous privilege-escalation paths (privileged containers, host namespaces, dangerous capabilities) but is compatible with most normal apps. |
| **Profile: Restricted** | Strongest built-in profile. Requires non-root, `allowPrivilegeEscalation: false`, dropped Linux capabilities, `seccompProfile: RuntimeDefault`, and safe volume types. Target for production app namespaces. |
| **Mode: enforce** | Non-compliant Pods are **rejected**. |
| **Mode: warn** | Pod is created; user sees a **warning** in the `kubectl` output. |
| **Mode: audit** | Pod is created; violation is written to the **audit log** only (no user-facing warning). |

Namespaces declare a profile with labels, e.g.:

```bash
kubectl label --overwrite ns production \
  pod-security.kubernetes.io/enforce=restricted
```

Labels only affect **new** Pods (create/update requests); existing running Pods are never retroactively evicted.

---

## 2. Why AKS Needs a Different Approach

| | Self-managed cluster (`kind`, kubeadm) | AKS (managed) |
|---|---|---|
| Control plane access | Full — you can mount an `AdmissionConfiguration` file and pass `--admission-control-config-file` to `kube-apiserver` | Not available — Microsoft manages and hosts the API server; you cannot mount files onto it |
| Cluster-wide default PSS | Configurable via the admission config file (as in the upstream tutorial) | Not configurable this way |
| Supported approach | Either cluster-level config file **or** namespace labels | **Namespace labels only** (or Azure Policy add-on — see §9) |
| Who sets the label | Cluster admin | Cluster admin / namespace owner via `kubectl label` |

**Takeaway for students:** on AKS (and any managed Kubernetes — EKS, GKE Autopilot, etc.), Pod Security Admission is still fully active — it ships built into the API server — you simply configure it per-namespace with labels rather than with a cluster-wide config file.

---

## 3. Prerequisites

On your workstation / lab VM, install:

- **Azure CLI** — `az --version` (≥ 2.60)
- **kubectl** — `kubectl version --client`
- An **Azure subscription** with permission to create an AKS cluster (or an existing AKS cluster on Kubernetes **v1.25+**)

Login and set subscription:

```bash
az login
az account set --subscription "<your-subscription-name-or-id>"
```

---

## 4. Step 1 — Create (or Connect to) an AKS Cluster

If you already have a cluster, skip to `az aks get-credentials` below.

```bash
# Variables — adjust as needed
RG=rg-pss-demo
LOCATION=centralindia
CLUSTER=aks-pss-demo

# Resource group
az group create --name $RG --location $LOCATION

# AKS cluster (single small node pool is enough for a classroom demo)
az aks create \
  --resource-group $RG \
  --name $CLUSTER \
  --node-count 1 \
  --node-vm-size Standard_B2s \
  --generate-ssh-keys \
  --kubernetes-version 1.30
```

Fetch credentials and point `kubectl` at the cluster:

```bash
az aks get-credentials --resource-group $RG --name $CLUSTER --overwrite-existing
kubectl get nodes
```

Confirm the Kubernetes version is 1.25+ (Pod Security Admission is GA and always on):

```bash
kubectl version -o yaml | grep -A2 serverVersion
```

---

## 5. Step 2 — Explore Existing Namespaces

```bash
kubectl get ns
kubectl get ns --show-labels
```

Notice none of the namespaces currently carry a `pod-security.kubernetes.io/*` label — PSA falls back to the `privileged` profile (no restriction) for unlabeled namespaces.

---

## 6. Step 3 — Dry-Run a Label to Preview Impact (Safe, No Changes Applied)

This is the same technique the upstream tutorial uses — server-side dry run shows you what **would** break, without changing anything:

```bash
kubectl label --dry-run=server --overwrite ns --all \
  pod-security.kubernetes.io/enforce=baseline
```

```bash
kubectl label --dry-run=server --overwrite ns --all \
  pod-security.kubernetes.io/enforce=restricted
```

Point out to students: `kube-system` will typically show warnings because system components legitimately need host access. **Never enforce `restricted` on `kube-system`.**

---

## 7. Step 4 — Create a Demo Namespace and Apply PSS Labels

Create an isolated namespace for the class demo so we never touch `kube-system` or `default`:

```bash
kubectl create namespace pss-demo
```

Apply the recommended "safe rollout" pattern: `baseline` in `enforce` (hard block), `restricted` in `warn` + `audit` (visibility only, doesn't block yet):

```bash
kubectl label --overwrite ns pss-demo \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest
```

Verify:

```bash
kubectl get ns pss-demo --show-labels
```

---

## 8. Step 5 — Try a Deliberately Insecure Pod (Show It Get Blocked / Warned)

`bad-pod.yaml` — requests a privileged container and runs as root:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: bad-pod
  namespace: pss-demo
spec:
  containers:
    - name: bad-container
      image: nginx
      securityContext:
        privileged: true
```

Apply it:

```bash
kubectl apply -f bad-pod.yaml
```

**Expected result:** the Pod is **rejected outright** — `privileged: true` violates even the `baseline` profile, which is in `enforce` mode. This is a good teaching moment: `baseline` blocks it; you don't even get to see what `restricted` would additionally flag.

Now try a milder violation that only breaks `restricted` (still passes `baseline`), so students can see the `warn`/`audit` behavior:

`mild-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: mild-pod
  namespace: pss-demo
spec:
  containers:
    - name: nginx
      image: nginx
      ports:
        - containerPort: 80
```

```bash
kubectl apply -f mild-pod.yaml
```

**Expected result:** Pod **is created** (it satisfies `baseline`), but `kubectl` prints a warning because it violates `restricted`, something like:

```
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
pod/mild-pod created
```

This is exactly the "migration signal" teams use before flipping enforcement to `restricted`.

---

## 9. Step 6 — Deploy a Fully Compliant (Restricted-Ready) Pod

`good-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: good-pod
  namespace: pss-demo
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: nginx
      image: nginx
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      ports:
        - containerPort: 80
```

```bash
kubectl apply -f good-pod.yaml
```

**Expected result:** created cleanly, **no warnings** — this manifest satisfies `restricted`.

> Note: the stock `nginx` image listens on port 80 and its master process normally wants to bind as root; with `runAsNonRoot: true` you may need an nginx image built for non-root (e.g. `nginxinc/nginx-unprivileged`) for it to actually start successfully. For the PSA admission demo itself, the Pod is accepted regardless — the image behavior is a separate, real-world follow-on discussion point for the class.

---

## 10. Step 7 — Promote the Namespace to Full `restricted` Enforcement

Once workloads have been fixed (as in Step 6), flip enforcement:

```bash
kubectl label --overwrite ns pss-demo \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest
```

Re-apply `bad-pod.yaml` and `mild-pod.yaml` — both should now be **rejected**. Re-apply `good-pod.yaml` — it still succeeds.

---

## 11. Step 8 — Version Pinning (Optional, Good for Discussion)

Pin a profile to a specific Kubernetes minor version so that behavior doesn't silently change on cluster upgrade:

```bash
kubectl label --overwrite ns pss-demo \
  pod-security.kubernetes.io/enforce-version=v1.30
```

Ask students: *why would a platform team want to pin this instead of always tracking `latest`?* (Answer: `restricted` gets stricter over Kubernetes releases; pinning avoids a Pod that worked yesterday suddenly failing after an unrelated cluster upgrade.)

---

## 12. Step 9 (Optional, AKS-Specific) — Azure Policy for AKS

Because AKS can't take a cluster-wide admission config file, teams that want **centralized, fleet-wide** enforcement (instead of per-namespace `kubectl label`) commonly layer **Azure Policy's Kubernetes add-on** on top of native PSA. It uses Gatekeeper/OPA under the hood and can:

- Enforce Pod Security Standards-equivalent constraints across **many AKS clusters** from Azure Policy, centrally
- Report compliance in the Azure Portal
- Complement (not replace) the native namespace-label PSA mechanism shown above

Enable it (optional demo, needs `Microsoft.PolicyInsights` registered on the subscription):

```bash
az aks enable-addons --resource-group $RG --name $CLUSTER --addons azure-policy
```

This is worth a mention slide but is a separate mechanism from core PSA — keep the two conceptually distinct for students: **native PSA = built into Kubernetes, free, per-namespace label. Azure Policy add-on = Azure-layer, fleet-wide governance, optional.**

---

## 13. Cleanup

```bash
kubectl delete ns pss-demo

# If you created a throwaway cluster for this class:
az aks delete --resource-group $RG --name $CLUSTER --yes --no-wait
az group delete --name $RG --yes --no-wait
```

---

## 14. Troubleshooting Cheat-Sheet

| Symptom | Likely cause | Fix |
|---|---|---|
| Pod silently created despite "insecure" spec | Namespace has no PSS label, or only `warn`/`audit` set | Check `kubectl get ns <ns> --show-labels`; add `enforce` label |
| `Error from server (Forbidden): error when creating "x.yaml": pods "x" is forbidden` | `enforce` mode blocked the Pod | Read the reason in the error — it names the exact field to fix |
| Warnings appear but Pod still created | That's `warn` mode working as designed | Fix the manifest, or leave in `warn` intentionally during migration |
| `kube-system` pods suddenly failing after a `--all` namespace label | Applied `enforce=restricted` (or `baseline`) cluster-wide including `kube-system` | Never label `kube-system`; system Pods legitimately need elevated access |
| Image (e.g. plain `nginx`) fails to actually run after passing PSA under `restricted` | PSA only checks the **Pod spec**, not runtime behavior; some images assume root at startup | Use a non-root-friendly image build, or add explicit `runAsUser` |

---

## 15. Suggested Student Exercise (for after the live demo)

1. Create a namespace `team-a`.
2. Set it to `enforce=baseline`, `warn=restricted`, `audit=restricted`.
3. Write a Deployment manifest (not just a bare Pod) for any web app image of their choice.
4. Iterate on the `securityContext` until `kubectl apply` shows **zero warnings**.
5. Flip the namespace to `enforce=restricted` and confirm the same Deployment still applies cleanly.
6. Submit the final manifest + a one-paragraph note on which fields they had to add and why.

---

## 16. Source Material


- Kubernetes.io, *Apply Pod Security Standards at the Cluster Level* — upstream `kind`-based tutorial this lab adapts for AKS.
- Kubernetes.io, *Pod Security Admission* / *Pod Security Standards* concept pages, for authoritative field-level detail on the `restricted` profile.
