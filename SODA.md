# SODA — browser-playable retro racing game

Runs the 1997 Windows game **SODA Off-Road Racing** (`offroad.exe`) in the cluster,
streamed to a web browser via **Selkies** (browser desktop + streaming) and **Wine**.
Internal / LAN-only, deployed to **production** via ArgoCD. Supports 2-player TCP/IP
racing (one pod per player; `soda-0` is the host).

---

## Architecture at a glance

| Piece | What it is |
|-------|-----------|
| Namespace | `soda` (isolated, like vault/cloudflared) |
| Workload | **StatefulSet** `soda`, one pod per player (`soda-0`, `soda-1`, …). `soda-0` is the fixed multiplayer host. |
| Streaming | Selkies, WebSocket transport, port `8080` inside the pod. One desktop per pod, locked to a single-app **kiosk** (no LXQt). |
| Routing | Per-pod ClusterIP Service `soda-N-web` (selects `statefulset.kubernetes.io/pod-name`, so exactly one pod — no round-robin). |
| Pod-to-pod | Headless Service `soda-headless` → stable DNS `soda-0.soda-headless.soda.svc` (the multiplayer host address). |
| Ingress | Own Ingress **in the `soda` namespace**. TLS terminates here. |
| Hostnames | `racing.home` → `soda-0`; `racing-1.home` → `soda-0`, `racing-2.home` → `soda-1`, … |
| Secret | Selkies basic-auth password from Vault (`kv/soda/auth`) via secrets-store CSI → K8s Secret `soda-auth`. User is `player`. |
| Storage | Per-pod node-local PV (`storageClassName: soda-data-pv`, `/mnt/ssd/soda/<ordinal>`). Holds the game + Wine prefix. **Not backed up** (disposable). |
| GPU | Intel iGPU with hardware H.264 encode. The **intel-gpu-plugin** DaemonSet advertises `gpu.intel.com/i915` and injects `/dev/dri`; the pod sets `supplementalGroups: [44, 993]` (host `video`/`render` GIDs) so the render node is openable. Falls back to llvmpipe if absent. |

### Files

```
k8s-manifests/infrastructure/charts/soda/
  templates/            # namespace, SA, SecretProviderClass, PV tpl,
                        #   StatefulSet tpl, Services, Ingress
  image/
    Dockerfile          # Selkies base + 32-bit Wine + VA driver + winetricks
    soda-launch.sh      # kiosk launcher (connect hook): prefix + DirectPlay + game
k8s-manifests/infrastructure/values/production/soda-values.yaml   # prod overrides (image tag, gpuGroups, storage)
k8s-manifests/overlays/production/apps/soda.yaml                  # ArgoCD Application
```

Touches elsewhere: `vault-bootstrap` (soda policy + k8s-auth role), `charts/dnsmasq`
(`racing(-N).home` DNS), `ansible/roles/storage` (`/mnt/ssd/soda/<N>` dirs).

---

## Deploy on a fresh cluster

Everything in git is GitOps (commit → ArgoCD syncs). These are the **manual
out-of-band prerequisites** only — secrets, a cert, and node-local dirs that we don't
put in git. Do them before (or alongside) the first sync.

### 1. Node storage directories

```bash
# on the server — one dir per replica:
sudo mkdir -p /mnt/ssd/soda/0 /mnt/ssd/soda/1
```
(Or run `./run_playbook.sh production ansible/playbooks/generate_storages.yaml`.)

### 2. Vault secret — the Selkies login password

```bash
# requires a logged-in vault CLI (see vault-commands.txt)
vault kv put kv/soda/auth password=<LONG-RANDOM-PASSWORD>
```
The Vault policy + role (`soda`) are created by the vault-bootstrap job on sync.
Username is fixed to `player`.

### 3. Self-signed TLS cert — REQUIRED

Selkies refuses to run over plain HTTP ("requires a secure connection"). TLS
terminates at the Ingress with a self-signed cert covering every racing hostname:

```bash
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /tmp/soda-tls.key -out /tmp/soda-tls.crt -days 3650 \
  -subj '/CN=racing.home' \
  -addext 'subjectAltName=DNS:racing.home,DNS:racing-1.home,DNS:racing-2.home'

kubectl create secret tls soda-tls -n soda \
  --cert=/tmp/soda-tls.crt --key=/tmp/soda-tls.key

rm -f /tmp/soda-tls.key /tmp/soda-tls.crt
```
Adding more players? Regenerate with the extra `racing-N.home` SANs and re-apply.

### 4. Confirm node GPU GIDs

```bash
# on the server — should be video=44, render=993:
getent group video render
```
If they differ, update `soda.gpuGroups` in `soda-values.yaml`.

### 5. Sync in ArgoCD, then check

```bash
kubectl -n soda rollout status statefulset/soda
kubectl -n soda get pods,svc,pvc,ingress,secretproviderclass
```

On first launch each pod self-provisions on its PVC: builds the 32-bit Wine prefix,
installs **native DirectPlay** (`winetricks directplay` — required for multiplayer;
needs pod egress to download the DirectX redist once), then launches the game. This
is one-time, guarded by a `.directplay-installed` marker.

> **Game files.** The game binary is seeded to each pod's PVC at
> `/home/ubuntu/soda/game/soda_off_road_racing/` (e.g. `kubectl -n soda cp`). This is
> not in git. Each new replica needs its copy seeded the same way.

---

## Playing

1. Browse **`https://racing-1.home`** (note **https** — HTTP redirects).
2. **Self-signed cert warning is expected.** Click through (in Chrome, type
   `thisisunsafe` on the warning page), or trust the cert:
   ```bash
   kubectl -n soda get secret soda-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > ~/soda-racing.crt
   sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/soda-racing.crt
   ```
3. Log in: user `player`, password from step 2 above. The game launches automatically.
4. **Multiplayer:** on `soda-0` (via `racing-1.home`) host a TCP/IP game; on `soda-1`
   (via `racing-2.home`) Join and type the host as **`soda-0.soda-headless.soda.svc`**.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Black screen, "requires a secure connection (HTTPS)" | No TLS. Do prereq #3 and browse `https://`. |
| Pods stuck `Pending` | PVs didn't bind. Check `/mnt/ssd/soda/<N>` dirs exist (prereq #1) and `kubectl -n soda get pvc,pv \| grep soda`. |
| Pod won't start, CSI mount error | Vault secret missing (`kv/soda/auth`) or the `soda` Vault role not created yet. Check `kubectl -n vault logs job/vault-bootstrap`. |
| `racing.home` doesn't resolve | dnsmasq entry missing / client not on the cluster DNS. Entries in `charts/dnsmasq/templates/config.yaml`. |
| Game window never appears after login | The connect hook (`SELKIES_RUN_AFTER_CONNECT`) didn't finish — on a fresh PVC it builds the Wine prefix + installs DirectPlay first (can take a minute, needs internet egress). Check `kubectl -n soda exec soda-0 -- cat /home/ubuntu/soda/prefix/.directplay-installed` (marker present = done) and the pod logs. |
| Multiplayer: host's session never shows, or "can't create session" | Native DirectPlay missing in that prefix (Wine's built-in `dpwsockx` is broadcast-only and can't host). Re-run `winetricks -q directplay` in the prefix with `W_CACHE=/home/ubuntu/soda/.cache/winetricks` (PVC-backed cache) and pod egress. Join with the DNS host `soda-0.soda-headless.soda.svc`, not broadcast. |
| GPU not used (llvmpipe), `vainfo` → "Failed to open the given device!" | The pod user must be in host GIDs `44`/`993` via `supplementalGroups` for `/dev/dri`. Verify `kubectl -n soda exec soda-0 -- id` lists 44 and 993. Working: `vainfo` shows `Intel iHD driver` + a `VAEntrypointEncSliceLP` line. |
| GPU `allocatable: 0`, pods `FailedScheduling: Insufficient gpu.intel.com/i915` | intel-gpu-plugin crashed on `too many open files` (node inotify exhausted). Fix in `k8s_prepare` role (`/etc/sysctl.d/k8s.conf`); live: `sudo sysctl -w fs.inotify.max_user_instances=8192` then `kubectl -n intel-gpu-plugin rollout restart ds/intel-gpu-plugin`. |
| StatefulSet permanently **OutOfSync**, pod `securityContext` is `{}` | A typo'd field was dropped silently. The field is `supplementalGroups` (not `supplementaryGroups`). Verify `kubectl -n soda get statefulset soda -o jsonpath='{.spec.template.spec.securityContext}'`. |
| Game looks soft/blurry when stretched | 640×480 upscaled to a non-integer size smooths. Quality is already maxed server-side. In the Selkies dashboard (`Ctrl+Shift+M`) turn **Anti-aliasing OFF**; for crisp pixels size the window to an integer multiple (e.g. 1280×960 = 2×). This softness is the hard ceiling for a 640×480 title. |

---

## Notes

- **Kiosk / hardening.** `START_LXQT=false` drops the desktop; the game launches via
  `SELKIES_RUN_AFTER_CONNECT=/usr/local/bin/soda-launch.sh` (idempotent). Clipboard,
  file transfer, mic/webcam, sharing and the command channel are all disabled; the
  container runs with `drop: [ALL]`, no priv-escalation, `RuntimeDefault` seccomp, and
  `automountServiceAccountToken: false`. The pod's `supplementalGroups: [44, 993]`
  (needed for the iGPU) is orthogonal to those drops.
- **Not yet done:** `readOnlyRootFilesystem` (needs scratch-path enumeration first);
  NetworkPolicy egress fencing (plain Flannel has no policy controller — silently
  ignored).
- **Remote play:** done (Phase 1) — remote WebRTC streaming over Cloudflare Access +
  a hardened self-hosted coturn relay. Transport is **WebRTC** (not the LAN WebSocket
  path). See [REMOTE-ACCESS.md](REMOTE-ACCESS.md) for the model, the shared-secret
  wiring, the manual Cloudflare DNS / Access / router-forward steps, and the DDoS
  threat-model scope.
