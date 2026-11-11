#!/usr/bin/env bash
# Removes everything created by the lab (also releases the GCP load balancer / external IP).
set -uo pipefail
echo "==> Deleting namespaces (this also deletes the LoadBalancer)"
kubectl delete namespace ecom-app billing payment-ns --ignore-not-found
echo "Done. Verify with: kubectl get ns"
