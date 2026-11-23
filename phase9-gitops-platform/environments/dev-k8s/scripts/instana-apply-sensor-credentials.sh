#!/usr/bin/env bash
# Merge Instana sensor credentials (Redis/PG lab + RabbitMQ/Jenkins từ Vault)
# rồi áp vào release Helm `instana-agent` (ns instana-agent) — --reuse-values.
#
# Usage:
#   VAULT_TOKEN=hvs.... bash phase9-gitops-platform/environments/dev-k8s/scripts/instana-apply-sensor-credentials.sh
set -euo pipefail

PHASE9="$(cd "$(dirname "$0")/../../.." && pwd)"
NS="${INSTANA_NS:-instana-agent}"
RELEASE="${INSTANA_RELEASE:-instana-agent}"
VAULT_NS="${VAULT_NS:-vault}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  echo "Set VAULT_TOKEN" >&2
  exit 1
fi

vget() {
  local path="$1" field="$2"
  kubectl exec -i -n "${VAULT_NS}" vault-0 -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_TOKEN}" \
    vault kv get -field="$field" "$path" 2>/dev/null | tr -d '\r'
}

echo "==> Read Vault rabbitmq/admin + platform/jenkins"
RABBIT_USER="$(vget secret/rabbitmq/admin username || true)"
RABBIT_PASS="$(vget secret/rabbitmq/admin password || true)"
JENKINS_USER="$(vget secret/platform/jenkins admin_username || true)"
JENKINS_PASS="$(vget secret/platform/jenkins admin_password || true)"

if [[ -z "$RABBIT_USER" || -z "$RABBIT_PASS" ]]; then
  echo "WARN: thiếu rabbitmq/admin — bỏ qua sensor RabbitMQ" >&2
fi
if [[ -z "$JENKINS_USER" || -z "$JENKINS_PASS" ]]; then
  echo "WARN: thiếu platform/jenkins — bỏ qua sensor Jenkins" >&2
fi

# Escape single quotes for YAML single-quoted strings: ' -> ''
ysq() { printf "%s" "${1//\'/\'\'}"; }

CFG="${TMP}/configuration.yaml"
cat >"$CFG" <<EOF
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) — lab npd-k8s
com.instana.plugin.redis:
  password: '$(ysq 'Mbfs@2025')'
  poll_rate: 10

com.instana.plugin.postgresql:
  user: 'banking'
  password: '$(ysq 'bankingpass')'
  database: 'banking'
  poll_rate: 10
EOF

if [[ -n "${RABBIT_USER}" && -n "${RABBIT_PASS}" ]]; then
  cat >>"$CFG" <<EOF

com.instana.plugin.rabbitmq:
  user: '$(ysq "$RABBIT_USER")'
  password: '$(ysq "$RABBIT_PASS")'
  poll_rate: 10
EOF
fi

if [[ -n "${JENKINS_USER}" && -n "${JENKINS_PASS}" ]]; then
  cat >>"$CFG" <<EOF

com.instana.plugin.jenkins:
  user: '$(ysq "$JENKINS_USER")'
  password: '$(ysq "$JENKINS_PASS")'
  poll_rate: 30
EOF
fi

echo "==> configuration.yaml preview (passwords redacted)"
sed -E "s/(password: ').+/\1***'/" "$CFG"

VALUES="${TMP}/values-sensors.yaml"
{
  echo "agent:"
  echo "  configuration_yaml: |"
  sed 's/^/    /' "$CFG"
} >"$VALUES"

if helm -n "$NS" status "$RELEASE" >/dev/null 2>&1; then
  echo "==> helm upgrade ${RELEASE} (--reuse-values + sensor config)"
  helm upgrade "$RELEASE" instana-agent \
    --repo https://agents.instana.io/helm \
    -n "$NS" \
    --reuse-values \
    -f "$VALUES"
else
  echo "==> Không thấy Helm release ${RELEASE}; thử patch Agent CR"
  AGENT_NAME="$(kubectl -n "$NS" get agents.instana.io -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$AGENT_NAME" ]]; then
    AGENT_NAME="$(kubectl -n "$NS" get agent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  fi
  if [[ -z "$AGENT_NAME" ]]; then
    echo "Không tìm thấy Helm release hay Agent CR trong ns ${NS}" >&2
    exit 1
  fi
  # Store config in a secret then set field — use kubectl apply of a merge patch file
  PATCH="${TMP}/agent-patch.yaml"
  {
    echo "spec:"
    echo "  agent:"
    echo "    configurationYaml: |"
    sed 's/^/      /' "$CFG"
  } >"$PATCH"
  # Field name differs by CRD version: configurationYaml vs configuration_yaml
  if kubectl -n "$NS" get "agents.instana.io/${AGENT_NAME}" >/dev/null 2>&1; then
    kubectl -n "$NS" patch "agents.instana.io/${AGENT_NAME}" --type merge --patch-file "$PATCH" \
      || kubectl -n "$NS" patch "agents.instana.io/${AGENT_NAME}" --type merge -p \
        "{\"spec\":{\"agent\":{\"configuration_yaml\":$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$CFG")}}}"
  else
    kubectl -n "$NS" patch "agent/${AGENT_NAME}" --type merge -p \
      "{\"spec\":{\"agent\":{\"configuration_yaml\":$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$CFG")}}}"
  fi
fi

echo "==> Restart daemonset agents (nạp config)"
kubectl -n "$NS" rollout restart ds -l app.kubernetes.io/name=instana-agent 2>/dev/null \
  || kubectl -n "$NS" rollout restart ds/instana-agent 2>/dev/null \
  || true

echo "OK. Kiểm tra:"
echo "  kubectl -n ${NS} logs -l app.kubernetes.io/name=instana-agent -c instana-agent --tail=50 | grep -iE 'redis|postgres|rabbit|jenkins|NOAUTH|Unauthorized'"
