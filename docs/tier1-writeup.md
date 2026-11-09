# Tier 1 write-up

**Secure Mailbridge Lab · Tier 1 complete on 2026-11-09**
Author: Marko Spasovski. Source of truth for the design: [`ARCHITECTURE.md`](ARCHITECTURE.md). Every decision cited as "(n)" is in [`decisions.md`](decisions.md) and explained in [`rationale.md`](rationale.md).

---

## 1. Summary

The lab answers one question: **if someone attacks a real web application placed behind layered defences, what actually stops them, and what actually sees them?** Tier 1 built everything needed to ask that question honestly, and attacked nothing (132). Understanding every layer first means that, in Tier 2, each finding can be explained by the layer that produced or missed it.

Tier 1 delivered:

- A segmented AWS VPC in `eu-central-1` with six subnets and three independent filtering layers (security groups, network ACLs, nftables), reached only through **OpenVPN** with one certificate per device.
- **Suricata** inline on the decrypted VPN traffic, **Nginx + ModSecurity** with the OWASP CRS in front of both applications, **Wazuh** collecting from every host, and **Prometheus, Grafana and Alertmanager** for health.
- **Mailbridge**, a unified Gmail and Outlook inbox, running end to end: a test user connected a real Gmail and a real Outlook mailbox through every layer.
- **OWASP Juice Shop** as a contained target with the same defences as Mailbridge, ready for the Tier 2 pentest.
- **CloudTrail** for the AWS control plane, every hand-built resource imported into Terraform, and the whole session routine as `make` targets.
- Proof that it is reproducible: the entire lab was **destroyed down to nothing and rebuilt from code**, and the second configuration run changed nothing on any host.

Built in about ten days of sessions: 146 recorded decisions, about 130 merged pull requests, and roughly $5.40 of AWS spend, all covered by credits.

---

## 2. What was built

| Layer | Component | Where |
|---|---|---|
| Entry | OpenVPN (offline easy-rsa CA, `tls-crypt`, TLS 1.3, CRL), user pool 10.8.0.0/24, admin pool 10.8.1.0/24 | fw-ips 10.0.1.10 |
| Network filtering | security groups, one NACL per subnet, nftables (per-pool policy, NAT for private subnets, logged drops) | VPC, fw-ips |
| IPS | Suricata 7 on NFQUEUE, ET Open plus custom rules, fails closed | fw-ips |
| DNS | Unbound with the private `mail.` and `vuln.` records; nothing private is in public DNS | fw-ips |
| Reverse proxy, WAF | Nginx (TLS 1.3, HSTS, rate limits), ModSecurity v3 with CRS 4.25.0 at paranoia level 1, blocking; lego with DNS-01 (staging) | proxy 10.0.2.10 |
| Application | Mailbridge in a hardened container, image from ECR by digest | app 10.0.3.10 |
| Database | PostgreSQL with separate owner and runtime roles | db 10.0.4.10 |
| SIEM | Wazuh 4.14.9 (manager, indexer on a persistent volume, dashboard), agents on all six other hosts, local rules for the gaps | siem 10.0.5.10 |
| Health | Prometheus, Grafana, Alertmanager, node, postgres and blackbox exporters, YACE for CPU credits, alerts to Discord | mon 10.0.5.20 |
| Target | OWASP Juice Shop, read-only container with no capabilities and no egress, in its own subnet | vuln 10.0.6.10 |
| AWS | CloudTrail, VPC flow logs, SSM Parameter Store, ECR, Route 53, budgets | `persistent` stack |

Infrastructure is Terraform in two stacks: `persistent`, which is never destroyed (secrets, data volumes, buckets, the DNS zone, ECR, CloudTrail, budgets), and `lab`, whose hosts exist only during a session. Configuration is Ansible, one role per host, reaching every host by SSH tunnelled through SSM. The diagrams are in the [README](../README.md#architecture).

---

## 3. The decisions that shaped it

Out of 146 decisions, these ten explain most of the design.

1. **One way in.** Only UDP 1194 is reachable from the internet. Both applications are VPN-only, and the planned "443 test window" was dropped (129). `tls-crypt` makes the VPN port silent to anyone without the shared key, so it can't even be fingerprinted.
2. **Routed, not NATed, VPN pools.** Nginx, Suricata and Wazuh see the real client address, so every event maps to one device certificate.
3. **One hop at a time, enforced three times.** proxy → app → db is allowed by the security groups, the NACLs and nftables independently. A mistake in one layer doesn't open a path on its own.
4. **An offline CA (21) and no keys on hosts.** The VPN CA never touches AWS; fw-ips pulls only its own five files from SSM with its own role (39). No instance stores an AWS key; every host has one role with only its own parameter paths.
5. **Secrets that never reach Terraform state.** Generated secrets are write-only (46). Hand-made keys and certificates are deliberately kept out of Terraform, because importing a parameter copies its value into state (143).
6. **Hosts that live for one session.** `make down` removes every host after a session (51), so the lab costs about $0.25 an hour while running and about $2.70 a month between sessions. Wazuh and Prometheus keep their history on volumes in `persistent` (88, 109).
7. **Suricata fails closed (33).** If the IPS stops, traffic stops. The cost became real once: a drop rule took Mailbridge down, which led to the rule that nothing is promoted to `drop` without realistic test captures (82).
8. **Juice Shop is a real app, contained.** It gets exactly Mailbridge's defences, no testing-only settings (129). Every path to and from its subnet crosses fw-ips and Suricata (68, 131), and its container can't open any connection (130).
9. **Standard, application-independent detection.** Wazuh's built-in rules first, local rules only for gaps, each covering both applications (133, 138).
10. **Only reviewed plans are applied.** Terraform changes go through a saved plan that I review and apply myself; the Makefile applies exactly that file and deletes it (142).

---

## 4. How it was proven

Every task in [`TASKS.md`](TASKS.md) has a verify step; a task is done only when it passes. The key evidence:

| Claim | Evidence |
|---|---|
| The lab rebuilds from code | 2026-11-09: everything in `lab` destroyed (217 resources), rebuilt from nothing (229); first run `failed=0` and **second run `changed=0` on all seven hosts**; `make verify` passed |
| Data survives the hosts | after the rebuild, Wazuh's 2026-11-07 index still held exactly its 12,245 alerts, the dashboard certificate fingerprint was unchanged, and Prometheus still answered queries for 2026-11-07 |
| The application works end to end | a test user connected a Gmail and an Outlook mailbox; both OAuth callbacks returned 302 through VPN, proxy and WAF; the first sync ran |
| Only the VPN is exposed | UDP 1194 `open|filtered` with no response (tls-crypt); TCP top 1000 all filtered except port 21, which **VPC flow logs prove was rejected** at AWS (the carrier answered it); 15,565 ports from the full scan, all `REJECT` in the flow logs |
| The WAF blocks and stays usable | the same SQL injection gets 403 on both sites (942100); 21 steps of Juice Shop's normal use and a browser pass with no block; the false positives found were lifted narrowly (139, 146) |
| Detection fires | live tests: brute force (100210, 100211 at level 10, T1110), rate limits (100212, 100213), container egress (100120), ModSecurity blocks (100201), unexpected TLS names (Suricata 1000003); counts in `alerts.json` equal the indexer's |
| The IPS acts | Suricata 1000004 dropped 1,050 SYNs during a parallel load test, before Nginx ever saw them |
| Least privilege holds | IAM simulator: proxy may write only the two challenge TXT records (a request that mixes in `vpn.` is denied); vuln may pull only `juice-shop`; both are denied every other parameter |
| The control plane is audited | CloudTrail multi-region with validation; a test call found in a delivered file; `validate-logs`: 3/3 digests and 26/26 files valid |
| Health is watched | 13 of 13 Prometheus targets up; `TargetDown` fired and resolved live in Discord; all five alert rules unit-tested with `promtool` on every deploy |
| No secret leaked | gitleaks in pre-commit and CI; secrets entered through a hidden prompt; generated passwords never in state; the repo has no account ID |

---

## 5. Found and fixed along the way

The most instructive problems, each recorded with its fix in [`lessons.md`](lessons.md):

- **The IPS that took the app down (82).** A Suricata rule promoted to `drop` matched normal TLS 1.3 clients whose ClientHello spans two TCP segments. Mailbridge went offline until the rule was set back to alert. Since then, three realistic TLS 1.3 captures must stay silent before any rule change.
- **"Slow requests" that were the IPS working.** 30 parallel connections managed only 6 requests a second. Suricata's log showed rule 1000004 dropping the SYN flood; one HTTP/2 connection got past it and reached Nginx's limiter instead.
- **A test that couldn't fail.** The first ModSecurity harness passed a SQL injection, because Nginx's `return` answers before ModSecurity inspects. Every harness since includes a must-be-blocked case.
- **False positives in pairs (146).** The first Gmail callback was blocked first by a regex step limit (the WAF correctly failed closed), then, once that was fixed, by `.profile` inside Google's `userinfo.profile` scope. Fixing one false positive can reveal the next.
- **Boot order only a clean build tests.** `make up` assumed private hosts were reachable right after the apply, but they reach SSM only through fw-ips's NAT; later, even fw-ips needed a minute before SSM answered. Both were found only by building from nothing.
- **A scan result that lied.** Port 21 "open" on fw-ips was answered by the mobile carrier. The flow logs, the target's own evidence, showed every probe rejected.
- **A rule that never fired.** Suricata 1000002 (TLS 1.0) can't match, because `tls.version` holds the negotiated version, which doesn't exist yet at the ClientHello. Found while replaying captures, now an open item.
- **Shell details that change results.** In zsh, `$A:repository` strips part of a value, which made every IAM simulation an invalid ARN and "deny everything". When all results look the same, suspect the test.

---

## 6. Known gaps

Tier 1 is complete, not perfect. These are known, documented, and become Tier 2 test hypotheses:

| Gap | Effect | Where tracked |
|---|---|---|
| No-SNI Suricata rule disabled (82) | a TLS client without a server name raises no IDS alert; Nginx still refuses it | TASKS open items |
| Suricata 1000002 can't fire | TLS 1.0 attempts raise no IDS alert; Nginx accepts TLS 1.3 only | TASKS open items |
| Private hosts use AmazonProvidedDNS (30) | DNS from a compromised private host isn't filtered by SGs or NACLs: a possible exfiltration path | scenario 2.2 |
| Mailbridge's own sign-in limit raises no alert | its `429 rate_limited` is logged but not alerted, unlike Nginx's | TASKS open items |
| Four alert rules proven by unit tests only | disk, certificate, probe and CPU-credit alerts have not fired live | 1.23 note |
| Staging certificates | browsers warn; production certificates wait for an explicit decision | 2.6 |
| No backups | the database is empty each session by design (49); backup and restore come in T2.3 | Tier 2 |
| No GuardDuty yet | nothing analyses CloudTrail automatically until its trial starts with the attacks | 2.14 |
| One availability zone | no high availability, accepted for a lab | ARCHITECTURE header |

---

## 7. Cost

Measured from October 1 to November 9, 2026: **about $5.40 in total, all covered by AWS credits**, of which EC2 compute $3.90, EBS $0.72, Route 53 $0.50 and public IPv4 $0.15. A full session with all seven hosts costs about $0.25 an hour; between sessions the two data volumes, ECR and CloudTrail's bucket cost about $2.70 a month. The guardrails: no NAT Gateway, ALB or interface endpoints, `standard` CPU credits, hosts removed after every session, and two budgets in code (a $20 one, and a $10 one whose forecast alert warns before the money is spent).

---

## 8. What Tier 2 starts with

Tier 2 begins with the **threat model** (2.17): written from the lab as built, it lists assets, trust boundaries and the four attacker positions, and states for each threat which layer is expected to stop or detect it. The attacks then test those claims:

1. **Attacker identity and tooling (2.14):** a separate user-pool certificate, a scope wrapper with rate caps, and GuardDuty's trial started.
2. **Juice Shop pentest (2.15):** a known-vulnerable application behind the real defences; every step recorded as attack, then detection or miss, then fix, then re-test.
3. **Mailbridge scenarios (2.2 to 2.5):** a stolen VPN certificate, malicious e-mail content, access control between users, and the outside view.

The gaps in section 6 are the first hypotheses: which of them an attacker can actually use, and whether anything sees it when they do.
