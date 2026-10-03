#!/usr/bin/env bash
# Bootstrap ArgoCD GitOps cho dev-k8s — chạy từ root repo cloud-native-platform
# Mặc định: AppProject + platform. STAGE=infra|observability|all để đi tiếp.
# Banking: repo banking-demo (deploy/dev-k8s/argocd).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
ENV_DIR=phase9-gitops-platform/environments/dev-k8s
APPS="$ENV_DIR/argocd/applications"
STAGE="${STAGE:-platform}"

echo "==> AppProject platform"
kubectl apply -f "$ENV_DIR/appproject.yaml" -n argocd

apply() { echo "==> $1"; kubectl apply -f "$APPS/$1-app-of-apps.yaml" -n argocd; }

case "$STAGE" in
  platform)      apply platform ;;
  infra)         apply infra ;;
  observability) apply observability ;;
  all)           kubectl apply -f "$ENV_DIR/argocd/app-of-apps.yaml" -n argocd ;;
  *) echo "STAGE không hợp lệ: $STAGE" >&2; exit 1 ;;
esac

echo "ArgoCD: https://npd-argocd.co"
