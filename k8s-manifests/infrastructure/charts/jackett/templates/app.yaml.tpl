{{- $app := (.Values.apps | default dict).jackett | default dict }}

apiVersion: apps/v1
kind: Deployment
metadata:
  name: jackett
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jackett
  template:
    metadata:
      labels:
        app: jackett
      annotations:
        pre.hook.backup.velero.io/command: '["/bin/sh", "-c", "kill -SIGSTOP 1"]'
        pre.hook.backup.velero.io/container: jackett
        pre.hook.backup.velero.io/timeout: "30s"
        post.hook.backup.velero.io/command: '["/bin/sh", "-c", "kill -SIGCONT 1"]'
        post.hook.backup.velero.io/container: jackett
        post.hook.backup.velero.io/timeout: "30s"
        backup.velero.io/backup-volumes: jackett-config
    spec:
      containers:
        - name: jackett
          image: linuxserver/jackett:latest
          ports:
            - name: webui
              containerPort: 9117
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
