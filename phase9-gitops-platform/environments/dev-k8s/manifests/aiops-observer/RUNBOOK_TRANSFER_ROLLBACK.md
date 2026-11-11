# Runbook — Rollback transfer-service (CK P2P gián đoạn)

**Khi dùng:** Alert `BankingTransferUnavailable` / `BankingProducer5xx` firing; user CK P2P fail; log `error_code=TRANSFER_DAILY_LIMIT_EXCEEDED` (hoặc downstream 503 sau bad release).

**Mục tiêu ops:** Khôi phục giao dịch bằng **Argo rollback** — không SSH sửa pod, không hotfix image tay.

## 1. Xác nhận sự cố

```bash
# UI / API: P2P trả 503 + TRANSFER_DAILY_LIMIT_EXCEEDED
kubectl -n npd-banking get deploy,pods -l app.kubernetes.io/component=transfer-service
kubectl -n npd-banking logs deploy/banking-transfer-service -c transfer-service --tail=100 \
  | grep -E 'TRANSFER_DAILY_LIMIT_EXCEEDED|transfer_rejected|daily_limit'

# Alertmanager / Telegram: FIRING BankingTransferUnavailable [critical] ns npd-banking
```

Kibana: index `logs-bank-*`, filter `failure_code` / `error_code` = `TRANSFER_DAILY_LIMIT_EXCEEDED`.

## 2. Rollback GitOps

Application ArgoCD: `banking-transfer-service` (repo `banking-demo`, chart transfer-service).

```bash
argocd app get banking-transfer-service
argocd app history banking-transfer-service
# Chọn revision TRƯỚC bản lỗi (image tag cũ / sync trước commit fault)
argocd app rollback banking-transfer-service <PREV_HISTORY_ID>
# hoặc UI ArgoCD → app → History → Rollback
```

Nếu values Git đã merge fault vào HEAD và Argo auto-sync: tạm `argocd app suspend banking-transfer-service` sau rollback, hoặc revert commit Git rồi sync (engineering).

## 3. Verify mitigate

```bash
kubectl -n npd-banking rollout status deploy/banking-transfer-service
# CK tay trên https://npd-banking.co → PENDING/SUCCESS
# Telegram có thể RESOLVED BankingTransferUnavailable
```

## 4. Bàn giao engineering

1. Giữ incident Concert mở đến khi có fix.
2. Fix: `P2P_DAILY_LIMIT_STRICT_DEFAULT=false` + `P2P_DAILY_LIMIT_VND` hợp lệ (xem `banking-demo/deploy/dev-k8s/DEMO_SCRIPT_P2P_LIMIT.md`).
3. CI → Argo sync → E2E peer + CK tay → resolve incident / đánh dấu runbook worked.

## 5. Tạo Runbook trên Concert Operate (AIOps) — làm một lần

File Markdown này là SOP nguồn. Runbook thật nằm trong **Operate → Automations → Runbooks**.

Demo lab: dùng **Manual runbook** (ops làm theo bước trên Argo UI / terminal). Semi-auto (HTTP Action gọi Argo API) để sau nếu cần.

### 5.1 Tạo runbook

1. Concert Operate console → menu **Operate** → **Automations**.
2. Tab **Runbooks** (Library).
3. **Create runbook** (hoặc *New runbook*).
4. Điền:
   - **Name:** `Rollback banking transfer-service (P2P outage)`
   - **Description:** `CK P2P 503 / TRANSFER_DAILY_LIMIT_EXCEEDED sau bad release — rollback Argo app banking-transfer-service.`
   - **Tags:** `banking`, `transfer-service`, `rollback`, `gitops`
5. Thêm **manual steps** (copy từ mục 1–4 ở trên), tối thiểu:
   - Step 1: Xác nhận Telegram/Alert `BankingTransferUnavailable` + log `TRANSFER_DAILY_LIMIT_EXCEEDED`.
   - Step 2: Mở ArgoCD `https://npd-argocd.co` → app `banking-transfer-service` → History → Rollback revision trước fault (hoặc lệnh `argocd app rollback …`).
   - Step 3: Nếu auto-sync kéo lại bản lỗi → Suspend sync / revert Git.
   - Step 4: Verify CK tay SUCCESS; chờ alert RESOLVED.
   - Step 5: Đánh dấu Runbook Worked; mở change cho eng fix `P2P_DAILY_LIMIT_*`.
6. **Save draft** → **Run** thử (dry) → **Publish** (operator mới thấy trên Incident).

Role cần: RBA Author / Approver (tuỳ bản Concert).

### 5.2 Gắn với alert / incident (để hiện trên RCA)

Cách A — **Policy** (khuyến nghị demo):

1. **Operate → Automations → Policies** → Create / template gần *runbook* / *recommended action*.
2. Condition: alertname contains `BankingTransferUnavailable` **OR** `BankingProducer5xx`; namespace `npd-banking` (nếu filter được).
3. Action: **Suggest / attach runbook** → chọn `Rollback banking transfer-service (P2P outage)`.
4. Execution: **manual approval** (ops bấm Run trên Incident) — không auto-rollback production lab trừ khi bạn chủ đích.

Cách B — Khi đang xem Incident: **Runbooks** / **Recommended actions** → Run → Start Runbook (nếu policy đã match).

Sau khi chạy xong: rate runbook → **Runbook Worked** để AI ưu tiên lần sau.
