# Kubernetes Security Lab: RBAC, NetworkPolicy and Pod Security Standards

Tested target: **Google Kubernetes Engine (GKE) v1.36.x**, run from **Cloud Shell**.

## Scenario

An e-commerce app split across three namespaces:

| Namespace | Purpose | Security control |
|---|---|---|
| `billing` | Finance auditing | **RBAC**: `finance-auditor-sa` has read-only access |
| `ecom-app` | Catalog API + Database | **NetworkPolicy**: only the catalog API can reach the DB |
| `payment-ns` | Payment API | **Pod Security Standard**: `restricted` is enforced |

## Files

| File | Purpose |
|---|---|
| `00-setup.sh` | Preflight checks, namespaces, PSS label, ServiceAccount (re-runnable) |
| `01-rbac-role.yaml`, `01-rbac-binding.yaml` | Read-only auditor access in `billing` |
| `02-db-svc.yaml` | DB Secret, Deployment, internal Service |
| `03-catalog-api.yaml` | Catalog API Deployment, LoadBalancer Service |
| `04-payment-api-secure.yaml` | PSS-restricted payment Deployment |
| `05-netpol-db.yaml` | DB isolation NetworkPolicy |
| `10-verify.sh` | Automated PASS/FAIL checks for everything |
| `99-cleanup.sh` | Delete everything |

## What changed from the original version

1. **Catalog API port fixed.** nginx listens on `80`, but the old manifest used `8080`, so the LoadBalancer never served traffic. Both `containerPort` and `targetPort` are now `80`.
2. **Test method changed.** `wget` against Postgres prints "error getting response" in both the allowed and blocked cases. The lab now uses `pg_isready`, which clearly says `accepting connections` or `no response`.
3. **Payment pod check fixed.** It is a Deployment, so the pod name has a random suffix. Use `-l app=payment-api`.
4. **Cluster requirement added.** Dataplane V2 is required for NetworkPolicy enforcement (Step 0).
5. **Setup script is re-runnable** (no more "AlreadyExists" errors) and warns if NetworkPolicy is not enforced.
6. **DB password moved into a Secret.**
7. **Images pinned** (`nginx:1.27-alpine`, `busybox:1.36`) instead of `latest`; probes and resource requests added (needed for smooth scheduling on GKE Autopilot).
8. **Payment pod hardened further** with `readOnlyRootFilesystem` and no mounted ServiceAccount token.
9. **PSS namespace label** also sets `enforce-version`, `warn` and `audit`.

---

## Step 0: Cluster and connection

### Cluster requirements

- GKE Standard (or Autopilot) cluster, version 1.36.x
- **Dataplane V2 must be enabled.** On Dataplane V1 (legacy), NetworkPolicy is silently ignored and the "blocked" tests will fail.
- Console: **Create cluster -> Networking -> Container Network Interface (CNI) -> select "Dataplane V2 (recommended)"**. No other network policy option is needed.
- Or via CLI (zonal, 2 x e2-medium, about US$0.08/hour):

```bash
gcloud container clusters create netpol-lab \
  --location <ZONE> --num-nodes 2 \
  --machine-type e2-medium --enable-dataplane-v2
```

### Connect

```bash
gcloud container clusters list
gcloud container clusters get-credentials <NAME> --location <LOCATION>
kubectl get nodes
```

Use the real values from the `list` output (do not type the placeholders).

### Check that NetworkPolicy is enforced

```bash
kubectl get pods -n kube-system | grep anetd
```

- `anetd-...` pods listed = enforcement ON, continue.
- Nothing listed = **STOP**. Policies would be ignored. Recreate the cluster with Dataplane V2.

You can also confirm from gcloud (should show `ADVANCED_DATAPATH`):

```bash
gcloud container clusters list --format="table(name,location,networkConfig.datapathProvider)"
```

## Step 1: Setup

```bash
chmod +x *.sh
./00-setup.sh
```

Expected: namespaces created, `payment-ns` labeled, `finance-auditor-sa` created.

```bash
kubectl get ns payment-ns --show-labels
```

## Step 2: Deploy

```bash
kubectl apply -f 01-rbac-role.yaml -f 01-rbac-binding.yaml
kubectl apply -f 02-db-svc.yaml -f 03-catalog-api.yaml
kubectl apply -f 04-payment-api-secure.yaml
```

Wait until everything is ready (about 1-2 minutes):

```bash
kubectl rollout status deploy/sample-db          -n ecom-app
kubectl rollout status deploy/sample-catalog-api -n ecom-app
kubectl rollout status deploy/sample-payment-api -n payment-ns
kubectl get pods -A | grep -E "ecom-app|payment-ns"
```

## Step 3: Verify RBAC

```bash
SA=system:serviceaccount:billing:finance-auditor-sa

kubectl auth can-i list pods     --as=$SA -n billing     # yes
kubectl auth can-i get pods/log  --as=$SA -n billing     # yes
kubectl auth can-i delete pods   --as=$SA -n billing     # no
kubectl auth can-i get secrets   --as=$SA -n billing     # no
kubectl auth can-i list pods     --as=$SA -n ecom-app    # no (other namespace)
```

Live demo with real calls:

```bash
kubectl get pods    -n billing --as=$SA      # allowed ("No resources found")
kubectl get secrets -n billing --as=$SA      # Error ... Forbidden
kubectl get pods    -n ecom-app --as=$SA     # Error ... Forbidden
```

## Step 4: NetworkPolicy (before and after)

**4a. BEFORE the policy** (nothing applied yet). Even a random pod can reach the DB:

```bash
kubectl run netpol-before --rm -i --restart=Never --quiet --image=postgres:14-alpine \
  -n ecom-app --labels=app=hacker -- pg_isready -h sample-db-internal -p 5432 -t 3
```

Expected: `sample-db-internal:5432 - accepting connections`

**4b. Apply the policy:**

```bash
kubectl apply -f 05-netpol-db.yaml
kubectl get networkpolicy -n ecom-app
sleep 5
```

**4c. Allowed: catalog-api label**

```bash
kubectl run netpol-ok --rm -i --restart=Never --quiet --image=postgres:14-alpine \
  -n ecom-app --labels=app=catalog-api -- pg_isready -h sample-db-internal -p 5432 -t 3
```

Expected: `accepting connections`

**4d. Blocked: wrong label**

```bash
kubectl run netpol-fail --rm -i --restart=Never --quiet --image=postgres:14-alpine \
  -n ecom-app --labels=app=hacker -- pg_isready -h sample-db-internal -p 5432 -t 3
```

Expected: `sample-db-internal:5432 - no response`

**4e. Blocked: different namespace**

```bash
kubectl run netpol-xns --rm -i --restart=Never --quiet --image=postgres:14-alpine \
  -n billing -- pg_isready -h sample-db-internal.ecom-app -p 5432 -t 3
```

Expected: `no response` (the policy only allows pods from the same namespace).

## Step 5: Pod Security Standards

**5a. Insecure pod is rejected:**

```bash
kubectl run insecure-test --image=busybox:1.36 -n payment-ns -- sleep 3600
```

Expected: `Error from server (Forbidden): ... violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false ..., unrestricted capabilities ..., runAsNonRoot != true ..., seccompProfile ...`

**5b. Compliant pod runs:**

```bash
kubectl get pods -n payment-ns -l app=payment-api      # 1/1 Running
```

**5c. Discussion exercise:** remove `seccompProfile` from `04-payment-api-secure.yaml`, re-apply, and watch the Deployment fail to create pods:

```bash
kubectl describe rs -n payment-ns | grep -i -A3 forbidden
```

## Step 6: Catalog API (LoadBalancer)

```bash
kubectl get svc sample-catalog-svc -n ecom-app -w      # wait for EXTERNAL-IP (1-2 min), then Ctrl+C
curl http://<EXTERNAL-IP>                               # nginx welcome page
```

## Step 7: One-command verification

```bash
./10-verify.sh
```

Prints a PASS/FAIL line for every check above and exits non-zero on any failure.

## Step 8: Cleanup (important: the LoadBalancer is billable)

```bash
./99-cleanup.sh
```

Then delete the cluster itself so cluster billing stops:

```bash
gcloud container clusters delete netpol-lab --location <ZONE>
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `gcloud ... Permission denied on 'locations/location'` | Placeholders `CLUSTER_NAME`/`LOCATION` typed literally | Use real values from `gcloud container clusters list` |
| Blocked test shows `accepting connections` | Cluster created with Dataplane V1 (legacy), or policy not applied yet | Confirm `anetd` pods exist (else recreate the cluster with Dataplane V2); confirm `kubectl get netpol -n ecom-app`; wait 5-10 s after apply |
| `wget: error getting response` | Postgres does not speak HTTP; this is not a block | Use `pg_isready` as in this guide |
| `couldn't attach to pod ... falling back to streaming logs` | Cloud Shell attach quirk with `-it` | Use `-i --restart=Never --quiet` (no `-t`) |
| Test pod stays `Pending` / slow first run | Image pull or Autopilot node scale-up | Wait 30-60 s; check `kubectl describe pod` |
| EXTERNAL-IP stuck on `<pending>` | GCP is provisioning the LB, or quota/permission issue | Wait 2 min; `kubectl describe svc sample-catalog-svc -n ecom-app` |
| `curl` to EXTERNAL-IP hangs | Old `8080` port mismatch | Make sure you use the fixed `03-catalog-api.yaml` (port 80) |
| Payment pod not created | PSS rejection | `kubectl describe rs -n payment-ns` shows the violated rule |
| `AlreadyExists` on re-run | Resources from an earlier run | Setup is idempotent; or run `99-cleanup.sh` first |

**If NetworkPolicy is not enforced** (cluster created with Dataplane V1), Dataplane V2 cannot generally be switched on for an existing cluster. Create a new one:

```bash
gcloud container clusters create netpol-lab --location <ZONE> \
  --num-nodes 2 --machine-type e2-medium --enable-dataplane-v2
gcloud container clusters get-credentials netpol-lab --location <ZONE>
```

## Teaching notes

- Run Step 4a before 4b so students see the firewall change the result.
- A NetworkPolicy selects **pods**, not Services. The ClusterIP `sample-db-internal` just forwards to the `app=database` pods.
- Once a pod is selected by an Ingress policy, everything not explicitly allowed is denied. This is why one small policy isolates the DB.
- Ask students: how would you also restrict egress from the catalog API, or add a default-deny policy for the whole namespace?
- Ask students: why is a plaintext password in a Secret manifest still not production-safe? (Base64 is not encryption; use Secret Manager or an external secrets operator.)
