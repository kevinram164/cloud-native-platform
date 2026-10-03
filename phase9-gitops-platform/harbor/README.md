# Harbor

Registry nội bộ cho CI (Jenkins Kaniko) và CD (kubelet pull image).

## Cụm K8s (`dev-k8s`)

| | |
|--|--|
| UI | **https://npd-harbor.co** |
| Ingress | f5-lb NGINX Plus (TLS) → HAProxy ingress (`haproxy`) trên npd-route `10.100.1.46` |
| StorageClass | `nfs-csi` (NFS `10.100.1.180:/shares/registry`) |

## Sau khi sync `platform-harbor`

1. Đăng nhập UI, đổi admin password ngay.
2. Tạo project cho từng app, ví dụ **`banking-demo`** (private).
3. Tạo **Robot Accounts** trong project:
   - `ci` — push + pull → Vault `secret/platform/harbor` (pipeline Kaniko đọc qua Vault API).
   - `k8s-pull` — chỉ pull → Vault `secret/platform/harbor-pull`.

## Pull secret

Kubelet pull image trước khi bất kỳ container nào (kể cả Vault Agent) chạy, nên robot `k8s-pull` vẫn phải nằm trong Secret `kubernetes.io/dockerconfigjson`. Vault giữ credential gốc, script tạo Secret:

```bash
v kv put secret/platform/harbor-pull \
  registry='npd-harbor.co' \
  username='robot$banking-demo+k8s-pull' \
  password='<TOKEN>'

VAULT_TOKEN=<token> NAMESPACES="npd-banking" \
  bash ../environments/dev-k8s/scripts/create-harbor-pull-secret.sh
kubectl get secret harbor-pull-creds -n npd-banking -o jsonpath='{.type}'; echo   # kubernetes.io/dockerconfigjson
```

Chart banking dùng secret này qua `imagePullSecrets` trong `deploy/dev-k8s/values/values-images.yaml`. Rotate token robot: cập nhật Vault rồi chạy lại script.

## Image naming

```text
npd-harbor.co/banking-demo/api-producer:<sha>
npd-harbor.co/banking-demo/auth-service:<sha>
...
```

## TLS

f5-lb terminate TLS cho `npd-harbor.co`; containerd mỗi node cần trust CA, xem [K8S-DEPLOY-GUIDE.md](../K8S-DEPLOY-GUIDE.md) mục 5. Kaniko dùng `kanikoSkipTlsVerify: true` (lab).
