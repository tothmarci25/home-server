{{- range .Values.ipAddressPools }}
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: {{ .name }}
  namespace: metallb-system
spec:
  addresses:
  {{- range .addresses }}
  - {{ . }}
  {{- end }}
{{- end }}
