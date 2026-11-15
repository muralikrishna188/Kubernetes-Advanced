# Helm Step-by-Step Kubernetes Engine (GKE 1.36) — Deploy the Ghost Blog



| | |
|---|---|
| **Helm version** | v4.x (tested with v4.3.2). Helm 3 reached end-of-life on 11 Nov 2026, |
| **Kubernetes** | Google Kubernetes Engine (GKE) **1.36** |
| **Application** | Ghost blog, image `ghost:6-alpine` |
| **Time needed** | about 3.5 to 4 hours (agenda in Part 8) |
| **Cost** | a small 2-node GKE cluster.  |


---



1. **Bitnami charts (slides 9, 11, 13, 20–24):** Bitnami moved its free container images to a frozen "legacy" repository in 2025, so `helm install my-apache bitnami/apache` can fail with image-pull errors. Part 3 of this guide uses **podinfo** (a small, maintained demo app) instead.
2. **Ghost image (slides 26, 27, 31):** The official `ghost` image now defaults to **production mode, which needs a MySQL database**. The PPT's plain `image: ghost` deployment will therefore most likely fail to start (expect `CrashLoopBackOff`). I could not run Ghost in my sandbox, so confirm this once. Fix: set `NODE_ENV=development` (built-in SQLite) for the lab and **pin the image tag**.
3. **`helm create` (slide 33):** the current `helm create` also generates `httproute.yaml` and `_helpers.tpl`. The slide's delete list misses `httproute.yaml`, and I confirmed that `helm lint` then fails with a nil-pointer error. Fix: delete everything inside `templates/` and write our own files.
4. **Helm 3 → Helm 4:** Helm 4 is the current stable release. Some flags were renamed (Part 7).

---

## Part 1 — Understand Helm first (15 minutes)

### 1.1 What is Helm?

💡 **Kubernetes needs many YAML files** (Deployment, Service, ConfigMap, Ingress…) for even one application. **Helm is the package manager for Kubernetes**, like `apt` on Ubuntu or the Play Store on your phone. You install a whole application with **one command**, and you customize it with **settings (values)** instead of editing YAML.

| Helm word | Everyday meaning | Technical meaning |
|---|---|---|
| **Chart** | A **recipe** | A folder or `.tgz` file with Kubernetes YAML *templates* |
| **Values** | Your **order**: "less salt, 3 servings" | Settings (`values.yaml`) that fill the templates |
| **Release** | The **dish served** at your table | One installed copy of a chart in a cluster, with a name you choose |
| **Revision** | A **save-point** | Every install, upgrade or rollback creates a new revision number |
| **Repository** | The **cookbook shelf** | A place where charts are published (HTTP repo or OCI registry) |

### 1.2 How Helm works

```
   Chart (templates)  ─┐
                       ├─►  helm  ─► rendered Kubernetes YAML ─► Kubernetes API ─► your app runs
   Values (settings)  ─┘                                              ▲
                                                                      │
                                   Helm saves release history as Secrets in the cluster
```

- Helm is just a **client program** on your laptop or Cloud Shell. There is **nothing to install inside the cluster** (the old "Tiller" of Helm 2 is gone).
- Helm **does not create clusters**. It puts applications **into** a cluster that already exists.
- Same chart + different values = different environments (dev, test, prod).

### 1.3 What is inside a chart?

```
my-ghost-app/
├── Chart.yaml        ← name and version of the chart
├── values.yaml       ← default settings
└── templates/        ← YAML files with {{ placeholders }}
    ├── deployment.yaml
    ├── service.yaml
    └── NOTES.txt     ← message shown after install
```

## Part 2 — Prepare the lab: GKE 1.36 cluster and Helm 4 (25 minutes)

### 2.1 What you need

- A Google Cloud account with a **project** that has **billing enabled**
- A web browser. We use **Cloud Shell** (a free Linux terminal inside Google Cloud) so students do not install anything.

### 2.2 Open Cloud Shell and set variables

🎯 **Goal:** a terminal that knows your project.

1. Go to <https://console.cloud.google.com> and click the **Activate Cloud Shell** icon (top right, `>_`).
2. Run (replace `YOUR_PROJECT_ID`):

⌨️ **Run**
```bash
gcloud config set project YOUR_PROJECT_ID

export CLUSTER=helm-lab
export ZONE=asia-south1-a      # Mumbai. Any zone near you is fine

gcloud config list project
```

✅ **Expected:** `project = YOUR_PROJECT_ID`

### 2.3 Enable the GKE API (once per project)

⌨️ **Run**
```bash
gcloud services enable container.googleapis.com
```

### 2.4 Confirm that Kubernetes 1.36 is offered in your zone

💡 Google releases Kubernetes versions in *channels* (Rapid, Regular, Stable). 1.36 is available in the **Regular** channel.

⌨️ **Run**
```bash
gcloud container get-server-config --zone $ZONE \
  --format="yaml(channels)" | grep -B2 -A12 "REGULAR"
```

✅ **Expected:** under `REGULAR`, you see versions starting with `1.36.`

### 2.5 Create the cluster

💡 We create a small **zonal** cluster with **2 nodes**. Ghost needs a little memory, so we use `e2-standard-2` (2 vCPU, 8 GB).

⌨️ **Run** (takes about 5 to 8 minutes)
```bash
gcloud container clusters create $CLUSTER \
  --zone $ZONE \
  --release-channel regular \
  --cluster-version 1.36 \
  --num-nodes 2 \
  --machine-type e2-standard-2
```

✅ **Expected:** a table ending with `STATUS  RUNNING` and `MASTER_VERSION` starting with `1.36.`

⚠️ **Careful:** if you get "version not available", run the command in 2.4 and use the exact `1.36.x-gke.xxxx` version shown there: `--cluster-version 1.36.x-gke.xxxx`.

### 2.6 Connect `kubectl` to the cluster

⌨️ **Run**
```bash
gcloud container clusters get-credentials $CLUSTER --zone $ZONE
kubectl get nodes
kubectl version
```

✅ **Expected:** 2 nodes in `Ready` state, VERSION like `v1.36.x-gke.xxxx`. `kubectl version` shows the Server Version `v1.36.x`.

### 2.7 Check Helm, and install Helm 4 if needed

⌨️ **Run**
```bash
helm version
```

- If it prints `Version:"v4.…"` → ✅ you are ready, go to Part 3.
- If it prints `v3.…`, install Helm 4 into your home folder (Cloud Shell keeps your `$HOME`):

⌨️ **Run**
```bash
mkdir -p $HOME/bin
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
USE_SUDO=false HELM_INSTALL_DIR=$HOME/bin ./get_helm.sh

echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc
export PATH=$HOME/bin:$PATH
helm version
```

✅ **Expected:** `version.BuildInfo{Version:"v4.…`

> 💡 **On your own laptop?** See <https://helm.sh/docs/intro/install/> (for example `brew install helm`, `winget install Helm.Helm`, `choco install kubernetes-helm`).

---

## Part 3 — Helm basics with a ready-made chart (60 minutes)

🎯 **Goal:** learn the complete life cycle: **add repo → search → install → check → upgrade → rollback → uninstall**.


### 3.1 Create a namespace for this part

💡 A **namespace** is a folder inside the cluster. It keeps our lab tidy and makes cleanup easy.

⌨️ **Run**
```bash
kubectl create namespace helm-basics
```

### 3.2 Add a chart repository

⌨️ **Run**
```bash
helm repo add podinfo https://stefanprodan.github.io/podinfo
helm repo update
helm repo list
```

✅ **Expected:** `"podinfo" has been added to your repositories`

### 3.3 Search for charts

⌨️ **Run**
```bash
helm search repo podinfo                  # latest version
helm search repo podinfo --versions | head -5   # several versions
helm search hub nginx | head -5           # search ALL public charts on Artifact Hub
```

💡 Two different searches:
- `helm search repo` → only repositories **you added**
- `helm search hub` → the public catalogue on **Artifact Hub**

### 3.4 Look inside a chart before installing

💡 Good habit: **read the chart before you run it.**

⌨️ **Run**
```bash
helm show chart podinfo/podinfo | head -20
helm show values podinfo/podinfo | head -40
```

Find the `ui:` section in the values. It has `message` and `color`, which we will change in a moment:

```bash
helm show values podinfo/podinfo | grep -A4 "^ui:"
```

### 3.5 Install your first release

💡 Syntax: `helm install <RELEASE-NAME> <CHART> [options]`. The **release name comes first**. There is no `--name` flag any more.

⌨️ **Run**
```bash
helm install my-podinfo podinfo/podinfo \
  --namespace helm-basics \
  --set ui.message="Hello from version 1"
```

✅ **Expected:** `STATUS: deployed` and `REVISION: 1`

### 3.6 See what Helm created

⌨️ **Run**
```bash
helm list -n helm-basics
helm status my-podinfo -n helm-basics
kubectl get all -n helm-basics
```

✅ **Expected:** a Deployment, a Pod (wait until `1/1 Running`), a Service and a ReplicaSet.

💡 **One command created several Kubernetes objects.** That is the power of Helm.

### 3.7 Test the application

💡 The Service is internal (`ClusterIP`), so we use `port-forward` to reach it from Cloud Shell.

⌨️ **Run**
```bash
kubectl get svc -n helm-basics                  # note the service name and port (9898)
kubectl port-forward svc/my-podinfo 8080:9898 -n helm-basics &
sleep 3
curl -s localhost:8080
```

✅ **Expected:** JSON text containing `"message": "Hello from version 1"`.

⚠️ If the service name differs, use the name shown by `kubectl get svc`.

### 3.8 Upgrade the release

💡 `helm upgrade` changes a running release. Helm makes a new **revision**; the old one stays in history.

⌨️ **Run**
```bash
kill %1 2>/dev/null     # stop the old port-forward

helm upgrade my-podinfo podinfo/podinfo \
  --namespace helm-basics \
  --set ui.message="Hello from version 2"

helm list -n helm-basics
```

✅ **Expected:** `REVISION` is now **2**.

⌨️ **Run** (check the new message)
```bash
kubectl rollout status deploy/my-podinfo -n helm-basics
kubectl port-forward svc/my-podinfo 8080:9898 -n helm-basics &
sleep 3
curl -s localhost:8080 | grep message
kill %1
```

✅ **Expected:** `"message": "Hello from version 2"`

### 3.9 See and use the history → rollback

⌨️ **Run**
```bash
helm history my-podinfo -n helm-basics
helm rollback my-podinfo 1 -n helm-basics
helm history my-podinfo -n helm-basics
```

✅ **Expected:** after the rollback there are **3 revisions**. Revision 3 says "Rollback to 1". Rollback never erases history; it creates a **new** revision that copies the old one.

### 3.10 Use a values file 

💡 `--set` is fine for one value. For many values, use a **file** with `-f`.

⌨️ **Run**
```bash
cat > podinfo-values.yaml <<'EOF'
replicaCount: 2
ui:
  message: "Hello from my values file"
  color: "#2a7de1"
EOF

helm upgrade my-podinfo podinfo/podinfo -n helm-basics -f podinfo-values.yaml

kubectl get pods -n helm-basics
helm get values my-podinfo -n helm-basics
```

✅ **Expected:** 2 pods. `helm get values` shows exactly the values you supplied.

> 💡 **Rule to remember:** if you use both, `--set` **wins** over `-f`. With several `-f` files, the **last file wins**.

### 3.11 Uninstall

⌨️ **Run**
```bash
helm uninstall my-podinfo -n helm-basics
helm list -n helm-basics
kubectl get all -n helm-basics
```

✅ **Expected:** the release is gone and all its Kubernetes objects are removed.

### 3.12 Bonus: charts from an OCI registry

💡 **OCI** (Open Container Initiative) lets charts live in the same kind of registry as container images (Docker Hub, GitHub Container Registry, Google Artifact Registry…). In Helm 4, OCI support is built in and on by default.

⌨️ **Run**
```bash
helm show chart oci://ghcr.io/stefanprodan/charts/podinfo | head -12
```

To install from OCI, put the version in `--version`, **not** after a colon:

```bash
helm install my-podinfo-oci oci://ghcr.io/stefanprodan/charts/podinfo \
  --namespace helm-basics --version <VERSION-SHOWN-ABOVE>

helm uninstall my-podinfo-oci -n helm-basics     # clean up
```

| | Traditional repo | OCI registry |
|---|---|---|
| Add step | `helm repo add …` | none, use `oci://…` in the command |
| Chart reference | `repo/chart` | `oci://registry/path/chart` |
| Version | `--version X` | `--version X` |

---

## Part 4 — Build and deploy the Ghost blog with our own Helm chart (90 minutes)

🎯 **Goal:** write a Helm chart from scratch, then deploy the **same chart** in different "environments" just by changing values.

### 4.1 Know your application: three facts about Ghost

Before packaging any application, ask: *how does it run?* For Ghost:

1. **Port 2368.** Ghost listens on port `2368` inside the container.
2. **Two modes.**
   - `development` → uses a built-in **SQLite** file database. Easy, no extra database needed.
   - `production` → **requires an external MySQL 8 database.** (This is the default in the official image.)
3. **The `url` setting.** Ghost must know its own public web address and uses it to build links. We pass it as an environment variable called `url`.


### 4.2 (Optional demo) Run Ghost with plain Docker

Cloud Shell already includes Docker.

⌨️ **Run**
```bash
docker run -d --rm --name my-ghost -e NODE_ENV=development -p 2368:2368 ghost:6-alpine
sleep 40
curl -sI localhost:2368 | head -3
docker rm -f my-ghost
```

✅ **Expected:** an HTTP status line such as `HTTP/1.1 200 OK` (a redirect `301`/`302` also means Ghost is alive).

💡 Notice `-e NODE_ENV=development`. The old slide did not have it, and today that would fail because production mode wants MySQL.

### 4.3 Step A: Deploy Ghost with plain Kubernetes YAML (no Helm yet)

💡 First feel the problem Helm solves. Create two files.

⌨️ **Run**
```bash
mkdir -p ~/helm-lab/plain && cd ~/helm-lab/plain

cat > deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ghost-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ghost-app
  template:
    metadata:
      labels:
        app: ghost-app
    spec:
      containers:
        - name: ghost-app
          image: ghost:6-alpine
          ports:
            - containerPort: 2368
          env:
            - name: NODE_ENV
              value: development
            - name: url
              value: http://localhost:8080
EOF

cat > service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: ghost-app
spec:
  type: ClusterIP
  selector:
    app: ghost-app
  ports:
    - port: 80
      targetPort: 2368
EOF

kubectl create namespace ghost-plain
kubectl apply -f deployment.yaml -f service.yaml -n ghost-plain
kubectl rollout status deploy/ghost-app -n ghost-plain --timeout=180s
```

⌨️ **Test**
```bash
kubectl port-forward svc/ghost-app 8080:80 -n ghost-plain &
sleep 3
curl -sI localhost:8080 | head -3
kill %1
```

✅ **Expected:** HTTP `200 OK` (or a redirect), which means Ghost is serving.

**Clean up:**
```bash
kubectl delete namespace ghost-plain
cd ~
```

### 4.4 The problem

Now imagine the company wants **non-prod** (1 replica, test URL) and **prod** (3 replicas, real URL), in **us-east** and **us-west**. With plain YAML you would copy these files again and again and change a few lines in each. That is hard to maintain, and mistakes creep in.

**With Helm:** one chart + a few small *values files*.

### 4.5 Create the chart

⌨️ **Run**
```bash
mkdir -p ~/helm-lab && cd ~/helm-lab
helm create my-ghost-app
ls -R my-ghost-app
```

✅ **Expected:** Helm created many files (`Chart.yaml`, `values.yaml`, and under `templates/` things like `deployment.yaml`, `hpa.yaml`, `ingress.yaml`, `httproute.yaml`, `_helpers.tpl`…).

💡 Those generated templates are for a big production chart. To **learn**, we keep only what we need. We delete **everything inside `templates/`** and write 3 small files ourselves.

> ⚠️ **Why not delete file by file (as in the old slide)?** Newer Helm versions generate extra files (`httproute.yaml`, `_helpers.tpl`). If you forget one, `helm lint` fails. Removing all of `templates/` is safer.

⌨️ **Run**
```bash
rm -rf my-ghost-app/templates/*
ls my-ghost-app/templates      # should be empty
```

### 4.6 File 1: `Chart.yaml` (the chart's ID card)

⌨️ **Run** (this replaces the generated file)
```bash
cat > my-ghost-app/Chart.yaml <<'EOF'
apiVersion: v2
name: my-ghost-app
description: A simple Helm chart to run the Ghost blog on Kubernetes (training lab)
type: application
version: 0.1.0        # version of the CHART (bump when you change the chart)
appVersion: "6.72.0"  # version of the APP (Ghost) this chart deploys
EOF
```

💡 **Two different versions, do not mix them up**

| Field | Meaning | When you change it |
|---|---|---|
| `version` | version of the **chart** (our packaging) | whenever you change the chart |
| `appVersion` | version of the **application** (Ghost) | when you move to a new Ghost version |

### 4.7 File 2: `values.yaml` (the default settings)

💡 Every setting a user may want to change goes here. The templates will read these values.

⌨️ **Run** (replaces the generated file)
```bash
cat > my-ghost-app/values.yaml <<'EOF'
# ---------- How many copies of Ghost ----------
replicaCount: 1

# ---------- Container image ----------
image:
  repository: ghost
  tag: "6-alpine"          # pinned major version, never use "latest" in teaching/production
  pullPolicy: IfNotPresent

# ---------- Ghost mode ----------
# "development" = built-in SQLite database (perfect for learning, no MySQL needed)
# "production"  = REQUIRES an external MySQL 8 database
nodeEnv: development

# ---------- Ghost URL (explained in the guide) ----------
prodUrlSchema: false       # false = non-prod URL style, true = prod URL style
datacenter: us-east
baseUrl: myapp.org
urlOverride: ""            # if set, this exact URL is used (we will set it to the LoadBalancer IP)

# ---------- Kubernetes Service ----------
service:
  type: LoadBalancer
  port: 80
  targetPort: 2368

# ---------- CPU / memory ----------
resources:
  requests:
    cpu: 100m
    memory: 512Mi
  limits:
    memory: 1Gi
EOF
```

💡 **How the `url` is decided (3 levels)**

1. If `urlOverride` is set → use exactly that.
2. Else if `prodUrlSchema: true` → `http://<baseUrl>` (for example `http://myapp.org`).
3. Else → `http://<datacenter>.non-prod.<baseUrl>` (for example `http://us-east.non-prod.myapp.org`).

### 4.8 File 3: `templates/deployment.yaml`

⌨️ **Run**
```bash
cat > my-ghost-app/templates/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  labels:
    app.kubernetes.io/name: ghost
    app.kubernetes.io/instance: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app.kubernetes.io/name: ghost
      app.kubernetes.io/instance: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ghost
        app.kubernetes.io/instance: {{ .Release.Name }}
    spec:
      containers:
        - name: ghost
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: 2368
          env:
            - name: NODE_ENV
              value: {{ .Values.nodeEnv | quote }}
            - name: url
              {{- if .Values.urlOverride }}
              value: {{ .Values.urlOverride | quote }}
              {{- else if .Values.prodUrlSchema }}
              value: {{ printf "http://%s" .Values.baseUrl | quote }}
              {{- else }}
              value: {{ printf "http://%s.non-prod.%s" .Values.datacenter .Values.baseUrl | quote }}
              {{- end }}
          readinessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 20
            periodSeconds: 10
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
EOF
```

💡 **Read the template like a story**

| You see | Meaning |
|---|---|
| `{{ .Release.Name }}` | the name you give at install time (`helm install THIS-NAME …`) |
| `{{ .Values.replicaCount }}` | takes `replicaCount` from `values.yaml` |
| `"{{ .Values.image.repository }}:{{ .Values.image.tag }}"` | builds `ghost:6-alpine` |
| `{{ .Values.nodeEnv \| quote }}` | `quote` adds quotation marks so YAML stays valid |
| `{{- if … }} … {{- else if … }} … {{- else }} … {{- end }}` | an **if / else if / else** decision (this builds the `url`) |
| `printf "http://%s.non-prod.%s" …` | joins text pieces together |
| `{{- toYaml .Values.resources \| nindent 12 }}` | copies a whole block from values and indents it by 12 spaces |
| the `-` in `{{-` | removes the blank line left behind, so the YAML stays clean |

💡 **Why `.Release.Name` instead of a fixed name?** It lets you install the **same chart twice** (for example `my-ghost-nonprod` and `my-ghost-prod`) in one namespace without name clashes.

### 4.9 File 4: `templates/service.yaml`

💡 The Service gives the pods one stable address. Type `LoadBalancer` asks Google Cloud for a **public IP address**.

⌨️ **Run**
```bash
cat > my-ghost-app/templates/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
  labels:
    app.kubernetes.io/name: ghost
    app.kubernetes.io/instance: {{ .Release.Name }}
spec:
  type: {{ .Values.service.type }}
  selector:
    app.kubernetes.io/name: ghost
    app.kubernetes.io/instance: {{ .Release.Name }}
  ports:
    - name: http
      protocol: TCP
      port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.targetPort }}
EOF
```

💡 Port `80` is what visitors use. `targetPort: 2368` is Ghost's port inside the pod. The `selector` links the Service to the pods with the same labels.

### 4.10 File 5: `templates/NOTES.txt` (the message after install)

⌨️ **Run**
```bash
cat > my-ghost-app/templates/NOTES.txt <<'EOF'
Ghost release "{{ .Release.Name }}" is installed in namespace "{{ .Release.Namespace }}".

1. Wait until the pod is Running and READY 1/1 (about 1-2 minutes):
     kubectl get pods -n {{ .Release.Namespace }} -l app.kubernetes.io/instance={{ .Release.Name }} -w

{{- if eq .Values.service.type "LoadBalancer" }}

2. Get the public IP (EXTERNAL-IP may show <pending> for ~1 minute):
     kubectl get svc {{ .Release.Name }} -n {{ .Release.Namespace }} -w

3. Tell Ghost its real address, then open the blog:
     helm upgrade {{ .Release.Name }} ./{{ .Chart.Name }} -n {{ .Release.Namespace }} --reuse-values --set urlOverride=http://<EXTERNAL-IP>
{{- else }}

2. Open the blog on your machine:
     kubectl port-forward svc/{{ .Release.Name }} 8080:{{ .Values.service.port }} -n {{ .Release.Namespace }}
{{- end }}

Blog:  <url>/        Admin: <url>/ghost
EOF
```

### 4.11 Four small "override" files (one per environment)

💡 Each file contains **only what differs**. Everything else comes from `values.yaml`.

⌨️ **Run**
```bash
cat > my-ghost-app/values.nonprod.yaml <<'EOF'
replicaCount: 1
prodUrlSchema: false
EOF

cat > my-ghost-app/values.prod.yaml <<'EOF'
replicaCount: 3
prodUrlSchema: true
EOF

cat > my-ghost-app/values.us-east.yaml <<'EOF'
datacenter: us-east
EOF

cat > my-ghost-app/values.us-west.yaml <<'EOF'
datacenter: us-west
EOF
```

✅ **Check your chart folder:**
```bash
find my-ghost-app -type f | sort
```
```
my-ghost-app/.helmignore
my-ghost-app/Chart.yaml
my-ghost-app/templates/NOTES.txt
my-ghost-app/templates/deployment.yaml
my-ghost-app/templates/service.yaml
my-ghost-app/values.nonprod.yaml
my-ghost-app/values.prod.yaml
my-ghost-app/values.us-east.yaml
my-ghost-app/values.us-west.yaml
my-ghost-app/values.yaml
```

### 4.12 Validate **before** deploying (very important habit)

💡 Three safety checks, from fastest to strongest. None of them changes the cluster (except the last, which only *asks* the cluster).

**Check 1: lint** (finds mistakes in the chart)
```bash
helm lint my-ghost-app
```
✅ `1 chart(s) linted, 0 chart(s) failed` (the message "icon is recommended" is only informational).

**Check 2: template** (shows the final YAML that Helm would send)
```bash
helm template my-ghost-nonprod ./my-ghost-app
```
✅ You see a `Service` and a `Deployment`. In the Deployment, find:
- `image: "ghost:6-alpine"`
- `replicas: 1`
- the `url` value `"http://us-east.non-prod.myapp.org"`

**Check 3: combine values files and see the difference**
```bash
# non-prod, us-east
helm template my-ghost-nonprod ./my-ghost-app \
  -f my-ghost-app/values.nonprod.yaml -f my-ghost-app/values.us-east.yaml \
  | grep -E "replicas:|value: \"http"

# non-prod, us-west
helm template my-ghost-nonprod ./my-ghost-app \
  -f my-ghost-app/values.nonprod.yaml -f my-ghost-app/values.us-west.yaml \
  | grep -E "replicas:|value: \"http"

# prod
helm template my-ghost-prod ./my-ghost-app \
  -f my-ghost-app/values.prod.yaml \
  | grep -E "replicas:|value: \"http"
```

✅ **Expected results**

| Command | replicas | url |
|---|---|---|
| nonprod + us-east | 1 | `http://us-east.non-prod.myapp.org` |
| nonprod + us-west | 1 | `http://us-west.non-prod.myapp.org` |
| prod | 3 | `http://myapp.org` |

💡 **Same chart, three different results, only by changing values.** That is the whole idea of Helm.

**Check 4: who wins when two sources disagree?**
```bash
helm template x ./my-ghost-app -f my-ghost-app/values.prod.yaml --set replicaCount=5 | grep replicas:
```
✅ `replicas: 5`. Order of strength: **`--set` > last `-f` file > earlier `-f` file > `values.yaml`.**

**Check 5: ask the real cluster to validate (server-side dry-run)**

The namespace must exist for the cluster to check the objects, so create it first:
```bash
kubectl create namespace ghost-lab

helm install my-ghost-nonprod ./my-ghost-app -n ghost-lab \
  -f my-ghost-app/values.nonprod.yaml -f my-ghost-app/values.us-east.yaml \
  --dry-run=server
```
✅ Prints the rendered manifests and `NOTES`, and **installs nothing** (check with `helm list -n ghost-lab`: empty).

### 4.13 Install Ghost on GKE (non-prod, us-east)

⌨️ **Run**
```bash
helm install my-ghost-nonprod ./my-ghost-app \
  --namespace ghost-lab --create-namespace \
  -f my-ghost-app/values.nonprod.yaml \
  -f my-ghost-app/values.us-east.yaml

# (--create-namespace is harmless here: the namespace already exists from Check 5)
```

✅ **Expected:** `STATUS: deployed`, `REVISION: 1`, and the NOTES text.

⌨️ **Watch it start** (Ghost needs 1 to 2 minutes on the first start)
```bash
kubectl get pods -n ghost-lab -w
```
Press **Ctrl+C** when the pod shows `1/1  Running`. Or wait with:
```bash
kubectl rollout status deploy/my-ghost-nonprod -n ghost-lab --timeout=300s
```

⚠️ **If the pod is not ready after 3 minutes:** run `kubectl logs deploy/my-ghost-nonprod -n ghost-lab` and see Part 5.

### 4.14 Get the public IP address

⌨️ **Run**
```bash
kubectl get svc my-ghost-nonprod -n ghost-lab -w
```
At first `EXTERNAL-IP` shows `<pending>`. After about a minute Google gives a real IP. Press **Ctrl+C**, then save it:

```bash
export EXTERNAL_IP=$(kubectl get svc my-ghost-nonprod -n ghost-lab \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo $EXTERNAL_IP
```

### 4.15 Tell Ghost its real address → your first real `helm upgrade`

💡 Right now Ghost believes its address is `http://us-east.non-prod.myapp.org` (a name that does not exist). Ghost builds page links from that setting, so the pages would look broken in your browser. We fix it with **one upgrade**, by setting `urlOverride`.

⌨️ **Run**
```bash
helm upgrade my-ghost-nonprod ./my-ghost-app \
  --namespace ghost-lab \
  --reuse-values \
  --set urlOverride=http://$EXTERNAL_IP

kubectl rollout status deploy/my-ghost-nonprod -n ghost-lab --timeout=300s
helm list -n ghost-lab
```

✅ **Expected:** `REVISION` is now **2**, and Kubernetes replaced the pod. (You changed an environment variable, so the pod template changed, and Kubernetes does a rolling update.)

💡 `--reuse-values` means "keep everything I set last time, and change only this one value".

### 4.16 Open the blog 🎉

Open in your browser:

- Blog: `http://<EXTERNAL_IP>/`
- Admin setup: `http://<EXTERNAL_IP>/ghost` → create the site owner account → write a test post.

Check also from the terminal:
```bash
curl -sI http://$EXTERNAL_IP | head -3
```

> 💡 Take a screenshot for the class: the first Ghost page deployed by **your own Helm chart**.

### 4.17 Look at what Helm remembers

⌨️ **Run**
```bash
helm get values my-ghost-nonprod -n ghost-lab        # only the values you supplied
helm get values my-ghost-nonprod -n ghost-lab -a     # ALL values (including defaults)
helm get manifest my-ghost-nonprod -n ghost-lab      # the YAML actually applied
helm history my-ghost-nonprod -n ghost-lab
```

### 4.18 Break it on purpose, then rollback 🛟

💡 **Scenario:** a teammate upgrades to an image version that does not exist.

⌨️ **Run: the bad upgrade**
```bash
helm upgrade my-ghost-nonprod ./my-ghost-app \
  --namespace ghost-lab --reuse-values \
  --set image.tag=9.99.99-does-not-exist

kubectl get pods -n ghost-lab
```

✅ **Expected:** you see **two pods**. The new one shows `ErrImagePull` / `ImagePullBackOff`. The **old pod is still `Running 1/1`**, so your blog is still up. (Kubernetes does not kill the old pod until the new one is ready.)

⌨️ **Look at the history, then roll back to the last good revision**
```bash
helm history my-ghost-nonprod -n ghost-lab
helm rollback my-ghost-nonprod 2 -n ghost-lab
helm history my-ghost-nonprod -n ghost-lab
kubectl get pods -n ghost-lab
```

✅ **Expected history**

| REVISION | STATUS | DESCRIPTION |
|---|---|---|
| 1 | superseded | Install complete |
| 2 | superseded | Upgrade complete (url fixed) |
| 3 | superseded | Upgrade (bad image tag) |
| 4 | deployed | Rollback to 2 |

The broken pod disappears and only the healthy pod remains.

> 💡 **Tip for pipelines:** `helm upgrade --rollback-on-failure` does the rollback automatically when an upgrade fails. (In Helm 3 this flag was called `--atomic`.)

### 4.19 (Optional) Why more replicas are not enough with SQLite

⌨️ **Run**
```bash
helm upgrade my-ghost-nonprod ./my-ghost-app -n ghost-lab --reuse-values --set replicaCount=2
kubectl get pods -n ghost-lab
```

✅ You get 2 pods, and the Service shares traffic between them.

💡 **Discuss:** each pod has its **own** SQLite file. Refresh the site many times: one pod may show your post and the other may not. Scaling a *stateful* app needs a shared database (MySQL) and storage. That is the next-level lesson.

Return to one replica:
```bash
helm upgrade my-ghost-nonprod ./my-ghost-app -n ghost-lab --reuse-values --set replicaCount=1
```

### 4.20 Prod settings: render only, do not install

💡 For `prod` the chart sets 3 replicas. With SQLite that would be 3 separate blogs, so in this lab we **look** at prod, we do not install it.

⌨️ **Run**
```bash
helm template my-ghost-prod ./my-ghost-app -f my-ghost-app/values.prod.yaml \
  | grep -E "name: my-ghost|replicas:|value: \"http"
```

✅ **Expected:** name `my-ghost-prod`, `replicas: 3`, `url` = `http://myapp.org`.

💡 Real production would also use **MySQL**, a **persistent volume**, **HTTPS** (`https://…`) and an **Ingress**.

### 4.21 Package the chart

💡 `helm package` makes one shareable `.tgz` file, which can be stored in a chart repository or an OCI registry.

⌨️ **Run**
```bash
helm package my-ghost-app
ls -lh my-ghost-app-0.1.0.tgz
tar tzf my-ghost-app-0.1.0.tgz
```

✅ **Expected:** the file `my-ghost-app-0.1.0.tgz` (name = chart name + chart `version`).

**Install from the package** to prove it works (this is how another team would use your chart):
```bash
helm install ghost-from-package ./my-ghost-app-0.1.0.tgz -n ghost-lab \
  --set service.type=ClusterIP
helm list -n ghost-lab
helm uninstall ghost-from-package -n ghost-lab
```

*(To publish to an OCI registry: `helm registry login <registry-domain>` then `helm push my-ghost-app-0.1.0.tgz oci://<registry>/<path>`. In Helm 4, `helm registry login` takes the domain only, not a full URL.)*

### 4.22 Uninstall Ghost

⌨️ **Run**
```bash
helm uninstall my-ghost-nonprod -n ghost-lab
kubectl get all -n ghost-lab
kubectl delete namespace ghost-lab
```

✅ Everything is gone, and the Google load balancer is released.

💡 Try the second environment quickly for practice: install `my-ghost-west` with `values.nonprod.yaml` + `values.us-west.yaml`, then uninstall it.

---

## Part 5 — Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `Error: unknown flag: --name` | Old Helm 2 syntax | Release name is the first argument: `helm install NAME CHART` |
| `Error: INSTALLATION FAILED: cannot re-use a name that is still in use` | A release with that name already exists | `helm list -A`, then `helm uninstall NAME -n NS` or use another name |
| `helm lint` → `nil pointer evaluating interface {}` | A template uses a value missing from `values.yaml` (typical when leftover `helm create` files stay in `templates/`) | `rm -rf my-ghost-app/templates/*` and recreate the 3 files |
| Pod `CrashLoopBackOff` | Ghost cannot start | `kubectl logs deploy/NAME -n NS`. If it mentions a database or MySQL, check `nodeEnv: development` |
| Pod `ImagePullBackOff` / `ErrImagePull` | Wrong image name or tag | `kubectl describe pod POD -n NS`; check `image.repository` and `image.tag` |
| Pod `Pending` | Not enough CPU or memory on nodes | `kubectl describe pod POD -n NS` (look at Events); use bigger nodes |
| Pod `Running` but `0/1` for a long time | Ghost is still starting (first start is slow) | Wait 2 minutes; `kubectl logs -f deploy/NAME -n NS` |
| `EXTERNAL-IP` stays `<pending>` | The cloud is creating the load balancer | Wait 1 to 3 minutes. If it persists: `kubectl describe svc NAME -n NS` |
| Page opens but is unstyled or links go to a wrong address | Ghost `url` setting does not match the address you use | Run the `--set urlOverride=http://<EXTERNAL_IP>` upgrade (4.15) |
| `no repo named "podinfo" found` | Repo not added | `helm repo add …` then `helm repo update` |
| Bitnami chart → `ImagePullBackOff` | Bitnami free images moved to the legacy repository | Use another chart (like podinfo), or mirror images yourself |
| `YAML parse error` after editing a template | Wrong indentation or a missing `end` | `helm template` shows the exact line; every `if` needs an `{{- end }}` |
| `kubectl` says "connection refused" or asks for a plugin | Cloud Shell lost the cluster credentials | Run `gcloud container clusters get-credentials $CLUSTER --zone $ZONE` again |
| Variables like `$CLUSTER` are empty | New Cloud Shell session | Re-run the `export` lines from 2.2 |

**Three commands that solve 80% of problems**
```bash
kubectl get pods -n NS
kubectl describe pod POD -n NS      # read the "Events" at the bottom
kubectl logs POD -n NS
```

---

## Part 6 — Clean up (do not skip: avoids charges)

⌨️ **Run**
```bash
# 1. make sure no releases are left
helm list -A

# 2. delete the lab namespaces if they still exist
kubectl delete namespace helm-basics --ignore-not-found
kubectl delete namespace ghost-lab --ignore-not-found

# 3. delete the cluster (about 3 to 5 minutes)
gcloud container clusters delete $CLUSTER --zone $ZONE
```

✅ Confirm in the Cloud Console: **Kubernetes Engine → Clusters** shows no cluster, and **VPC network → Forwarding rules** has no leftover rules.

---

## Part 7 — Cheat sheet and Helm 3 → Helm 4 changes

### Everyday commands

```bash
# Repos
helm repo add NAME URL        helm repo update        helm repo list
helm search repo WORD         helm search hub WORD

# Inspect before installing
helm show chart CHART         helm show values CHART

# Build and check a chart
helm create NAME              helm lint ./NAME
helm template REL ./NAME -f values.x.yaml
helm package ./NAME

# Install / upgrade / rollback / remove
helm install REL CHART -n NS --create-namespace -f a.yaml -f b.yaml --set k=v
helm install REL CHART -n NS --dry-run=client      # or =server
helm upgrade REL CHART -n NS --reuse-values --set k=v
helm upgrade --install REL CHART -n NS             # install if missing, else upgrade
helm rollback REL REVISION -n NS
helm uninstall REL -n NS

# Inspect releases
helm list -A        helm status REL -n NS        helm history REL -n NS
helm get values REL -n NS      helm get manifest REL -n NS
```

### What changed in Helm 4 (important for scripts)

| Helm 3 | Helm 4 |
|---|---|
| `--atomic` | `--rollback-on-failure` (old flag still works but shows a deprecation warning) |
| `--force` | `--force-replace` |
| `--wait` (on or off) | `--wait` is a *strategy*: `watcher` (default when you write `--wait`), `hookOnly`, `legacy` |
| `helm registry login https://host/path` | domain only: `helm registry login host` |
| `HELM_EXPERIMENTAL_OCI=1` | removed; OCI is stable and always on |
| Client-side apply only | New installs use **server-side apply** |
| Charts with `apiVersion: v2` | Still fully supported, so **our chart needs no change** |

Support dates: Helm 3 received bug fixes until 8 July 2026 and security fixes until **11 November 2026**, so new training should use Helm 4.

---

## Part 8 — Instructor corner

### Suggested agenda (about 4 hours)

| Time | Part | Activity |
|---|---|---|
| 0:00 | 1 | Concepts and quick check |
| 0:15 | 2 | Create GKE 1.36 cluster. **While it creates (5 to 8 min), teach Part 1.3 and 4.1** |
| 0:40 | 3 | Helm basics with podinfo |
| 1:45 | break | 10 minutes |
| 1:55 | 4.1–4.4 | Ghost facts, Docker demo, plain Kubernetes |
| 2:25 | 4.5–4.12 | Build the chart, validate (lint, template, values files) |
| 3:10 | 4.13–4.18 | Install, upgrade, break and rollback |
| 3:45 | 4.20–4.22, 6 | Package, uninstall, cleanup, review |

### Review questions for students

1. Why does the release name come first in `helm install`?
2. What is the difference between `version` and `appVersion` in `Chart.yaml`?
3. You run `helm template … -f values.prod.yaml --set replicaCount=5`. How many replicas, and why?
4. After a bad upgrade, the old pod kept serving traffic. Why?
5. What does `helm rollback RELEASE 2` do to the revision numbers?
6. Why can't we run 3 Ghost replicas safely with SQLite?
7. Why is `--dry-run=server` stronger than `helm template`?

### Next steps (follow-up sessions)

1. **Ghost with MySQL:** add a MySQL database and set `nodeEnv: production`.
2. **Persistent storage:** add a `PersistentVolumeClaim` so data survives pod restarts.
3. **Ingress + HTTPS** (Google-managed certificate) instead of a raw LoadBalancer IP.
4. **Secrets:** never put passwords in values files in Git (use Kubernetes Secrets, Secret Manager, or sealed secrets).
5. **Chart dependencies** (`Chart.yaml` → `dependencies:`) and **hooks / `helm test`**.
6. **CI/CD:** `helm upgrade --install --rollback-on-failure` in a pipeline.

---

*Sources checked for this revision: Helm project blog and docs (Helm 4 release, Helm 3 support dates, flag changes), Docker Official Image page for `ghost` (production mode needs MySQL, `NODE_ENV` default), Bitnami catalog change notices (images moved to legacy repository), GKE release notes (1.36 in Regular channel), podinfo project README (Helm repo and OCI locations).*
