apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-snapshot
  namespace: vault
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: vault-snapshot
  namespace: vault
spec:
  schedule: "30 2 * * *"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          serviceAccountName: vault-snapshot
          volumes:
            - name: vault-token
              projected:
                sources:
                  - serviceAccountToken:
                      path: token
                      expirationSeconds: 7200
                      audience: vault
          containers:
            - name: snapshot
              image: hashicorp/vault:1.15.6
              volumeMounts:
                - name: vault-token
                  mountPath: /var/run/secrets/vault
                  readOnly: true
              command:
                - sh
                - -c
                - |
                  set -e

                  apk add --no-cache aws-cli

                  echo "Authenticating to Vault via Kubernetes auth..."
                  JWT=$(cat /var/run/secrets/vault/token)
                  VAULT_TOKEN=$(vault write -field=token auth/kubernetes/login \
                    role=vault-snapshot \
                    jwt="$JWT")
                  export VAULT_TOKEN

                  echo "Fetching R2 credentials from Vault..."
                  AWS_ACCESS_KEY_ID=$(vault kv get -field=access_key_id kv/vault/r2-snapshot-credentials)
                  AWS_SECRET_ACCESS_KEY=$(vault kv get -field=secret_access_key kv/vault/r2-snapshot-credentials)
                  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

                  TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
                  SNAPSHOT_FILE="/tmp/${TIMESTAMP}.snap"

                  echo "Taking Raft snapshot..."
                  vault operator raft snapshot save "$SNAPSHOT_FILE"

                  echo "Uploading snapshot to R2..."
                  aws s3 cp "$SNAPSHOT_FILE" \
                    "s3://{{ .Values.snapshot.r2Bucket }}/vault-snapshots/${TIMESTAMP}.snap" \
                    --endpoint-url https://{{ .Values.snapshot.r2AccountId }}.r2.cloudflarestorage.com \
                    --region auto

                  echo "Snapshot uploaded: vault-snapshots/${TIMESTAMP}.snap"
              env:
                - name: VAULT_ADDR
                  value: http://vault.vault.svc:8200
