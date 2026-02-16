# Kubernetes-Advanced

Security:

-----

# 🛡️ Kubernetes Security: The Three Walls of Defense

To secure a **Kubernetes Cluster**, we implement layers of defense. This guide frames these layers as the **"Three Walls of Defense"** to clearly define where each control applies.

-----

## Part 1: Role-Based Access Control (RBAC)

**Analogy:** The **ID Badge system** in a secure office building.
**Focus:** **Who** can get in and touch the API? (The ID Card)

### 1\. The Core Concepts

| Concept | The "Who/What" | Explanation |
| :--- | :--- | :--- |
| **Subject** | The "Who" | User, Group, or **ServiceAccount** (for pods/programs). |
| **Resource** | The "What" | Pods, Secrets, Deployments, Services. |
| **Verb** | The "Action" | `Get`, `List`, `Create`, `Delete`, `Watch`. |
| **Role** | Permissions | A set of permissions (Keys to a specific room). |
| **RoleBinding** | Granting | Giving those keys to a specific person (**Subject**). |

> **Tip:** `Role` + `RoleBinding` = **Namespace specific** (Room keys). `ClusterRole` + `ClusterRoleBinding` = **Cluster-wide** (Master keys).

### 2\. Practical Example: The "Junior Dev"

**Goal:** Allow a developer to **read logs** and **list pods**, but **NOT delete them** or **view secrets**.

#### A. Create the Role (The Permission Slip)

```yaml
# role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: development
  name: log-reader
rules:
- apiGroups: [""] # "" indicates the core API group
  resources: ["pods", "pods/log"]
  verbs: ["get", "list"]
```

#### B. Create the Binding (Granting the Permission)

```yaml
# rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-logs-binding
  namespace: development
subjects:
- kind: User
  name: alice  # The user "Alice"
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: log-reader # Matches the Role created above
  apiGroup: rbac.authorization.k8s.io
```

**How to Apply:** `kubectl apply -f role.yaml -f rolebinding.yaml`

-----

## Part 2: Network Policies

**Analogy:** Internal **Firewalls** or **"Cubicle Walls"**. By default, Kubernetes is an "Open Office"—everyone can talk to everyone. Network Policies put up walls.
**Focus:** **Who** can talk to whom **inside**? (The Traffic Cop)

### 1\. The Core Concepts

| Concept | Definition |
| :--- | :--- |
| **Ingress** | Traffic coming **IN** to a pod. |
| **Egress** | Traffic going **OUT** of a pod. |
| **Selector** | Labels used to identify **which pods** the rules apply to (The **target**). |
| **Default Deny** | If a pod is selected by **any** policy, all traffic **not explicitly allowed** is rejected. |

### 2\. Practical Example: The "Database Fortress"

**Goal:** Only the `backend-app` can talk to the database. No one else.

#### A. The Policy

```yaml
# db-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-access-protection
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: database # This policy protects the DB pods
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: backend-app # Only allows traffic FROM pods labeled 'backend-app'
    ports:
    - protocol: TCP
      port: 5432
```

**How to Apply:** `kubectl apply -f db-policy.yaml`

> **Critical Note for Students:** Network Policies require a **CNI plugin** that supports them (like Calico, Cilium, or Antrea). If you are using standard Flannel or AWS VPC CNI without policy enablement, these YAMLs will be accepted by the API but **ignored** by the network.

-----

## Part 3: Pod Security Standards (PSS)

**Analogy:** **OSHA Safety Regulations**. You can't just walk into a construction site (The Node) without proper gear.
**Focus:** **What** are workloads allowed to do on the host? (The Safety Gear)

### 1\. The Three Profiles

| Profile | Restriction Level | Typical Use Case |
| :--- | :--- | :--- |
| **Privileged** | **Unrestricted**. | System drivers, monitoring agents. **Avoid unless necessary.** |
| **Baseline** | **Minimally restrictive**. | Prevents known privilege escalations. Good for "default" non-production. |
| **Restricted** | **Heavily hardened**. | Follows best practices (Non-root, drop capabilities). **Target for production apps.** |

### 2\. How it works (Namespace Labels)

You label the **namespace** to tell the Admission Controller what to check.

  * `enforce`: **Reject** pods that violate the rule.
  * `warn`: Allow the pod but show a **warning** to the user.
  * `audit`: Allow the pod but **log** the violation.

### 3\. Practical Example: Enforcing Safety

**Goal:** Ensure no pods in the `production` namespace run as **Root**.

#### A. Apply the Control (Command Line)

```bash
# Label the namespace to ENFORCE the 'restricted' standard
kubectl label namespace production pod-security.kubernetes.io/enforce=restricted
```

#### B. Test it (The Failure)

If a student tries to deploy a "bad" pod (one that runs as root by default, like Nginx):

```yaml
# bad-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: root-pod
  namespace: production
spec:
  containers:
  - name: nginx
    image: nginx # Nginx tries to run as root by default
```

**Result:** Error\! The pod is rejected because the restricted profile requires `runAsNonRoot: true`.

#### C. The Fix

By adding a **`securityContext`**, we make the pod safe:

```yaml
# good-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-pod
  namespace: production
spec:
  securityContext:
    runAsUser: 1000 # Run as a specific user ID
    runAsGroup: 3000
    fsGroup: 2000
  containers:
  - name: nginx
    image: nginx
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"] # Drop all Linux capabilities
      runAsNonRoot: true
```

-----

