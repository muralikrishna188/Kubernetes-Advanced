This guide adapts the "Three Walls of Defense" framework to a microservices-based **e-commerce application**. We will map users, services, and security risks to concrete Kubernetes configurations.

-----

## 📘 Module 1: RBAC (E-commerce Roles & Access)

**Scenario:** A standard e-commerce company requires different levels of access for its teams.

  * **Marketing Team (The Developers):** Needs full control over the `frontend` (Deployments, ConfigMaps) in the `marketing` namespace.
  * **Finance Team (The Auditors):** Only needs to read logs and list pods in the `billing` namespace for auditing purposes. They must **never** access Secrets (like database credentials).

### 1\. The Finance Auditor Role

**Goal:** Allow the `finance-auditor-sa` to `get` and `list` pods and logs in the `billing` namespace, but nothing else.

**Step A: Create the Namespace and Auditor**

```bash
kubectl create namespace billing
kubectl create serviceaccount finance-auditor-sa -n billing
```

**Step B: The Role (Read-Only)**

```yaml
# finance-auditor-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: billing
  name: auditor-read-only
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log", "services"]
  verbs: ["get", "list", "watch"] # No verbs for Secrets or deletion
```

*Apply:* `kubectl apply -f finance-auditor-role.yaml`

**Step C: The Binding**

```yaml
# finance-auditor-binding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bind-auditor
  namespace: billing
subjects:
- kind: ServiceAccount
  name: finance-auditor-sa
  namespace: billing
roleRef:
  kind: Role
  name: auditor-read-only
  apiGroup: rbac.authorization.k8s.io
```

*Apply:* `kubectl apply -f finance-auditor-binding.yaml`

**Step D: Verification (Auditing the Auditing Role)**

```bash
# Verify SUCCESS (Can list pods)
kubectl auth can-i list pods --as=system:serviceaccount:billing:finance-auditor-sa -n billing
# Output: yes

# Verify FAILURE (Cannot view secrets/database credentials)
kubectl auth can-i get secrets --as=system:serviceaccount:billing:finance-auditor-sa -n billing
# Output: no
```

-----

## 🚧 Module 2: Network Policies (Microservices Traffic Control)

**Scenario:** We have four critical services: `frontend`, `catalog-api`, `payment-api`, and `database`. The golden rule is: **Only services that need to talk can talk.**

### 1\. The Security Goal

1.  **Database Lockdown:** The `database` pod must be isolated. Only the `catalog-api` can initiate connections to it.
2.  **Implicit Deny:** Any pod without the `app: catalog-api` label should be blocked from reaching the database.

### 2\. The Lab Steps

**Step A: Setup Services**
Assume all services are deployed in the `ecom-app` namespace with their corresponding labels (`app: catalog-api`, `app: database`, etc.).

**Step B: The Network Policy (The Database Firewall)**
We create a policy that selects the **Database** pod and defines an **Ingress** rule only from the **Catalog API** pod.

```yaml
# db-netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-only-from-catalog
  namespace: ecom-app
spec:
  podSelector:
    matchLabels:
      app: database # This protects the pod with this label
  policyTypes:
  - Ingress # We are controlling traffic coming INTO the database
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: catalog-api # ONLY allow traffic FROM the catalog-api
    ports:
    - protocol: TCP
      port: 5432 # The standard PostgreSQL port
```

*Apply:* `kubectl apply -f db-netpol.yaml`

**Step C: Testing the Isolation**

1.  **Test 1 (Failure):** Run a test pod without the `app: catalog-api` label and try to reach the database. **Connection should timeout/be rejected.**
2.  **Test 2 (Success):** Run a test pod *with* the `app: catalog-api` label and try to reach the database. **Connection should succeed.**

### 🚨 E-commerce Context Note:

If the `frontend` needs to talk to the `catalog-api`, and the `catalog-api` needs to talk to the `database`, you need *two* separate Network Policies:

1.  One policy protecting the **`catalog-api`** (allowing ingress from `frontend`).
2.  One policy protecting the **`database`** (allowing ingress from `catalog-api`).

-----

## 🛡️ Module 3: Pod Security Standards (Protecting Payment Data)

**Scenario:** The `payment-api` service handles sensitive PCI data (credit cards). This service is the highest security priority. We must ensure its pods run under the **most restrictive** security settings possible.

### 1\. The Security Goal

Enforce the **Restricted** PSS profile on the entire `payment` namespace to prevent the deployment of any pod that runs as root or requires high host privileges.

### 2\. The Lab Steps

**Step A: Create and Enforce the Namespace**
We'll create a dedicated namespace and apply the strictest enforcement label.

```bash
kubectl create namespace payment-ns
# Enforce the strictest rule on the namespace
kubectl label namespace payment-ns pod-security.kubernetes.io/enforce=restricted
```

**Step B: Attempt a Violation (A Risky Pod)**
Show that a default, unsecure pod deployment is immediately rejected by the Admission Controller.

```yaml
# risky-payment.yaml
apiVersion: v1
kind: Pod
metadata:
  name: unsecure-payment-service
  namespace: payment-ns
spec:
  containers:
  - name: payment-api
    image: custom-payment-image:latest # Assume this image runs as root
```

*Apply:* `kubectl apply -f risky-payment.yaml`
*Result:* **Forbidden Error\!** The PSS controller rejects the pod because it violates rules like running as non-root.

**Step C: Deploy the Secure Payment Pod**
The secure application image is configured to run as a non-root user and drops all unnecessary Linux capabilities.

```yaml
# secure-payment.yaml (CORRECTED)
apiVersion: v1
kind: Pod
metadata:
  name: secure-payment-service
  namespace: payment-ns
spec:
  # Pod-level security context applies to all containers
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    runAsNonRoot: true
    # 💥 ADD THESE LINES TO SATISFY THE RESTRICTED PSS 💥
    seccompProfile:
      type: RuntimeDefault 
  containers:
  - name: payment-api
    image: custom-payment-image:latest
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      runAsNonRoot: true
```

*Apply:* `kubectl apply -f secure-payment.yaml`
*Result:* **Success.** The pod is created because it adheres to the **Restricted** security context requirements.

### 🚨 E-commerce Context Note:

By enforcing PSS at the namespace level, you guarantee that **all** workloads (even monitoring agents or sidecars) deployed in the sensitive `payment-ns` must meet these minimum security standards. This prevents a misconfigured third-party service from accidentally becoming an attack vector.