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
| Longhorn      | Distributed block storage |
| Velero        | Kubernetes backups (CSI snapshots) |
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
- `app_storage_map` — per-app volume and mount configuration. Config volumes reference the per-app Longhorn PVCs (e.g. `plex-config`); data volumes reference the raw local PVCs (e.g. `ssd-pvc`).
- `longhorn_pvcs` — list of Longhorn-backed PVCs to create for app config volumes, with name and size.
- `vault_disk_name` — name of the disk (from `usb_disks`) used for Vault storage. Leave empty to skip Vault directory and values generation.

```yaml
usb_disks:
  - name: ssd
    uuid: "your-disk-uuid-here"
    size: 2000Gi
    storageClass: local-ssd

longhorn_pvcs:
  - name: plex-config
    size: 20Gi

vault_disk_name: "ssd"
```

```bash
./run_playbook.sh staging ansible/playbooks/generate_storages.yaml
```

This mounts USB disks by UUID, creates local PersistentVolumes, labels the node with storage availability, generates the Helm values files consumed by ArgoCD (including the Longhorn PVC definitions in `longhornPvcs`), and writes `generated-values.yaml`. If `vault_disk_name` is set, it also creates the `vault-data` and `vault-audit` directories on the disk and generates `vault-pv-values.yaml`.

### 4. Configure IP addresses

All service IPs are configured in a single network values file per environment:

- `k8s-manifests/infrastructure/values/staging/network-values.yaml`
- `k8s-manifests/infrastructure/values/production/network-values.yaml`

Set each IP to an address on your local network that does not overlap with your DHCP range:

```yaml
nginxIngressIP: "192.168.1.100"  # nginx-ingress entry point; used by DNSMasq and CloudFlared
plexIP: "192.168.1.101"          # Plex direct-access IP
qbittorrentIP: "192.168.1.102"   # qBittorrent direct-access IP
dnsmasqIP: "192.168.1.103"       # DNSMasq IP
```

MetalLB creates a dedicated IP pool for each service (`ingress-pool`, `plex-pool`, `qbittorrent-pool`, `dnsmasq-pool`) from these values.

### 5. Bootstrap ArgoCD

```bash
./run_playbook.sh staging ansible/playbooks/bootstrap_argocd.yaml
```

This installs Helm, deploys ArgoCD via Helm chart (v9.3.7), and applies the root ArgoCD `Application` manifest. ArgoCD then syncs all other applications from this repo automatically.

The initial ArgoCD admin password is printed at the end of the playbook output.

### 6. Initialize Vault

After Vault is deployed by ArgoCD, you have two paths:

#### 6a. Fresh initialization (first time only)

Run init commands from a shell inside the Vault pod:

```bash
kubectl exec -it -n vault statefulset/vault -- sh
```

```bash
vault operator init          # Save the 5 unseal keys and root token securely
vault operator unseal        # Run 3 times with 3 different unseal keys
vault login <root-token>

vault secrets enable -version=2 kv

# CloudFlared tunnel credentials
vault kv put kv/cloudflared \
  credentials.json=@credentials.json \
  tunnel-id="your-tunnel-id"

# Vault snapshot R2 credentials (for daily Raft snapshots to Cloudflare R2)
vault kv put kv/vault/r2-snapshot-credentials \
  access_key_id="<r2-access-key-id>" \
  secret_access_key="<r2-secret-access-key>"

# Velero backup R2 credentials (for nightly Kubernetes backups to Cloudflare R2)
cat > /tmp/velero-cloud.txt << 'EOF'
[default]
aws_access_key_id = <YOUR_R2_ACCESS_KEY_ID>
aws_secret_access_key = <YOUR_R2_SECRET_ACCESS_KEY>
EOF
vault kv put kv/velero/r2-credentials cloud=@/tmp/velero-cloud.txt
rm /tmp/velero-cloud.txt

# Longhorn backup R2 credentials (for volume backup data to Cloudflare R2)
vault kv put kv/longhorn/backup-credentials \
  AWS_ACCESS_KEY_ID="<YOUR_R2_ACCESS_KEY_ID>" \
  AWS_SECRET_ACCESS_KEY="<YOUR_R2_SECRET_ACCESS_KEY>"

# Create a short-lived bootstrap token for the vault-bootstrap job
vault token create -ttl=15m
kubectl -n vault create secret generic vault-bootstrap-token \
  --from-literal=token=<token>
```

#### 6b. Restore from snapshot (reinstall)

If you are reinstalling the cluster and have a Raft snapshot in Cloudflare R2, restore it instead of re-initializing from scratch. This recovers all secrets (including the CloudFlared credentials) without re-entering them manually.

> **Note:** The snapshot is taken daily at 02:30 UTC by the `vault-snapshot` CronJob and stored as `vault-snapshots/vault.snap` in your R2 bucket (only the latest snapshot is kept).

**1. Download the snapshot from R2 to your local machine:**

```bash
AWS_ACCESS_KEY_ID=<r2-access-key-id> AWS_SECRET_ACCESS_KEY=<r2-secret-access-key> \
  aws s3 cp "s3://<r2-bucket>/vault-snapshots/vault.snap" ./vault.snap \
  --endpoint-url https://<r2-account-id>.r2.cloudflarestorage.com \
  --region auto
```

**2. Copy the snapshot to the server using the `copy_files` role:**

Add an entry to `ansible/roles/copy_files/defaults/main.yaml`:

```yaml
copy_files_list:
  - src: /path/to/local/vault.snap
    dest: /tmp/
    mode: "0600"
```

Then run the playbook:

```bash
./run_playbook.sh production ansible/playbooks/copy_files.yaml
```

**3. Copy the snapshot into the Vault pod and restore:**

```bash
kubectl cp /tmp/vault.snap vault/vault-0:/tmp/vault.snap
```

```bash
kubectl exec -it -n vault statefulset/vault -- sh
```

```bash
# Initialize Vault (required before restore; discard these keys after)
vault operator init

# Unseal with the throwaway keys just generated (needed to accept the restore)
vault operator unseal   # run 3 times with 3 different keys from the init above

# Log in with the throwaway root token
vault login <throwaway-root-token>

# Restore the snapshot — use -force because the throwaway init keys differ from the snapshot's keys
vault operator raft snapshot restore -force /tmp/vault.snap
```

After the restore completes, Vault will be sealed again. Unseal using the **original unseal keys** from before the reinstall (the snapshot preserves the original encryption keys):

```bash
vault operator unseal   # run 3 times with 3 different original unseal keys
vault login <original-root-token>
```

All secrets are now restored. Skip re-running the `kv put` commands below and proceed directly to creating the bootstrap token.

---

### 7. Sync vault-bootstrap and applications

Manually sync the vault-bootstrap job via the ArgoCD CLI or UI:

```bash
argocd app sync vault-bootstrap
```

Once the job completes, sync the cloudflared, longhorn, and velero applications:

```bash
argocd app sync cloudflared longhorn velero
```

> **Note:** Longhorn must be running before Velero, as Velero uses the Longhorn CSI driver for volume snapshots. The sync waves enforce this order automatically (Longhorn: wave 1, Velero: wave 2), but if syncing manually ensure Longhorn pods are healthy first.
>
> **Backup architecture:** Longhorn handles volume data backups natively to R2 (incremental, block-level). Velero orchestrates the backup schedule and stores PVC metadata. When Velero triggers a VolumeSnapshot, Longhorn's CSI driver creates a backup to R2 via the configured backup target. Restore is done through `velero restore` which recreates PVCs and triggers Longhorn to pull data back from R2.

### 8. (Optional) Setup WireGuard VPN

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
