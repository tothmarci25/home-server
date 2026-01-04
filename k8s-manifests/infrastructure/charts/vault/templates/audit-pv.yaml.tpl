apiVersion: v1
kind: PersistentVolume
metadata:
  name: vault-audit-pv
spec:
  capacity:
    storage: {{ .Values.audit.storage }}
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: {{ .Values.audit.storageClassName }}
  local:
    path: {{ .Values.audit.localPath }}
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - {{ .Values.nodeName }}
