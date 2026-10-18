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
      securityContext:
        # Host GIDs for /dev/dri access (video, render). Read at implement time
        # via `getent group video render` on the node; these are the measured
        # values for tothmarci25-homeserver. Best-effort GPU passthrough — if
        # the iGPU does not come through, Selkies falls back to llvmpipe.
        supplementaryGroups:
          {{- toYaml (.Values.soda.gpuGroups | default (list 44 993)) | nindent 10 }}
      containers:
        - name: soda
          image: {{ .Values.soda.image | quote }}
          imagePullPolicy: {{ .Values.soda.imagePullPolicy | default "IfNotPresent" }}
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
            - name: dev-dri
              mountPath: /dev/dri
            - name: soda-data
              mountPath: /home/ubuntu/soda
          resources:
            requests:
              cpu: {{ .Values.soda.resources.requests.cpu | default "2" | quote }}
              memory: {{ .Values.soda.resources.requests.memory | default "2Gi" | quote }}
            limits:
              memory: {{ .Values.soda.resources.limits.memory | default "4Gi" | quote }}
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
        - name: dev-dri
          hostPath:
            path: /dev/dri
            type: Directory
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
