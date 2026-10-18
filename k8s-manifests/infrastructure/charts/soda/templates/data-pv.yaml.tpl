{{- $replicas := int (.Values.soda.replicas | default 2) -}}
{{- $sc := .Values.soda.storageClassName | default "soda-data-pv" -}}
{{- $base := .Values.soda.localPathBase | default "/mnt/ssd/soda" -}}
{{- $size := .Values.soda.dataSize | default "20Gi" -}}
{{- $node := .Values.soda.nodeName | default "tothmarci25-homeserver" -}}
# Pre-provisioned node-local PVs, one per StatefulSet ordinal. Dedicated
# storageClassName (soda-data-pv) so nothing else binds them. NOT Longhorn and
# NO velero.io/backup label => excluded from Velero backups (per user: game
# data must not be backed up). The StatefulSet's volumeClaimTemplates requests
# this storageClassName; claim soda-data-soda-N binds PV soda-data-pv-N.
{{- range $i := until $replicas }}
{{- if gt $i 0 }}
---
{{- end }}
apiVersion: v1
kind: PersistentVolume
metadata:
  name: soda-data-pv-{{ $i }}
  annotations:
    argocd.argoproj.io/sync-wave: "4"
spec:
  capacity:
    storage: {{ $size | quote }}
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: {{ $sc | quote }}
  local:
    path: {{ printf "%s/%d" $base $i | quote }}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - {{ $node }}
{{- end }}
