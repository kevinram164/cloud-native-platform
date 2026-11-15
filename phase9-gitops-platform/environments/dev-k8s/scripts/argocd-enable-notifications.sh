#!/usr/bin/env bash
# Bật Argo CD Notifications → Telegram (cùng Vault bot Alertmanager).
#
# Prerequisites:
#   - helm release `argocd` ns `argocd`
#   - VAULT_TOKEN (root/admin) — đọc secret qua kubectl exec vault-0 (không cần port-forward)
#   - kubectl context = npd-k8s
#
# Usage:
#   VAULT_TOKEN=hvs.... bash phase9-gitops-platform/environments/dev-k8s/scripts/argocd-enable-notifications.sh
set -euo pipefail

PHASE9="$(cd "$(dirname "$0")/../../.." && pwd)"
VALUES="${PHASE9}/environments/dev-k8s/argocd-install/values-notifications.yaml"
NS="${ARGOCD_NS:-argocd}"
RELEASE="${ARGOCD_RELEASE:-argocd}"
VAULT_NS="${VAULT_NS:-vault}"

if [[ ! -f "$VALUES" ]]; then
  echo "Missing values file: $VALUES" >&2
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
# vault kv get -format=json: data.data for KV v2
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

echo "==> Helm upgrade ${RELEASE} (notifications enabled)"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install "$RELEASE" argo/argo-cd -n "$NS" \
  --reuse-values \
  --set 'configs.params.server\.insecure=true' \
  -f "$VALUES"

echo "==> Wait notifications controller"
kubectl -n "$NS" rollout status deploy/argocd-notifications-controller --timeout=180s || \
  kubectl -n "$NS" get deploy -l app.kubernetes.io/name=argocd-notifications-controller || true

echo "OK — Telegram sẽ nhận sync succeeded/failed cho mọi Application."
echo "Test: sync một app trên https://npd-argocd.co"
