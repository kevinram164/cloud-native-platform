# Instana — Logs + Trace correlation (lab NPD)

Hướng dẫn đẩy log (INFO / WARN / ERROR / …) lên Instana và map với `trace.id` để investigate nghiệp vụ (tương tự Dynatrace log ↔ trace).

| | |
|--|--|
| **UI** | `https://instana.apps.itz-tdl40p.infra01-lb.dal14.techzone.ibm.com/` |
| **App mẫu** | `banking-demo` (`dev-k8s`) — Python FastAPI + OTLP logs |
| **Collector** | `opentelemetry-collector` ns `observability` → `otlp/instana` (:4317 agent) |
| **Liên quan** | [DEPLOY.md](./DEPLOY.md), [TROUBLESHOOTING-HOST-AGENT.md](./TROUBLESHOOTING-HOST-AGENT.md) |

---

## 1. Kiến trúc

```
App (stdout JSON vẫn giữ)
  │
  ├─ OTLP logs  :4317  ──┐
  └─ OTLP traces:4317  ──┤
                         ▼
              OpenTelemetry Collector (observability)
                         │
                         ├─► Elastic APM / Kibana
                         └─► Instana agent :4317  ──► TechZone Instana
```

- **Traces** → Instana **Applications / Calls** (waterfall).
- **Logs** → Instana **Analytics → Logs**.
- Map nghiệp vụ: **cùng `trace.id`** trên 2 màn (hoặc Trace detail nếu có Error/Warn logs).

> Instana Call detail thường chỉ hiện đếm **Error logs / Warn logs**. Log **INFO** xem ở **Analytics → Logs** (filter Trace ID / Service).

---

## 2. Điều kiện nền (platform) — thường **không** sửa app

Đã có trên NPD (`cloud-native-platform`):

| Thành phần | Yêu cầu |
|------------|---------|
| Instana host agent | Service expose **4317 / 4318** (OTLP) |
| OTel Collector | Pipeline `logs:` exporters gồm **`otlp/instana`** (và thường `otlp/apm`) |
| Network | App → `opentelemetry-collector.observability:4317`; Collector → `instana-agent.instana-agent:4317` |

Values tham chiếu:

- `environments/dev-k8s/values/values-otel-collector.yaml` — pipeline `logs → otlp/apm, otlp/instana`
- Agent: cài tay / Helm — xem `DEPLOY.md` mục “Agent phải expose OTLP gRPC :4317”

**Không cần sửa code app** nếu chỉ mới dựng collector + agent. App vẫn phải **gửi** log vào OTLP (mục 3–4) thì Instana mới có nội dung log.

Verify collector nhận/gửi log:

```bash
PODIP=$(kubectl -n observability get pod -l app.kubernetes.io/name=opentelemetry-collector \
  -o jsonpath='{.items[0].status.podIP}')
kubectl -n observability run otel-logm --rm -i --restart=Never --image=curlimages/curl:8.5.0 -- \
  sh -c "curl -sS http://$PODIP:8888/metrics | grep -E 'otelcol_receiver_accepted_log|otelcol_exporter_sent_log|otelcol_exporter_send_failed_log'"
```

Kỳ vọng: `accepted` / `sent{exporter="otlp/instana"}` tăng, `send_failed` = 0.

---

## 3. Yêu cầu phía ứng dụng

### 3.1 Env tối thiểu

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://opentelemetry-collector.observability.svc.cluster.local:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
OTEL_SERVICE_NAME=<tên-service>          # vd. api-producer
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=dev-k8s,k8s.namespace.name=npd-banking,k8s.cluster.name=npd-k8s
OTEL_LOGS=1                              # bật OTLP logs (banking-demo)
LOG_LEVEL=INFO                           # INFO+ ; DEBUG = mọi level
```

Banking: `banking-demo/deploy/dev-k8s/values/values-observability.yaml`.

### 3.2 Code cần có gì?

| Khả năng | Bắt buộc? | Ghi chú |
|----------|-----------|---------|
| Gửi **traces** OTLP | Nên có | Call waterfall trên Instana |
| Gửi **logs** OTLP (LoggerProvider + exporter) | **Có** (nếu muốn Log trên Instana) | Stdout alone **không** đủ |
| Gắn `trace_id` / `span_id` vào log | Nên có | Map log ↔ call |
| Đổi message nghiệp vụ | Không | Giữ `logger.info` / `error` hiện có |

**Banking Python (đã làm):**

- `phase8-application-v3/common/observability.py` — `init_logging()`, `attach_otlp_log_handler()`
- `logging_utils.py` — `get_json_logger()` gắn OTLP; JSON có `trace.id` qua `current_trace_fields()`
- Deploy image mới + sync Argo

---

## 4. Khi nào **phải** sửa code / khi nào **không**

### Không cần sửa code (hoặc chỉ env / infra)

| Tình huống | Việc làm |
|------------|----------|
| Collector chưa export logs sang Instana | Sửa values collector, sync Argo, restart |
| Agent chưa mở 4317 | Helm upgrade agent bật OTLP |
| App **đã** có OTLP logs, chỉ muốn đổi level | Đổi `LOG_LEVEL` / `OTEL_LOGS` |
| Chỉ xem traces (không cần log trên Instana) | Giữ như cũ — stdout → Loki/Kibana vẫn được |
| Java + **Instana agent** đã attach + log sensor / auto | Xem mục 6 — nhiều case chỉ cấu hình agent |

### Phải sửa code (hoặc agent instrumentation)

| Tình huống | Việc làm |
|------------|----------|
| App chỉ `print` / log stdout, **không** OTLP logs | Thêm OTel Logging SDK **hoặc** ship log qua Fluent Bit → OTLP |
| Muốn map log ↔ trace nhưng log thiếu `trace.id` | Enrich từ span context (như `current_trace_fields`) |
| Python dùng logger riêng, chưa gắn `LoggingHandler` | Gọi `init_logging` + `attach_otlp_log_handler` |
| Framework log không đi qua logger chuẩn | Adapter / instrumentation tương ứng |
| Muốn WARN/ERROR hiện trong **Call detail** Instana | Đảm bảo emit đúng level WARNING/ERROR trên cùng trace (INFO thường chỉ ở Analytics → Logs) |

### Không cần sửa từng API / business method

- Không phải thêm log mới từng endpoint nếu đã `logger.info` / `log_event` / `log_error_event`.
- Một lần gắn OTLP handler vào logger dùng chung là đủ; level theo `LOG_LEVEL`.

---

## 5. Triển khai (checklist)

1. **Platform:** Collector có pipeline `logs` → `otlp/instana`; agent :4317 OK.  
2. **App:** Image có OTLP logs + env `OTEL_*` / `LOG_LEVEL`.  
3. **Build & deploy** (Jenkins/Argo).  
4. **Verify metrics** collector (mục 2).  
5. **UI:**  
   - `Analytics → Logs` — filter `Service name = api-producer`  
   - Copy `trace.id` từ JSON → `Analytics → Calls` filter Trace ID  
6. **Application Perspective** (`npd-banking`): filter **Dest Service Name** (OR các service), **không** dùng Dest Kubernetes Service. Xem [DEPLOY.md](./DEPLOY.md).

---

## 6. Java — cần làm gì?

Hai hướng phổ biến. Chọn một (hoặc kết hợp).

### Cách A — Instana Java agent (ít đụng code)

Phù hợp app JVM chạy cùng host/pod có Instana agent (hoặc init container agent).

1. Attach agent: `-javaagent:/path/instana-javaagent.jar` (hoặc sensor Kubernetes tự attach).  
2. Bật thu thập log (Log4j / Logback / JUL) theo doc Instana **Java Tracing / Logging**.  
3. Framework hỗ trợ tốt: Log4j2, Logback — agent inject **trace id** vào MDC và/hoặc gửi log lên backend.

| | |
|--|--|
| **Sửa code?** | Thường **không** (hoặc chỉ config `logback.xml` / `log4j2.xml` pattern có `%X{traceId}` nếu muốn file/stdout) |
| **Cần** | Agent Instana trên node/pod, quyền attach, sensor log bật |
| **Hạn chế** | Phụ thuộc agent; container distroless / không attach được thì khó |

### Cách B — OpenTelemetry Java (giống banking Python → collector)

Đồng bộ với pipeline NPD hiện tại (app → collector → Instana).

**Option B1 — Java agent OTel (ít code):**

```bash
-javaagent:opentelemetry-javaagent.jar
-Dotel.service.name=my-java-service
-Dotel.exporter.otlp.endpoint=http://opentelemetry-collector.observability.svc:4317
-Dotel.exporter.otlp.protocol=grpc
-Dotel.logs.exporter=otlp
-Dotel.resource.attributes=deployment.environment=dev-k8s,k8s.namespace.name=...
```

- Auto: traces + (tùy version/agent) bridge logging.  
- Kiểm tra version agent hỗ trợ **OTLP logs**; nếu chưa: dùng appender (B2).

**Option B2 — Sửa code / config logging (chắc chắn có logs OTLP):**

1. Dependencies (OpenTelemetry + exporter OTLP).  
2. `SdkLoggerProvider` + `OtlpGrpcLogRecordExporter` (hoặc HTTP).  
3. Logback: appender OpenTelemetry **hoặc** MDC `trace_id` / `span_id` + ship stdout bằng Fluent Bit → OTLP.  
4. Log4j2: tương tự (OTLP appender / context data).

| | |
|--|--|
| **Sửa code?** | Agent-only: chủ yếu JVM args. Appender/SDK: **có** (deps + config) |
| **Map trace** | OTel context tự gắn; hoặc MDC `%X{trace_id}` |

### Java — quyết định nhanh

```
Có thể attach Instana Java agent ổn định?
  ├─ YES → Cách A (ưu tiên lab JVM cổ điển)
  └─ NO / muốn đồng bộ collector NPD
        ├─ Thử OTel Java agent + otel.logs.exporter=otlp
        └─ Không đủ → Logback/Log4j OTLP appender hoặc Fluent Bit tail → collector
```

**Không cần** sửa từng `logger.info("...")` nghiệp vụ nếu đã dùng Logback/Log4j chuẩn và appender/agent bắt root logger.

---

## 7. Xem trên Instana UI

| Mục tiêu | Cách |
|----------|------|
| Danh sách log theo service | **Analytics → Logs** — filter Service name (không phải Kubernetes Service) |
| Log theo 1 request | Copy `trace.id` từ log JSON hoặc từ Call header → filter Logs / Calls |
| Waterfall | **Calls** → mở trace |
| Log trong Call detail | Chủ yếu khi có **Error/Warn** trên trace; INFO → Analytics → Logs |
| Perspective `npd-banking` | Dest Service Name ∈ banking services (+ optional Technology = openTelemetry) |

---

## 8. Troubleshooting ngắn

| Triệu chứng | Kiểm tra |
|-------------|----------|
| Analytics Logs trống | Image đã có OTLP logs? `OTEL_LOGS=1`? Collector `accepted_log`? |
| Có log collector, UI trống | Filter sai (Kubernetes Service); thử Service name / bỏ perspective |
| Có log, Call detail Error/Warn = 0 | Bình thường nếu chỉ INFO |
| Trace có, log không cùng id | Chưa enrich context; log ngoài span |
| Java không có log | Agent chưa attach / `otel.logs.exporter` tắt / appender chưa vào root logger |

---

## 9. Tham chiếu code lab

| Repo / path | Nội dung |
|-------------|----------|
| `banking-demo` `phase8-application-v3/common/observability.py` | `init_logging`, OTLP log exporter |
| `banking-demo` `phase8-application-v3/common/logging_utils.py` | JSON logger + attach OTLP |
| `banking-demo` `deploy/dev-k8s/values/values-observability.yaml` | Env OTEL / LOG_LEVEL |
| `cloud-native-platform` `.../values-otel-collector.yaml` | Pipeline logs → Instana |
