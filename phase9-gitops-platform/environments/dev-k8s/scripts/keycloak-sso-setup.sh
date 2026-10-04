#!/usr/bin/env bash
# Keycloak realm `platform` cho SSO ArgoCD / Jenkins / Harbor / Grafana (idempotent, chạy lại được).
#   - realm platform, group platform-admin
#   - client argocd / jenkins / harbor / grafana (confidential, redirect theo domain npd-<app>.co, mapper groups)
#   - (tuỳ chọn) user SSO_USER ∈ platform-admin
#   - ghi client secret vào Vault secret/platform/keycloak-clients {argocd, jenkins, harbor, grafana}
#
#   export VAULT_TOKEN=<root/admin token>
#   export KC_ADMIN_PASSWORD=<mật khẩu admin realm master>   # DB cũ OCP: admin cũ vẫn còn
#   export SSO_USER=kiet.tran SSO_PASSWORD='...'              # tuỳ chọn
#   bash phase9-gitops-platform/environments/dev-k8s/scripts/keycloak-sso-setup.sh
set -euo pipefail

: "${VAULT_TOKEN:?export VAULT_TOKEN}"
: "${KC_ADMIN_PASSWORD:?export KC_ADMIN_PASSWORD (admin realm master)}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_NS="${KC_NS:-keycloak}"
KC_POD="${KC_POD:-keycloak-0}"
VAULT_NS="${VAULT_NS:-vault}"
REALM="${REALM:-platform}"
ADMIN_GROUP="${ADMIN_GROUP:-platform-admin}"

kc() {
  kubectl exec -i -n "${KC_NS}" "${KC_POD}" -c keycloak -- \
    /opt/bitnami/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config
}

echo "==> Đăng nhập kcadm (realm master)"
kc config credentials --server http://localhost:8080 --realm master \
  --user "${KC_ADMIN_USER}" --password "${KC_ADMIN_PASSWORD}"

echo "==> Realm ${REALM}"
kc get "realms/${REALM}" >/dev/null 2>&1 || kc create realms -s realm="${REALM}" -s enabled=true

echo "==> Group ${ADMIN_GROUP}"
GROUP_ID=$(kc get groups -r "${REALM}" -q exact=true -q search="${ADMIN_GROUP}" --fields id --format csv --noquotes | head -1)
if [[ -z "${GROUP_ID}" ]]; then
  GROUP_ID=$(kc create groups -r "${REALM}" -s name="${ADMIN_GROUP}" -i)
fi

# client <clientId> <rootUrl> <redirectUrisJSON>
client() {
  local cid="$1" root="$2" redirects="$3" id
  echo "==> Client ${cid} (${root})" >&2
  id=$(kc get clients -r "${REALM}" -q clientId="${cid}" --fields id --format csv --noquotes | head -1)
  local common=(
    -s enabled=true -s protocol=openid-connect -s publicClient=false
    -s clientAuthenticatorType=client-secret
    -s standardFlowEnabled=true -s directAccessGrantsEnabled=false
    -s rootUrl="${root}" -s baseUrl="${root}"
    -s "redirectUris=${redirects}" -s "webOrigins=[\"${root}\"]"
    -s 'attributes."post.logout.redirect.uris"=+'
  )
  if [[ -z "${id}" ]]; then
    id=$(kc create clients -r "${REALM}" -s clientId="${cid}" "${common[@]}" -i)
  else
    kc update "clients/${id}" -r "${REALM}" "${common[@]}"
  fi

  if ! kc get "clients/${id}/protocol-mappers/models" -r "${REALM}" --fields name --format csv --noquotes | grep -qx groups; then
    kc create "clients/${id}/protocol-mappers/models" -r "${REALM}" \
      -s name=groups -s protocol=openid-connect -s protocolMapper=oidc-group-membership-mapper \
      -s 'config."claim.name"=groups' -s 'config."full.path"=false' \
      -s 'config."id.token.claim"=true' -s 'config."access.token.claim"=true' \
      -s 'config."userinfo.token.claim"=true' >/dev/null
  fi

  kc get "clients/${id}/client-secret" -r "${REALM}" --fields value --format csv --noquotes
}

ARGOCD_SECRET=$(client argocd https://npd-argocd.co \
  '["https://npd-argocd.co/auth/callback","http://localhost:8085/auth/callback"]')
JENKINS_SECRET=$(client jenkins https://npd-jenkins.co \
  '["https://npd-jenkins.co/securityRealm/finishLogin"]')
HARBOR_SECRET=$(client harbor https://npd-harbor.co \
  '["https://npd-harbor.co/c/oidc/callback"]')
GRAFANA_SECRET=$(client grafana https://npd-grafana.co \
  '["https://npd-grafana.co/login/generic_oauth"]')

if [[ -n "${SSO_USER:-}" ]]; then
  echo "==> User ${SSO_USER} ∈ ${ADMIN_GROUP}"
  USER_ID=$(kc get users -r "${REALM}" -q exact=true -q username="${SSO_USER}" --fields id --format csv --noquotes | head -1)
  if [[ -z "${USER_ID}" ]]; then
    USER_ID=$(kc create users -r "${REALM}" -s username="${SSO_USER}" -s enabled=true \
      -s emailVerified=true -s email="${SSO_EMAIL:-${SSO_USER}@npd.co}" -i)
  fi
  if [[ -n "${SSO_PASSWORD:-}" ]]; then
    kc set-password -r "${REALM}" --userid "${USER_ID}" --new-password "${SSO_PASSWORD}"
  fi
  kc update "users/${USER_ID}/groups/${GROUP_ID}" -r "${REALM}" -n
fi

echo "==> Vault secret/platform/keycloak-clients"
kubectl exec -i -n "${VAULT_NS}" vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_TOKEN}" \
  vault kv put secret/platform/keycloak-clients \
    argocd="${ARGOCD_SECRET}" jenkins="${JENKINS_SECRET}" harbor="${HARBOR_SECRET}" \
    grafana="${GRAFANA_SECRET}" >/dev/null

echo
echo "OK. Issuer: https://npd-keycloak.co/realms/${REALM}"
echo "Tiếp: argocd-oidc-keycloak.sh, harbor-oidc-keycloak.sh; Jenkins/Grafana tự đọc secret qua Vault Agent"
echo "(pod đang chạy cần restart: kubectl -n platform delete pod jenkins-0; kubectl -n monitoring rollout restart deploy kube-prometheus-stack-grafana)."
