# Wazuh certificates (task 1.16 part 2, decisions 89 and 90)

Wazuh's indexer, manager (Filebeat) and dashboard authenticate each other with
certificates from Wazuh's own internal CA. They're made **once** on the laptop
and stored by hand in SSM, so the siem host is rebuilt every session with the
same certificates and the browser trusts the CA once.

Nothing secret is in this directory: only `config.yml` (node names and the IP
in the SAN). The generated files live outside the repo in
`~/mailbridge-pki/wazuh/`, next to the VPN CA, and `.gitignore` refuses
`*.pem` and `*.key` anywhere in the repo.

## What exists

| SSM parameter | Type | File | Used by |
|---|---|---|---|
| `/siem/certs/root-ca-cert` | String | `root-ca.pem` | every component, and the browser (trust once) |
| `/siem/certs/admin-cert`, `admin-key` | String, SecureString | `admin.pem`, `admin-key.pem` | `securityadmin` on siem (CN=admin is the indexer's `admin_dn`) |
| `/siem/certs/indexer-cert`, `indexer-key` | String, SecureString | `node-1.pem`, `node-1-key.pem` | indexer REST (9200) and transport (9300) |
| `/siem/certs/server-cert`, `server-key` | String, SecureString | `wazuh-1.pem`, `wazuh-1-key.pem` | Filebeat on the manager, to the indexer |
| `/siem/certs/dashboard-cert`, `dashboard-key` | String, SecureString | `dashboard.pem`, `dashboard-key.pem` | dashboard: browser-facing 443 and its client to the indexer |
| `/wazuh-ca/key` | SecureString | `root-ca.key.enc` (AES-256, passphrase) | nobody at run time; backup for re-signing |

siem's instance role reads `/siem/*` only, so it can present certificates but
can never sign one. The CA key's passphrase is kept off AWS (password manager).

All certificates: RSA 2048, SHA-256, SAN `IP:10.0.5.10`, issued 2026-11-05,
expire **2036-11-02** (the tool's fixed 3650 days). Renew before then with the
procedure below; 1.23's certificate-expiry alert covers the dashboard.

## How they were made

Tool: `https://packages.wazuh.com/4.14/wazuh-certs-tool.sh`, downloaded
2026-11-05, SHA-256
`5c3135baaef34ca25a9f0fa631e65312871934533fd061442d50d9d70f23b759`.
Wazuh publishes no checksum or signature for it, so it was read before running:
bash around `openssl`, no network calls when generating.

```sh
W=~/mailbridge-pki/wazuh; mkdir -p "$W"; chmod 700 "$W"; cd "$W"
curl -fsSLO https://packages.wazuh.com/4.14/wazuh-certs-tool.sh
sha256sum wazuh-certs-tool.sh          # must match the hash above, or re-review
cp <repo>/siem-certs/config.yml .      # the tool reads config.yml next to itself
umask 077
bash ./wazuh-certs-tool.sh -A -tmp "$W/tmp-certs"   # keys never touch /tmp
```

Then the CA key is encrypted and the plaintext removed:

```sh
openssl rand -base64 32 > ca-passphrase             # move into the password manager
openssl pkey -in wazuh-certificates/root-ca.key -aes256 \
  -passout file:ca-passphrase -out root-ca.key.enc
shred -u wazuh-certificates/root-ca.key
```

Each file is stored with
`aws ssm put-parameter --type <String|SecureString> --name <name> --value file://<file>`
(certificates `String` and keys `SecureString`, like `/vpn/*`; no `--overwrite`,
so an existing value is never replaced by accident).

## Verify

```sh
cd ~/mailbridge-pki/wazuh/wazuh-certificates
for c in admin node-1 wazuh-1 dashboard; do openssl verify -CAfile root-ca.pem $c.pem; done
# expect four lines "<name>.pem: OK"
openssl x509 -in node-1.pem -noout -ext subjectAltName -enddate
# expect "IP Address:10.0.5.10" and "notAfter=Nov  2 ... 2036 GMT"

# SSM holds exactly the laptop's bytes (jq -j: --output text adds a newline)
aws ssm get-parameter --name /siem/certs/indexer-key --with-decryption --output json \
  | jq -j .Parameter.Value | sha256sum; sha256sum < node-1-key.pem
# expect the same hash twice

# siem's role can read the host files and not the CA key
aws iam simulate-principal-policy --policy-source-arn <siem role ARN> \
  --action-names ssm:GetParameter \
  --resource-arns <arn>/siem/certs/admin-key <arn>/wazuh-ca/key \
  --query 'EvaluationResults[].ResourceSpecificResults[].[EvalResourceName,EvalResourceDecision]'
# expect allowed, implicitDeny
```

In zsh, write `${A}:parameter`, not `$A:parameter`: `:p` and `:r` after a bare
variable are history modifiers and silently change the ARN.

## Re-signing one component (renewal or a lost key)

```sh
cd ~/mailbridge-pki/wazuh; umask 077
openssl pkey -in root-ca.key.enc -passin file:ca-passphrase -out tmp-ca.key
mv wazuh-certificates wazuh-certificates.old     # the tool refuses a non-empty output dir
bash ./wazuh-certs-tool.sh -wd wazuh-certificates.old/root-ca.pem tmp-ca.key -tmp "$PWD/tmp-certs"
shred -u tmp-ca.key wazuh-certificates/root-ca.key   # the tool copies the CA key into its output
ls wazuh-certificates                                  # expect root-ca.pem plus the new pair only
# then: put-parameter --overwrite for that component's two values, and restart it on siem
```

`-wi`, `-ws`, `-wd` and `-a` re-sign the indexer, server, dashboard and admin
certificates. The root CA itself expires on the same day; replacing it means
re-signing everything and trusting the new CA in the browser again.
