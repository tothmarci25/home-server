{{- $replicas := .Values.soda.replicas | default 2 -}}
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: soda
  namespace: {{ .Release.Namespace }}
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  serviceName: soda-headless
  replicas: {{ $replicas }}
  selector:
    matchLabels:
      app: soda
  template:
    metadata:
      labels:
        app: soda
    spec:
      serviceAccountName: soda
      # The game never calls the Kubernetes API, and the soda SA has no RBAC
      # bindings — its auto-mounted token is unused dead weight and a liability if
      # the session is ever breached. The secrets-store CSI driver mints its own
      # audience-`vault` token independently, so turning this off does NOT break
      # the Vault basic-auth secret flow.
      automountServiceAccountToken: false
      # The intel-gpu-plugin grants the cgroup device-allow rule for /dev/dri,
      # but the render node (/dev/dri/renderD128) is mode crw-rw---- owned by the
      # host's render group (gid 993); card0 by video (gid 44). The container user
      # (ubuntu) must be a member of those NUMERIC gids or open() returns EPERM
      # ("Failed to open the given device!"). These are HOST gids read via
      # `stat -c %g /dev/dri/*` / `getent group video render` on the node — the
      # container's /etc/group may map the same numbers to different names.
      securityContext:
        supplementalGroups:
        {{- range .Values.soda.gpuGroups }}
          - {{ . }}
        {{- end }}
      containers:
        - name: soda
          image: {{ .Values.soda.image | quote }}
          imagePullPolicy: {{ .Values.soda.imagePullPolicy | default "IfNotPresent" }}
          # Container hardening (modelled on charts/intel-gpu-plugin, which runs a
          # hardened GPU workload). Orthogonal to the pod's supplementalGroups —
          # dropping caps/priv-escalation does NOT affect /dev/dri access.
          # readOnlyRootFilesystem is intentionally NOT set yet: Selkies/Wine/labwc
          # write scratch state outside the PVC and /dev/shm; enable it only after
          # enumerating those paths and backing each with a writable emptyDir.
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            seccompProfile:
              type: RuntimeDefault
          ports:
            - name: web
              containerPort: 8080
          env:
            - name: SELKIES_PORT
              value: "8080"
            - name: SELKIES_PUBLIC
              value: "true"
            - name: SELKIES_ENABLE_HTTPS
              value: "false"
            # SODA caps at 640x480. Disable dynamic resize so the desktop stays
            # pinned (soda-launch.sh calls `selkies-resize 640x480`) instead of
            # snapping to the browser window size and leaving a tiny game window.
            - name: SELKIES_ENABLE_RESIZE
              value: "false"
            # Stream-quality defaults, baked server-side so no per-browser tuning
            # is needed. The client's own defaults are jpeg_quality=60 /
            # paint_over_jpeg_quality=90, which looked soft; pin them to max. For
            # these range-style vars "X-X" is an initial value that also LOCKS it
            # (per `selkies --help`), so the client dashboard can't drift off max.
            - name: SELKIES_ENCODER        # CPU-striped JPEG (what we settled on)
              value: "jpeg"
            - name: SELKIES_JPEG_QUALITY   # UI "Base Quality"; default was 60
              value: "100-100"
            - name: SELKIES_PAINT_OVER_JPEG_QUALITY  # UI "Paintover Quality"
              value: "100-100"
            - name: SELKIES_USE_PAINT_OVER_QUALITY   # high-quality static paint-overs
              value: "true"
            - name: SELKIES_FRAMERATE      # lock 60 FPS
              value: "60-60"
            # --- Kiosk + lockdown (defense in depth; see SODA.md) ---------------
            # Drop the whole LXQt desktop: no panel, no terminal, no file manager,
            # no app launcher — just the display server + Selkies + the game. The
            # base image's entrypoint honours START_LXQT and removes the lxqt s6
            # service when it isn't "true".
            - name: START_LXQT
              value: "false"
            # With LXQt gone, XDG autostart never fires (it's an lxqt-session
            # function), so the game is launched by Selkies' own connect hook
            # instead. soda-launch.sh is idempotent (reconnect won't double-launch).
            - name: SELKIES_RUN_AFTER_CONNECT
              value: "/usr/local/bin/soda-launch.sh"
            # Turn off the websocket "command" channel (runs commands as the
            # session user). The desktop image defaults this to "true" — override.
            - name: SELKIES_COMMAND_ENABLED
              value: "false"
            # No clipboard, file transfer, mic, webcam, or session sharing: a
            # racing game needs none of them, and each is attack surface.
            - name: SELKIES_ENABLE_CLIPBOARD
              value: "false"
            - name: SELKIES_ENABLE_BINARY_CLIPBOARD
              value: "false"
            - name: SELKIES_FILE_TRANSFERS
              value: "none"
            - name: SELKIES_MICROPHONE_ENABLED
              value: "false"
            - name: SELKIES_WEBCAM_ENABLED
              value: "false"
            - name: SELKIES_ENABLE_SHARING
              value: "false"
            # Hide the sidebar entries that would otherwise invite installing
            # apps / browsing files (cosmetic; the real gates are the flags above).
            - name: SELKIES_UI_SIDEBAR_SHOW_APPS
              value: "false"
            - name: SELKIES_UI_SIDEBAR_SHOW_FILES
              value: "false"
            - name: SELKIES_BASIC_AUTH_USER
              value: {{ .Values.soda.basicAuthUser | default "player" | quote }}
            - name: SELKIES_BASIC_AUTH_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: soda-auth
                  key: password
          volumeMounts:
            - name: shared-memory
              mountPath: /dev/shm
            - name: vault-secrets
              mountPath: /mnt/secrets-store
              readOnly: true
            - name: soda-data
              mountPath: /home/ubuntu/soda
          resources:
            requests:
              cpu: {{ .Values.soda.resources.requests.cpu | default "2" | quote }}
              memory: {{ .Values.soda.resources.requests.memory | default "2Gi" | quote }}
            limits:
              memory: {{ .Values.soda.resources.limits.memory | default "4Gi" | quote }}
              # One shared slot on the iGPU (provided by the intel-gpu-plugin
              # DaemonSet, which injects /dev/dri with the correct cgroup rule).
              gpu.intel.com/i915: "1"
      volumes:
        - name: shared-memory
          emptyDir:
            medium: Memory
            sizeLimit: {{ .Values.soda.shmSize | default "2Gi" | quote }}
        - name: vault-secrets
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: soda-vault
  volumeClaimTemplates:
    - metadata:
        name: soda-data
      spec:
        accessModes:
          - ReadWriteOnce
        storageClassName: {{ .Values.soda.storageClassName | default "soda-data-pv" | quote }}
        resources:
          requests:
            storage: {{ .Values.soda.dataSize | default "20Gi" | quote }}
