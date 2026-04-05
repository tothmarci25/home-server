{{- $app := (.Values.apps | default dict).sonarr | default dict }}

apiVersion: apps/v1
kind: Deployment
metadata:
  name: sonarr
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sonarr
  template:
    metadata:
      labels:
        app: sonarr
      annotations:
        pre.hook.backup.velero.io/command: '["/bin/sh", "-c", "kill -SIGSTOP 1"]'
        pre.hook.backup.velero.io/container: sonarr
        pre.hook.backup.velero.io/timeout: "30s"
        post.hook.backup.velero.io/command: '["/bin/sh", "-c", "kill -SIGCONT 1"]'
        post.hook.backup.velero.io/container: sonarr
        post.hook.backup.velero.io/timeout: "30s"
        backup.velero.io/backup-volumes: sonarr-config
    spec:
      containers:
        - name: sonarr
          image: linuxserver/sonarr:latest
          ports:
            - name: webui
              containerPort: 8989
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
