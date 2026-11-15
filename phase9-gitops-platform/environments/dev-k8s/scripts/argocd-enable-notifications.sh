#!/usr/bin/env bash
# Bật Argo CD Notifications → Telegram (cùng Vault bot Alertmanager).
#
# Prerequisites:
#   - helm repo argo, release name `argocd` ns `argocd`
#   - VAULT_TOKEN (hoặc đã login) để đọc secret/platform/alertmanager-telegram
#   - kubectl context = npd-k8s
#
# Usage (từ root cloud-native-platform hoặc bất kỳ cwd):
#   VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=... \
#     bash phase9-gitops-platform/environments/dev-k8s/scripts/argocd-enable-notifications.sh
set -euo pipefail

# scripts → …/phase9-gitops-platform/environments/dev-k8s/scripts
PHASE9="$(cd "$(dirname "$0")/../../.." && pwd)"
VALUES="${PHASE9}/environments/dev-k8s/argocd-install/values-notifications.yaml"
NS="${ARGOCD_NS:-argocd}"
RELEASE="${ARGOCD_RELEASE:-argocd}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"

if [[ ! -f "$VALUES" ]]; then
  echo "Missing values file: $VALUES" >&2
  exit 1
fi

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  echo "Set VAULT_TOKEN (read secret/platform/alertmanager-telegram)" >&2
  exit 1
fi

echo "==> Read Telegram bot_token from Vault"
RAW="$(curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "${VAULT_ADDR%/}/v1/secret/data/platform/alertmanager-telegram")"
TOKEN="$(echo "$RAW" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("data") or {}).get("data") or {}).get("bot_token") or "")')"
if [[ -z "$TOKEN" ]]; then
  echo "Vault secret missing bot_token: $RAW" >&2
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
