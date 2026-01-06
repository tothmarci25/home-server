{{- $app := (.Values.apps | default dict).plex | default dict }}

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
