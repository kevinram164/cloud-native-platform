#!/usr/bin/env bash
# Bật Argo CD Notifications → Telegram (cùng Vault bot Alertmanager).
#
# Lab ArgoCD thường cài bằng manifest (không còn Helm release) — script chỉ:
#   1) seed Secret argocd-notifications-secret từ Vault
#   2) apply ConfigMap argocd-notifications-cm
#   3) restart notifications-controller (pod đã có sẵn trên cluster)
#
# Usage:
#   VAULT_TOKEN=hvs.... bash phase9-gitops-platform/environments/dev-k8s/scripts/argocd-enable-notifications.sh
set -euo pipefail

PHASE9="$(cd "$(dirname "$0")/../../.." && pwd)"
CM_FILE="${PHASE9}/environments/dev-k8s/argocd-install/argocd-notifications-cm.yaml"
NS="${ARGOCD_NS:-argocd}"
VAULT_NS="${VAULT_NS:-vault}"

if [[ ! -f "$CM_FILE" ]]; then
  echo "Missing ConfigMap file: $CM_FILE" >&2
  exit 1
fi

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  echo "Set VAULT_TOKEN (read secret/platform/alertmanager-telegram via vault-0)" >&2
  exit 1
fi

echo "==> Read Telegram bot_token from Vault (kubectl exec ${VAULT_NS}/vault-0)"
RAW="$(kubectl exec -i -n "${VAULT_NS}" vault-0 -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_TOKEN}" \
  vault kv get -format=json secret/platform/alertmanager-telegram)"

TOKEN="$(echo "$RAW" | python3 -c '
import json,sys
d=json.load(sys.stdin)
data=(d.get("data") or {})
inner=data.get("data") if isinstance(data.get("data"), dict) else data
print((inner or {}).get("bot_token") or (inner or {}).get("token") or "")
')"

if [[ -z "$TOKEN" ]]; then
  echo "Vault secret missing bot_token. Raw:" >&2
  echo "$RAW" >&2
  exit 1
fi

echo "==> Upsert Secret ${NS}/argocd-notifications-secret"
kubectl -n "$NS" create secret generic argocd-notifications-secret \
  --from-literal=telegram-token="$TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Apply ConfigMap argocd-notifications-cm"
kubectl apply -f "$CM_FILE"

echo "==> Restart notifications controller (nếu có)"
if kubectl -n "$NS" get deploy argocd-notifications-controller >/dev/null 2>&1; then
  kubectl -n "$NS" rollout restart deploy/argocd-notifications-controller
  kubectl -n "$NS" rollout status deploy/argocd-notifications-controller --timeout=120s
elif kubectl -n "$NS" get sts argocd-notifications-controller >/dev/null 2>&1; then
  kubectl -n "$NS" rollout restart sts/argocd-notifications-controller
else
  echo "WARN: không thấy deploy/sts argocd-notifications-controller — kiểm tra ArgoCD đã bật notifications chưa." >&2
  kubectl -n "$NS" get pods -l app.kubernetes.io/name=argocd-notifications-controller || true
fi

echo "OK — Telegram nhận sync succeeded/failed."
echo "Test: argocd app sync <app> hoặc Sync trên https://npd-argocd.co"
