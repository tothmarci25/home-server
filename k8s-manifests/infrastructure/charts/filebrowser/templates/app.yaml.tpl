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
