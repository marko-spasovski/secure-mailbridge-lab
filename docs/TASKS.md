# Tasks & progress

Single tracker for the whole lab. Session notes go in `progress.md`, decisions in `decisions.md`.

**Status:** `[ ]` todo · `[~]` in progress · `[x]` done and verified
**Owner:** **M** = Marko writes it, Claude reviews · **C** = Claude drafts after an OK on the approach · **M+C** = shared

**Layer loop (network, fw-ips, db, app, proxy, siem):** build by hand → test → compare with code → destroy and rebuild from code → re-test. A layer is finished only after the rebuild passes. Remove paid hand-built resources at the end of each session.

A task is done only when its verify step passes. A phase is done only when `make up` deploys it,
it is verified, and the relevant doc section is updated.

## Current position

- **Phase:** 1, Tier 1 on AWS (0.6 and 0.7 still open)
- **Next task:** the "Before db" list below, then 1.13, the `db` role. fw-ips is in Terraform and Ansible and was rebuilt from code (2026-11-02).

## Before db (agreed 2026-11-02)

1. [x] **Session routine and second rebuild from code.** Passed 2026-11-02: every check below as expected, and the fallback AMI and snapshot are deleted. The first apply hit a race (the Elastic IP association ran while the instance was pending); a second apply finished it and the fix is `depends_on` in item 2. Commands, from the repo root, kept as the start-of-session routine:
   - `aws login`, then `aws sts get-caller-identity --query Arn --output text` (ends in `marko-admin`)
   - `ssh-add ~/.ssh/mailbridge-lab-ansible`
   - Claude saves the plan: `terraform -chdir=terraform/lab plan -out=<scratchpad>/on.tfplan` (expect 4 to add: instance, Elastic IP, association, `vpn` record). Marko runs `! cd terraform/lab && terraform apply <scratchpad>/on.tfplan`
   - New ID into the inventory: `sed -i "s/ansible_host: i-[0-9a-f]*/ansible_host: $(terraform -chdir=terraform/lab output -raw fw_instance_id)/" ansible/inventories/aws/hosts.yml`
   - Wait for first boot: `cd ansible && ansible fw_ips -m command -a 'cloud-init status --wait'` (expect `status: done`)
   - `ansible-playbook site.yml`, then again (expect `changed=0`)
   - Connect the VPN; `ping -c 3 10.0.1.10`; `dig +short @10.0.1.10 mail.<domain>` (expect `10.0.2.10`)
   - `terraform -chdir=terraform/lab plan` (expect no changes)
   - If all pass: delete the fallback AMI and its snapshot, with Marko's OK
2. [ ] **Small fixes, one PR each:** `depends_on = [aws_instance.fw]` on the Elastic IP association (found in item 1); remove `default` from the fw-ips ENI (§4); tighten the fw-ips role description and use the account ID instead of `*` in its grant; rule 1000004 `flow:to_server`, written by Marko and reviewed by Claude.
3. [ ] **Inventory from Terraform:** decide between the `aws_ec2` dynamic inventory and generating `hosts.yml` from `terraform output`, before more hosts make hand-edited IDs error-prone.
4. [ ] **Where `db`'s password lives** (part of 1.2): Terraform stores parameter values in state, so decide how `/mailbridge/db-password` is created. Consider importing the hand-built `persistent` pieces at the same time.

End every session with: Claude saves `terraform -chdir=terraform/lab plan -var fw_enabled=false -out=<scratchpad>/off.tfplan` (expect 4 to destroy), Marko disconnects the VPN and runs the apply, Claude confirms no instance, Elastic IP or volume is left.

## Open items

- [~] **Delegate the subdomain:** zone and NS records built by hand and verified with `dig`, parent MX unchanged. Import the zone in 1.2.
- [x] **Fallback AMI:** deleted with its snapshot on 2026-11-02 after the second rebuild passed. It was: keep `mailbridge-lab-fw-ips-handbuilt-2026-11-02` and its snapshot until the next session's rebuild from code also passes every check, then delete both. It's the only copy of the hand-built host, for inspecting anything the role may still miss.
- [x] **Session routine (decision 41, replaces decision 24):**
  - Start: `terraform -chdir=terraform/lab apply`, then put `terraform -chdir=terraform/lab output -raw fw_instance_id` into `ansible/inventories/aws/hosts.yml`, wait for `cloud-init status` = `done`, run `ansible-playbook site.yml` from `ansible/`, and connect the VPN.
  - End: `terraform -chdir=terraform/lab apply -var fw_enabled=false`, then check that no instance or Elastic IP is left.
- [x] **Ansible over SSM:** decided: SSH tunnelled through SSM with a laptop-only key (decision 36). fw-ips gets the public key once through SSM, because it was launched without a key pair.
- [x] **Suricata upkeep:** daily `suricata-update.timer` with `reload-rules`; the refusal was a test run replacing the command socket (decision 38).
- [~] **Default security group on the fw-ips ENI:** the ENI carries `mailbridge-lab-fw` and `default`. `default` has no rules, so it grants nothing, but §4 says sg-fw only. Fixed in code by decision 42; done once the apply is verified.
- [ ] **VPN client exits on the laptop:** the `openvpn` client process ended twice on 2026-11-02 (about 11:40, and after a server restart) instead of reconnecting. Read the client's last log lines next time it happens.
- [ ] **Own package mirror or proxy:** Marko wants to discuss this later. Parked until Tier 1 is finished; no design change yet.
- [ ] **SSH over the VPN:** proposed as a daily-use path from the admin pool, with SSM kept for emergencies. Discuss after 1.9b; no design change yet.
- [ ] **Mailbridge repo location:** where the source lives, so the image can be built and pushed to ECR. Needed for 1.14.

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
- [ ] **1.13** `db` role: PostgreSQL, app user, access from the app host only · C
  - Verify: connect succeeds from app, is refused from proxy
- [ ] **1.14** `app` role: Mailbridge from ECR pinned by digest, listening on 3000, secrets from SSM · C
  - Verify: `docker inspect` shows the pinned digest; port 3000 reachable from proxy, unreachable from the VPN directly
- [ ] **1.15** `proxy` role: Nginx, TLS, rate limit, ModSecurity v3 + CRS, `certbot-dns-route53` (staging) · C
  - Verify: `curl -k https://mail.<domain>` over VPN returns 200; `?id=1' OR '1'='1` gets 403 and is in the audit log

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
