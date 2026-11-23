#!/usr/bin/env bash
# Seed observability/instana-otlp-credentials rồi sync Argo otel-collector
# (dual ELK APM + Instana cho banking / shop / movie).
#
# Usage:
#   INSTANA_KEY='...' bash .../instana-seed-otlp-and-sync.sh
#   # hoặc lấy key từ Vault:
#   VAULT_TOKEN=hvs.... bash .../instana-seed-otlp-and-sync.sh
set -euo pipefail

VAULT_NS="${VAULT_NS:-vault}"
OBS_NS="${OBS_NS:-observability}"

if [[ -z "${INSTANA_KEY:-}" && -n "${VAULT_TOKEN:-}" ]]; then
  INSTANA_KEY="$(kubectl exec -i -n "${VAULT_NS}" vault-0 -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_TOKEN}" \
    vault kv get -field=key secret/platform/instana 2>/dev/null | tr -d '\r' || true)"
fi

if [[ -z "${INSTANA_KEY:-}" ]]; then
  echo "Set INSTANA_KEY hoặc VAULT_TOKEN (Vault path secret/platform/instana field key)" >&2
  exit 1
fi

kubectl create namespace "$OBS_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$OBS_NS" create secret generic instana-otlp-credentials \
  --from-literal=key="$INSTANA_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "OK secret ${OBS_NS}/instana-otlp-credentials"

if kubectl -n argocd get application observability-otel-collector >/dev/null 2>&1; then
  kubectl -n argocd patch application observability-otel-collector --type merge \
    -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}' \
    2>/dev/null || argocd app sync observability-otel-collector --prune=false 2>/dev/null || true
  echo "Triggered Argo sync observability-otel-collector (push git values trước nếu chưa)"
fi

if kubectl -n "$OBS_NS" get deploy opentelemetry-collector >/dev/null 2>&1; then
  kubectl -n "$OBS_NS" rollout restart deploy/opentelemetry-collector
  kubectl -n "$OBS_NS" rollout status deploy/opentelemetry-collector --timeout=180s
  kubectl -n "$OBS_NS" set env deploy/opentelemetry-collector --list | grep -E 'INSTANA|APM' || true
fi

echo "Done. UI: Applications → filter Call technology=OpenTelemetry hoặc Dest Kubernetes Namespace=npd-banking|npd-shop|npd-movie"
echo "  (bỏ Dest Agent zone trên Application Perspective nếu vẫn trống)"
