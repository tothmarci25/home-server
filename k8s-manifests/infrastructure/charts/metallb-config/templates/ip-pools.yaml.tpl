---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ingress-pool
  namespace: metallb-system
spec:
  addresses:
    - {{ .Values.nginxIngressIP }}/32
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: plex-pool
  namespace: metallb-system
spec:
  addresses:
    - {{ .Values.plexIP }}/32
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: qbittorrent-pool
  namespace: metallb-system
spec:
  addresses:
    - {{ .Values.qbittorrentIP }}/32
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: dnsmasq-pool
  namespace: metallb-system
spec:
  addresses:
    - {{ .Values.dnsmasqIP }}/32
