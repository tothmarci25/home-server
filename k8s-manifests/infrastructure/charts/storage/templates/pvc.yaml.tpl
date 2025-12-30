{{ range .Values.storages }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .name }}-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: {{ .storageClass }}
  resources:
    requests:
      storage: {{ .size }}
---
{{ end }}
