-----

# 🛡️ Lab: The 3 Layers of Kubernetes Security

**Objective:** In this lab, you will configure the three critical walls of Kubernetes security:

1.  **RBAC:** Restrict user permissions.
2.  **Network Policies:** Restrict pod-to-pod traffic.
3.  **Pod Security Standards:** Restrict what pods can do on the host.

**Prerequisites:**

  * A Kubernetes cluster (Minikube, Kind, or Cloud).
  * `kubectl` installed.
  * *Note for Minikube users:* You must start minikube with a CNI plugin for Network Policies to work (e.g., `minikube start --cni=calico`).

-----

## 🏗️ Setup: Create the Workspace

First, let's create a namespace to keep our work isolated.

```bash
kubectl create namespace sec-lab
```

-----

## Part 1: RBAC (The ID Card)

**Scenario:** You have a "Junior Developer" named `alice-sa` (ServiceAccount). She should be able to **list pods**, but she strictly **cannot read Secrets**.

### Step 1: Create the Service Account

```bash
kubectl create serviceaccount alice-sa -n sec-lab
```

### Step 2: Create the Role (The Permissions)

Create a file named `role.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: sec-lab
  name: pod-viewer
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
```

Apply it:

```bash
kubectl apply -f role.yaml
```

### Step 3: Bind the Role (Give Alice the permissions)

Create `rolebinding.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: alice-view-binding
  namespace: sec-lab
subjects:
- kind: ServiceAccount
  name: alice-sa
  namespace: sec-lab
roleRef:
  kind: Role
  name: pod-viewer
  apiGroup: rbac.authorization.k8s.io
```

Apply it:

```bash
kubectl apply -f rolebinding.yaml
```

### ✅ Verification (The "Can I?" Check)

We will impersonate Alice to test her permissions.

**1. Test: Can Alice list pods? (Should be YES)**

```bash
kubectl auth can-i list pods --as=system:serviceaccount:sec-lab:alice-sa -n sec-lab
# Expected Output: yes
```

**2. Test: Can Alice read secrets? (Should be NO)**

```bash
kubectl auth can-i get secrets --as=system:serviceaccount:sec-lab:alice-sa -n sec-lab
# Expected Output: no
```

-----

## Part 2: Network Policies (The Traffic Cop)

**Scenario:** You have a `backend` service. You want to ensure **only** the `frontend` pod can talk to it.

### Step 1: Deploy the Apps

Let's create a simple backend (nginx) and a frontend (a temporary curl pod).

```bash
# 1. Create the Backend
kubectl run backend --image=nginx --labels=app=backend --port=80 -n sec-lab

# 2. Expose it locally
kubectl expose pod backend --port=80 --target-port=80 -n sec-lab
```

### Step 2: Test Default Connectivity (The "Open Office")

By default, anyone can talk to the backend. Run a temporary pod to test it:

```bash
kubectl run test-connection --rm -it --image=curlimages/curl -n sec-lab -- curl -m 2 backend
# Expected Output: HTML code from Nginx (Welcome to nginx!)
```

*Note: Delete the test pod if it doesn't auto-delete.*

### Step 3: The "Lockdown" (Default Deny)

Create `deny-all.yaml`. This isolates the backend.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-backend-ingress
  namespace: sec-lab
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  # No ingress rules listed means "Deny All"
```

Apply it:

```bash
kubectl apply -f deny-all.yaml
```

### Step 4: Verify Isolation

Try the connection again. It should **fail** (timeout).

```bash
kubectl run test-connection --rm -it --image=curlimages/curl -n sec-lab -- curl -m 2 backend
# Expected Output: curl: (28) Connection timed out
```

### Step 5: Open the specific Door

Create `allow-frontend.yaml`.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-only
  namespace: sec-lab
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
```

Apply it:

```bash
kubectl apply -f allow-frontend.yaml
```

### ✅ Verification

Now, let's simulate the `frontend` pod. It must have the label `app=frontend`.

```bash
kubectl run frontend --rm -it --image=curlimages/curl --labels=app=frontend -n sec-lab -- curl -m 2 backend
# Expected Output: HTML code (Welcome to nginx!) - SUCCESS
```

-----

## Part 3: Pod Security Standards (The Safety Gear)

**Scenario:** We want to force the `sec-lab` namespace to follow **Restricted** standards (Best Practices). This means no running as Root\!

### Step 1: Enforce the Standard

We do this by labeling the Namespace.

```bash
kubectl label namespace sec-lab pod-security.kubernetes.io/enforce=restricted
```

### Step 2: Try to be "Lazy" (The Violation)

Try to deploy a standard Nginx pod. Nginx tries to bind to port 80 and run as Root by default.

```bash
kubectl run risky-pod --image=nginx -n sec-lab
```

**Expected Result:**

> **Error:** `Error from server (Forbidden): pods "risky-pod" is forbidden: violates PodSecurity "restricted": (container "risky-pod" must set securityContext.runAsNonRoot=true...)`

### Step 3: Deploy the "Secure" Pod (The Fix)

Create `secure-pod.yaml`. We explicitly tell it to use a non-root user and drop dangerous permissions.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-pod
  namespace: sec-lab
spec:
  securityContext:
    runAsUser: 1000
    runAsGroup: 3000
    fsGroup: 2000
  containers:
  - name: nginx
    image: nginxinc/nginx-unprivileged # Uses port 8080 by default, compatible with non-root
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      runAsNonRoot: true
      seccompProfile:
        type: RuntimeDefault
```

Apply it:

```bash
kubectl apply -f secure-pod.yaml
```

### ✅ Verification

Check if the pod is running:

```bash
kubectl get pods -n sec-lab
# Expected Output: secure-pod   1/1     Running
```

-----

## 🧹 Lab Cleanup

When you are finished, remove the lab environment:

```bash
kubectl delete namespace sec-lab
```

-----

### 👨‍🏫  Recap for the Class

1.  **RBAC** stopped `alice-sa` from seeing Secrets.
2.  **Network Policies** stopped random pods from talking to the Backend.
3.  **PSS** stopped us from running a Root container, forcing us to use a secure configuration.

Would you like me to create a short **"Quiz"** (Multiple choice) based on this lab to check their understanding?

## 🧑‍💻 Summary Lab Workflow for Students

This scenario connects all three walls in a single lab:

1.  **Setup:** Create a namespace `student-lab`.
2.  **RBAC:** Create a `Role` `pod-manager` that can **create and delete pods**. Bind it to a `ServiceAccount` `student-sa`. **Verify** they cannot read Secrets.
3.  **Network Policy:** Deploy an `nginx` pod and a `curl` pod. Apply a policy that **denies all Ingress** to `nginx`. Try to curl the `nginx` pod—it should hang/fail. Update the policy to explicitly allow the `curl` pod's traffic.
4.  **PSS:** Label the `student-lab` namespace with `enforce=restricted`. Try to deploy a basic Nginx pod. **Watch it fail.** Fix the security context (add `runAsUser`) to make it pass.
