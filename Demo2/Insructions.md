## E-commerce application scenario. 
`ecom-app` namespace for the services and the `billing` namespace for the RBAC setup.

The manifest files ensure:

1.  The `payment-ns` enforces the **Restricted** Pod Security Standard.
2.  The `finance-auditor-sa` has **read-only** access to the `billing` namespace.
3.  The **Database** is isolated, only allowing traffic from the **Catalog API**.
4.  The **Catalog API** is exposed externally for application access.

-----

## 🛠️ Step 0: Initial Setup and PSS Enforcement

Execute this script first to create the namespaces and set up the necessary ServiceAccounts and security standards.

**File: `00-setup.sh`**
chmod +x 00-setup.sh

```bash
#!/bin/bash

# Create application and security namespaces
echo "Creating application namespaces..."
kubectl create namespace ecom-app
kubectl create namespace billing
kubectl create namespace payment-ns # Dedicated sensitive namespace

# --- PSS ENFORCEMENT ---
echo "Enforcing Restricted PSS on the Payment Namespace..."
# This label ensures only PSS-compliant pods can run here
kubectl label namespace payment-ns pod-security.kubernetes.io/enforce=restricted

# --- RBAC SETUP ---
echo "Creating Finance Auditor ServiceAccount..."
# Create the user identity for the auditing team
kubectl create serviceaccount finance-auditor-sa -n billing

echo "Setup Complete. Apply YAML manifests next."
```

## 🔐 Step 1: RBAC Manifests (Finance Auditor)

These files grant the `finance-auditor-sa` read-only access to the `billing` namespace.

**File: `01-rbac-role.yaml`**

```yaml
# Role: Allows listing, getting, and watching Pods/Logs in the 'billing' namespace
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: billing
  name: auditor-read-only
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log", "services"]
  verbs: ["get", "list", "watch"]
```

**File: `01-rbac-binding.yaml`**

```yaml
# RoleBinding: Connects the Role to the ServiceAccount (the Auditor)
---
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

## 📦 Step 2: E-commerce Core Services

These files deploy the internal database and the main user-facing API.

**File: `02-db-svc.yaml`**

```yaml
# Database Deployment and Internal Service
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-db
  namespace: ecom-app
spec:
  selector:
    matchLabels:
      app: database # Target for Network Policy
  replicas: 1
  template:
    metadata:
      labels:
        app: database
    spec:
      containers:
      - name: db
        image: postgres:14-alpine
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_DB
          value: ecom
        - name: POSTGRES_PASSWORD
          value: secret-password # In a real app, use a K8s Secret!
---
apiVersion: v1
kind: Service
metadata:
  name: sample-db-internal
  namespace: ecom-app
spec:
  selector:
    app: database
  ports:
  - protocol: TCP
    port: 5432
    targetPort: 5432
```

**File: `03-catalog-api.yaml`**

```yaml
# Catalog API Deployment and External Service
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-catalog-api
  namespace: ecom-app
spec:
  selector:
    matchLabels:
      app: catalog-api # Source for Network Policy
  replicas: 2
  template:
    metadata:
      labels:
        app: catalog-api
    spec:
      containers:
      - name: api
        image: nginx:latest # Placeholder for the API container
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: sample-catalog-svc
  namespace: ecom-app
spec:
  selector:
    app: catalog-api
  ports:
  - protocol: TCP
    port: 80
    targetPort: 8080
  type: LoadBalancer # Exposes the application externally
```

## 💳 Step 3: PSS-Compliant Payment API

This pod is deployed in the `payment-ns` (where PSS is enforced) and includes the necessary **seccompProfile** to pass the security check.

**File: `04-payment-api-secure.yaml`**

```yaml
# Highly Secure Payment API Deployment
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-payment-api
  namespace: payment-ns
spec:
  selector:
    matchLabels:
      app: payment-api
  replicas: 1
  template:
    metadata:
      labels:
        app: payment-api
    spec:
      # PSS REQUIRES: Setting a seccompProfile at the Pod level
      securityContext:
        runAsUser: 1000 
        runAsGroup: 1000
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault # Required for PSS Restricted level
      containers:
      - name: payment-processor
        image: busybox:latest # Placeholder image
        command: ["/bin/sh", "-c", "sleep 3600"]
        ports:
        - containerPort: 9090
        # PSS REQUIRES: Dropping privileges at the Container level
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
```

## 🔒 Step 4: Network Policy Manifest

This policy isolates the database, ensuring only the `catalog-api` can reach it.

**File: `05-netpol-db.yaml`**

```yaml
# Network Policy for Database Isolation
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-catalog-to-db
  namespace: ecom-app
spec:
  podSelector:
    matchLabels:
      app: database # 1. PROTECT THE DATABASE
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: catalog-api # 2. ONLY ALLOW TRAFFIC FROM THE CATALOG-API
    ports:
    - protocol: TCP
      port: 5432 # 3. ON THE DATABASE PORT
```

-----

## 🚀 Application Steps Summary

To deploy the entire application and all security features:

1.  **Run Setup Script:**
    ```bash
    ./00-setup.sh
    ```
2.  **Apply Security Manifests (RBAC & Services):**
    ```bash
    kubectl apply -f 01-rbac-role.yaml -f 01-rbac-binding.yaml
    kubectl apply -f 02-db-svc.yaml -f 03-catalog-api.yaml
    kubectl apply -f 04-payment-api-secure.yaml
    ```
3.  **Apply Network Policy:**
    ```bash
    kubectl apply -f 05-netpol-db.yaml
    ```

The application is accessible via the **LoadBalancer IP** assigned to the `sample-catalog-svc` in the `ecom-app` namespace.