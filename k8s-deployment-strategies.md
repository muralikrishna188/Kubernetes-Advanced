# Kubernetes Deployment Strategies — Hands-on Test Lab

Test four deployment strategies on any Kubernetes cluster (AKS, GKE, EKS, kind, minikube) and **see** the behaviour from a live traffic log.

| # | Strategy | What you will prove |
|---|----------|---------------------|
| 1 | Recreate | Downtime happens during the switch |
| 2 | Rolling Update | Zero downtime, old and new versions mixed temporarily; rollback works |
| 3 | Blue/Green | Instant switch and instant rollback via Service selector |
| 4 | Canary | A small share of traffic reaches the new version first |

**Time:** ~45 minutes | **Cost:** negligible (tiny pods) | **Needs:** `kubectl` access to a cluster, 2 terminals

---

## 0. Setup

### 0.1 Verify the cluster

```bash
kubectl version
kubectl get nodes
```

Expected: at least 1 node in `Ready` state.

### 0.2 Create a namespace

```bash
kubectl create namespace deploy-strategies
kubectl config set-context --current --namespace=deploy-strategies
```

### 0.3 About the test app

We use `hashicorp/http-echo`, a tiny web server that replies with a fixed text. The text is the "version", so every response tells you which version served it.

- `-text=v1` → version 1
- `-text=v2` → version 2

### 0.4 Traffic generator (reused in every lab)

The traffic pod calls a Service twice a second and prints a timestamp plus the response. A failed request prints `FAIL`.

Use **Terminal 2** for this. Replace `TARGET` per lab:

```bash
kubectl run traffic --image=curlimages/curl:8.10.1 --restart=Never \
  --env TARGET=web-recreate \
  --command -- sh -c 'while true; do echo "$(date +%T) $(curl -s -m 1 http://$TARGET || echo FAIL)"; sleep 0.5; done'

kubectl logs -f traffic
```

Between labs, remove it:

```bash
kubectl delete pod traffic --now
```

> **Tip:** Run the `kubectl` commands in **Terminal 1** and keep `kubectl logs -f traffic` visible in **Terminal 2**.

---

## Lab 1 — Recreate

**Idea:** Kill all old pods, then start new ones. Simple, but there is a gap with no pods serving traffic.

### 1.1 Deploy v1

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-recreate
spec:
  replicas: 4
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: web-recreate
  template:
    metadata:
      labels:
        app: web-recreate
    spec:
      containers:
      - name: web
        image: hashicorp/http-echo:1.0
        args: ["-text=v1"]
        ports:
        - containerPort: 5678
        readinessProbe:
          httpGet:
            path: /
            port: 5678
          initialDelaySeconds: 5
          periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: web-recreate
spec:
  selector:
    app: web-recreate
  ports:
  - port: 80
    targetPort: 5678
EOF

kubectl rollout status deployment/web-recreate
```

### 1.2 Start traffic

Run the traffic pod from section 0.4 with `TARGET=web-recreate`. You should see only `v1`.

### 1.3 Update to v2

```bash
kubectl patch deployment web-recreate --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["-text=v2"]}]'
kubectl get pods -w
```

### 1.4 Expected result

- Traffic log shows a stretch of `FAIL` lines (several seconds), then `v2`.
- `kubectl get pods -w` shows all `v1` pods `Terminating` **before** new pods start.

### 1.5 Verify

```bash
kubectl rollout history deployment/web-recreate
```

**Pass criteria:** at least one `FAIL` appeared during the update, and traffic ends 100% on `v2`.

### 1.6 Clean up

```bash
kubectl delete pod traffic --now
kubectl delete deployment,service web-recreate
```

---

## Lab 2 — Rolling Update

**Idea:** Replace pods gradually. `maxUnavailable: 0` and `maxSurge: 1` mean a new pod must be Ready before an old one is removed.

### 2.1 Deploy v1

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-rolling
spec:
  replicas: 4
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: web-rolling
  template:
    metadata:
      labels:
        app: web-rolling
    spec:
      containers:
      - name: web
        image: hashicorp/http-echo:1.0
        args: ["-text=v1"]
        ports:
        - containerPort: 5678
        readinessProbe:
          httpGet:
            path: /
            port: 5678
          initialDelaySeconds: 5
          periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: web-rolling
spec:
  selector:
    app: web-rolling
  ports:
  - port: 80
    targetPort: 5678
EOF

kubectl rollout status deployment/web-rolling
```

### 2.2 Start traffic

Use `TARGET=web-rolling` and keep the logs open.

### 2.3 Update to v2

```bash
kubectl patch deployment web-rolling --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["-text=v2"]}]'
kubectl rollout status deployment/web-rolling
```

### 2.4 Expected result

- Traffic log shows `v1` and `v2` **mixed** for a while, then only `v2`.
- **No `FAIL` lines.**
- `kubectl get rs` shows the old ReplicaSet scaling down while the new one scales up.

```bash
kubectl get rs
```

### 2.5 Pause and resume (control the rollout)

```bash
kubectl patch deployment web-rolling --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["-text=v3"]}]'
kubectl rollout pause deployment/web-rolling
```

> Note: pausing right after the patch may let the first pod or two roll. Check the log, then:

```bash
kubectl rollout resume deployment/web-rolling
kubectl rollout status deployment/web-rolling
```

### 2.6 Simulate a bad release

Use an image tag that does not exist:

```bash
kubectl set image deployment/web-rolling web=hashicorp/http-echo:does-not-exist
kubectl rollout status deployment/web-rolling --timeout=60s
kubectl get pods
```

**Expected:** new pod stuck in `ErrImagePull` / `ImagePullBackOff`, **old pods still serving**, traffic log still healthy. This is the safety net of rolling updates with `maxUnavailable: 0`.

### 2.7 Roll back

```bash
kubectl rollout history deployment/web-rolling
kubectl rollout undo deployment/web-rolling
kubectl rollout status deployment/web-rolling
```

**Expected:** traffic returns to the previous good version, no `FAIL`.

### 2.8 Pass criteria

- [ ] No `FAIL` during the v1 → v2 update
- [ ] Mixed v1/v2 responses seen during rollout
- [ ] Bad image did not take down the service
- [ ] `rollout undo` restored a healthy version

### 2.9 Clean up

```bash
kubectl delete pod traffic --now
kubectl delete deployment,service web-rolling
```

---

## Lab 3 — Blue/Green

**Idea:** Run two full environments side by side. The Service selector decides which one gets traffic. Switching is a one-line change; rollback is the same line reversed.

### 3.1 Deploy blue (v1) and green (v2)

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-blue
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web-bg
      color: blue
  template:
    metadata:
      labels:
        app: web-bg
        color: blue
    spec:
      containers:
      - name: web
        image: hashicorp/http-echo:1.0
        args: ["-text=v1-BLUE"]
        ports:
        - containerPort: 5678
        readinessProbe:
          httpGet:
            path: /
            port: 5678
          periodSeconds: 2
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-green
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web-bg
      color: green
  template:
    metadata:
      labels:
        app: web-bg
        color: green
    spec:
      containers:
      - name: web
        image: hashicorp/http-echo:1.0
        args: ["-text=v2-GREEN"]
        ports:
        - containerPort: 5678
        readinessProbe:
          httpGet:
            path: /
            port: 5678
          periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: web-bg
spec:
  selector:
    app: web-bg
    color: blue
  ports:
  - port: 80
    targetPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: web-bg-green-preview
spec:
  selector:
    app: web-bg
    color: green
  ports:
  - port: 80
    targetPort: 5678
EOF

kubectl rollout status deployment/web-blue
kubectl rollout status deployment/web-green
```

### 3.2 Start traffic against the live Service

Use `TARGET=web-bg`. You should see only `v1-BLUE`.

### 3.3 Test green privately before switching

The preview Service lets you validate green without touching live traffic:

```bash
kubectl run smoke --image=curlimages/curl:8.10.1 --restart=Never --rm -it \
  -- curl -s http://web-bg-green-preview
```

**Expected:** `v2-GREEN`, while the traffic log still shows `v1-BLUE`.

### 3.4 Switch live traffic to green

```bash
kubectl patch service web-bg -p '{"spec":{"selector":{"app":"web-bg","color":"green"}}}'
```

**Expected:** the traffic log flips from `v1-BLUE` to `v2-GREEN` almost instantly, with no `FAIL` and no mixed period.

### 3.5 Instant rollback

```bash
kubectl patch service web-bg -p '{"spec":{"selector":{"app":"web-bg","color":"blue"}}}'
```

**Expected:** traffic returns to `v1-BLUE` immediately.

### 3.6 Pass criteria

- [ ] Green was reachable via the preview Service before the switch
- [ ] Switch caused no `FAIL` and no v1/v2 mixing
- [ ] Rollback was instant

> **Trade-off to note:** you pay for two full environments while both run.

### 3.7 Clean up

```bash
kubectl delete pod traffic --now
kubectl delete deployment web-blue web-green
kubectl delete service web-bg web-bg-green-preview
```

---

## Lab 4 — Canary

**Idea:** Send a small share of traffic to the new version first. With plain Kubernetes, the share is controlled by the **ratio of pod counts** behind one Service.

### 4.1 Deploy stable (v1) with 9 replicas, canary (v2) with 1

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-stable
spec:
  replicas: 9
  selector:
    matchLabels:
      app: web-canary
      track: stable
  template:
    metadata:
      labels:
        app: web-canary
        track: stable
    spec:
      containers:
      - name: web
        image: hashicorp/http-echo:1.0
        args: ["-text=v1-stable"]
        ports:
        - containerPort: 5678
        readinessProbe:
          httpGet:
            path: /
            port: 5678
          periodSeconds: 2
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-canary
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web-canary
      track: canary
  template:
    metadata:
      labels:
        app: web-canary
        track: canary
    spec:
      containers:
      - name: web
        image: hashicorp/http-echo:1.0
        args: ["-text=v2-CANARY"]
        ports:
        - containerPort: 5678
        readinessProbe:
          httpGet:
            path: /
            port: 5678
          periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: web-canary
spec:
  selector:
    app: web-canary
  ports:
  - port: 80
    targetPort: 5678
EOF

kubectl rollout status deployment/web-stable
kubectl rollout status deployment/web-canary
```

The Service selects only `app: web-canary`, so it covers **both** tracks.

### 4.2 Measure the traffic split

Run a one-off counter of 100 requests:

```bash
kubectl run count --image=curlimages/curl:8.10.1 --restart=Never --rm -it \
  --command -- sh -c 'for i in $(seq 1 100); do curl -s http://web-canary; done | sort | uniq -c'
```

**Expected:** roughly 90 `v1-stable` and 10 `v2-CANARY`. The split is approximate, because kube-proxy balances per connection, not exactly.

### 4.3 Promote the canary gradually

```bash
# 50 / 50
kubectl scale deployment web-stable --replicas=5
kubectl scale deployment web-canary --replicas=5
```

Re-run the counter from 4.2. Expected: roughly half and half.

```bash
# Full promotion
kubectl scale deployment web-canary --replicas=10
kubectl scale deployment web-stable --replicas=0
```

Re-run the counter. Expected: 100% `v2-CANARY`.

### 4.4 Abort the canary (rollback)

Reset and simulate a failed canary:

```bash
kubectl scale deployment web-stable --replicas=10
kubectl scale deployment web-canary --replicas=0
```

**Expected:** 100% `v1-stable` again.

### 4.5 Pass criteria

- [ ] Initial split is close to 90/10
- [ ] Split shifted as replicas changed
- [ ] Abort returned all traffic to stable

> **Limitation:** replica-ratio canaries cannot do exact percentages (e.g. 1%) or header-based routing. For that, see the "Next steps" section.

### 4.6 Clean up

```bash
kubectl delete deployment web-stable web-canary
kubectl delete service web-canary
```

---

## Final Clean-up

```bash
kubectl delete pod traffic --ignore-not-found --now
kubectl config set-context --current --namespace=default
kubectl delete namespace deploy-strategies
```

---

## Summary Comparison

| Strategy | Downtime | Extra resources | Rollback speed | Risk exposure | Best for |
|----------|----------|-----------------|----------------|---------------|----------|
| Recreate | Yes | None | Slow (redeploy) | All users at once | Dev/test, apps that cannot run two versions |
| Rolling | No | Small (`maxSurge`) | Fast (`rollout undo`) | Gradual | Default for most stateless apps |
| Blue/Green | No | 2x capacity | Instant (selector flip) | All users at once, but pre-validated | Releases needing quick, safe cutover |
| Canary | No | Small | Fast (scale down) | Small % first | Risky changes, real-user validation |

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Traffic pod shows only `FAIL` | `kubectl get endpoints <service>` — empty means selector mismatch or pods not Ready |
| Pods stuck `Pending` | `kubectl describe pod <name>` — look for insufficient CPU/memory |
| `ImagePullBackOff` on good image | Check node outbound access to Docker Hub / registry rate limits |
| Rolling update never finishes | `kubectl describe deployment <name>`; check readiness probe and `kubectl rollout status` |
| Canary split far from expected | Too few requests; use 100+ and remember per-connection balancing |
| `kubectl logs -f traffic` shows nothing | Pod may not be running yet: `kubectl get pod traffic` |

---

## Next Steps (optional)

- **Exact-percentage canary and header routing:** try Argo Rollouts or Flagger, or traffic splitting through ingress-nginx canary annotations or the Gateway API (`HTTPRoute` weights).
- **Automated analysis and rollback:** connect canary metrics (Prometheus) to an automated promotion gate.
- **Add PodDisruptionBudgets and `preStop` hooks** to see how graceful shutdown affects zero-downtime claims.
