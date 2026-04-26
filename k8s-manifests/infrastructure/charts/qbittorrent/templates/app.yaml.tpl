{{- $app := (.Values.apps | default dict).qbittorrent | default dict }}

apiVersion: apps/v1
kind: Deployment
metadata:
  name: qbittorrent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: qbittorrent
  template:
    metadata:
      labels:
        app: qbittorrent
    spec:
      containers:
        - name: qbittorrent
          image: linuxserver/qbittorrent:latest
          ports:
            - name: webui
              containerPort: 8090
            - name: torrenting-tcp
              containerPort: 6887
              protocol: TCP
            - name: torrenting-udp
              containerPort: 6887
              protocol: UDP
          env:
            - name: PUID
              value: "1000"
            - name: PGID
              value: "1000"
            - name: TZ
              value: "Etc/UTC"
            - name: WEBUI_PORT
              value: "8090"
            - name: TORRENTING_PORT
              value: "6887"
          volumeMounts:
            {{- toYaml ($app.extraVolumeMounts | default list) | nindent 12 }}
      volumes:
        {{- toYaml ($app.extraVolumes | default list) | nindent 8 }}
