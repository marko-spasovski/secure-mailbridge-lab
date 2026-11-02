# Tasks & progress

Single tracker for the whole lab. Session notes go in `progress.md`, decisions in `decisions.md`.

**Status:** `[ ]` todo · `[~]` in progress · `[x]` done and verified
**Owner:** **M** = Marko writes it, Claude reviews · **C** = Claude drafts after an OK on the approach · **M+C** = shared

**Layer loop (network, fw-ips, db, app, proxy, siem):** build by hand → test → compare with code → destroy and rebuild from code → re-test. A layer is finished only after the rebuild passes. Remove paid hand-built resources at the end of each session.

A task is done only when its verify step passes. A phase is done only when `make up` deploys it,
it is verified, and the relevant doc section is updated.

## Current position

- **Phase:** 1, Tier 1 on AWS (0.6 and 0.7 still open)
- **Next task:** 1.14, the `app` host and role. 1.13 (`db`) is done (2026-11-02). Mailbridge is being prepared for deployment in its own repo (`docs/deployment.md` there); its env vars, secret formats and the ADR 0008 role question feed 1.14.

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
- [~] **Mailbridge repo location:** a separate repo, being prepared for deployment (inventory and gaps in its `docs/deployment.md`, 2026-11-02). Still to decide in 1.14: where the image is built and pushed, the OAuth redirect URIs (the app uses `/accounts/callback/{gmail,outlook}`, not §6's `/oauth/callback`), `/mailbridge/session-secret`, and one or two DB roles (the app's ADR 0008).

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
  - Note: captures are synthetic, so re-test rules against real TLS in 1.15, then consider promoting them to `drop`. `reload-rules` was refused because a `suricata -r` test run replaced the daemon's command socket; tests on fw-ips use `--set unix-command.enabled=no` (decision 38).
  - Verify: `suricata -k none -r <pcap> -S <rules> --set unix-command.enabled=no` raises the expected alert; live traffic is dropped inline

**db, app, proxy**
- [x] **1.13** Built from code on 2026-11-02 and verified on db's side (decision 48); app→db and proxy→db are checked in 1.14 and 1.15. `db` role: PostgreSQL, app user, access from the app host only · C
  - Note: db reads `/mailbridge/db-password` with its own instance role and sets it on the host (decision 47)
  - Note: 2026-11-02, built in three PRs: the Terraform host and role (37), the `common` role (38), the `db` role (39). The helper `set-db-password` sets the password through stdin, never argv, a file or an Ansible variable (decision 52)
  - Verified 2026-11-02: second `site.yml` run `changed=0` on both hosts; PostgreSQL listens on 10.0.4.10 and 127.0.0.1 only; the SSM password logs in as `mailbridge` and a wrong one fails; `postgres` over TCP and `mailbridge` to another database get `no pg_hba.conf entry`; the role isn't superuser and can't create roles or databases; the password is stored as `SCRAM-SHA-256`; the value appears 0 times in the `-v` run log and the PostgreSQL logs; the IAM simulator allows only `/mailbridge/db-password`. From the admin pool, with a route to 10.0.4.0/24 added by hand (the pool gets no such route), `nc` to 5432 times out and fw-ips logs `FW-DROP` from 10.8.1.10
  - Note: the laptop needs the collections in `ansible/requirements.yml` (`ansible-galaxy collection install -r requirements.yml`)
  - Verify (decision 48, db side only): PostgreSQL listens on 10.0.4.10:5432; `pg_hba` allows only the app user from 10.0.3.10/32 with `scram-sha-256`; a local login with the SSM value works; `nc -zv -w 3 10.0.4.10 5432` from the VPN admin pool times out and fw-ips logs the drop; the IAM simulator allows only `/mailbridge/db-password`. "Connect from app" moves to 1.14 and "refused from proxy" to 1.15
- [ ] **1.14** `app` role: Mailbridge from ECR pinned by digest, listening on 3000, secrets from SSM · C
  - Note: two DB roles (decision 54): db creates `mailbridge_app`; app runs migrate as the owner, applies `db-roles.sql` with `psql`, then runs the app as `mailbridge_app`. Secrets generated in `persistent` (decision 55); OAuth secrets wait for 1.19
  - Note: secrets reach the containers through start scripts under systemd with `--rm` (decision 56); the image is built and pushed by hand for now, automated in T2.2 (decision 57). The app host and its role are in `modules/compute/app.tf`
  - Verify: `docker inspect` shows the pinned digest; port 3000 reachable from proxy, unreachable from the VPN directly; `psql` to 10.0.4.10 as the app user connects (decision 48)
- [ ] **1.15** `proxy` role: Nginx, TLS, rate limit, ModSecurity v3 + CRS, `certbot-dns-route53` (staging) · C
  - Verify: `curl -k https://mail.<domain>` over VPN returns 200; `?id=1' OR '1'='1` gets 403 and is in the audit log; `nc -zv -w 3 10.0.4.10 5432` from proxy times out (decision 48)

**siem**
- [ ] **1.16** `siem` role: Wazuh manager, indexer, dashboard · C
  - Verify: dashboard reachable from the admin pool only
- [ ] **1.17** Wazuh agents and log collection on all hosts (§8 list) · C
  - Verify: agents show active; a Suricata alert, an nftables drop, a ModSecurity block and a VPN connect all appear in Wazuh

**Close-out**
- [ ] **1.18** CloudTrail to S3, GuardDuty trial · C
  - Verify: events visible; trial end date noted in `progress.md`
- [ ] **1.19** End-to-end check: VPN, `https://mail.<domain>`, OAuth login with test accounts · M+C
  - Verify: `nmap -sU -p 1194` and a TCP scan from outside show only UDP 1194 open
- [ ] **1.20** Includes the deferred network rebuild (1.5c): `make up` rebuilds the lab from clean; second Ansible run is idempotent · M+C
  - Verify: second run reports `changed=0`
- [ ] **1.21** Update docs for any deviation; confirm teardown works · M+C
  - Verify: after `terraform destroy` of `lab` (approved), no billable lab resources remain

## Phase 2: Attack scenarios (§11)

Targets: own deployment only, never Google/Microsoft APIs. Each one follows attack → detection or miss → rule/fix → re-test.

- [ ] **2.1** Outside: scan, then SQLi/XSS/brute force during a 443 window · M
- [ ] **2.2** Inside: stolen VPN cert: reachability, visibility, time to revoke via CRL; include private hosts querying 10.0.0.2 directly (decision 30) · M
- [ ] **2.3** Malicious email: HTML/JS payload, sanitising, CSP · M
- [ ] **2.4** Access control: user A reading user B's mailbox by changing IDs · M
- [ ] **2.5** Complete `findings-report.md`; TCP 443 confirmed closed again · M
  - Verify: each scenario has all four steps recorded
- [ ] **2.6** Switch to production Let's Encrypt certs, only when Marko says so · M+C
  - Verify: `curl https://mail.<domain>` succeeds without `-k`

**Tier 1 is done here.** Tier 2 starts only after this write-up.

## Tier 2 (gated)

- [ ] **T2.1** `mon` host: Prometheus, Grafana, Alertmanager, exporters
- [ ] **T2.2** App CI (§10): Jest, Playwright, k6, Trivy, SonarCloud, ZAP baseline
- [ ] **T2.3** S3 gateway endpoint with a separate `data` route table; nightly `pg_dump` to S3, plus a tested and documented restore

## Tier 3 (gated)

- [ ] **T3.1** k3s for the app tier
- [ ] **T3.2** Vulnerability scanning (Nuclei/Greenbone)
- [ ] **T3.3** ISO 27001/NIS2 controls map
