# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a GitOps-based home server infrastructure project. It uses Ansible to provision and configure a single-node Kubernetes cluster, and ArgoCD to continuously deploy self-hosted applications from this repository.

**Stack:**
- Ansible for cluster provisioning and initial setup
- Kubernetes 1.35 with containerd runtime and Flannel CNI
- ArgoCD (Helm chart 9.3.7) for GitOps deployments
- Kustomize overlays per environment (staging/production)
- Helm charts for each application

## Running Playbooks

All playbooks are run via `run_playbook.sh`, which loads credentials from `.env` and selects the correct inventory:

```bash
./run_playbook.sh [staging|production] <playbook-path> [extra-ansible-args]
```

Copy `.env.example` to `.env` and populate: `ANSIBLE_SSH_KEY`, `SUDO_PASSWORD`, `SERVER_IP`, `SERVER_SSH_PORT`, `SERVER_USER`.

**Available playbooks:**
```bash
./run_playbook.sh staging ansible/playbooks/k8s_install.yaml       # Provision K8s cluster
./run_playbook.sh staging ansible/playbooks/bootstrap_argocd.yaml  # Install ArgoCD + bootstrap GitOps
./run_playbook.sh staging ansible/playbooks/generate_storages.yaml # Generate storage Helm values
./run_playbook.sh staging ansible/playbooks/setup_wireguard.yaml   # Configure WireGuard VPN
```

## Architecture

### Ansible Roles

| Role | Purpose |
|------|---------|
| `k8s_prepare` | OS-level prep: swap off, kernel modules, containerd, kubeadm/kubelet/kubectl install |
| `k8s_init` | `kubeadm init`, Flannel CNI, removes control-plane taint for single-node scheduling |
| `argocd_init` | Helm-installs ArgoCD, retrieves initial credentials, applies root App manifest |
| `storage` | Mounts USB disks by UUID, creates local PVs, labels nodes, generates Helm values |
| `setup_wireguard` | WireGuard server config with NAT masquerading, UFW rules |

### GitOps / Kubernetes Structure

ArgoCD tracks `main` branch, syncing from `k8s-manifests/overlays/{staging,production}/apps`.

```
k8s-manifests/
  infrastructure/
    base/          # Base nginx-ingress, MetalLB resources
    charts/        # Helm charts: plex, radarr, sonarr, jackett, qbittorrent,
                   #   filebrowser, vault, cloudflared, dnsmasq, metallb, storage
    values/        # Helm values split by: common/, staging/, production/
  overlays/
    staging/       # Kustomize patches + app manifests for staging
    production/    # Kustomize patches + app manifests for production
```

### Environments

- **Staging**: Targets `ubuntu-ansible-test` (typically a local Multipass VM)
- **Production**: Targets `tothmarci25-homeserver` (physical home server)

Storage defaults per environment live in `ansible/roles/storage/defaults/main.yaml` and are overridden by inventory group vars or role vars for each environment.

### Storage

USB disks are mounted by UUID at `/mnt/{disk_name}`. The `storage` role generates aggregated Helm values files for PersistentVolume declarations and app-specific volume mount subpaths. Apps using storage: Plex, Radarr, Sonarr, Jackett, qBittorrent, FileBrowser.

Storage classes used: `local-ssd`, `local-usb`.

## Key Files

- `run_playbook.sh` — main entrypoint for all Ansible operations
- `ansible/ansible.cfg` — sets default inventory to staging, roles path, SSH options
- `ansible/requirements.yaml` — requires `kubernetes.core` collection
- `ansible/roles/storage/defaults/main.yaml` — disk UUID mappings and app volume config
- `k8s-manifests/infrastructure/charts/` — one directory per deployed application
- `vault-commands.txt` — reference commands for Vault init and CloudFlared secrets
- `useful-commands.txt` — Multipass SSH key setup reference
