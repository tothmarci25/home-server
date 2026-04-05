{{- $app := (.Values.apps | default dict).radarr | default dict }}

apiVersion: apps/v1
kind: Deployment
metadata:
  name: radarr
spec:
  replicas: 1
  selector:
    matchLabels:
      app: radarr
  template:
    metadata:
      labels:
        app: radarr
      annotations:
        pre.hook.backup.velero.io/command: '["/bin/sh", "-c", "kill -SIGSTOP 1"]'
        pre.hook.backup.velero.io/container: radarr
        pre.hook.backup.velero.io/timeout: "30s"
        post.hook.backup.velero.io/command: '["/bin/sh", "-c", "kill -SIGCONT 1"]'
        post.hook.backup.velero.io/container: radarr
        post.hook.backup.velero.io/timeout: "30s"
        backup.velero.io/backup-volumes: radarr-config
    spec:
      containers:
        - name: radarr
          image: linuxserver/radarr:latest
          ports:
            - name: webui
              containerPort: 7878
          env:
            - name: PUID
              value: "1000"
            - name: PGID
              value: "1000"
            - name: TZ
              value: "Etc/UTC"
          volumeMounts:
            {{- toYaml ($app.extraVolumeMounts | default list) | nindent 12 }}
      volumes:
        {{- toYaml ($app.extraVolumes | default list) | nindent 8 }}
