#!/usr/bin/env bash
# Automated verification of RBAC, NetworkPolicy and PSS. Run AFTER applying 05-netpol-db.yaml.
set -uo pipefail

SA="system:serviceaccount:billing:finance-auditor-sa"
PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ✔ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✘ $1"; FAIL=$((FAIL+1)); }
skip() { echo "  - $1 (skipped)"; SKIP=$((SKIP+1)); }

can_i() {  # desc expected <can-i args...>
  local desc="$1" expected="$2"; shift 2
  local got; got=$(kubectl auth can-i "$@" --as="$SA" 2>/dev/null || true)
  if [[ "$got" == "$expected" ]]; then ok "$desc -> $got"; else bad "$desc -> expected '$expected', got '$got'"; fi
}

probe() {  # podname label namespace host
  kubectl run "$1" --rm -i --restart=Never --quiet --image=postgres:14-alpine \
    -n "$3" --labels="app=$2" -- pg_isready -h "$4" -p 5432 -t 3 2>&1
}

echo "==> Waiting for workloads to be ready"
kubectl rollout status deploy/sample-db          -n ecom-app   --timeout=180s
kubectl rollout status deploy/sample-catalog-api -n ecom-app   --timeout=180s
kubectl rollout status deploy/sample-payment-api -n payment-ns --timeout=180s

echo
echo "==> 1. RBAC (finance-auditor-sa)"
can_i "list pods in billing"      yes list pods   -n billing
can_i "get pod logs in billing"   yes get pods/log -n billing
can_i "delete pods in billing"    no  delete pods -n billing
can_i "get secrets in billing"    no  get secrets -n billing
can_i "list pods in ecom-app"     no  list pods   -n ecom-app

echo
echo "==> 2. NetworkPolicy (DB isolation)"
sleep 3   # give the dataplane a moment to program the policy
out=$(probe netpol-ok catalog-api ecom-app sample-db-internal)
if grep -q "accepting connections" <<<"$out"; then ok "catalog-api label -> ALLOWED"; else bad "catalog-api label should be allowed. Output: $out"; fi

out=$(probe netpol-fail hacker ecom-app sample-db-internal)
if grep -q "no response" <<<"$out"; then ok "app=hacker label -> BLOCKED"; else bad "app=hacker should be blocked (is NetworkPolicy enforced?). Output: $out"; fi

out=$(probe netpol-xns probe billing sample-db-internal.ecom-app)
if grep -q "no response" <<<"$out"; then ok "other namespace (billing) -> BLOCKED"; else bad "cross-namespace should be blocked. Output: $out"; fi

echo
echo "==> 3. Pod Security Standards (payment-ns = restricted)"
out=$(kubectl run insecure-test --image=busybox:1.36 -n payment-ns -- sleep 3600 2>&1 || true)
if grep -q "violates PodSecurity" <<<"$out"; then ok "insecure pod REJECTED by PSS"; else bad "insecure pod was not rejected. Output: $out"; kubectl delete pod insecure-test -n payment-ns --ignore-not-found >/dev/null 2>&1; fi

phase=$(kubectl get pods -n payment-ns -l app=payment-api -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
if [[ "$phase" == "Running" ]]; then ok "sample-payment-api is Running (compliant)"; else bad "sample-payment-api phase='$phase'"; fi

echo
echo "==> 4. Catalog API via LoadBalancer"
IP=$(kubectl get svc sample-catalog-svc -n ecom-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
if [[ -z "$IP" ]]; then
  skip "EXTERNAL-IP still pending; re-run later"
else
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$IP" || true)
  if [[ "$code" == "200" ]]; then ok "http://$IP -> HTTP 200"; else bad "http://$IP -> HTTP '$code'"; fi
fi

echo
echo "Result: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
