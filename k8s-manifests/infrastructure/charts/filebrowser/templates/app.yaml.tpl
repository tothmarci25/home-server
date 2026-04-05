{{- $app := (.Values.apps | default dict).filebrowser | default dict }}

apiVersion: apps/v1
kind: Deployment
metadata:
  name: filebrowser
spec:
  replicas: 1
  selector:
    matchLabels:
      app: filebrowser
  template:
    metadata:
      labels:
        app: filebrowser
      annotations:
        pre.hook.backup.velero.io/command: '["/bin/sh", "-c", "kill -SIGSTOP 1"]'
        pre.hook.backup.velero.io/container: filebrowser
        pre.hook.backup.velero.io/timeout: "30s"
        post.hook.backup.velero.io/command: '["/bin/sh", "-c", "kill -SIGCONT 1"]'
        post.hook.backup.velero.io/container: filebrowser
        post.hook.backup.velero.io/timeout: "30s"
        backup.velero.io/backup-volumes: filebrowser-config
    spec:
      containers:
        - name: filebrowser
          image: filebrowser/filebrowser:latest
          ports:
            - containerPort: 8080
          env:
            - name: PUID
              value: "1000"
            - name: PGID
              value: "1000"
          volumeMounts:
            {{- toYaml ($app.extraVolumeMounts | default list) | nindent 12 }}
      volumes:
        {{- toYaml ($app.extraVolumes | default list) | nindent 8 }}
