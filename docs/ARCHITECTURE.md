# Secure Mailbridge Lab — AWS Architecture

Private-access deployment of Mailbridge (unified Gmail/Outlook inbox) inside a segmented AWS VPC.
Only entry point: OpenVPN. Purpose: run the app securely, attack it, detect attacks, document findings.

Region: `eu-central-1` (Frankfurt) · Single AZ (lab; multi-AZ deliberately skipped for cost)
Deploy: Terraform (infra) + Ansible (config) · Teardown: `terraform destroy` when not in use

---

## 1. Diagram

```
                         Internet
                            │  UDP 1194 only (OpenVPN)
                            │  TCP 443 closed — opened only for outside-attack test windows
                            │
  VPC 10.0.0.0/16  ┌────────▼──────────────────────────────────────┐
                   │ PUBLIC 10.0.1.0/24          route: 0/0 → IGW  │
                   │ fw-ips  10.0.1.10  (t3.small, Elastic IP)     │
                   │  • OpenVPN server (tun0)                      │
                   │      users 10.8.0.0/24 · admins 10.8.1.0/24   │
                   │  • nftables firewall + NAT for private nets   │
                   │  • Suricata inline IPS on decrypted tun0      │
                   │  • Unbound DNS (pushed to VPN clients)        │
                   └────────┬──────────────────────────────────────┘
                            │ all private subnets: 0/0 → fw-ips ENI
                   ┌────────▼───────────────┐
                   │ DMZ 10.0.2.0/24        │
                   │ proxy 10.0.2.10        │ Nginx (TLS, rate limit) + ModSecurity v3 / OWASP CRS
                   └────────┬───────────────┘
                   ┌────────▼───────────────┐
                   │ APP 10.0.3.0/24        │
                   │ app   10.0.3.10        │ Mailbridge (Docker) → egress 443 to Gmail/Graph APIs
                   └────────┬───────────────┘
                   ┌────────▼───────────────┐
                   │ DATA 10.0.4.0/24       │
                   │ db    10.0.4.10        │ PostgreSQL · nightly pg_dump → S3 (gateway endpoint)
                   └────────────────────────┘
                   ┌────────────────────────┐
                   │ MGMT 10.0.5.0/24       │ reachable only from admin VPN pool 10.8.1.0/24
                   │ siem  10.0.5.10        │ Wazuh (manager + indexer + dashboard)
                   │ mon   10.0.5.20        │ Prometheus + Grafana + Alertmanager
                   └────────────────────────┘
                   ┌────────────────────────┐
                   │ VULN 10.0.6.0/24       │ own route table; reached only from proxy, through fw-ips
                   │ vuln 10.0.6.10         │ OWASP Juice Shop (Docker), deliberately vulnerable target
                   └────────────────────────┘

  Outside AWS: GitHub Actions → Jest/Playwright, k6, Trivy, SonarCloud, ZAP baseline
```

---

## 2. Subnets & routing

| Subnet | CIDR | Internet route | Notes |
|---|---|---|---|
| public | 10.0.1.0/24 | → Internet Gateway | only fw-ips lives here |
| dmz | 10.0.2.0/24 | → fw-ips ENI | no direct internet |
| app | 10.0.3.0/24 | → fw-ips ENI | egress for Gmail/Graph APIs via fw |
| data | 10.0.4.0/24 | → fw-ips ENI | + S3 **gateway endpoint** (free) for backups, added in Tier 2 (T2.3) |
| mgmt | 10.0.5.0/24 | → fw-ips ENI | admin-only |
| vuln | 10.0.6.0/24 | → fw-ips ENI | Juice Shop only, own route table; no general egress (decisions 67, 68) |

- **VPN pools are routed, not NATed:** VPC route `10.8.0.0/16 → fw-ips ENI`. Nginx, Wazuh and Suricata see the real VPN client IP, so every event is attributable to a device certificate.
- fw-ips: **source/destination check disabled**. Its ENI is a standalone resource, so routes can target it before the instance exists.
- Tier 1 uses one private route table for dmz, app, data and mgmt. `data` gets its own table when the S3 endpoint is added.
- **East-west inspection for Juice Shop (decision 68):** the private route table has `10.0.6.0/24 → fw-ips ENI` and the vuln table has `0.0.0.0/0`, `10.0.2.0/24` and `10.0.5.0/24 → fw-ips ENI`. These are more specific than the `local` route, which AWS allows when the destination is a whole subnet CIDR. So proxy→Juice Shop traffic is plain HTTP through fw-ips and Suricata. Mailbridge's proxy→app traffic keeps the direct `local` route, so mail never reaches Suricata's logs. Every path to the vuln subnet must be symmetric: the private table is shared with mgmt, so siem's replies to the Juice Shop agent go through fw-ips, and the agent's requests must too, or fw-ips sees half a connection and drops it. Security groups on these paths must name IP addresses, not other groups.
- No NAT Gateway, no ALB, no interface endpoints (all bill hourly).

---

## 3. Instances

| Name | Type | Disk (gp3, encrypted) | Role | Tier |
|---|---|---|---|---|
| fw-ips | t3.small | 20 GB | OpenVPN, nftables, NAT, Suricata, Unbound | 1 |
| proxy | t3.micro | 10 GB | Nginx + ModSecurity v3 (engine and connector from Ubuntu, OWASP CRS 4.25.0 pinned by SHA-256, decisions 58, 63), lego (ACME client, decision 59) | 1 |
| app | t3.small | 20 GB | Mailbridge in Docker | 1 |
| db | t3.micro | 20 GB | PostgreSQL | 1 |
| siem | t3.large (was t3.medium, decisions 87, 99) | 20 GB, plus a 20 GB data volume from `persistent` (decision 88) | Wazuh 4.14.9 all-in-one: manager, indexer, Filebeat, dashboard (decisions 85, 86) | 1 |
| vuln | t3.small | 10 GB | OWASP Juice Shop in Docker, from its own ECR repository by digest; exists only with `vuln_enabled` (decisions 67, 69, 74) | 1 (Phase 2) |
| mon | t3.small | 20 GB, plus a 10 GB data volume in `persistent` (decision 109) | Prometheus and Alertmanager from pinned release tarballs, Grafana from its pinned apt repository (decision 108); alerts to a Discord webhook from SSM (decision 110). Prometheus 3.13 LTS and Alertmanager 0.34.2 on 127.0.0.1 only, Alertmanager's cluster port off (decisions 114, 116, 119); Grafana 13.2.5 (decision 117) on 10.0.5.20:3000 with TLS 1.3 and a certificate from the Wazuh root CA (decision 113), admin password from `/mon/*`, set at the first start (decisions 112, 118). Moved into Tier 1, decision 84 | 1 |

All instances: IMDSv2 required · SSM agent (admin access; Ansible uses SSH tunnelled through SSM to sshd on loopback, so port 22 is never open to any network) · unattended security updates · apt over HTTPS (regional Ubuntu mirror, port 80 stays closed) · Wazuh agent · node_exporter.

- fw-ips: runs Ubuntu 24.04 LTS (official Canonical AMI, x86_64).
- fw-ips: its Elastic IP belongs to the `lab` stack and exists only during a session. Clients connect to `vpn.<domain>` (TTL 60), which `lab` updates on each apply.
- app: pulls the Mailbridge image from ECR with its instance role, pinned by digest (`image@sha256:...`). The `mailbridge` repository is in `persistent`, with immutable tags, scanning on push and a lifecycle policy (decision 53).
- proxy: lego (the ACME client) authenticates to Route 53 with its instance role; no stored DNS credentials (decision 59).
- vuln: the container runs with `--cap-drop ALL`, `no-new-privileges`, memory and pids limits, its image's non-root user, no Docker socket, and a DNS server address that routes nowhere. The host's `DOCKER-USER` chain drops (and logs) every new connection from the container network, so SSRF or RCE in the container can't open anything outward. IMDS hop limit 1 keeps the container away from IMDS. The host never contacts Docker Hub (decision 69).

---

## 4. Security groups (stateful, least privilege)

| SG | Inbound | From |
|---|---|---|
| sg-fw | UDP 1194 | 0.0.0.0/0 (or home IP if static) |
| | all (to be routed/NATed) | 10.0.0.0/16 |
| | TCP 443 | 0.0.0.0/0 — **test windows only** |
| sg-proxy | TCP 443 | 10.8.0.0/22 (VPN pools) |
| | TCP 443 | 10.0.5.20/32 (mon's blackbox probe, decision 84) |
| sg-app | TCP 3000 | sg-proxy |
| sg-db | TCP 5432 | sg-app |
| sg-siem | TCP 1514, 1515 (agents) | 10.0.0.0/16 |
| | TCP 443 (dashboard) | 10.8.1.0/24 (admin pool) |
| sg-mon | TCP 3000 (Grafana) | 10.8.1.0/24 |
| sg-vuln | TCP 3000 | 10.0.2.10/32 (proxy, by IP: decision 68) |
| | TCP 9100 | 10.0.5.20/32 (mon, by IP: the path crosses fw-ips) |
| sg-proxy | TCP 8443 | Marko's public IP /32 — **Juice Shop test windows only** (decision 72) |
| all | TCP 9100 (node_exporter), 9187 (postgres_exporter on db) | sg-mon |

mon's scrape and probe rules are built with the exporters in 1.23: 9100 in 3a (the rows above, sg-mon egress to each scraped group and to 10.0.1.10, and an nftables input rule on fw-ips; decision 120), 9187 in 3b (sg-db from sg-mon, data NACL 108/109; postgres_exporter logs in by peer authentication, decision 124) and 443 to proxy in 3c; Grafana's row, sg-mon's egress and the mgmt NACL's 112/115 are built in 1.22 (decision 111).

**Egress (explicit, stateful replies need no rule):**

| SG | Outbound | To |
|---|---|---|
| sg-fw | all | 0.0.0.0/0 (forwarded traffic; nftables applies the policy) |
| sg-proxy, sg-app, sg-db, sg-siem, sg-mon | TCP 443, UDP 123 | 0.0.0.0/0 (through fw-ips) |
| | TCP/UDP 53 | 10.0.1.10/32 (Unbound) |
| sg-proxy, sg-app, sg-db, sg-mon | TCP 1514, 1515 | sg-siem |
| sg-proxy | TCP 3000 | sg-app |
| sg-app | TCP 5432 | sg-db |
| sg-proxy | TCP 3000 | 10.0.6.10/32 (Juice Shop, by IP) |
| sg-vuln | TCP 443, UDP 123 | 0.0.0.0/0 (through fw-ips, logged; used for SSM, ECR and S3 image layers, not destination-filtered by name) |
| | TCP 1514, 1515 | 10.0.5.10/32 (siem, by IP: the path crosses fw-ips) |

The VPC default security group has no rules.

Second layer: Network ACLs per subnet mirroring the same flows. Third layer: nftables on fw-ips.

**Network ACLs (stateless, one per subnet, first match wins, default deny).** `eph` is TCP/UDP 1024–65535.

| Subnet | Inbound | Outbound |
|---|---|---|
| public | 100 UDP 1194 from 0.0.0.0/0 · 110 all from 10.0.0.0/16 · 120 TCP eph from 0.0.0.0/0 · 130 UDP eph from 0.0.0.0/0 | 100 all to 10.0.0.0/16 · 110 TCP 443 to 0.0.0.0/0 · 120 UDP 123 to 0.0.0.0/0 · 130 UDP eph to 0.0.0.0/0 |
| dmz | 100 TCP 443 from 10.8.0.0/22 · 106 TCP 9100 from 10.0.5.20/32 · 107 deny TCP 9100 from 0.0.0.0/0 · 110 TCP eph from 0.0.0.0/0 · 120 UDP eph from 0.0.0.0/0 | 100 TCP 3000 to 10.0.3.0/24 · baseline · 150 agents · 160 TCP eph to 10.8.0.0/22 · 170 TCP eph to 10.0.5.20/32 |
| app | 100 TCP 3000 from 10.0.2.0/24 · 105 deny TCP 3000 from 0.0.0.0/0 · 106 TCP 9100 from 10.0.5.20/32 · 107 deny TCP 9100 from 0.0.0.0/0 · 110 TCP eph from 0.0.0.0/0 · 120 UDP eph from 0.0.0.0/0 | 100 TCP 5432 to 10.0.4.0/24 · baseline · 150 agents · 160 TCP eph to 10.0.2.0/24 · 170 TCP eph to 10.0.5.20/32 |
| data | 100 TCP 5432 from 10.0.3.0/24 · 105 deny TCP 5432 from 0.0.0.0/0 · 106 TCP 9100 from 10.0.5.20/32 · 107 deny TCP 9100 from 0.0.0.0/0 · 108 TCP 9187 from 10.0.5.20/32 · 109 deny TCP 9187 from 0.0.0.0/0 · 110 TCP eph from 0.0.0.0/0 · 120 UDP eph from 0.0.0.0/0 | baseline · 150 agents · 160 TCP eph to 10.0.3.0/24 · 170 TCP eph to 10.0.5.20/32 |
| mgmt | 100 TCP 1514–1515 from 10.0.0.0/16 · 105 deny TCP 1514–1515 from 0.0.0.0/0 · 110 TCP 443 from 10.8.1.0/24 · 112 TCP 3000 from 10.8.1.0/24 · 115 deny TCP 3000 from 0.0.0.0/0 · 120 TCP eph from 0.0.0.0/0 · 130 UDP eph from 0.0.0.0/0 | baseline · 160 TCP eph to 10.0.0.0/16 · 170 TCP eph to 10.8.1.0/24 |

Baseline outbound: 110 TCP 443 to 0.0.0.0/0 · 120 UDP 123 to 0.0.0.0/0 · 130 UDP 53 and 140 TCP 53 to 10.0.1.10/32. Agents: TCP 1514–1515 to 10.0.5.0/24. A 443 test window also needs inbound TCP 443 and outbound TCP eph to 0.0.0.0/0 on public.

**Juice Shop additions (decisions 67, 68, 72):**

| Subnet | Inbound | Outbound |
|---|---|---|
| vuln (new) | 100 TCP 3000 from 10.0.2.0/24 · 105 deny TCP 3000 from 0.0.0.0/0 · 110 TCP eph from 0.0.0.0/0 · 120 UDP eph from 0.0.0.0/0 | baseline · 150 agents · 160 TCP eph to 10.0.2.0/24 |
| dmz (added) | 105 TCP 443 from 10.0.5.20/32 (mon's probe, decision 84) · window only: TCP 8443 from Marko's /32 | 105 TCP 3000 to 10.0.6.0/24 · window only: TCP eph to Marko's /32 |

The vuln subnet has no rule to data, app or mgmt, so db, Mailbridge and Wazuh's dashboard are refused at its NACL as well as at its security group and on fw-ips. A Juice Shop window also needs inbound TCP 443 from Marko's /32 on public.

**nftables on fw-ips (core rules):** fw-ips has one interface, so rules separate internet from VPC traffic by address. NAT applies only to private subnets going to non-VPC addresses, never to VPN pools.
- `tun0` user pool (10.8.0.0/24) → only `10.0.2.10:443`
- `tun0` admin pool (10.8.1.0/24) → proxy:443 + mgmt subnet
- private subnets → internet: TCP 443 (+ DNS via Unbound, NTP) only, logged
- to fw-ips itself: UDP 1194, DHCP replies, DNS to 10.0.1.10 from private subnets and VPN pools, ping from the admin pool only; `output` stays open
- everything else: drop + log → Wazuh
- forwarded `tun0` traffic → NFQUEUE → Suricata (inline, can drop), in a separate chain after the firewall rules, failing closed
- Juice Shop (decisions 67, 68, 72), written by Marko in 2.9: proxy 10.0.2.10 → 10.0.6.10:3000 accepted and queued to Suricata; the vuln subnet is **not** in the private-subnet set, so it gets only explicit TCP 443 and UDP 123 to the internet (logged `FW-EGRESS`), TCP 1514–1515 to siem 10.0.5.10, and nothing else to any VPC address (dropped and logged); during a window, internet TCP 443 from Marko's /32 is DNATed to 10.0.2.10:8443 and queued to Suricata

---

## 5. VPN (OpenVPN)

- Own PKI with easy-rsa · **one certificate per device** · revocation via CRL
- **Offline CA:** the CA and all signing stay on Marko's laptop, outside the repo, with the key passphrase-protected. fw-ips holds only `ca.crt`, its server cert and key, the CRL and the `tls-crypt` key. The encrypted CA key is backed up to SSM under `/vpn/`, which no instance role can read. fw-ips pulls its five files from `/vpn/fw-ips/*` with its own instance role, so the values never pass through the admin laptop or Ansible output (decision 39). A CRL update needs no OpenVPN restart.
- Per-client config (`client-config-dir`): user certs → dynamic pool in 10.8.0.0/24, admin cert → fixed address in 10.8.1.0/24. `ccd-exclusive` is off, so attribution of user IPs comes from OpenVPN connection logs in Wazuh
- Hardening: `tls-crypt`, `data-ciphers AES-256-GCM`, `tls-version-min 1.3`, `crl-verify`, `user nobody`
- Pushed: routes to 10.0.2.0/24 and 10.0.1.10/32 (users) or + 10.0.5.0/24 (admins), DNS 10.0.1.10
- Client profiles use `remote vpn.<domain> 1194 udp`, so they survive rebuilds
- Client: `sudo openvpn --config marko-laptop.ovpn` → `https://mail.<domain>`
- A separate **attacker** device certificate gets a user-pool address (10.8.0.x). Attacks come from it, never from the admin certificate, so logs separate attack traffic from administration (decision 73).

---

## 6. DNS & TLS

- Unbound on fw-ips (10.0.1.10): private record `mail.<domain> → 10.0.2.10`, forwards everything else to AmazonProvidedDNS (10.0.0.2). The name resolves only inside the VPN. Unbound serves VPN clients; private hosts keep AmazonProvidedDNS, which security groups and NACLs don't filter (known gap, tested in scenario 2.2). VPN DNS ends at fw-ips, so Suricata doesn't see it. Unbound doesn't validate DNSSEC, because AmazonProvidedDNS returns no signatures.
- lego (one pinned static binary, verified by SHA-256, decision 59) obtains a Let's Encrypt cert via **DNS-01 challenge** using the proxy instance role — no public exposure and no stored API token. Nginx serves it; the role installs a systemd timer that runs `lego renew` and reloads Nginx after a renewal.
- Nginx on proxy accepts TLS 1.3 only, sends HSTS (short `max-age` while on staging; Nginx is the only layer that sets it, and the app's own header is hidden, decision 62) and hides its version; no OCSP stapling, because Let's Encrypt no longer runs OCSP (decision 61).
- ModSecurity on proxy blocks from the first deploy at CRS paranoia level 1 with the default anomaly thresholds (decisions 64, 65). CRS 4.25.0 is the newest release Ubuntu 24.04's engine (3.0.12) can load; only JSON request bodies are accepted (decision 63). Local rules run before the CRS in `exclusions-before.conf`: the profile photo field is checked against the exact data-URL shape the app accepts, and only then skipped by the attack rules. The audit log keeps parts `ABFHZ` (no bodies) for flagged transactions and 5xx, root only (decision 66).
- Nginx on proxy rate-limits per client address before the app: 20 requests/s with burst 50 everywhere, and 6 per minute with burst 5 for POSTs to the sign-in, registration, password reset and password change paths. Over the limit gets `429`, logged at `error` for Wazuh. The app keeps its own 15-minute and per-account counters (decisions 77, 78).
- **Staging certificates while building and rebuilding; switch to production certs once the setup is stable** (avoids Let's Encrypt rate limits).
- DNS provider: **Route 53** public hosted zone in the `persistent` stack. `<domain>` is a subdomain of a domain Marko already owns, delegated by adding NS records for that subdomain at the parent's DNS provider. The parent domain stays where it is, and the real name stays out of this public repo.
- Public records: `_acme-challenge.mail.<domain>` (TXT, lego) and `vpn.<domain>` (A, TTL 60, written by `lab`). `mail.<domain>` is never public.
- Juice Shop (decisions 70, 72): Unbound adds `vuln.<domain> → 10.0.2.10`. proxy serves it with its **own** certificate (not a SAN on mail's), from a templated `lego-renew@<name>` service per name, with the decision 60 condition extended to `_acme-challenge.vuln.<domain>`. During a window, a public `vuln.<domain>` A record points at the Elastic IP, and fw-ips forwards to a **separate listener on 10.0.2.10:8443** that has only a handshake-refusing default server and the Juice Shop server. `mail.<domain>` has no server block on 8443, so it can't be reached from outside even by asking for its name.
- OAuth redirects `https://mail.<domain>/accounts/callback/gmail` and `https://mail.<domain>/accounts/callback/outlook` (the app's own routes) work because the redirect happens in the browser, which is inside the tunnel.
- Google/Microsoft OAuth apps stay in **testing mode, test accounts only**.

---

## 7. Secrets & IAM

- SSM Parameter Store (`/siem/*`): the Wazuh indexer and API users' passwords, generated by `persistent` into write-only SecureString values (decision 89), and under `/siem/certs/*` the Wazuh CA certificate and the admin, indexer, server and dashboard certificates (String) and keys (SecureString), made once on the laptop with `wazuh-certs-tool` from `siem-certs/config.yml` and stored by hand. The Wazuh CA key is never under `/siem/`: it stays on the laptop in `~/mailbridge-pki/wazuh/`, encrypted with a passphrase kept off AWS, and its backup is `/wazuh-ca/key`, which no instance role can read (decision 90)
- SSM Parameter Store (SecureString, `/mailbridge/*`): DB owner and runtime passwords (decision 54), session secret, token encryption key (decision 55), OAuth client secrets (1.19)
- ECR repository `juice-shop` in `persistent`, separate from `mailbridge`: immutable tags, scan on push, KMS, lifecycle; filled by hand from Docker Hub by digest on the laptop (decision 69)
- The DB password is generated by the `persistent` stack with an ephemeral `random_password` written to a write-only `value_wo`, so it never appears in Terraform state, plans, the repo or the laptop (decision 46)
- Mailbox OAuth tokens encrypted in the DB by the app (key from Parameter Store)
- The database has two roles: the owner `mailbridge` runs migrations only, and `mailbridge_app` (row access only) runs the app, so the app's credentials can't change the schema or the insert-only audit log (decision 54)
- One IAM role per instance: all → `mailbridge-lab-ssm-min` (`AmazonSSMManagedInstanceCore` without `ssm:GetParameter` and `ssm:GetParameters`, so no host reads a parameter unless granted); fw-ips → read `/vpn/fw-ips/*` only; app → read `/mailbridge/*` + pull from the Mailbridge ECR repository only; proxy → `route53:ChangeResourceRecordSets` on this zone only for TXT `UPSERT`/`DELETE` of `_acme-challenge.mail.<domain>` (condition keys), `route53:ListResourceRecordSets` on this zone, `route53:GetChange`, and no `ListHostedZones` (decision 60); db → read `/mailbridge/db-password` and `/mailbridge/db-app-password` only, pulled on the host (decisions 47, 54); siem → read `/siem/*` only (decision 89); fw-ips, db, app and proxy → also read `/siem/agent-enrollment-password` only, to enroll their Wazuh agents (decision 100); vuln → `ecr:GetAuthorizationToken` plus image pull on the `juice-shop` ECR repository only, nothing else (decision 69); proxy's ACME condition also covers `_acme-challenge.vuln.<domain>` (decision 70); `s3:PutObject` on the backup prefix is added in T2.3
- No stored AWS keys on any instance: roles provide temporary credentials through IMDSv2
- CloudTrail (management events) → S3 · GuardDuty free trial during testing
- Terraform runs from the laptop with temporary `aws login` credentials; no access keys exist
- Terraform state: versioned, encrypted S3 bucket with native locking (`use_lockfile`), hand-built then imported into `persistent`

---

## 8. Detection & monitoring

**Security (Wazuh — "is something malicious happening?")**
- Wazuh 4.14.9, pinned, from Wazuh's apt repository with its signing key checked, configured entirely by the `siem` role (decisions 85, 86). The indexer's Java heap is 3 GB on the t3.large (decisions 87, 99). Its data lives on an encrypted volume in `persistent` that is attached to each session's `siem` host, so alerts survive teardown; certificates and passwords come from SSM, so the dashboard's certificate stays the same every session (decisions 88, 89). Wazuh's repository may supply only its four packages, each only at the pinned version (an apt pin by version) and held (decisions 91, 104); the volume is formatted only when it has no filesystem and the indexer can't start without it (decision 92); the indexer listens on 10.0.5.10 only (decision 93); its only internal users are `admin` and `kibanaserver` (decision 94). The manager's API listens on 127.0.0.1 only, agent enrollment (authd, 1515) requires the password in `/siem/agent-enrollment-password`, and vulnerability detection is off in Tier 1 (decisions 96, 97); Filebeat, the connector and the API users get their credentials from SSM through `set-manager-credentials` (decision 95). The dashboard listens on 10.0.5.10:443 with TLS 1.3 only and verifies the indexer's address (decision 98). The Wazuh agent (`wazuh_agent` role) runs on fw-ips, db, app and proxy at the same pinned version, each pulling the enrollment password with its own instance role and enrolling under its host name (decisions 100, 101)
- Suricata `eve.json`, nftables drops, Nginx access/error logs + ModSecurity audit log, auth logs, OpenVPN connect/disconnect, file integrity monitoring. Each agent reads its sources from a per-group list in `group_vars` (fw-ips: `eve.json`; proxy: Nginx and the audit log; the kernel, OpenVPN and auth through journald) (decision 105). Where Wazuh decodes an event but stores no alert, the lab's own rules in `mailbridge_rules.xml` (IDs 100100–100299, children of the decoding parent) add one: nftables drops and egress, a burst of drops from one address, OpenVPN session ends, and ModSecurity 403 blocks from the audit log (decision 106)
- Juice Shop (decision 71): proxy runs one ModSecurity bundle per server, so Mailbridge and Juice Shop have their own engine mode and paranoia level. Juice Shop's audit log (`vuln-audit.log`) keeps request bodies (`ABCFHZ`), because its data is fake and the payload is the evidence; Mailbridge's keeps decision 66. Both audit logs and the per-server JSON access logs go to Wazuh, plus `DOCKER-USER` drops from the vuln host and Suricata's alerts on the decrypted proxy→Juice Shop path

**Network evidence (VPC flow logs)**
- All traffic metadata → S3 bucket in `persistent`, 30-day lifecycle. Used for investigation, including traffic that never crosses fw-ips. Not fed to Wazuh in Tier 1, including for Juice Shop.

**Health (Prometheus/Grafana — "is everything healthy?")** — Tier 1, after Wazuh (decision 84)
- node_exporter on all VMs, postgres_exporter on db, blackbox_exporter probing `https://mail.<domain>` (pinned tarballs, decision 120); CPU credit balances from CloudWatch through YACE (decision 121); one provisioned dashboard, "Lab health" (decision 122)
- Alertmanager → email/Discord: host down, disk > 80%, cert expiry < 14 days, probe failing, CPU credit balance near 0 (t3 `standard` credits, decision 84)
- The vuln host is scraped across fw-ips (decision 68): nftables allows 10.0.5.20 → 10.0.6.10:9100, and the security group names mon's IP

---

## 9. Backups

- Nightly `pg_dump` → S3 bucket (SSE, versioning, 30-day lifecycle) via gateway endpoint
- **Restore tested and documented** (a backup that was never restored doesn't count)

---

## 10. CI/CD (GitHub Actions) — Tier 2

Jest + Supertest (API) · Playwright (UI) · k6 (load) · Trivy (image scan) · SonarCloud (code quality) · OWASP ZAP baseline · build & push image

---

## 11. Attack scenarios (findings report)

| Position | Tests |
|---|---|
| Outside (internet) | Scan: only UDP 1194 should respond. During a 443 window (Marko's /32 only, Juice Shop only, decision 72): SQLi/XSS/brute force vs ModSecurity; Mailbridge is never exposed and is tested from inside the VPN; Suricata sees only traffic the firewall allowed, so TLS metadata and behaviour, not payloads, because TLS ends at Nginx. Scans of blocked ports appear as nftables drops |
| Inside (stolen VPN cert) | What's reachable? What does Suricata/Wazuh see? Time to revoke via CRL? |
| Malicious email | HTML/JS payload in an incoming email → is it sanitized? CSP? |
| Access control | Can user A read user B's mailbox by changing IDs? |
| Juice Shop ground truth (decisions 67–76) | The same attack classes against a known-vulnerable target from the attacker certificate: which layer blocks, detects or misses each, ModSecurity mode × paranoia level matrix, decrypted traffic for Suricata, egress containment of SSRF and RCE |

For each: attack → detection (or miss) → custom rule/fix → re-test.

---

## 12. Cost control

- AWS Budget alert at **$20** on day one
- `terraform destroy` when not in use (stopped VMs still pay for disks + public IP). Between sessions, `terraform apply -var hosts_enabled=false` removes every session host (fw-ips with its Elastic IP and the `vpn` record, and the private hosts) (decision 51); the network stays up (decision 16). Each session starts with `terraform apply` and `ansible-playbook site.yml` (decision 41)
- The Wazuh data volume (20 GB gp3, encrypted, in `persistent`) costs about $1.90/month even between sessions (decision 88)
- The Prometheus data volume (10 GB gp3, encrypted, in `persistent`) adds about $0.80/month once mon is built (decision 109)
- Approx. compute ~$0.15/hour for the full set — a few hours per week stays within credits (verify in AWS Pricing Calculator)
- mon adds a t3.small (about $0.024/hour) and siem a t3.large (about $0.096/hour, decision 99); with both, a full session is roughly $0.22/hour (decision 84)
- Juice Shop adds a t3.small (about $0.024/hour) and its 10 GB disk only while `vuln_enabled` is on, plus a few hundred MB in ECR; no hourly fixed resource (decision 74)

---

## 13. Build order

Everything runs on AWS. There is no VPS phase, and no VPS is used anywhere in this project.

1. Tier 1 on AWS: network (VPC, subnets, IGW, routes, SGs — free) → fw-ips (OpenVPN, then NAT, because private hosts reach SSM through it) → db → app → proxy → siem → mon (decision 84) → the vuln target (decision 67) → close-out (decision 83). Built bottom-up, so each host is tested against its real dependency.
2. Tier 1 attack scenarios → findings report
3. Tier 2: CI, backups + restore test (monitoring moved into Tier 1, decision 84)
4. Tier 3: k3s for app tier, vuln scanning (Nuclei/Greenbone), ISO 27001/NIS2 controls map

**Method for each layer:** build by hand → test → compare with code (`terraform import` + `plan`, or `ansible-playbook --check --diff`) → destroy and rebuild from code → re-test. The final state is always Terraform + Ansible. Exception: the network layer stays up between sessions and its rebuild test is deferred to task 1.20; paid resources are still removed after each session.

**Do not start a tier until the previous tier's write-up is done.**

---

## Repo layout

```
secure-mailbridge-lab/
  terraform/
    modules/      network/ security/ compute/   (shared)
    persistent/   created once, never destroyed: encrypted VPN CA backup + secrets, Wazuh data volume, Prometheus data volume, backup bucket, flow log bucket, state bucket, Route 53 zone, ECR repository, Budget
    lab/          VPC, subnets, SGs (free, kept between sessions) · VMs, Elastic IP, vpn.<domain> record (removed after every session) (uses modules/)
  ansible/        roles: fw_ips/ proxy/ app/ db/ vuln/ siem/ mon/   (Ansible role names cannot contain hyphens; the host stays fw-ips)
  suricata-rules/ custom rules + test pcaps
  siem-certs/     wazuh-certs-tool input (config.yml) and the procedure; the certificates themselves are on the laptop and in SSM (decision 90)
  attacks/        scope file and wrapper that refuses targets outside the lab (decision 75)
  docs/           ARCHITECTURE.md · TASKS.md · decisions.md · rationale.md · progress.md · threat-model.md · findings-report.md · iso27001-map.md
  .github/workflows/
  README.md       one-command deploy + teardown
```
