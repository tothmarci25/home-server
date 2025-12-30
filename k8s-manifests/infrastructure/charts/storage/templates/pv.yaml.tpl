{{- range .Values.storages }}
apiVersion: v1
kind: PersistentVolume
metadata:
  name: {{ .name }}-pv
spec:
  capacity:
    storage: {{ .size }}
  accessModes:
    - ReadWriteOnce
  storageClassName: {{ .storageClass }}
  persistentVolumeReclaimPolicy: Retain
  local:
    path: {{ .path }}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: {{ .nodeLabel }}
              operator: In
              values:
                - "true"
---
{{- end }}
