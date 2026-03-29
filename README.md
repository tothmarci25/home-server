# Home Server

GitOps-based single-node Kubernetes cluster for self-hosted applications. Ansible provisions the cluster and bootstraps ArgoCD, which then continuously deploys all applications from this repository.

## Deployed Applications

| App           | Purpose                  |
| ------------- | ------------------------ |
| Plex          | Media server             |
| Radarr        | Movie management         |
| Sonarr        | TV series management     |
| Jackett       | Torrent indexer          |
| qBittorrent   | Torrent client           |
| FileBrowser   | Web-based file manager   |
| Vault         | Secrets management       |
| CloudFlared   | Cloudflare tunnel        |
| DNSMasq       | Local DNS server         |
| MetalLB       | Bare-metal load balancer |
| nginx-ingress | Ingress controller       |

## Prerequisites

- Ansible installed on your local machine
- `ansible-galaxy collection install -r ansible/requirements.yaml` (installs `kubernetes.core`)
- A target Ubuntu server (physical or VM) with SSH access
- USB disk(s) attached and their UUIDs known (for storage)

## Setup

### 1. Configure credentials

```bash
cp .env.example .env
```

Edit `.env`:

```
ANSIBLE_SSH_KEY=/path/to/your/ssh/private/key
SUDO_PASSWORD=your_sudo_password
SERVER_IP=192.168.x.x
SERVER_SSH_PORT=22
SERVER_USER=ubuntu
```

> **Staging with Multipass:** Copy the Multipass SSH key first:
>
> ```bash
> sudo cp "/var/root/Library/Application Support/multipassd/ssh-keys/id_rsa" ~/.ssh/multipass_id_rsa
> sudo chown $USER ~/.ssh/multipass_id_rsa
> chmod 600 ~/.ssh/multipass_id_rsa
> ```

### 2. Provision the Kubernetes cluster

```bash
./run_playbook.sh staging ansible/playbooks/k8s_install.yaml
```

This installs containerd, kubeadm, kubelet, kubectl (v1.35), initializes the cluster with Flannel CNI, and removes the control-plane taint so workloads can run on the single node.

### 3. Mount storage and generate Helm values

Before running, edit `ansible/roles/storage/defaults/main.yaml` to match your setup:

- `usb_disks` — disk name, UUID, size, and storage class for each attached USB disk. Find UUIDs on the server with `blkid` or `lsblk -f`.
- `app_storage_map` — per-app volume and mount configuration referencing those disks.
- `vault_disk_name` — name of the disk (from `usb_disks`) used for Vault storage. Leave empty to skip Vault directory and values generation.

```yaml
usb_disks:
  - name: ssd
    uuid: "your-disk-uuid-here"
    size: 16Gi
    storageClass: local-ssd

vault_disk_name: "ssd"
```

```bash
./run_playbook.sh staging ansible/playbooks/generate_storages.yaml
```

This mounts USB disks by UUID, creates local PersistentVolumes, labels the node with storage availability, and generates the Helm values files consumed by ArgoCD. If `vault_disk_name` is set, it also creates the `vault-data` and `vault-audit` directories on the disk and generates `vault-pv-values.yaml`.

### 4. Bootstrap ArgoCD

```bash
./run_playbook.sh staging ansible/playbooks/bootstrap_argocd.yaml
```

This installs Helm, deploys ArgoCD via Helm chart (v9.3.7), and applies the root ArgoCD `Application` manifest. ArgoCD then syncs all other applications from this repo automatically.

The initial ArgoCD admin password is printed at the end of the playbook output.

### 5. Initialize Vault (first time only)

After Vault is deployed by ArgoCD, exec into the Vault pod to run init commands:

```bash
kubectl exec -it -n vault statefulset/vault -- sh
```

```bash
vault operator init          # Save the unseal keys and root token
vault operator unseal        # Run 3 times with 3 different unseal keys
vault login <root-token>

# Store CloudFlared secrets before syncing the bootstrap job
vault secrets enable -version=2 kv
vault kv put kv/cloudflared \
  credentials.json=@credentials.json \
  tunnel-id="your-tunnel-id"

# Create a short-lived bootstrap token for the vault-bootstrap job
vault token create -ttl=15m
kubectl -n vault create secret generic vault-bootstrap-token \
  --from-literal=token=<token>
```

### 6. Sync vault-bootstrap and cloudflared

Manually sync the vault-bootstrap job via the ArgoCD CLI or UI:

```bash
argocd app sync vault-bootstrap
```

Once the job completes, sync the cloudflared application:

```bash
argocd app sync cloudflared
```

### 7. (Optional) Setup WireGuard VPN

```bash
./run_playbook.sh staging ansible/playbooks/setup_wireguard.yaml
```

Configures a WireGuard server on `10.7.0.1`, listening on port `51820`.

## Running playbooks

```bash
./run_playbook.sh [staging|production] <playbook-path> [extra-ansible-args]
```

The script loads `.env`, selects the inventory for the given environment, and passes any additional args directly to `ansible-playbook`.

## How GitOps works

After bootstrap, this repo drives all changes:

1. ArgoCD watches the `main` branch of this repository
2. The root `Application` at `k8s-manifests/overlays/{env}/root-app.yaml` points to `k8s-manifests/overlays/{env}/apps/`
3. Each file in `apps/` is an ArgoCD `Application` referencing a Helm chart in `k8s-manifests/infrastructure/charts/`
4. Values are layered: `values/common/` → `values/{env}/` → per-app generated storage values

To deploy a change: commit and push to `main`. ArgoCD syncs automatically (pruning and self-healing enabled).
