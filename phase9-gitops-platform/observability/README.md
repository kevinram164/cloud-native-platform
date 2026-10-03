# Observability — Coroot + OpenTelemetry

Stack thống nhất cho **metrics, logs, traces**. Không dùng service mesh: Cilium lo CNI/network policy, Coroot node-agent (eBPF) thấy traffic giữa các service mà không cần sidecar.

Môi trường `dev-k8s` dùng values trong `environments/dev-k8s/values/` (`values-coroot-ce.yaml`, `values-otel-collector.yaml`). Các file `values-*-k3d.yaml` / `-ocp.yaml` ở đây là bản cũ cho OpenShift.

## Kiến trúc

```text
App pods (vd. npd-banking)
    │ OTLP gRPC :4317
    ▼
OpenTelemetry Collector (ns observability)
    │ OTLP → Coroot
    ▼
Coroot CE (UI + ClickHouse + cluster-agent + node-agent eBPF)
    ├── Metrics
    ├── Logs
    └── Traces
```

| Thành phần | Namespace | Domain UI |
|------------|-----------|-----------|
| **Coroot** | `observability` | https://npd-coroot.co |
| **OTEL Collector** | `observability` | — (internal) |

## ArgoCD apply (sau platform + infra)

```bash
STAGE=observability bash phase9-gitops-platform/environments/dev-k8s/apply-argocd.sh
```

| Wave | App |
|------|-----|
| 0 | coroot-operator |
| 1 | opentelemetry-collector |
| 2 | coroot-ce |

Ingress `npd-coroot.co` nằm trong `environments/dev-k8s/manifests/ingress/coroot.yaml`.

## Instrumentation cho app

App tự khai báo OTEL trong repo của nó, ví dụ banking: `banking-demo/deploy/dev-k8s/values/values-observability.yaml`:

- `OTEL_EXPORTER_OTLP_ENDPOINT=http://opentelemetry-collector.observability.svc.cluster.local:4317`
- `OTEL_RESOURCE_ATTRIBUTES=deployment.environment=dev-k8s,k8s.namespace.name=<ns>,k8s.cluster.name=npd-k8s`
