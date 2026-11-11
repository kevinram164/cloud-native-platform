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

## 5. Gắn Concert (UI)

- Recommended action / Runbook Automation: trỏ runbook này.
- Match alertname: `BankingTransferUnavailable`, `BankingProducer5xx` (và `Workload*` nếu pod lệch).
- Resource hint: `transfer-service` / namespace `npd-banking`.
