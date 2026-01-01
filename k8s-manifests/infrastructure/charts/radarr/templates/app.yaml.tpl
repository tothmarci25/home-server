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
    spec:
      containers:
        - name: sonarr
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
