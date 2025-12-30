{{- $app := (.Values.apps | default dict).plex | default dict }}

apiVersion: apps/v1
kind: Deployment
metadata:
  name: plex
spec:
  replicas: 1
  selector:
    matchLabels:
      app: plex
  template:
    metadata:
      labels:
        app: plex
    spec:
      containers:
        - name: plex
          image: plexinc/pms-docker:latest
          ports:
            - containerPort: 32400
              name: web
          env:
            - name: PLEX_UID
              value: "1000"
            - name: PLEX_GID
              value: "1000"
            - name: CHANGE_CONFIG_DIR_OWNERSHIP
              value: "false"
            - name: TZ
              value: "Etc/UTC"
            - name: ADVERTISE_IP
              value: "https://plex.tothmarci25.com,http://192.168.0.6:32400"
          volumeMounts:
            {{- toYaml ($app.extraVolumeMounts | default list) | nindent 12 }}
      volumes:
        {{- toYaml ($app.extraVolumes | default list) | nindent 8 }}
