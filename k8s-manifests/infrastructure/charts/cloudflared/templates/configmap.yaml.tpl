apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-config
  namespace: cloudflared
  annotations:
    argocd.argoproj.io/sync-wave: "2"
data:
  config.yml: |
    # Tunnel ID will be injected from environment variable
    # which comes from Vault secret
    credentials-file: /etc/cloudflared/credentials.json
    ingress:
{{- range .Values.tunnel.ingress }}
  {{- if .hostname }}
      - hostname: {{ .hostname }}
        service: {{ .service }}
  {{- else }}
      - service: {{ .service }}
  {{- end }}
{{- end }}
