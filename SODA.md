# SODA — browser-playable retro racing game

Runs the 1997 Windows game **SODA Off-Road Racing** (`offroad.exe`) in the cluster,
streamed to a web browser via **Selkies** (browser desktop + streaming) and **Wine**.
Internal / LAN-only, deployed to **production** via ArgoCD.

> Status: **Step A complete** — stock Selkies desktop streams in the browser over
> HTTPS. Wine + the game itself come in Steps B–D (see the plan).

---

## Architecture at a glance

| Piece | What it is |
|-------|-----------|
| Namespace | `soda` (isolated, like vault/cloudflared) |
| Workload | **StatefulSet** `soda`, one pod per player (`soda-0`, `soda-1`, …). `soda-0` is the fixed multiplayer host. |
| Streaming | Selkies, WebSocket transport, port `8080` inside the pod. One desktop per pod. |
| Routing | Per-pod ClusterIP Service `soda-N-web` (selects `statefulset.kubernetes.io/pod-name`, so exactly one pod — no round-robin). |
| Pod-to-pod | Headless Service `soda-headless` → stable DNS `soda-0.soda-headless.soda.svc` (used by the game's LAN multiplayer in Step D). |
| Ingress | Own Ingress **in the `soda` namespace** (the shared `default` Ingress can't cross namespaces). TLS terminates here. |
| Hostnames | `racing.home` → `soda-0`; `racing-1.home` → `soda-0`, `racing-2.home` → `soda-1`, … |
| Secret | Selkies basic-auth password from Vault (`kv/soda/auth`) via secrets-store CSI → synced to K8s Secret `soda-auth`. |
| Storage | Per-pod node-local PV (`storageClassName: soda-data-pv`, `/mnt/ssd/soda/<ordinal>`). **Outside Longhorn, not backed up by Velero** (game data is disposable). |
| GPU | Best-effort iGPU passthrough: `/dev/dri` hostPath + `supplementalGroups: [44, 993]` (host `video`/`render` GIDs). Falls back to llvmpipe software rendering. |

### Files

```
k8s-manifests/infrastructure/charts/soda/
  Chart.yaml
  values.yaml                      # chart defaults
  templates/
    namespace.yaml
    service-account.yaml           # SA `soda`, bound by the Vault role
    secret-provider.yaml           # SecretProviderClass soda-vault -> Secret soda-auth
    data-pv.yaml.tpl               # one node-local PV per replica
    statefulset.yaml.tpl           # the StatefulSet (one pod per player)
    svc.yaml                       # soda-headless + per-pod soda-N-web Services
    ingress.yaml                   # racing(-N).home, TLS, websocket timeouts

k8s-manifests/infrastructure/values/production/soda-values.yaml   # prod overrides
k8s-manifests/overlays/production/apps/soda.yaml                   # ArgoCD Application
```

Edited elsewhere:
- `infrastructure/base/vault-bootstrap/policies-configmap.yaml` + `job.yaml` — soda read policy + kubernetes-auth role.
- `infrastructure/charts/dnsmasq/templates/config.yaml` — `racing.home`, `racing-1/2.home` DNS.
- `ansible/roles/storage/{defaults/main.yaml,tasks/mount.yaml}` (+ `main_prod.yaml.example`) — create `/mnt/ssd/soda/<N>` dirs.

---

## Deploy from scratch (what was needed for Step A)

These are the **manual, out-of-band prerequisites** (secrets and a self-signed cert —
things we don't put in git). Everything else is GitOps: commit and ArgoCD syncs it.

### 1. Node GPU GIDs (already confirmed: `video`=44, `render`=993)

```bash
# on the server:
getent group video render
# -> video:x:44:  render:x:993:
```
Set these in `soda-values.yaml` under `soda.gpuGroups` if they ever differ.

### 2. Node storage directories

Created declaratively by the storage role, but on an existing node create them once:
```bash
# on the server:
sudo mkdir -p /mnt/ssd/soda/0 /mnt/ssd/soda/1
```
(Or re-run: `./run_playbook.sh production ansible/playbooks/generate_storages.yaml`)

### 3. Vault secret — Selkies login password

```bash
# requires a logged-in vault CLI (see vault-commands.txt)
vault kv put kv/soda/auth password=<LONG-RANDOM-PASSWORD>
```
The Vault policy + role (`soda`) are created by the vault-bootstrap job on sync.
Username is fixed to `player` (set via `soda.basicAuthUser`).

### 4. Self-signed TLS cert — REQUIRED (Selkies needs a secure browser context)

Selkies refuses to run over plain HTTP ("This application requires a secure
connection (HTTPS)"). TLS terminates at the Ingress with a self-signed cert.

```bash
# generate a cert covering all racing hostnames (10-year validity):
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /tmp/soda-tls.key -out /tmp/soda-tls.crt -days 3650 \
  -subj '/CN=racing.home' \
  -addext 'subjectAltName=DNS:racing.home,DNS:racing-1.home,DNS:racing-2.home'

# create the TLS secret in the soda namespace:
kubectl create secret tls soda-tls -n soda \
  --cert=/tmp/soda-tls.crt --key=/tmp/soda-tls.key

# clean up:
rm -f /tmp/soda-tls.key /tmp/soda-tls.crt
```

> If you add more players (more replicas), regenerate the cert with the extra
> `racing-N.home` SANs and recreate the secret (`kubectl create secret tls ... --dry-run=client -o yaml | kubectl apply -f -`).

### 5. Sync in ArgoCD

Commit the manifests → ArgoCD syncs the `soda` Application. Then:
```bash
kubectl -n soda rollout status statefulset/soda
kubectl -n soda get pods,svc,pvc,ingress,secretproviderclass
```

---

## Accessing it

1. Browse **`https://racing-1.home`** (note **https** — HTTP redirects to it).
2. **Self-signed cert warning is expected** (`ERR_CERT_AUTHORITY_INVALID`). Either:
   - click **Advanced → Proceed** (in Chrome, you can type `thisisunsafe` on the warning page), or
   - trust the cert permanently (macOS):
     ```bash
     kubectl -n soda get secret soda-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > ~/soda-racing.crt
     sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/soda-racing.crt
     ```
3. Log in: user `player`, password = the Vault value from step 3.
4. The Selkies desktop streams. (`racing.home` and `racing-1.home` both reach `soda-0`.)

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Black screen, "requires a secure connection (HTTPS)" | No TLS. Do prereq #4 and browse `https://`. |
| `ERR_CERT_AUTHORITY_INVALID` | Normal for self-signed. Proceed anyway, or trust the cert (see Accessing #2). |
| StatefulSet permanently **OutOfSync** in ArgoCD, pod `securityContext` is `{}` | A dropped/unknown field. We hit this with a typo — the field is `supplementalGroups`, **not** `supplementaryGroups`. K8s silently drops unknown fields. Verify: `kubectl -n soda get statefulset soda -o jsonpath='{.spec.template.spec.securityContext}'`. |
| Pods stuck `Pending` | PVs didn't bind. Check `/mnt/ssd/soda/<N>` dirs exist (prereq #2) and `kubectl -n soda get pvc,pv \| grep soda`. Binding matches on `storageClassName`=`soda-data-pv` + `ReadWriteOnce` + size. |
| Pod won't start, CSI mount error | Vault secret missing (`kv/soda/auth`) or the `soda` Vault role/policy not yet created. Check the vault-bootstrap job ran: `kubectl -n vault logs job/vault-bootstrap`. |
| `racing.home` doesn't resolve | dnsmasq entry missing / client not using the cluster DNS. Entries are in `charts/dnsmasq/templates/config.yaml`. |
| GPU not used (llvmpipe) | Verify in-pod (Step C): `vainfo`, `glxinfo \| grep renderer`. Needs the Mesa/Intel VA driver in the image. Acceptable fallback for this game. |

---

## Verify GPU GIDs actually landed

```bash
kubectl -n soda get statefulset soda -o jsonpath='{.spec.template.spec.securityContext}{"\n"}'
# want: {"supplementalGroups":[44,993]}

kubectl -n soda exec soda-0 -- id
# groups should include 44 and 993
```

---

## Roadmap

- **A ✅ — Stock Selkies desktop, reachable over HTTPS.** (done)
- **B — Wine-enabled custom image** (`FROM` the Selkies base + 32-bit Wine + audio + Mesa/VA driver).
- **C — Install + auto-launch SODA** per pod (`SELKIES_RUN_AFTER_CONNECT`), single-player first.
- **D — 2-player TCP/IP racing** (`soda-0` hosts, `soda-1` joins `soda-0.soda-headless.soda.svc`).

Full plan: `~/.claude/plans/sparkling-sleeping-petal.md`.
