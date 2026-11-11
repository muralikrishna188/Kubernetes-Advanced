#!/usr/bin/env bash
# Step 0: preflight checks + namespaces + PSS label + ServiceAccount.
# Safe to re-run (idempotent).
set -euo pipefail

echo "==> Preflight checks"
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: kubectl cannot reach a cluster."
  echo "Run: gcloud container clusters get-credentials <NAME> --location <LOCATION>"
  exit 1
fi
echo "Context : $(kubectl config current-context)"
kubectl version 2>/dev/null | grep -i "server version" || true

# NetworkPolicy is only enforced with Dataplane V2 (anetd/cilium) or Calico.
if kubectl get pods -n kube-system -o name 2>/dev/null | grep -Eq 'anetd|cilium|calico-node'; then
  echo "NetworkPolicy enforcement: DETECTED (OK)"
else
  echo "WARNING: no anetd/cilium/calico pods found in kube-system."
  echo "         NetworkPolicy may NOT be enforced on this cluster. See Instructions.md (Troubleshooting)."
fi

echo
echo "==> Creating namespaces"
for ns in ecom-app billing payment-ns; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

echo
echo "==> Enforcing Restricted Pod Security Standard on payment-ns"
kubectl label namespace payment-ns \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted \
  --overwrite

echo
echo "==> Creating Finance Auditor ServiceAccount"
kubectl create serviceaccount finance-auditor-sa -n billing \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Setup complete. Next: apply the YAML manifests (see Instructions.md, Step 2)."
