#!/usr/bin/env bash
# Sync / restart otel-collector (dual ELK APM + Instana qua host agent :4317).
# npd không cần secret OTLP SaaS — agent đã có key; tránh otlp-grpc.instana… (DNS fail).
#
# Usage:
#   bash .../instana-seed-otlp-and-sync.sh
set -euo pipefail

OBS_NS="${OBS_NS:-observability}"
AGENT_NS="${AGENT_NS:-instana-agent}"

echo "==> Check instana-agent Service :4317"
kubectl -n "$AGENT_NS" get svc -o wide
if ! kubectl -n "$AGENT_NS" get svc instana-agent >/dev/null 2>&1; then
  echo "WARN: thiếu svc/${AGENT_NS}/instana-agent — Helm agent phải tạo ClusterIP OTLP" >&2
fi

if kubectl -n argocd get application observability-otel-collector >/dev/null 2>&1; then
  kubectl -n argocd annotate application observability-otel-collector \
    argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true
  echo "Annotated Argo refresh observability-otel-collector (push git values trước nếu chưa)"
fi

if kubectl -n "$OBS_NS" get deploy opentelemetry-collector >/dev/null 2>&1; then
  kubectl -n "$OBS_NS" rollout restart deploy/opentelemetry-collector
  kubectl -n "$OBS_NS" rollout status deploy/opentelemetry-collector --timeout=180s
fi

echo "==> Recent export errors (expect hết 'otlp-grpc.instana' / no such host)"
kubectl -n "$OBS_NS" logs deploy/opentelemetry-collector --tail=40 2>/dev/null \
  | grep -iE 'instana|Export|error|no such|Unavailable' || echo "(no matching lines)"

echo "Done. UI: Applications → Dest Kubernetes Namespace=npd-banking|npd-shop|npd-movie"
