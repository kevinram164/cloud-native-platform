# AIOps — home kubeadm (dev-k8s) integration notes

## Stack

- Alertmanager → Telegram + Generic Webhook Concert Operate
- Kubernetes Observer topology (VIP FortiGate / f5-lb `10.100.1.100`)
- ELK pull; rules: `manifests/monitoring/rules-aiops-topology.yaml`, `rules-apps.yaml`
- After new namespaces (vd `npd-shop`): **Load lại** Kubernetes Observer trên Concert

## Demo P2P daily limit (video)

Xem:

- Repo `banking-demo`: `deploy/dev-k8s/DEMO_SCRIPT_P2P_LIMIT.md` — lời thoại + shot list
- `manifests/aiops-observer/RUNBOOK_TRANSFER_ROLLBACK.md` — ops rollback

Luồng: CR hạn mức ngày → bad release `transfer-service` → Telegram/UI/noti fail → Concert RCA → Argo rollback → fix env → redeploy.

## Windows hosts

Chỉ map domain lab → `10.100.1.100` (không dùng VIP OCP cũ `10.100.1.32` cho `npd-banking.co`).
