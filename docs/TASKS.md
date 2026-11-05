# Tasks & progress

Single tracker for the whole lab. Session notes go in `progress.md`, decisions in `decisions.md`.

**Status:** `[ ]` todo · `[~]` in progress · `[x]` done and verified
**Owner:** **M** = Marko writes it, Claude reviews · **C** = Claude drafts after an OK on the approach · **M+C** = shared

**Layer loop (network, fw-ips, db, app, proxy, siem):** build by hand → test → compare with code → destroy and rebuild from code → re-test. A layer is finished only after the rebuild passes. Remove paid hand-built resources at the end of each session.

A task is done only when its verify step passes. A phase is done only when `make up` deploys it,
it is verified, and the relevant doc section is updated.

## Current position

- **Phase:** 1, Tier 1 on AWS (0.6 and 0.7 still open)
- **Next tasks, in order:** 1.16 (`siem` host, Wazuh manager, indexer and dashboard) → 1.17 (Wazuh agents and log collection on every host) → 1.22 and 1.23 (`mon`: Prometheus, Grafana, Alertmanager, exporters; moved into Tier 1, decision 84) → the Juice Shop block (2.1, 2.7 to 2.16) → close-out 1.18 to 1.21 (decision 83) → scenarios 2.2 to 2.5. The full detection and health stack comes first, so every Juice Shop attack can be followed from nftables through Suricata and ModSecurity to Wazuh, with its effect on the hosts visible in Grafana.
- **Done:** 1.13 (`db`), 1.14 (`app`), 1.15 (`proxy`). The Suricata rules from PR 60 (decisions 79 to 81) are merged; their deploy and live re-test on fw-ips is pending.

## Before db (agreed 2026-11-02)

1. [x] **Session routine and second rebuild from code.** Passed 2026-11-02: every check below as expected, and the fallback AMI and snapshot are deleted. The first apply hit a race (the Elastic IP association ran while the instance was pending); a second apply finished it and the fix is `depends_on` in item 2. Commands, from the repo root, kept as the start-of-session routine:
   - `aws login`, then `aws sts get-caller-identity --query Arn --output text` (ends in `marko-admin`)
   - `ssh-add ~/.ssh/mailbridge-lab-ansible`
   - Claude saves the plan: `terraform -chdir=terraform/lab plan -out=<scratchpad>/on.tfplan` (expect 4 to add: instance, Elastic IP, association, `vpn` record). Marko runs `! cd terraform/lab && terraform apply <scratchpad>/on.tfplan`
   - No inventory step: the `aws_ec2` plugin finds the new instance by its tags (decision 45). `cd ansible && ansible-inventory --graph` shows it under `fw_ips`
   - Wait for first boot: `cd ansible && ansible fw_ips -m command -a 'cloud-init status --wait'` (expect `status: done`)
   - `ansible-playbook site.yml`, then again (expect `changed=0`)
   - Connect the VPN; `ping -c 3 10.0.1.10`; `dig +short @10.0.1.10 mail.<domain>` (expect `10.0.2.10`)
   - `terraform -chdir=terraform/lab plan` (expect no changes)
   - If all pass: delete the fallback AMI and its snapshot, with Marko's OK
2. [x] **Small fixes, one PR each:** ~~`depends_on = [aws_instance.fw]` on the Elastic IP association~~ (PR 26, proved at the next start); ~~remove `default` from the fw-ips ENI~~ (decision 42, verified); ~~tighten the fw-ips role description and use the account ID instead of `*` in its grant~~ (decision 43, verified); ~~rule 1000004 `flow:to_server`~~ (written by Claude at Marko's explicit request; the Suricata warning about a missing direction is gone, and the flood capture still raises it).
3. [x] **Inventory from Terraform:** the `aws_ec2` dynamic inventory, by the `Project` and `Role` tags (decision 45). Verified 2026-11-02: `ansible-inventory --graph` shows `fw_ips` → `mailbridge-lab-fw-ips`, ping returns `pong`, and `site.yml` reports `changed=0`. Each new host needs `Project` and `Role` tags in Terraform.
4. [x] **Where `db`'s password lives** (part of 1.2): decision 46. `terraform/persistent` creates `/mailbridge/db-password` from an ephemeral `random_password` into the write-only `value_wo`. Verified 2026-11-02: the parameter is a `SecureString` at version 1; the state has `value_wo` null, and the real value appears in it 0 times; the plan JSON held no value; a second plan shows no changes. The other hand-built `persistent` pieces are imported later in 1.2, one at a time.

End every session with: Claude saves `terraform -chdir=terraform/lab plan -var hosts_enabled=false -out=<scratchpad>/off.tfplan` (expect 4 to destroy for fw-ips, plus 1 per private host: 6 with db and app), Marko disconnects the VPN and runs the apply, Claude confirms no instance, Elastic IP or volume is left.

## Open items

- [~] **Delegate the subdomain:** zone and NS records built by hand and verified with `dig`, parent MX unchanged. Import the zone in 1.2.
- [x] **Fallback AMI:** deleted with its snapshot on 2026-11-02 after the second rebuild passed. It was: keep `mailbridge-lab-fw-ips-handbuilt-2026-11-02` and its snapshot until the next session's rebuild from code also passes every check, then delete both. It's the only copy of the hand-built host, for inspecting anything the role may still miss.
- [x] **Session routine (decision 41, replaces decision 24):**
  - Start: `terraform -chdir=terraform/lab apply` (the dynamic inventory finds the new instance, decision 45), wait for `cloud-init status` = `done`, run `ansible-playbook site.yml` from `ansible/`, and connect the VPN.
  - End: `terraform -chdir=terraform/lab apply -var hosts_enabled=false` (renamed from `fw_enabled`, decision 51), then check that no instance or Elastic IP is left.
- [x] **Ansible over SSM:** decided: SSH tunnelled through SSM with a laptop-only key (decision 36). fw-ips gets the public key once through SSM, because it was launched without a key pair.
- [x] **Suricata upkeep:** daily `suricata-update.timer` with `reload-rules`; the refusal was a test run replacing the command socket (decision 38).
- [x] **Default security group on the fw-ips ENI:** removed on 2026-11-02 (decision 42). Verified: the ENI lists only `mailbridge-lab-fw`, the next plan shows no changes, and the VPN ping still works.
- [ ] **VPN client exits on the laptop:** the `openvpn` client process ended twice on 2026-11-02 (about 11:40, and after a server restart) instead of reconnecting. Read the client's last log lines next time it happens.
- [ ] **Own package mirror or proxy:** Marko wants to discuss this later. Parked until Tier 1 is finished; no design change yet.
- [ ] **SSH over the VPN:** proposed as a daily-use path from the admin pool, with SSM kept for emergencies. Discuss after 1.9b; no design change yet.
- [ ] **Keep the proxy certificate between sessions:** proxy is rebuilt every session, so it would request a new certificate each time. Fine on staging; production allows 5 duplicate certificates per week, so decide before 2.6 (for example, keep the lego account and certificate in SSM). Parked 2026-11-04.
- [~] **Evidence before teardown:** Wazuh's indexed data survives on its own volume (decision 88). Decided by Marko on 2026-11-04: raw host logs (`eve.json`, ModSecurity audit logs, Nginx logs, kernel drop logs) are exported to the laptop, outside the repo, before each teardown. What exactly, where, and how (a script in the end-of-session routine) is designed in 1.17, before 2.15.
  Was: every host, `siem` included, is destroyed at the end of each session, so Wazuh's indexed data and each host's logs (`eve.json`, audit logs, kernel drop logs) are lost. Should they be exported to the laptop before each teardown, and if so what, and where (outside the repo)? Marko decides before 2.15.
- [ ] **No-SNI rule (1000006):** disabled after it fired on a split ClientHello (decision 82). Rewrite so it waits for the whole hello, and re-enable only once `tls13-big-2seg.pcap` stays silent and a live session shows no false positives. Until then, Nginx's handshake refusal is the only control for clients without SNI.
- [ ] **Slow fw-ips run:** `site.yml --limit fw_ips` took 11 min 37 s on 2026-11-04 (normally about 5). Profile the next run with `ANSIBLE_CALLBACKS_ENABLED=profile_tasks` before changing anything.
- [x] **Mailbridge repo location:** a separate repo, prepared for deployment on 2026-11-02 (its `docs/deployment.md`); the image is built from a clean export of a merged commit and pushed by hand (decision 57). OAuth secrets and redirect URI registration remain for 1.19.

---

## Phase 0: Repo foundation

- [x] **0.1** Folder structure, git repo, `.gitignore`, doc stubs · C
  - Verify: `git check-ignore x.tfstate x.ovpn x.key .env` prints all four names
- [x] **0.2** Decide Mailbridge image, DNS, Elastic IP, build order, NAT timing, repo visibility · M
  - Verify: all six are in `decisions.md` and `rationale.md`
- [x] **0.3** Confirm the moved permissions are active · M
  - Verify: restart Claude Code, run `/permissions`; `terraform apply` appears under deny
- [x] **0.4** Pre-commit: `gitleaks`, `terraform fmt` · C
  - Verify: `pre-commit run --all-files` passes; a fake AWS key in a test commit is blocked
- [x] **0.5** CI workflow: `terraform fmt -check`, `terraform validate`, `tflint`, `checkov`, `ansible-lint`, `gitleaks`, then branch protection on `main` · C
  - Verify: the first PR shows all six checks green; a PR with a failing job cannot be merged
- [ ] **0.6** Makefile skeleton (`up`, `down`, `verify`) · C
  - Verify: `make -n up` prints the steps without executing them
- [ ] **0.7** First draft of `threat-model.md` · M
  - Verify: covers assets, trust boundaries and the four attacker positions from §11

## Phase 1: Tier 1 on AWS

Order follows ARCHITECTURE.md §13: network → fw-ips (OpenVPN, then NAT) → db → app → proxy → siem.

**Every `terraform apply`, `destroy` or AWS resource creation needs Marko's explicit go-ahead.**

**Foundation**
- [x] **1.1** Account safety: root MFA, admin IAM user with MFA, no root access keys · M
  - Verify: IAM Dashboard shows root MFA enabled; console sign-in as the admin user works
- [x] **1.1b** AWS Budget alert at $20, by hand now, imported into `terraform/persistent` with 1.2 (day one, §12) · M
  - Verify: in CloudShell, `aws budgets describe-budget --account-id <id> --budget-name mailbridge-lab-monthly` shows a 20 USD limit and `FilterExpression` excludes `Credit` and `Refund`
- [ ] **1.2** `terraform/persistent`: state bucket, backup bucket, flow log bucket, Route 53 zone, ECR repository, VPN CA + secrets · C
  - Note: `/vpn/ca/*` was created by hand. Don't import `/vpn/ca/key` without a plan for its value, because Terraform stores parameter values in state.
  - Note: started 2026-11-02 with `/mailbridge/db-password` only (decision 46). The stack uses the same state bucket under its own key, `persistent/terraform.tfstate`.
  - Note: the `mailbridge` ECR repository added 2026-11-02 (decision 53)
  - Verify: Marko reviews `terraform plan` before any apply; no secret values in the repo or in plan output

**Network (free resources)**
- [x] **1.3** `modules/network`: VPC, 5 subnets, routes, IGW, standalone fw-ips ENI, flow logs · C
  - Note: private routes show as `blackhole` until fw-ips attaches; the S3 endpoint moved to T2.3
  - Verify: plan shows no NAT Gateway, ALB or interface endpoint
- [x] **1.4** `modules/security`: security groups and NACLs from §4 · C
  - Verify: `checkov` passes; line-by-line review against the §4 table
- [x] **1.5a** Hand-build the network, security groups and flow logs in the console, without reading the modules · M
  - Verify: `aws ec2 describe-subnets` shows the 5 CIDRs from §2; `aws ec2 describe-flow-logs` shows `ACTIVE`
- [x] **1.5b** State bucket by hand, `aws login`, `terraform/lab` root stack (network only, written by Marko), import the hand build, compare · M+C
  - Verify: `terraform plan` reports no changes
- [ ] **1.5c** Deferred to 1.20: destroy the hand build and rebuild from code · M
  - Verify: the 1.5a checks pass again; `terraform plan` reports no changes

**fw-ips**
- [x] **1.6** Rebuilt from code on 2026-11-02 and verified: second `terraform plan` shows no changes, the third Ansible run `changed=0`, packages and nftables identical to the hand-built host. Remove the `CKV2_AWS_5` skips as groups get attached. `modules/compute` and IAM: fw-ips instance, IMDSv2, encrypted gp3, `credit_specification = "standard"`, source/dest check off, Elastic IP and `vpn.<domain>` record · C
  - Note: roles use `mailbridge-lab-ssm-min`, never `AmazonSSMManagedInstanceCore` (decision 22)
  - Note: fw-ips is rebuilt from code with IAM and the Elastic IP imported, and an AMI of the old instance as fallback (decision 40)
  - Note: instances get the Ansible public key through `aws_key_pair`; the private key stays on the laptop (decision 36)
  - Verify: `tflint` and `checkov` pass; plan shows `http_tokens = "required"`; the IAM simulator denies the fw-ips role `ssm:GetParameter` on `/vpn/ca/*` and `/mailbridge/*`; `aws ssm start-session` connects; `dig vpn.<domain> +short` matches the Elastic IP
- [x] **1.7a** Offline CA on the laptop with easy-rsa, outside the repo: CA, CRL, encrypted key backed up to SSM under `/vpn/` · M+C
  - Verify: `pki/private/ca.key` starts with `ENCRYPTED PRIVATE KEY`; `openssl crl -in pki/crl.pem -noout -nextupdate` shows a future date; the SSM parameter exists as `SecureString`
- [x] **1.7b** Hand build verified; the `fw_ips` role pulls the five files from `/vpn/fw-ips/*` with the instance role (decision 39). Fetch parameters through a pipe, because the snap `aws` wrote 0 bytes when stdout was a file. Sign the server cert and one cert per device on the laptop, revoke a test cert, and have the `fw_ips` role install only the public files, server key and CRL · M+C
  - Verify: `openssl crl -in crl.pem -noout -text` lists a test-revoked serial; no CA private key exists on fw-ips
- [x] **1.8** Hand build verified; `tasks/openvpn.yml` installs `server.conf` and `ccd/marko-laptop` (2026-11-02). `fw_ips` role: OpenVPN server, §5 hardening, `client-config-dir` pools, profiles using `vpn.<domain>` · C
  - Verify: user cert gets 10.8.0.x, admin cert gets 10.8.1.x
- [x] **1.9a** nftables: forwarding and NAT for private subnets · **C** (Marko explicitly asked Claude to write this one)
  - Note: verified by hand with a temporary VM. The files are in `ansible/roles/fw_ips/files/`; `tasks/network.yml` installs them (2026-11-02, live rules unchanged by checksum).
  - Note: private hosts reach SSM through fw-ips, so this comes before any of them is configured
  - Verify: `aws ssm describe-instance-information` lists a private test host as `Online`
- [x] **1.9b** Core nftables ruleset: full §4 policy on top of 1.9a · **C** (Marko explicitly asked Claude to write this one)
  - Note: verified by hand, including a reboot. No proxy exists yet, so 443 was shown as not dropped; a working connection is proved in 1.15. `tasks/network.yml` installs the files.
  - Verify: `nft list ruleset`; user pool reaches only 10.0.2.10:443, other traffic is dropped and logged; SSM still `Online`
- [x] **1.10** Hand build verified for admin and user pools, including a reboot. Unbound is in `tasks/dns.yml`, and the pushed route is in the role's `server.conf`. `fw_ips` role: Unbound with the private `mail.<domain>` record; push a route to 10.0.1.10/32 to VPN clients (decision 27) · C
  - Verify: `dig @10.0.1.10 mail.<domain> +short` from the VPN returns 10.0.2.10
- [x] **1.11** Hand build verified, including fail-closed and a reboot, using 528 MB of RAM with ET Open; `tasks/suricata.yml` installs it (2026-11-02). `fw_ips` role: Suricata install, NFQUEUE wiring, `eve.json` · C
  - Note: the role owns the whole `suricata.yaml`, installed with `copy` (decision 37)
  - Verify: `suricata -T` passes; `sudo tail -f eve.json` shows flows while using the VPN
- [x] **1.12** Custom Suricata rules and test pcaps · **C** (Marko explicitly asked Claude to write these)
  - Note: captures are synthetic, so re-test rules against real TLS in 1.15, then consider promoting them to `drop`. Re-tested 2026-11-04 against real Nginx: 1000003 (SNI `other.test`), 1000002 (TLS 1.0 ClientHello) and 1000005 (plain HTTP to 443) fire; 1000005 alerts several times per flow; **1000001 never fires**, because Nginx answers any non-TLS bytes on 443 with an HTTP 400, so Suricata labels the flow `http`. Changed the same day, written by Claude at Marko's explicit request (decisions 79 to 81): 1000001 and 1000005 share a flowbit, so one alert per flow; new 1000006 (with helper 1000007) for TLS without SNI; 1000002 and 1000005 now `drop`. Replayed in a Suricata 7.0.3 container: one alert per capture, none on clean TLS, with three new captures (`no-sni`, `binary-nginx400`, `text-nginx400`). 1000003 must allow `vuln.<domain>` in 2.9. **Outage the same day (decision 82):** as a drop, 1000002 blocked normal TLS 1.3 clients whose ClientHello spans two TCP segments; restored by hand on fw-ips (alert + reload), then fixed in code: 1000002 has `ssl_state:client_hello` and is `alert`, 1000006/1000007 are disabled, and three realistic TLS 1.3 captures (`tls13-small`, `tls13-big-1seg`, `tls13-big-2seg`) must stay silent on every rule change. `reload-rules` was refused because a `suricata -r` test run replaced the daemon's command socket; tests on fw-ips use `--set unix-command.enabled=no` (decision 38).
  - Verify: `suricata -k none -r <pcap> -S <rules> --set unix-command.enabled=no` raises the expected alert; live traffic is dropped inline

**db, app, proxy**
- [x] **1.13** Built from code on 2026-11-02 and verified on db's side (decision 48); app→db and proxy→db are checked in 1.14 and 1.15. `db` role: PostgreSQL, app user, access from the app host only · C
  - Note: db reads `/mailbridge/db-password` with its own instance role and sets it on the host (decision 47)
  - Note: 2026-11-02, built in three PRs: the Terraform host and role (37), the `common` role (38), the `db` role (39). The helper `set-db-password` sets the password through stdin, never argv, a file or an Ansible variable (decision 52)
  - Verified 2026-11-02: second `site.yml` run `changed=0` on both hosts; PostgreSQL listens on 10.0.4.10 and 127.0.0.1 only; the SSM password logs in as `mailbridge` and a wrong one fails; `postgres` over TCP and `mailbridge` to another database get `no pg_hba.conf entry`; the role isn't superuser and can't create roles or databases; the password is stored as `SCRAM-SHA-256`; the value appears 0 times in the `-v` run log and the PostgreSQL logs; the IAM simulator allows only `/mailbridge/db-password`. From the admin pool, with a route to 10.0.4.0/24 added by hand (the pool gets no such route), `nc` to 5432 times out and fw-ips logs `FW-DROP` from 10.8.1.10
  - Note: the laptop needs the collections in `ansible/requirements.yml` (`ansible-galaxy collection install -r requirements.yml`)
  - Verify (decision 48, db side only): PostgreSQL listens on 10.0.4.10:5432; `pg_hba` allows only the app user from 10.0.3.10/32 with `scram-sha-256`; a local login with the SSM value works; `nc -zv -w 3 10.0.4.10 5432` from the VPN admin pool times out and fw-ips logs the drop; the IAM simulator allows only `/mailbridge/db-password`. "Connect from app" moves to 1.14 and "refused from proxy" to 1.15
- [x] **1.14** Built from code on 2026-11-03 and verified, except "reachable from proxy", which is checked in 1.15 (decision 48). `app` role: Mailbridge from ECR pinned by digest, listening on 3000, secrets from SSM · C
  - Note: two DB roles (decision 54): db creates `mailbridge_app`; app runs migrate as the owner, applies `db-roles.sql` with `psql`, then runs the app as `mailbridge_app`. Secrets generated in `persistent` (decision 55); OAuth secrets wait for 1.19
  - Note: secrets reach the containers through start scripts under systemd with `--rm` (decision 56); the image is built and pushed by hand for now, automated in T2.2 (decision 57). The app host and its role are in `modules/compute/app.tf`
  - Note: db creates `mailbridge_app` and sets both passwords with `set-db-password <role> <parameter>`; `pg_hba` allows both roles from 10.0.3.10 and loopback only; app gets the `common` baseline in `site.yml`
  - Note: image `bb5c84f` pushed 2026-11-03 by hand (decision 57): one OCI manifest, about 90 MB; ECR's basic scan reports 5 HIGH, all in Debian base packages (zlib, util-linux, glibc), matching the app's Trivy result of 0 fixable HIGH/CRITICAL. The `app` role pins the digest in `defaults/main.yml`, with `db-roles.sql` from the same commit
  - Verified 2026-11-03: third `site.yml` run `changed=0` on all hosts; `/healthz` and `/health` (DB, as `mailbridge_app`) return 200; the container runs the pinned digest with `POSTGRES_USER=mailbridge_app` and the owner password 0 times in its env; no secret in any command line; IMDS from inside the container times out (hop limit 1); as `mailbridge_app`, `DROP TRIGGER audit_events_guard_row` gets "must be owner", `UPDATE audit_events`, `CREATE TABLE`, `TRUNCATE` and `pgmigrations` get "permission denied", `ALTER TABLE` gets "must be owner"; `systemctl stop` leaves `Result=success` and 0 containers; from the admin pool with a hand-added route, port 3000 times out and fw-ips logs `FW-DROP`. Fixed on the way: `ExecStop` failed on a container `--rm` had already removed (PR 46)
  - Verify: `docker inspect` shows the pinned digest; port 3000 reachable from proxy, unreachable from the VPN directly; `psql` to 10.0.4.10 as the app user connects (decision 48)
- [x] **1.15** `proxy` role: Nginx, TLS, rate limit, ModSecurity v3 + CRS, lego with Route 53 DNS-01 (staging, decision 59) · C
  - Note: lego is pinned in `defaults` by version and SHA-256; at each version bump the release's build provenance is checked on the laptop with `gh attestation verify` before the hash is committed. The role writes `lego-renew.service` and `lego-renew.timer` (decision 59). IAM grant: decision 60; Ansible looks up the zone ID from the laptop at run time and writes it into lego's environment file
  - Note: TLS 1.3 only, `server_tokens off`, HSTS with a short `max-age` on staging, no OCSP stapling (decision 61); Nginx owns HSTS and hides the app's header (decision 62)
  - Note: ModSecurity engine and Nginx connector from Ubuntu packages, CRS 4 from one pinned upstream release checked by SHA-256 (decision 58). CRS 4.25.0, because 4.25.1+ needs libmodsecurity ≥ 3.0.16; JSON bodies only (decision 63). Blocking, PL1, default thresholds (decisions 64, 65); audit log `ABFHZ`, flagged and 5xx only, root only (decision 66)
  - Note: tested before AWS in an Ubuntu 24.04 container with the real packages, 2026-11-04: 848 rules load; clean GET 200; SQLi in query and JSON body 403; XSS 403; PUT/PATCH/DELETE 200; 800 KB photo 200; non-data-URL photo 400 (rule 10010); XML and form bodies 403 (920420); audit log `600 root`, no bodies
  - Note: rate limits per client address, general 20 r/s burst 50 and auth POSTs 6/min burst 5, 429 logged at `error` (decisions 77, 78); tested in the container harness on 2026-11-04
  - Verify: `curl -k https://mail.<domain>` over VPN returns 200; `?id=1' OR '1'='1` gets 403 and is in the audit log; `nc -zv -w 3 10.0.4.10 5432` from proxy times out (decision 48)
  - Verified 2026-11-04 on a proxy built from code: second run `changed=0`; `/healthz` 200 through VPN → Suricata → Nginx → app; TLS 1.3 only (`-tls1_2` gets alert 70); staging certificate from lego v5 (`(STAGING)` issuer, 64-day lifetime, files `0600 lego`, timer active); exactly one HSTS header, `max-age=300` (decision 62); `?id=1' OR '1'='1` 403 with 942100/949110 and `OWASP_CRS/4.25.0` in the audit log; XML body 403 (920420); audit log `600 root`; 30 login POSTs gave 8 app answers and 22 × 429, logged with `zone "mail_auth", client: 10.8.1.10` (no NAT); from proxy, 10.0.4.10:5432 times out and 10.0.3.10:3000 connects (decision 48, closes the 1.13 and 1.14 items)

**siem**
- [ ] **1.16** `siem` role: Wazuh manager, indexer, dashboard · C
  - Note: Wazuh 4.14.9 pinned; apt repository with the signing key checked, configured by our own role from the step-by-step guide, not the all-in-one script (decisions 85, 86); t3.medium with a 1.5 GB indexer heap, t3.large as the fallback; a new t3 has no CPU credits, so the first install gets long timeouts (decision 87)
  - Note: indexer data on a 20 GB encrypted gp3 volume in `persistent`, attached in `lab` each session; same Availability Zone as the mgmt subnet; the indexer is stopped cleanly before teardown (decision 88)
  - Note: passwords generated by `persistent` into write-only SSM values under `/siem/`; certificates made once on the laptop with `wazuh-certs-tool`, stored by hand under `/siem/`; siem's role reads `/siem/*` only (decision 89)
  - Note: Terraform written 2026-11-04 (PR 1), not yet applied: `persistent/wazuh.tf` (the volume with `prevent_destroy`, four write-only `/siem/*` passwords; the two API ones use the API's required character set) and `modules/compute/siem.tf` (role reading `/siem/*` only, t3.medium at 10.0.5.10, attachment with `stop_instance_before_detaching` and an AZ precondition). Expect `persistent` 5 to add and `lab` 6 to add
  - Order: (1) Terraform: data volume in `persistent`, siem host, IAM and attachment in `lab`; (2) certificates on the laptop and in SSM; (3) the role: indexer, manager and Filebeat, dashboard; each a PR, hand build before code
  - Done 2026-11-05, part 2: certificates made with `wazuh-certs-tool` 4.14 from `siem-certs/config.yml` (`node-1`, `wazuh-1`, `dashboard`, `admin`; SAN `IP:10.0.5.10`; expire 2036-11-02) and stored under `/siem/certs/*`; the CA key is encrypted and backed up to `/wazuh-ca/key`, out of siem's reach (decision 90). Verified: four `openssl verify` OK, keys match their certificates, all ten SSM values hash-equal to the laptop files, simulator allows siem on `/siem/certs/*` and denies `/wazuh-ca/key`; the re-sign procedure was tested on a throwaway CA. Procedure: `siem-certs/README.md`
  - Done 2026-11-05, part 3a (indexer): data volume found by tag and NVMe `by-id`, formatted only when `blkid -p` finds nothing, `RequiresMountsFor` on the indexer (decision 92); Wazuh repo key pinned by SHA-256, repo limited to Wazuh's four packages, `wazuh-indexer 4.14.9-1` held (decision 91); listens on 10.0.5.10 only, 1.5 GB heap drop-in (decision 93); only `admin` and `kibanaserver`, set by `set-indexer-users` (decision 94). Verified: cluster green, heap 1.5gb, users `['admin', 'kibanaserver']`, every demo login and `admin:admin` 401, 9200/9300 on 10.0.5.10 only and 9200 times out from the admin pool, certs `0400 wazuh-indexer`, helper `unchanged`. Next: 3b manager and Filebeat, 3c dashboard
  - Done 2026-11-05, part 3b (manager and Filebeat): `wazuh-manager 4.14.9-1` and `filebeat 7.10.2-2` held; package `ossec.conf` with the indexer at 10.0.5.10, authd off until 1.17, vulnerability detection off (decisions 96, 97); API on 127.0.0.1; Wazuh's `filebeat.yml`, index template and module pinned by SHA-256; credentials by `set-manager-credentials` (decision 95). Verified: all three services active; 795 alerts in `wazuh-alerts-4.x-2026.11.05` within minutes; `filebeat test output` OK over TLS 1.3; `IndexerConnector initialized`; API default logins 401; 1515 closed, 55000 on loopback; helper `unchanged`; root disk 33 %. Open: the new start order is proven only on the next fresh siem. Next: 3c dashboard
  - Verify: dashboard reachable from the admin pool only; the indexer's heap is 1.5 GB and the cluster is green; after a teardown and a new session, an alert from the previous session is still searchable and the dashboard certificate is unchanged; no Wazuh password appears in the repo, Terraform state or Ansible output
- [ ] **1.17** Wazuh agents and log collection on all hosts (§8 list) · C
  - Verify: agents show active; a Suricata alert, an nftables drop, a ModSecurity block and a VPN connect all appear in Wazuh
  - Note: Juice Shop's logs and rules are added in 2.13 (decision 71)
  - Note: before 2.15 starts, Wazuh must collect Suricata's `eve.json`, nftables drops (`FW-DROP`, `FW-EGRESS`, `FW-INPUT-DROP`), Nginx access and error logs, the ModSecurity audit log and OpenVPN connect and disconnect logs, each confirmed with a test event in the dashboard
  - Note: all hosts, `siem` included, are destroyed at every teardown, so Wazuh's data and the logs on each host go with them. Open question for Marko: export Wazuh's data and the evidence to the laptop before each teardown? (Open items)

**mon (moved from Tier 2 as T2.1, decision 84).** After 1.17, before the Juice Shop block.
- [ ] **1.22** `mon` host (10.0.5.20, t3.small) and role: Prometheus, Grafana and Alertmanager; Grafana reachable from the admin pool only (sg-mon, §4); design decisions first (install method, retention on a session-only host, alert channel) · C
  - Verify: Grafana answers on 10.0.5.20:3000 from the admin pool and times out from the user pool; Prometheus shows its own target `up`
  - Layer loop: hand build, compare with code, rebuild from code, second run `changed=0`
- [ ] **1.23** Exporters and alerts: node_exporter on every host (the vuln host too, across fw-ips: nftables rule by Marko and SG rule by IP), postgres_exporter on db, blackbox_exporter probing `https://mail.<domain>` (sg-proxy and the dmz NACL accept 443 from 10.0.5.20); Alertmanager rules for host down, disk over 80 %, certificate under 14 days, probe failing, and CPU credit balance near 0 · C
  - Verify: every target `up`; each alert fires once on a forced test (stop a host's exporter, a probe to a wrong name) and clears
  - Note: `mail.<domain>` resolves only through Unbound (VPN-only, §6), and mon uses AmazonProvidedDNS, so the probe targets 10.0.2.10 and sets the TLS server name (`tls_config.server_name`) instead of resolving the name

## Phase 2: Attack scenarios (§11)

Targets: own deployment only, never Google/Microsoft APIs. Each one follows attack → detection or miss → rule/fix → re-test.

**Juice Shop block, first (decisions 67 to 76).** Done first in Phase 2, after 1.16, 1.17, 1.22 and 1.23, so Wazuh and Grafana collect from every layer before anything is measured (decision 83 replaces decision 67's 1.19 gate). Same layer loop: hand build → test → compare with code → rebuild from code → re-test. Flow logs stay S3-only.

- [ ] **2.1** Outside: scan, then SQLi/XSS/brute force against Juice Shop during a 443 window from Marko's /32 only; Mailbridge is never exposed and its SQLi/XSS tests run from inside the VPN (decision 72) · M (done inside this block, after 2.15)
- [x] **2.7** Decisions 67 to 76 and the doc updates (ARCHITECTURE, TASKS, decisions, rationale, threat model) · C
  - Verify: Marko reviews the PR; ARCHITECTURE §1–4, 6–8, 11, 12 and the repo layout describe the vuln subnet, host, routes, listener and logs
- [ ] **2.8** Network: `vuln` subnet 10.0.6.0/24 with its own route table (`0.0.0.0/0`, `10.0.2.0/24`, `10.0.5.0/24 → fw ENI`), `10.0.6.0/24 → fw ENI` on the private table, `sg-vuln`, the vuln NACL, and the sg-proxy and dmz NACL additions; built by hand, then imported · M+C
  - Verify: `terraform plan` after import shows no changes; `describe-route-tables` shows the routes; SG rules on these paths name IPs, not groups (decision 68)
- [ ] **2.9** nftables on fw-ips: proxy → 10.0.6.10:3000 queued to Suricata, vuln egress limited to TCP 443, UDP 123 and siem 1514–1515, vuln → VPC dropped and logged, window DNAT to 10.0.2.10:8443 from Marko's /32; Suricata config for the routed path. Optional: limit vuln's 443 egress to AWS address ranges · **M**
  - Verify: Claude reviews; `nft list ruleset`; from the vuln host, `nc` to 10.0.4.10:5432 and 10.0.3.10:3000 time out and fw-ips logs the drops; `eve.json` shows `http` events for Juice Shop and none for mail
- [ ] **2.10** ECR repository `juice-shop` in `persistent` (decision 69); image mirrored by hand by digest; `modules/compute/vuln.tf` (t3.small, IMDSv2 hop 1, `credit_specification = "standard"`, `ssm-min` + pull on `juice-shop` only, `Role=vuln`, `vuln_enabled`); `vuln` role (Docker, pinned digest, container hardening, `DOCKER-USER` drop with logging, unroutable container DNS) · C
  - Verify: IAM simulator allows pull on `juice-shop` and denies `mailbridge` and `/mailbridge/*`; from inside the container, db, app, IMDS and the internet all fail and the drops are logged; second run `changed=0`
  - Layer loop: run the container by hand on a test host and record the working flags; write the role; `ansible-playbook --check --diff` against the hand build shows no difference; destroy the host (`vuln_enabled=false`, then `true`), run `site.yml` from code, repeat the checks above, and the second run reports `changed=0`
- [ ] **2.11** proxy: `vuln.<domain>` server block, its own certificate through `lego-renew@<name>`, decision 60 condition extended, the 8443 window listener; Unbound record on fw-ips · C
  - Verify: staging certificate with only `vuln.<domain>` in its SANs; the simulator allows its TXT and still denies `vpn.<domain>`; SNI `mail.<domain>` on 8443 gets a handshake alert
  - Layer loop: configure the server block, certificate service and Unbound record by hand first; write the role changes; `--check --diff` shows no difference; rebuild proxy and fw-ips from code (`hosts_enabled=false`, then `true`), repeat the checks above, and the second run reports `changed=0`
- [ ] **2.12** Per-server ModSecurity bundles (decision 71): `mail/` keeps decisions 63 to 66; `vuln/` with its own mode and paranoia level, JSON, form, multipart and XML bodies, `ABCFHZ` in `vuln-audit.log`; tested in the container harness first, including memory · C
  - Verify: Juice Shop at DetectionOnly and mail at On: the same SQLi gets 200 and 403, and both logs record it; only Juice Shop's entries have `request.body`
  - Layer loop: build both bundles by hand in the Ubuntu 24.04 container harness (real packages) and record memory; write the role changes; deploy, `--check --diff` shows no difference; rebuild proxy from code, repeat the checks above, and the second run reports `changed=0`
- [ ] **2.13** Wazuh: proxy agent reads both audit logs and JSON access logs; vuln agent reads `DOCKER-USER` drops; local rules 100100 to 100299 (ModSecurity match, block, DetectionOnly hit, brute force on 401s, IDOR enumeration, egress drop) · C
  - Verify: each rule fires once on a test event and appears in the dashboard
- [ ] **2.14** Attacker device certificate in the user pool (decision 73); `attacks/scope.conf` and the wrapper with rate caps (decision 75); separate browser profile for Juice Shop (decision 76) · M+C
  - Verify: attacker profile gets 10.8.0.x; the wrapper refuses 10.0.0.2, a public IP and `mail.<domain>` in a Juice Shop run
- [ ] **2.15** Matrix runs: {DetectionOnly, On} × paranoia level 1 to 4, each with GoTestWAF, the scripted challenges and the benign capture; Suricata rules on the decrypted path written by Marko · M
  - Verify: `findings-report.md` has the matrix (block %, bypass %, false positives %) and one table per attack class
- [ ] **2.16** Juice Shop window run (2.1) and its findings; window closed again · M
  - Verify: during the window only Marko's IP reaches 443; after it, `terraform plan` shows the window rules and record removed

**Close-out (after the Juice Shop block, decision 83)**
- [ ] **1.18** CloudTrail to S3, GuardDuty trial · C
  - Verify: events visible; trial end date noted in `progress.md`
- [ ] **1.19** End-to-end check: VPN, `https://mail.<domain>`, OAuth login with test accounts · M+C
  - Verify: `nmap -sU -p 1194` and a TCP scan from outside show only UDP 1194 open
- [ ] **1.20** Includes the deferred network rebuild (1.5c): `make up` rebuilds the lab from clean; second Ansible run is idempotent · M+C
  - Verify: second run reports `changed=0`
- [ ] **1.21** Update docs for any deviation; confirm teardown works · M+C
  - Verify: after `terraform destroy` of `lab` (approved), no billable lab resources remain

**Deferred until after 2.16.** Not started or planned before the Juice Shop block is finished: a known-vulnerable target first, to learn how ModSecurity, Suricata and Wazuh behave before attacking Mailbridge.
- [ ] **2.2** Inside: stolen VPN cert: reachability, visibility, time to revoke via CRL; include private hosts querying 10.0.0.2 directly (decision 30) · M
- [ ] **2.3** Malicious email: HTML/JS payload, sanitising, CSP · M
- [ ] **2.4** Access control: user A reading user B's mailbox by changing IDs · M
- [ ] **2.5** Complete `findings-report.md`; TCP 443 confirmed closed again · M
  - Verify: each scenario has all four steps recorded

**Any time, when Marko says so**
- [ ] **2.6** Switch to production Let's Encrypt certs, only when Marko says so · M+C
  - Verify: `curl https://mail.<domain>` succeeds without `-k`

**Tier 1 is done here.** Tier 2 starts only after this write-up.

## Tier 2 (gated)

- [x] **T2.1** Moved into Tier 1 as 1.22 and 1.23 (decision 84)
- [ ] **T2.2** App CI (§10): Jest, Playwright, k6, Trivy, SonarCloud, ZAP baseline
- [ ] **T2.3** S3 gateway endpoint with a separate `data` route table; nightly `pg_dump` to S3, plus a tested and documented restore
- [ ] **T2.4** ModSecurity engine ≥ 3.0.16 and the current CRS 4.25.x (the official CRS image pinned by digest, or an LTS engine once one ships 3.0.16), closing the 4.25.1 fixes 4.25.0 lacks, including the JSON bypass 4RI-250413 (decision 63)

## Tier 3 (gated)

- [ ] **T3.1** k3s for the app tier
- [ ] **T3.2** Vulnerability scanning (Nuclei/Greenbone)
- [ ] **T3.3** ISO 27001/NIS2 controls map
