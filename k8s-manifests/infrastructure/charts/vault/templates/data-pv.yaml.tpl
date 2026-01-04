apiVersion: v1
kind: PersistentVolume
metadata:
  name: vault-data-pv
spec:
  capacity:
    storage: {{ .Values.data.storage }}
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: {{ .Values.data.storageClassName }}
  local:
    path: {{ .Values.data.localPath }}
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - {{ .Values.nodeName }}
