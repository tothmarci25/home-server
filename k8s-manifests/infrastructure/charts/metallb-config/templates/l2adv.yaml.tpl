apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2
  namespace: metallb-system
spec:
  ipAddressPools:
  {{- range .Values.l2Advertisement.ipAddressPools }}
    - {{ . }}
  {{- end }}
