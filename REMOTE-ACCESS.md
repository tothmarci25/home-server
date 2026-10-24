# Remote access (Cloudflare Access + hardened coturn)

How self-hosted apps in this cluster are exposed for remote access, and the full
model behind SODA's remote WebRTC play. The generalizable pattern ("put an app
behind Cloudflare Access") is at the end.

## The model in one line

**Auth answers *who* · the tunnel answers *how HTTP/signaling arrives* · coturn
answers *how WebRTC UDP media is relayed*.** Three independent trust checks
(Cloudflare identity → Selkies password → valid ephemeral TURN credential) and
two physically different network paths (TCP/HTTP via Cloudflare; UDP media via the
router forward + coturn).

```
   Browser ──HTTPS──▶ Cloudflare Access ──▶ cloudflared tunnel ──▶ nginx ──▶ Selkies :8080
 (racing.tothmarci25.com)  [WHO?]            (signaling, TCP/WS)          [basic-auth → game]
      │
      └── WebRTC media (UDP, SRTP) ──▶ home router UDP forward ──▶ coturn ⇄ Selkies pod
                                       (the one open inbound hole; NOT via the tunnel)
```

## Why two paths (the key fact)

Cloudflare's tunnel carries HTTP/TCP (including the WebSocket used for WebRTC
*signaling*) and **cannot carry WebRTC's UDP media**. So media takes its own path:
the browser opens a UDP connection to `turn.tothmarci25.com:3478`, which hits the
home router's UDP port-forward → coturn, which relays the media to/from the Selkies
pod. This is why coturn and the router forward exist, and why `turn.tothmarci25.com`
is an **unproxied** A-record (Cloudflare can't proxy the UDP, so it points at the
real home WAN IP, kept current by the `cloudflare_ddns` role).

## The flow, start to finish

1. **Identity (WHO).** Browser hits `racing.tothmarci25.com`; Cloudflare Access
   challenges for login (Google/GitHub/OTP) and checks the allowlist. Not on it →
   rejected at the edge; the cluster never sees the request.
2. **Signaling (via tunnel).** Authed HTTP/WS flows browser → Cloudflare →
   cloudflared → nginx → Selkies `:8080`. Selkies basic-auth prompts (second,
   independent layer). The WebRTC handshake (SDP offer/answer + ICE candidates +
   the ephemeral TURN credential) happens over this WebSocket. No inbound TCP port
   is opened — cloudflared dials out.
3. **Media (via coturn, UDP).** WebRTC tries direct/STUN first; between two home
   networks it usually falls back to the TURN relay. The browser opens UDP to
   `turn.tothmarci25.com:3478` → router forward → coturn, which validates the
   ephemeral credential and relays media ⇄ the Selkies pod. **WebRTC-only — there is
   no WebSocket fallback**, so a black screen means the UDP path is broken (check the
   router forward and the shared secret).

## The shared-secret wiring (one Vault secret, two consumers)

coturn runs in `use-auth-secret` mode with `static-auth-secret=S`. Selkies, given
`SELKIES_TURN_SHARED_SECRET=S`, computes a **time-limited** credential per browser:

```
username = <expiry-unix-ts>
password = base64(HMAC-SHA1(S, username))
```

and puts it in the WebRTC offer. coturn validates the HMAC against the same `S`.
**The secret never reaches the browser** — only the short-lived derived credential
does (TTL ~minutes). Both charts read the **same** Vault key:

- Vault path: `kv/coturn/auth`, key `shared-secret`.
- coturn: SecretProviderClass `coturn-vault` → Secret `coturn-auth` → injected as
  `--static-auth-secret` at runtime (never in a ConfigMap).
- soda: SecretProviderClass `soda-vault` → Secret `soda-turn` → env
  `SELKIES_TURN_SHARED_SECRET`.

If these two ever diverge, every credential is rejected and media never flows.

## How coturn relays to the right pod (the allocation model)

coturn **never chooses or looks up a pod.** Per session, each Selkies pod sends
coturn a TURN **Allocate** request (authed with the ephemeral credential) and gets
back a dedicated **relay port** from the narrow range; coturn binds that port to the
pod's socket (5-tuple) and advertises `turn.tothmarci25.com:<port>` as the pod's ICE
candidate. The browser is recorded as that allocation's permitted peer. coturn then
blindly relays whatever hits `<port>` back to that pod, and vice-versa. **The pod
reaches out first and claims the port; the port IS the session's identity.**

So **one coturn serves all player pods** — a 2-player game is two independent
allocations through the *same* coturn / same `turn` subdomain / same UDP forward
(e.g. soda-0 ⇄ :49200 ⇄ player 1, soda-1 ⇄ :49201 ⇄ player 2). **Do NOT create a
per-pod or per-player TURN subdomain.** This is also why the pod-scoped
`allowed-peer-ip` hardening is sufficient: it constrains the only side of an
allocation coturn would ever accept.

## coturn hardening

Config: `charts/coturn/templates/configmap.yaml` (turnserver.conf). All non-optional:

- **Ephemeral HMAC auth** (`use-auth-secret`): no valid, unexpired credential → no
  allocation → no relay. A scanner hitting `:3478` gets nothing.
- **LAN-blind peer policy**: `denied-peer-ip` for all private ranges + loopback +
  link-local/cloud-metadata (`169.254/16`) + IPv6 ULA/link-local, plus
  `no-multicast-peers` / `no-loopback-peers`. `allowed-peer-ip` re-allows ONLY the
  Selkies pod CIDR. coturn can **never** be aimed at the home LAN (no Vault/Plex/
  k8s-API pivot).
- **Narrow relay port range** (`min-port`–`max-port`, ~11 ports): only these are
  forwarded on the router, vs coturn's default 49152–65535. 2 players need ~2.
- **Quotas** (`total-quota`, `user-quota`, `max-bps`, `bps-capacity`): bound session
  count and bandwidth so a flood can't exhaust the home uplink or the node. Tune
  `bps-capacity` to the measured uplink.
- **Surface reduction**: UDP-only listener (`no-tcp`, `no-tls`, `no-dtls`),
  `no-tcp-relay`, `no-cli`, `stale-nonce`, `fingerprint`.
- **Container**: non-root, `allowPrivilegeEscalation:false`, `capabilities.drop:[ALL]`,
  `seccompProfile:RuntimeDefault`, `automountServiceAccountToken:false`.

## DDoS / threat-model scope (accepted residual risk)

Self-hosted coturn was chosen over Cloudflare Realtime TURN (free <1000 GB/mo, which
would hide the home IP and absorb volumetric DDoS at the edge) to keep everything
in-cluster/GitOps with no external dependency. Consequences, knowingly accepted:

- **Amplification / reflection (coturn used to attack others): MITIGATED** — the HMAC
  auth gate (no credential = no relay), `denied-peer-ip` (never relays to arbitrary/
  LAN peers), and quotas (bounded emission) mean you will **not** become a DDoS
  *source*.
- **Volumetric DDoS against the home line: NOT mitigated, and not mitigable
  self-hosted.** The `turn` A-record is **unproxied** (the tunnel is TCP-only and
  cannot carry WebRTC UDP), so it exposes the **real home WAN IP** with no upstream
  absorption — a flood saturates the uplink *before* coturn can drop it. Judged
  low-risk for a private, undisclosed 2-player game.
- **Exposure hygiene**: UDP-only listener, narrow relay range, keep the `turn`
  hostname undisclosed; optionally use a non-standard listener port to dodge blanket
  `:3478` scans.
- **Escape hatch**: if remote play ever becomes higher-value or is attacked, switch
  to Cloudflare Realtime TURN (Selkies supports `SELKIES_TURN_REST_URI` /
  `SELKIES_TURN_REST_API_KEY` for dynamic creds) — that removes the open port and the
  IP exposure entirely.

## Manual checklist — enabling remote play end to end

Everything in `k8s-manifests/` is GitOps (commit → ArgoCD syncs coturn + the soda
WebRTC/public-host changes). The steps below are the **out-of-band** pieces that are
NOT in git — do them in order. `[ ]` = one-time per cluster unless noted.

**1. Vault secret — the shared HMAC secret** (read by both coturn and soda; if these
ever differ, every TURN credential is rejected and media never flows):
```bash
# requires a logged-in vault CLI (see vault-commands.txt)
vault kv put kv/coturn/auth shared-secret="$(openssl rand -base64 32)"
```

**2. Commit + let ArgoCD sync** the repo-side changes (coturn chart, soda WebRTC env,
soda-public Ingress, cloudflared hosts, metallb coturn-pool, vault-bootstrap role).
Then confirm coturn came up and got its LoadBalancer IP:
```bash
kubectl -n coturn get pods,svc           # svc EXTERNAL-IP should be 192.168.0.9
kubectl -n coturn logs deploy/coturn      # no auth/secret errors
```

**3. Cloudflare DNS** (dashboard):
- `racing.tothmarci25.com` → tunnel (**proxied** CNAME, like `plex`).
- `racing-2.tothmarci25.com` → tunnel (**proxied** CNAME).
- `turn.tothmarci25.com` → **unproxied A-record** (grey cloud). Create it once with
  any placeholder IP — the `cloudflare_ddns` role now manages it and will correct it
  to the real home WAN IP within 10 min (verified: it rewrote a `1.2.4.3` placeholder
  to the live WAN IP). To push it immediately instead of waiting:
  ```bash
  ./run_playbook.sh production ansible/playbooks/setup_cloudflare_ddns.yaml
  ```
  (The record must exist first — the role updates existing records, it does not create
  them. `turn` MUST stay unproxied: the tunnel is TCP-only and cannot carry WebRTC UDP.)

**4. Cloudflare Access** (Zero Trust dashboard): one Access application whose hostnames
cover **both** `racing.tothmarci25.com` and `racing-2.tothmarci25.com`, with a policy
allowing the specific player identities (free tier ≤50 users). This is the identity
gate — without it the hosts are open to anyone.

**5. Home-router UDP forward** (HARD dependency — there is no WebSocket fallback, so if
this is wrong the screen stays black): forward **`3478/udp`** *and* the relay range
**`49200–49210/udp`** to the coturn LoadBalancer IP **`192.168.0.9`**.

**6. Verify from genuinely off-LAN** (phone hotspot, not home Wi-Fi) — see *Verifying*
below. Expect a **relay** ICE candidate in `chrome://webrtc-internals` and the game
streaming. For 2-player, player 1 on `racing` (soda-0) hosts, player 2 on `racing-2`
(soda-1) joins at `soda-0.soda-headless.soda.svc`.

> Adding more remote players later: add another `racing-N` CNAME (step 3), cover it in
> the Access app (step 4), add the `publicHostN` + a `racing-N` tunnel ingress entry in
> the repo, and bump the coturn relay range by ~1 port if you exceed the current 11.

## Verifying

- `chrome://webrtc-internals`: the active ICE candidate should be a **relay** candidate
  via coturn, with media flowing. A black screen = UDP path broken → re-check the
  router forward and that the Vault shared secret matches on both sides.
- 2-player: player 1 on `racing.tothmarci25.com` (soda-0) hosts the race; player 2 on
  `racing-2.tothmarci25.com` (soda-1) joins at `soda-0.soda-headless.soda.svc`. The
  pod-to-pod DirectPlay channel stays internal to Flannel and is unaffected by the
  public hosts.

## Generalization: putting another app behind Cloudflare Access

No cluster redeploy needed:

1. Add `- hostname: <app>.tothmarci25.com` to `tunnel.ingress` in
   `values/production/cloudflared-values.yaml` (routes to nginx automatically).
2. Ensure the app has an Ingress rule for that hostname (plain HTTP backend; TLS is
   terminated by Cloudflare at the edge).
3. Add a Cloudflare DNS record (proxied CNAME → tunnel) and a Cloudflare Access
   application + allowlist policy for the hostname.

coturn is only needed for WebRTC-UDP media; plain web apps need just steps 1–3.
