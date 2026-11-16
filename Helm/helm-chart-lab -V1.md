# Helm Chart Lab (Helm 4 + GKE)

Simple, step-by-step. Only Helm chart implementation. Two parts:

- **Part A**: Use a ready-made chart (install, upgrade, rollback, uninstall)
- **Part B**: Build your own chart for the **Ghost** blog

---

## 0. What changed vs the old deck

| Old (deck) | Now |
|---|---|
| Bitnami charts (`apache`, `postgresql`, `nginx`) | **Bitnami stopped publishing free charts/images on 28 Aug 2025.** Old images moved to `docker.io/bitnamilegacy` (no updates), so these demos can fail with `ImagePullBackOff`. We use **podinfo** instead. |
| `helm install ... --name api` | `--name` was removed in Helm 3. Release name is now the first argument: `helm install api myrepo/msa` |
| `--set nameOverride: api` | Correct syntax is `--set nameOverride=api` |
| `helm delete` | Use `helm uninstall` |
| Helm 3 | **Helm 4** is the current major version. Helm 3 gets no further minor releases. Charts with `apiVersion: v2` work unchanged. |
| "Helm deploys a Kubernetes cluster" | Helm deploys the **application** into an existing cluster |
| Postgres values nested under `postgresql:` with `db-name` | Wrong keys. Removed with the Bitnami demo. |
| `image: ghost` (floating tag) | Pinned: `image: ghost:6` |
| Fixed names `ghost-app`, `my-service-for-my-webapp` | Names use the release name, so prod and non-prod can run together |

---

## 1. Prerequisites

### 1.1 Install Helm 4

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
./get_helm.sh
helm version
```

(Google Cloud Shell users: run the same commands there.)

### 1.2 Connect to the GKE cluster

```bash
gcloud container clusters get-credentials CLUSTER_NAME --zone ZONE --project PROJECT_ID
kubectl get nodes
```

If `kubectl` complains about `gke-gcloud-auth-plugin`, install it:

```bash
gcloud components install gke-gcloud-auth-plugin
```

You should see your nodes in `Ready` state.

---

## Part A: Use a ready-made chart (podinfo)

podinfo is a tiny public demo web app. It has no Bitnami dependency.

### A1. Add the repo and search

```bash
helm repo add podinfo https://stefanprodan.github.io/podinfo
helm repo update
helm repo ls
helm search repo podinfo
helm search hub podinfo        # searches Artifact Hub (public catalog)
```

### A2. Install

```bash
helm install my-podinfo podinfo/podinfo
helm status my-podinfo
helm ls
kubectl get deploy,pods,svc
```

### A3. Open the app

```bash
kubectl port-forward svc/my-podinfo 8080:9898
```

Open `http://localhost:8080` (Cloud Shell: **Web Preview** -> port 8080). Press `Ctrl+C` to stop.

### A4. Look at the chart's default values

```bash
helm show values podinfo/podinfo | head -50
```

### A5. Upgrade

```bash
helm upgrade my-podinfo podinfo/podinfo --set replicaCount=3
helm history my-podinfo
kubectl get pods
```

You should see **REVISION 2** and 3 pods.

### A6. Rollback

```bash
helm rollback my-podinfo 1
helm history my-podinfo
```

Rollback creates a **new revision (3)** that has revision 1's settings.

### A7. Install with your own values file

Create `values.yaml`:

```yaml
replicaCount: 2
ui:
  color: "#2f855a"
  message: "Hello from Helm"
```

```bash
helm install my-custom -f values.yaml podinfo/podinfo
```

Upgrade it with `new-values.yaml`:

```yaml
replicaCount: 2
ui:
  color: "#2f855a"
  message: "Updated with helm upgrade"
```

```bash
helm upgrade my-custom podinfo/podinfo -f new-values.yaml
```

> `helm upgrade` does not keep old `--set` / values by default. Put every value you want in the file (or add `--reuse-values`).

### A8. OCI method (same chart, no `helm repo add`)

```bash
helm install my-oci oci://ghcr.io/stefanprodan/charts/podinfo
```

OCI charts need Helm 3.8+ (Helm 4 is fine).

### A9. Clean up

```bash
helm uninstall my-podinfo
helm uninstall my-custom
helm uninstall my-oci
helm ls
```

---

## Part B: Build your own chart (Ghost blog)

### B1. Test Ghost with plain Docker (optional)

Ghost 6 starts in *production* mode by default and then **needs MySQL**. Without it you get `ECONNREFUSED 127.0.0.1:3306`. For this demo we set `NODE_ENV=development`, which uses a built-in SQLite database.

```bash
docker run --rm -p 2368:2368 --name my-ghost -e NODE_ENV=development ghost:6
# open http://localhost:2368 , then Ctrl+C
```

### B2. Create the chart skeleton

```bash
helm create my-ghost-app
```

Keep only what we need. Delete all generated templates and start clean:

```bash
rm -rf my-ghost-app/templates/*
```

Your chart now looks like this:

```
my-ghost-app/
├── Chart.yaml
├── values.yaml
├── charts/
└── templates/        (empty)
```

### B3. `Chart.yaml`

Replace the content of `my-ghost-app/Chart.yaml`:

```yaml
apiVersion: v2
name: my-ghost-app
description: A simple Helm chart for the Ghost blog
type: application
version: 0.1.0
appVersion: "6"
```

### B4. `values.yaml` (defaults)

Replace the content of `my-ghost-app/values.yaml`:

```yaml
replicaCount: 1
prodUrlSchema: false
datacenter: us-east
baseUrl: myapp.org
```

### B5. `templates/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-ghost
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}-ghost
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}-ghost
    spec:
      containers:
        - name: ghost
          image: ghost:6
          ports:
            - containerPort: 2368
          env:
            - name: NODE_ENV
              value: development
            - name: url
              {{- if .Values.prodUrlSchema }}
              value: http://{{ .Values.baseUrl }}
              {{- else }}
              value: http://{{ .Values.datacenter }}.non-prod.{{ .Values.baseUrl }}
              {{- end }}
```

What the template does:

- `{{ .Values.replicaCount }}` is replaced from values.
- `{{ .Release.Name }}` is the name you give at `helm install`.
- The `if / else` builds the `url` environment variable differently for prod and non-prod.

### B6. `templates/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-ghost
spec:
  type: LoadBalancer
  selector:
    app: {{ .Release.Name }}-ghost
  ports:
    - protocol: TCP
      port: 80
      targetPort: 2368
```

> On GKE, `type: LoadBalancer` creates a Google Cloud load balancer with an external IP (it can be billed). Always `helm uninstall` when you finish.

### B7. Check the chart before deploying

```bash
helm lint ./my-ghost-app
helm template my-ghost ./my-ghost-app
```

In the output, `replicas: 1` and `value: http://us-east.non-prod.myapp.org` confirm the defaults work.

### B8. Environment override files

Create these files inside `my-ghost-app/`:

`values.prod.yaml`
```yaml
replicaCount: 3
prodUrlSchema: true
```

`values.nonprod.yaml`
```yaml
replicaCount: 1
prodUrlSchema: false
```

`values.us-east.yaml`
```yaml
datacenter: us-east
```

`values.us-west.yaml`
```yaml
datacenter: us-west
```

Combine them (the last `-f` file wins on conflicts):

```bash
helm template my-ghost ./my-ghost-app -f my-ghost-app/values.prod.yaml
helm template my-ghost ./my-ghost-app -f my-ghost-app/values.nonprod.yaml -f my-ghost-app/values.us-west.yaml
```

### B9. Install

```bash
helm install my-ghost-prod ./my-ghost-app -f my-ghost-app/values.prod.yaml
helm ls
kubectl rollout status deploy/my-ghost-prod-ghost
kubectl get pods,svc
```

You should see 3 pods and a `LoadBalancer` service. `EXTERNAL-IP` can show `<pending>` for a minute.

Because the release name is part of every resource name, you can run non-prod **at the same time**:

```bash
helm install my-ghost-nonprod ./my-ghost-app \
  -f my-ghost-app/values.nonprod.yaml \
  -f my-ghost-app/values.us-east.yaml
```

### B10. Open Ghost in the browser

Ghost builds links from the `url` setting, so opening it with a different address can redirect you to `url`. For a clean test, install a copy whose `url` is `localhost`:

```bash
helm install my-ghost ./my-ghost-app \
  --set prodUrlSchema=true --set baseUrl=localhost:2368
kubectl rollout status deploy/my-ghost-ghost
kubectl port-forward svc/my-ghost-ghost 2368:80
```

Open `http://localhost:2368` (Cloud Shell: **Web Preview** -> change port to 2368). Ghost can take 30-60 seconds on first start.

> Demo only: `NODE_ENV=development` makes Ghost use SQLite inside each pod, so data is not shared between replicas and is lost when a pod restarts. A real deployment needs MySQL and persistent storage.

### B11. Upgrade and rollback your own chart

```bash
helm upgrade my-ghost-prod ./my-ghost-app -f my-ghost-app/values.prod.yaml --set replicaCount=2
helm history my-ghost-prod
helm rollback my-ghost-prod 1
```

### B12. Clean up everything

```bash
helm uninstall my-ghost-prod
helm uninstall my-ghost-nonprod
helm uninstall my-ghost
helm ls
kubectl get all
```

---

## Quick command reference

| Task | Command |
|---|---|
| Add repo | `helm repo add NAME URL` |
| Refresh repos | `helm repo update` |
| Search | `helm search repo WORD` / `helm search hub WORD` |
| Show default values | `helm show values CHART` |
| Install | `helm install RELEASE CHART [-f file.yaml] [--set k=v]` |
| List releases | `helm ls` |
| Upgrade | `helm upgrade RELEASE CHART [-f file.yaml]` |
| History | `helm history RELEASE` |
| Rollback | `helm rollback RELEASE REVISION` |
| Uninstall | `helm uninstall RELEASE` |
| New chart | `helm create NAME` |
| Check chart | `helm lint ./CHART` |
| Render YAML only | `helm template RELEASE ./CHART -f values.yaml` |

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `ImagePullBackOff` on a Bitnami chart | Bitnami free images were moved/retired (Aug 2025). Use a different chart, or build/pull images from a source you control. |
| `Error: INSTALLATION FAILED: cannot re-use a name that is still in use` | A release with that name exists. Run `helm ls`, then `helm uninstall NAME` or pick another name. |
| `unknown flag: --name` | Helm 3/4 has no `--name`. Put the release name right after `helm install`. |
| YAML error in template | Run `helm lint ./my-ghost-app` and `helm template ...` to see the line. |
| `EXTERNAL-IP` stays `<pending>` | Wait a minute, then `kubectl get svc -w`. Check your project's load balancer quota. |
| `ECONNREFUSED 127.0.0.1:3306` | Ghost is in production mode and wants MySQL. Set env `NODE_ENV=development` (demo) or deploy MySQL. |
| Ghost redirects to `myapp.org` | Expected: `url` is set to that name. Use B10 (`localhost:2368`). |
