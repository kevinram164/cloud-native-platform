#!/usr/bin/env bash
# Cho pod phân giải npd-<app>.co → f5-lb (10.100.1.100). Cần cho OIDC backchannel
# (ArgoCD / Harbor / Jenkins / Grafana gọi https://npd-keycloak.co) và Jenkins/Kaniko gọi npd-harbor.co.
# Không cần nếu DNS nội bộ (mà node dùng trong /etc/resolv.conf) đã có các bản ghi này.
# Chạy lại được: block hosts npd-*.co cũ bị thay bằng danh sách APPS hiện tại.
#
#   bash phase9-gitops-platform/environments/dev-k8s/scripts/coredns-npd-hosts.sh
set -euo pipefail

LB_IP="${LB_IP:-10.100.1.100}"
APPS="${APPS:-argocd harbor jenkins vault keycloak kafka-ui banking minio minio-console grafana prometheus alertmanager kibana}"

COREFILE=$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')

# Bỏ block hosts npd-*.co cũ (nhận diện qua dòng "# npd-hosts")
COREFILE=$(awk '
  /# npd-hosts begin/ { skip=1 }
  !skip { print }
  /# npd-hosts end/ { skip=0 }
' <<<"${COREFILE}")
# Block do bản script trước tạo (không có marker): hosts { ... npd-keycloak.co ... }
COREFILE=$(awk '
  /^[[:space:]]*hosts[[:space:]]*\{/ { buf=$0; inblk=1; next }
  inblk { buf=buf "\n" $0; if ($0 ~ /^[[:space:]]*\}/) { inblk=0; if (buf !~ /npd-[a-z-]+\.co/) print buf }; next }
  { print }
' <<<"${COREFILE}")

HOSTS="    # npd-hosts begin"$'\n'"    hosts {"
for a in ${APPS}; do HOSTS+=$'\n'"        ${LB_IP} npd-${a}.co"; done
HOSTS+=$'\n'"        fallthrough"$'\n'"    }"$'\n'"    # npd-hosts end"

NEW=$(awk -v block="${HOSTS}" '/^[[:space:]]*forward \./ && !done { print block; done=1 } { print }' <<<"${COREFILE}")

kubectl -n kube-system create configmap coredns --from-literal=Corefile="${NEW}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n kube-system rollout restart deploy coredns
kubectl -n kube-system rollout status deploy coredns --timeout=120s
echo "OK. Kiểm tra:"
echo "  kubectl run dnstest --rm -it --image=busybox:1.36 --restart=Never -- nslookup npd-grafana.co"
