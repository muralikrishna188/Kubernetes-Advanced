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