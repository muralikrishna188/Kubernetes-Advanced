# AKS Pod Security Standards (PSS) -- Simple Hands-on Lab

## 1. Objective

In this lab, you will implement **Pod Security Standards (PSS)** on
**Azure Kubernetes Service (AKS)**.

You will learn how to:

-   Apply `Baseline` and `Restricted` security policies.
-   Use `warn`, `audit`, and `enforce`.
-   Deploy an insecure Pod and see why it is rejected.
-   Fix the Pod security settings and deploy it successfully.

------------------------------------------------------------------------

## 2. PSS Profiles

  Profile      Security Level   Purpose
  ------------ ---------------- -------------------------------
  Privileged   Low              Trusted/system workloads
  Baseline     Medium           Prevent common security risks
  Restricted   High             Strongly secured workloads

For this lab, we mainly use **Baseline** and **Restricted**.

------------------------------------------------------------------------

## 3. PSA Modes

Pod Security Admission (PSA) provides three modes:

  Mode        What happens?
  ----------- ----------------------------------------------
  `warn`      Pod is allowed, but a warning is shown
  `audit`     Pod is allowed and the violation is recorded
  `enforce`   Pod is rejected if it violates the policy

Recommended learning flow:

``` text
WARN → AUDIT → ENFORCE
```

------------------------------------------------------------------------

# 4. Prerequisites

You need:

-   Azure subscription
-   Azure CLI
-   kubectl

Login:

``` bash
az login
```

Verify:

``` bash
az account show
kubectl version --client
```

------------------------------------------------------------------------

# 5. Create an AKS Cluster

Set variables:

``` bash
RESOURCE_GROUP="rg-aks-pss-lab"
CLUSTER_NAME="aks-pss-lab"
LOCATION="centralindia"
```

Create resource group:

``` bash
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION
```

Create AKS:

``` bash
az aks create \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --location $LOCATION \
  --node-count 2 \
  --generate-ssh-keys
```

Connect to AKS:

``` bash
az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME
```

Verify:

``` bash
kubectl get nodes
```

Expected:

``` text
STATUS
Ready
```

------------------------------------------------------------------------

# 6. Create a Namespace

Create the namespace:

``` bash
kubectl create namespace pss-demo
```

Verify:

``` bash
kubectl get namespace pss-demo
```

------------------------------------------------------------------------

# 7. Enable WARN Mode

Apply Restricted in `warn` mode:

``` bash
kubectl label --overwrite namespace pss-demo \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest
```

Check:

``` bash
kubectl get namespace pss-demo --show-labels
```

------------------------------------------------------------------------

# 8. Deploy an Insecure Pod

Create a file called `bad-pod.yaml`:

``` yaml
apiVersion: v1
kind: Pod
metadata:
  name: bad-pod
  namespace: pss-demo
spec:
  containers:
  - name: nginx
    image: nginx:1.27
    securityContext:
      privileged: true
```

Deploy:

``` bash
kubectl apply -f bad-pod.yaml
```

Because we are using `warn`, Kubernetes should allow the Pod but display
a **Pod Security warning**.

Check:

``` bash
kubectl get pods -n pss-demo
```

### Question for Students

**Why was the Pod allowed even though it violates Restricted PSS?**

**Answer:** Because `warn` reports the violation but does not block the
Pod.

------------------------------------------------------------------------

# 9. Enable ENFORCE Mode

Delete the Pod:

``` bash
kubectl delete pod bad-pod -n pss-demo
```

Now enable enforcement:

``` bash
kubectl label --overwrite namespace pss-demo \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest
```

Try the same Pod again:

``` bash
kubectl apply -f bad-pod.yaml
```

Expected result:

``` text
Error from server (Forbidden)
```

The Pod is rejected because:

``` yaml
privileged: true
```

violates the Restricted policy.

------------------------------------------------------------------------

# 10. Fix the Pod

Create `good-pod.yaml`:

``` yaml
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
    image: nginxinc/nginx-unprivileged:1.27-alpine

    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL

    ports:
    - containerPort: 8080
```

Deploy:

``` bash
kubectl apply -f good-pod.yaml
```

Check:

``` bash
kubectl get pods -n pss-demo
```

Expected:

``` text
NAME        READY   STATUS
good-pod    1/1     Running
```

------------------------------------------------------------------------

# 11. What Did We Change?

  Security Setting       Bad Pod         Good Pod
  ---------------------- --------------- ------------------
  Privileged             `true`          Not used
  Run as non-root        No              Yes
  Privilege escalation   Default         `false`
  Linux capabilities     Default         Drop `ALL`
  Seccomp                Not specified   `RuntimeDefault`

These settings help the Pod satisfy the **Restricted** security
requirements.

------------------------------------------------------------------------

# 12. Baseline vs Restricted

Create another namespace:

``` bash
kubectl create namespace pss-baseline
```

Enable Baseline:

``` bash
kubectl label --overwrite namespace pss-baseline \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/enforce-version=latest
```

  -----------------------------------------------------------------------
  Feature                 Baseline                Restricted
  ----------------------- ----------------------- -----------------------
  Blocks privileged       Yes                     Yes
  containers                                      

  Strong security         Medium                  High
  hardening                                       

  Non-root required       Not generally           Yes

  Suitable for            General applications    Security-sensitive
                                                  applications
  -----------------------------------------------------------------------

------------------------------------------------------------------------

# 13. Add Audit Mode

You can use all three modes together:

``` bash
kubectl label --overwrite namespace pss-demo \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest
```

The concept is:

  Mode      Result
  --------- ----------------------
  WARN      Tell the user
  AUDIT     Record the violation
  ENFORCE   Block the Pod

------------------------------------------------------------------------

# 14. Understand the Flow

``` text
kubectl apply
      |
      v
AKS API Server
      |
      v
Pod Security Admission
      |
      v
PSS Policy
      |
      +---- Compliant ----> ALLOW
      |
      +---- Violation ----> WARN / AUDIT / DENY
```

------------------------------------------------------------------------

# 15. Student Challenge

Create a Deployment called:

``` text
secure-nginx
```

Requirements:

  Requirement            Value
  ---------------------- ------------------
  Namespace              `student-pss`
  PSS                    `restricted`
  Replicas               2
  Run as non-root        Yes
  Privilege escalation   Disabled
  Capabilities           Drop ALL
  Seccomp                `RuntimeDefault`

Verify:

``` bash
kubectl get deployment -n student-pss
kubectl get pods -n student-pss
```

------------------------------------------------------------------------

# 16. Break and Fix Exercise

### Step 1 -- Break

Change:

``` yaml
allowPrivilegeEscalation: false
```

to:

``` yaml
allowPrivilegeEscalation: true
```

Apply the Deployment.

### Step 2 -- Observe

Read the PSS admission error.

### Step 3 -- Fix

Change it back:

``` yaml
allowPrivilegeEscalation: false
```

Apply again.

### Step 4 -- Verify

``` bash
kubectl get pods -n student-pss
```

------------------------------------------------------------------------

# 17. Key Takeaways

  Topic              Remember
  ------------------ ----------------------------------------
  PSS                Defines Kubernetes Pod security levels
  PSA                Enforces/warns/audits PSS
  Baseline           Basic workload security
  Restricted         Strong workload security
  WARN               Shows violations
  AUDIT              Records violations
  ENFORCE            Blocks violations
  Namespace labels   Common way to configure PSA

------------------------------------------------------------------------

# 18. Cleanup

Delete the lab namespaces:

``` bash
kubectl delete namespace pss-demo
kubectl delete namespace pss-baseline
```

Delete the AKS resource group:

``` bash
az group delete \
  --name $RESOURCE_GROUP \
  --yes
```

------------------------------------------------------------------------

## Official References

Kubernetes PSS:

https://kubernetes.io/docs/concepts/security/pod-security-standards/

Kubernetes PSS Cluster-Level Tutorial:

https://kubernetes.io/docs/tutorials/security/cluster-level-pss/

Microsoft AKS -- Pod Security Admission:

https://learn.microsoft.com/en-us/azure/aks/use-psa

Microsoft AKS -- Deployment Safeguards:

https://learn.microsoft.com/en-us/azure/aks/deployment-safeguards
