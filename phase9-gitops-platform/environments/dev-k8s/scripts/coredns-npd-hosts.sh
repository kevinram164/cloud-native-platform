#!/usr/bin/env bash
# Cho pod phân giải npd-<app>.co → f5-lb (10.100.1.100). Cần cho OIDC backchannel
# (ArgoCD / Harbor / Jenkins gọi https://npd-keycloak.co) và Jenkins/Kaniko gọi npd-harbor.co.
# Không cần nếu DNS nội bộ (mà node dùng trong /etc/resolv.conf) đã có các bản ghi này.
#
#   bash phase9-gitops-platform/environments/dev-k8s/scripts/coredns-npd-hosts.sh
set -euo pipefail

LB_IP="${LB_IP:-10.100.1.100}"
APPS="${APPS:-argocd harbor jenkins vault coroot kafka-ui banking keycloak}"

COREFILE=$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')
if grep -q 'npd-keycloak.co' <<<"${COREFILE}"; then
  echo "Corefile đã có block hosts npd-*.co — bỏ qua"
  exit 0
fi

HOSTS="    hosts {"
for a in ${APPS}; do HOSTS+=$'\n'"        ${LB_IP} npd-${a}.co"; done
HOSTS+=$'\n'"        fallthrough"$'\n'"    }"

NEW=$(awk -v block="${HOSTS}" '/^[[:space:]]*forward \./ && !done { print block; done=1 } { print }' <<<"${COREFILE}")

kubectl -n kube-system create configmap coredns --from-literal=Corefile="${NEW}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "OK — CoreDNS reload trong ~30s. Kiểm tra:"
echo "  kubectl run dnstest --rm -it --image=busybox:1.36 --restart=Never -- nslookup npd-keycloak.co"
