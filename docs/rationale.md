# Design rationale

The reasoning behind each design decision. `decisions.md` is the one-line index; this file is the interview preparation.

Each section covers the problem, the options, the choice, the trade-off and how to verify it.

---

## 1. Mailbridge image in ECR, pinned by digest (2026-10-31)

**Problem.** The `app` host must get the Mailbridge image from somewhere. That choice decides whether the host holds a registry credential and whether we can prove what is running.

**Options.** A: Amazon ECR. B: GitHub Container Registry with a pull token in SSM. C: build on the `app` host.

**Chosen: A.** The `app` instance gets an IAM role allowing `ecr:GetAuthorizationToken` plus pull actions on one repository. An instance role delivers temporary credentials through the instance metadata service, and they rotate automatically. With IMDSv2 required, reading them needs a session token obtained by a `PUT` request, which blocks the classic SSRF attack where a vulnerable app is tricked into a simple `GET` against the metadata address. Stored keys, by contrast, never expire and can leak through backups, logs or a compromised disk. Least privilege applies too: this role can pull one repository and cannot push.

Tags such as `:latest` are mutable pointers, so the same tag can mean different code tomorrow. A digest (`image@sha256:...`) is a hash of the image content, so a pinned deployment runs exactly the reviewed image, or fails. Trivy results also stay meaningful because they describe that exact digest.

**Trade-off accepted.** About $0.10/GB per month, more IAM surface in §7, and each release needs its digest updated in configuration.

**Verify once built.** On `app`, `docker inspect --format '{{index .RepoDigests 0}}' <container>` shows the pinned digest. `aws ecr batch-delete-image` from `app` returns `AccessDenied`. `grep -rn "aws_secret_access_key" ansible/ terraform/` finds nothing.

---

## 2. Route 53 for DNS and the DNS-01 challenge (2026-10-31)

**Problem.** `mail.<domain>` resolves only inside the VPN and TCP 443 is closed to the internet, yet it needs a Let's Encrypt certificate. Let's Encrypt must be able to validate domain ownership without reaching the server.

**Options.** A: Route 53. B: Cloudflare DNS with a zone-scoped API token. C: a delegated subdomain of a domain already owned.

**Chosen: A.** HTTP-01 validation requires Let's Encrypt to connect to the server, which this design forbids. DNS-01 instead asks Certbot to publish a TXT record at `_acme-challenge.mail.<domain>`, which Let's Encrypt looks up in public DNS. No inbound port is needed, so this works for a private server.

Delegation is how the domain reaches Route 53: the registrar's NS records are set to the four name servers of the Route 53 hosted zone, so the registrar can be any company. Public DNS holds only the challenge record and `vpn.<domain>`. The `mail` A record stays in Unbound.

`certbot-dns-route53` authenticates with the `proxy` instance role, using the same temporary credentials as decision 1. Cloudflare would need a long-lived token in SSM. The policy allows `route53:ListHostedZones`, `route53:GetChange` and `route53:ChangeResourceRecordSets` on this zone only, with `ChangeResourceRecordSets` conditioned to the `_acme-challenge` name, so a compromised proxy cannot repoint `vpn.<domain>`.

**Trade-off accepted.** About $0.50/month per zone, unlike free Cloudflare DNS. Production certificates also appear in public Certificate Transparency logs, so the hostname `mail.<domain>` is public knowledge even though it does not resolve publicly.

**Verify once built.** `dig NS <domain> +short` returns the Route 53 name servers. `dig mail.<domain> @1.1.1.1 +short` returns nothing. `certbot renew --dry-run` succeeds on `proxy`.

---

## 3. Elastic IP in lab, clients use vpn.<domain> (2026-10-31)

**Problem.** The `lab` stack is destroyed after each session, but `.ovpn` profiles on client devices need a stable target. AWS charges for public IPv4 addresses even when they are not attached to anything.

**Options.** A: Elastic IP in `lab`, with profiles using `vpn.<domain>`. B: Elastic IP in `persistent`, with profiles using the raw IP.

**Chosen: A.** Public IPv4 costs about $0.005/hour, which is about $3.60/month for an address held while the lab is down. Under A the address exists only during a session, and `terraform apply` of `lab` writes its current value to `vpn.<domain>` in the persistent hosted zone. A profile contains `remote vpn.<domain> 1194 udp`, so a new IP needs no profile change. A low TTL (60 seconds) limits how long resolvers cache the previous address after a rebuild.

The Budget sits in `persistent` because a spending alert must outlive every teardown.

**Trade-off accepted.** The VPN now depends on public DNS working, the IP cannot be allowlisted anywhere, and a client may wait up to one TTL after a rebuild.

**Verify once built.** After `apply`, `dig vpn.<domain> +short` matches `terraform output` for the IP, and the record's TTL shows 60. After destroying `lab`, `aws ec2 describe-addresses` returns no addresses. The same `.ovpn` file connects across two rebuilds.

---

## 4. Bottom-up build order: db → app → proxy (2026-10-31)

**Problem.** The original order built `proxy` and `app` before their dependencies existed, so neither could be fully tested when finished.

**Options.** A: db → app → proxy. B: keep the original order and accept failures until `db` exists. C: keep the order and put a stub container behind `proxy`.

**Chosen: A.** Building bottom-up means each layer is tested against the real layer beneath it. When a step fails, the fault is in the newest layer, because everything below is already verified. B makes expected errors look like real ones. C works, but writes a stub that gets thrown away.

**Trade-off accepted.** The WAF is tested later than it would be with a stub, and `app` has no browser-facing path until `proxy` exists, so it is checked from inside the network first.

**Verify once built.** `psql` from `app` connects before the `app` role runs. `curl http://10.0.3.10:3000` from `proxy` succeeds before the `proxy` role runs. `https://mail.<domain>` then returns 200 on the first try.

---

## 5. NAT on fw-ips before the full nftables policy (2026-10-31)

**Problem.** Private hosts are managed through SSM, and the SSM agent makes outbound HTTPS calls to AWS service endpoints. Private subnets have no internet route except through fw-ips, and there is no NAT Gateway or interface endpoint because both bill hourly.

**Options.** A: split the work into NAT first, full policy second. B: write the whole ruleset as one task.

**Chosen: A.** A private host has only a private address. Without source NAT on fw-ips, its packets could leave but replies could never return, so the agent never registers and Ansible over SSM cannot reach the host. fw-ips also needs source/destination check disabled, since it forwards traffic that is not addressed to it. Masquerading therefore comes first, and it needs only forwarding plus NAT to prove the path. The least-privilege policy is added on top, so a later SSM failure points to one new rule rather than an entire ruleset. Both steps stay hand-written by Marko.

**Trade-off accepted.** A short window where forwarding is less restricted than the final policy. It is limited because private hosts have no inbound path from the internet, and it closes before the private hosts are configured. fw-ips is also a single point of failure for all private egress, an accepted lab cost.

**Verify once built.** `aws ssm describe-instance-information` lists private hosts as `Online`. From `db`, `curl -sI https://ssm.eu-central-1.amazonaws.com` gets a response, and the source address seen outside is the fw-ips Elastic IP.

---

## 6. Public repo with branch protection (2026-10-31)

**Problem.** The convention "merge only on green CI" is only a promise unless GitHub enforces it.

**Options.** A: public repo. B: private now, public after Tier 1.

**Chosen: A.** On a free personal account, branch protection is available for public repos but not private ones. With required status checks on `main`, GitHub refuses a merge until the six CI jobs pass, so the rule is enforced by a system rather than by discipline. The repo also works as a public portfolio piece.

Public visibility raises the stakes on secrets. `gitleaks` runs in pre-commit and in CI, and `.gitignore` excludes state, keys and profiles. Terraform state, which can contain sensitive values, lives only in the state bucket. Anything committed must be treated as permanently public, even if removed later, so a leaked secret must be rotated rather than just deleted.

**Trade-off accepted.** The network design, the domain and eventually the findings are visible to anyone. Security must not depend on the design being secret, which is the right assumption anyway (Kerckhoffs's principle), but real IPs, tokens and unfixed-vulnerability details stay out of the repo.

**Verify once built.** `gh api repos/rossiko22/secure-mailbridge-lab/branches/main/protection` shows the required checks. A PR with a failing job cannot be merged.

---

## 7. Security groups in their own module (2026-10-31)

**Problem.** Security groups could live with the network resources they sit on, or in their own module.

**Options.** A: separate `modules/security`. B: everything in `modules/network`.

**Chosen: A.** The network module answers where packets can go, and the security module answers who is allowed. Keeping them apart means the rules can be reviewed line by line against §4 without routing mixed in. The module takes `vpc_id` as input and attaches `sg-fw` to the fw-ips ENI using `aws_network_interface_sg_attachment`, so dependencies flow one way. Rules are separate resources rather than inline blocks, because `sg-app` and `sg-proxy` reference each other and inline rules would form a cycle.

**Trade-off accepted.** More wiring in the root stack, and the fw-ips ENI briefly holds only the empty default group during creation.

**Revised by decision 42.** The attachment left `default` on the ENI, so the ENI now declares its own groups and network takes sg-fw's ID from security.

**Verify once built.** `aws ec2 describe-network-interfaces` shows `sg-fw` on the ENI. Each rule in `aws ec2 describe-security-group-rules` maps to a §4 row or the egress table.

---

## 8. S3 gateway endpoint deferred (2026-10-31)

**Problem.** The endpoint lets `db` reach S3 without passing through fw-ips, but only Tier 2 backups use it.

**Options.** A: include it now. B: add it in T2.3 with backups.

**Chosen: B.** Unused infrastructure is something to explain and secure with no benefit, and the project gate says Tier 2 components wait. A gateway endpoint works by adding a route to chosen route tables, so a later `data`-only endpoint needs `data` on its own route table. Until then one private table serves all four private subnets.

**Trade-off accepted.** T2.3 has to add a route table and move one subnet association. The deployed network differs from the final design until then, which §2 records.

**Verify once built.** `aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=<vpc-id>` returns an empty list in Tier 1.

---

## 9. Explicit egress per security group (2026-10-31)

**Problem.** §4 listed only inbound rules. AWS security groups allow all egress by default, but Terraform removes that default, so egress must be stated. The question is how much to allow.

**Options.** A: explicit egress per group. B: allow all, and rely on nftables.

**Chosen: A.** This is defence in depth: egress filtering limits what a compromised host can do, such as scanning sideways or reaching a server that is not its next hop. Security groups are enforced by AWS outside the instance, so root on the host cannot alter them. Under B, traffic to neighbours in the same subnet would never reach fw-ips at all, so nftables could not see it. Stateful tracking means replies need no rules of their own. Traffic to the Amazon DNS resolver and metadata service is not filtered by security groups at all, which is why neither appears here.

`sg-fw` is the exception, with all egress allowed, because it forwards traffic for the whole VPC and nftables applies the policy there.

**Trade-off accepted.** More rules, and each new flow needs an egress rule as well as an ingress rule. A missing rule fails silently as a timeout. `apt` over port 80 is blocked here as well as in nftables, so HTTPS mirrors remain the expected fix.

**Verify once built.** From `proxy`, `nc -zv 10.0.4.10 5432` times out while `nc -zv 10.0.3.10 3000` connects. From `db`, `curl -sI https://ssm.eu-central-1.amazonaws.com` responds.

---

## 10. Standalone fw-ips network interface (2026-10-31)

**Problem.** Private route tables must point at fw-ips, but the instance is created later and is replaced more often than the routes should change.

**Options.** A: a standalone ENI in `modules/network`. B: an instance-owned interface, with routes created after it.

**Chosen: A.** A route to an ENI is valid before anything is attached to it, and the network layer stops depending on compute. Because the ENI outlives the instance, the fixed address `10.0.1.10`, source/destination check setting and security group all survive instance replacement. Source/destination check must be off, as fw-ips forwards packets that are not addressed to it.

**Trade-off accepted.** Until an instance attaches, private routes show as `blackhole`, which is expected in the network-only stage.

**Verify once built.** `aws ec2 describe-route-tables` shows the routes `active` after fw-ips is attached. `aws ec2 describe-network-interfaces` shows `SourceDestCheck: false`.

---

## 11. Hand build, compare, rebuild from code (2026-10-31)

**Problem.** Marko must understand and defend every part of the lab, but the final deployment must still be repeatable with `make up`. Generating code alone teaches little, and a hand-built lab cannot be reproduced.

**Options.** A: per layer, build by hand, test, compare with code, rebuild from code. B: build all of Tier 1 by hand, then write all the code. C: code first with a walkthrough.

**Chosen: A.** The layers are network, fw-ips, db, app, proxy and siem. Each goes through four steps: build by hand, test, compare, rebuild. For infrastructure, `terraform import` brings the hand-built resources into state, and `terraform plan` then shows any difference between code and reality, known as drift. For configuration, `ansible-playbook --check --diff` does the same job. Comparison alone proves the code describes the build, not that it can create it, so the hand-built version is destroyed and redeployed from code, then the same tests run again. Ordering problems only appear on that clean deploy.

**Trade-off accepted.** Slower progress, and every layer is built twice. Hand-built resources also keep billing until deleted, so paid resources are removed at the end of each session.

**Verify once built.** After import, `terraform plan` reports no changes. After the rebuild, every test in the layer's tasks passes. For Ansible, a second run on a fresh host reports `changed=0`.

---

## 12. VPC flow logs to S3 (2026-10-31)

**Problem.** nftables and Suricata only see traffic crossing fw-ips. Traffic between two hosts in the same subnet never reaches it, so an attacker moving sideways there would be invisible. checkov also flags the VPC for having no flow logs.

**Options.** A: flow logs to S3. B: skip them for Tier 1. C: flow logs to CloudWatch Logs.

**Chosen: A.** Flow logs record metadata for each network interface: addresses, ports, protocol, bytes and whether traffic was accepted or rejected. They hold no packet contents. A `REJECT` entry also shows a security group stopping something, which is direct evidence for the "inside attacker" scenario. The bucket sits in `persistent`, because a bucket in `lab` would lose the evidence at each teardown, and a lifecycle rule expires objects after 30 days. S3 costs less than CloudWatch ingestion and needs no separate delivery role. A 60-second aggregation interval gives tighter attack timelines.

**Trade-off accepted.** Logs still arrive minutes late, so this is for investigation rather than live alerting, and Wazuh does not read them in Tier 1. Queries mean downloading files or using Athena.

**Verify once built.** `aws ec2 describe-flow-logs` shows `ACTIVE`. After a blocked connection attempt, objects appear in the bucket and contain a `REJECT` record for that address and port.

---

## 13. NACL return traffic and service port denies (2026-10-31)

**Problem.** NACLs are stateless, so replies need their own rules, and those replies land on ephemeral ports (1024–65535). Replies from the internet can come from any address, so private subnets need that range open from `0.0.0.0/0`. The range also contains ports 3000, 5432, 1514 and 1515, so a simple return rule would quietly undo the "one hop" design at this layer.

**Options.** A: an explicit deny for each service port, numbered just before the return rule. B: return rules only, relying on security groups. C: narrow return rules to known sources, which cannot work for internet replies.

**Chosen: A.** NACL rules are checked in number order and the first match wins. Allowing the legitimate source at 100, denying the same port from everywhere at 105 and allowing ephemeral ports at 110 means the port stays limited to its one permitted source. The second layer then stands alone, as §4 intends.

**Trade-off accepted.** Three extra rules to maintain, and any new service in that port range needs its own deny. NACLs stay coarse: they work on subnets, so they cannot express per-host rules the way security groups can. Traffic to the Amazon DNS resolver and metadata service is not filtered by NACLs.

**Verify once built.** With the `db` security group temporarily opened to the DMZ, `nc -zv 10.0.4.10 5432` from `proxy` still times out and flow logs show `REJECT`. Restore the group afterwards.

---

## 14. Laptop credentials with aws login (2026-10-31)

**Problem.** Terraform on the laptop needs AWS credentials, and no access keys exist by design.

**Options.** A: `aws login`. B: run Terraform in CloudShell. C: create access keys.

**Chosen: A.** `aws login` signs in through the browser with the existing console identity and MFA, then gives the CLI short-lived credentials. This is the same principle as decision 1: a credential that expires limits the damage if it leaks, and an access key does not. If a tool cannot read these credentials directly, `aws configure export-credentials --format env` passes them through as environment variables.

**Trade-off accepted.** Sessions expire, so long work needs signing in again, and it depends on a recent AWS CLI. It also still uses `AdministratorAccess`, so a session on the laptop is powerful while it lasts.

**Verify once built.** After `aws login`, `aws sts get-caller-identity` shows `marko-admin` or its login session. `~/.aws/credentials` contains no access key.

---

## 15. Terraform state in S3 (2026-10-31)

**Problem.** State maps code to real resources and can contain sensitive values. Losing it means Terraform no longer knows what it manages, and each rebuild in this project depends on it.

**Options.** A: an S3 bucket built by hand now. B: local state, migrated later.

**Chosen: A.** S3 keeps state off the laptop. Versioning allows recovery from a bad write, encryption protects it at rest, and blocking public access keeps it private. S3 native locking (`use_lockfile`) stops two runs writing at once, without a DynamoDB table. The bucket is hand-built and later imported into `terraform/persistent`, since a stack cannot create the bucket holding its own state. The backend block stays partial, with the bucket name in a gitignored `backend.hcl`, because the name contains the account ID and the repo is public.

**Trade-off accepted.** A small storage cost, a bootstrap step that cannot be fully automated, and a manual `-backend-config=backend.hcl` on init.

**Verify once built.** `aws s3api get-bucket-versioning` shows `Enabled`. After `terraform apply`, `aws s3 ls` shows the state object. `git check-ignore backend.hcl` prints the name.

---

## 16. Keep the hand-built network, defer the rebuild test (2026-10-31)

**Problem.** The layer loop ends with destroying the hand build and rebuilding from code. Marko prefers to keep the network built by hand.

**Options.** A: rebuild now. B: defer the rebuild and build fw-ips on the existing network.

**Chosen: B.** Terraform already manages all 114 resources and `plan` reports no changes, so the network is fully under code control. VPCs, subnets, route tables, security groups, NACLs and an unattached ENI have no hourly charge, so nothing needs to be torn down to save money. Paid resources, starting with instances and the Elastic IP, are still removed after each session.

**Trade-off accepted.** The code has proven that it describes the network, not that it can create it. Ordering problems stay hidden until the first full rebuild, which then involves more resources. `make up` cannot count as verified for this layer until that test has run.

**Verify once built.** Run `terraform destroy` and `terraform apply` once before Tier 1 closes (task 1.20), then re-run the 1.5a checks. `terraform plan` reports no changes.

---

## 17. Pinned CI with documented checkov skips (2026-10-31)

**Problem.** CI must enforce "merge only on green", but a workflow that follows moving tags can change without any commit here, and checkov flags two things that are not real problems.

**Options.** A: pin actions by commit, and skip each false positive with a written reason. B: use version tags and turn the two checks off globally.

**Chosen: A.** A Git tag such as `v7` can be moved, so a compromised action could reach every repo that follows it. This is a supply chain attack. A commit SHA identifies exact content, the same idea as digest pinning in decision 1. The token is read-only. Skips sit next to the resource they apply to and state why, so the check stays active for everything else. `CKV2_AWS_5` is skipped for security groups the compute module will attach, and those skips come out in task 1.6. `CKV2_AWS_1` is skipped because checkov cannot trace `subnet_ids` across modules.

**Trade-off accepted.** Pinned versions need updating by hand, and a skip can go stale if nobody removes it.

**Verify once built.** The pull request shows six green checks. `grep -rn 'checkov:skip' terraform` lists each skip with its reason.

---

## 18. fw-ips operating system (2026-11-01)

**Problem.** `ARCHITECTURE.md` did not set an operating system, and fw-ips runs the most security-critical software in the lab: OpenVPN, nftables, Suricata and Unbound.

**Options.** A: Ubuntu 24.04 LTS. B: Amazon Linux 2023. C: Debian 12.

**Chosen: A.** An LTS release gets security updates for years, so unattended updates stay meaningful for the life of the lab. The official Canonical AMI ships with the SSM agent, which Session Manager needs from first boot. The packages the host depends on are mainstream on Ubuntu, and most documentation and interview examples assume Debian-family tooling. Amazon Linux fits AWS closely but has a smaller package set for this stack. Debian would also work, but its AWS images need more checking around the SSM agent.

**Trade-off accepted.** Ubuntu installs the SSM agent as a snap, which is less plain than an apt package, and its default mirrors commonly use port 80, which the public NACL blocks. That second point is tracked as an open item and tested right after launch.

**Verify once built.** On fw-ips, `lsb_release -d` prints `Ubuntu 24.04` and `snap list amazon-ssm-agent` lists the agent.

---

## 19. Delegated subdomain for `<domain>` (2026-11-01)

**Problem.** The lab needs a public DNS zone in Route 53 for `vpn.<domain>` and Certbot's DNS-01 challenge. Marko already owns domains, so none needs buying, but they already have DNS records, including email forwarding.

**Options.** A: delegate one subdomain of an existing domain to Route 53. B: move a whole existing domain to Route 53. C: use a different owned domain that may be serving a live site.

**Chosen: A.** NS records say which servers answer for a name. Adding NS records for one subdomain hands over only that subdomain, while the parent's provider keeps answering for everything else. Moving the whole domain would break email forwarding until those records were recreated. This also limits blast radius, because a mistake in the lab zone cannot touch the parent. Certbot and the proxy role work unchanged, since the `_acme-challenge` record sits inside the delegated zone. The real name stays out of this public repo, in line with keeping the state bucket name private.

**Trade-off accepted.** Names are one label longer, and DNS now spans two providers. The zone costs about $0.50 a month and stays between sessions.

**Verify once built.** `dig +short NS <domain>` returns the four Route 53 name servers, and the parent domain's MX records are unchanged.

---

## 20. Package updates over HTTPS (2026-11-01)

**Problem.** Ubuntu's default apt sources use `http://`, but the public NACL allows outbound TCP 443 and not 80. A test on fw-ips confirmed it: the HTTP mirror timed out, and the HTTPS regional mirror returned 200.

**Options.** A: point apt at the HTTPS regional mirror. B: open outbound TCP 80. C: run an own package mirror or proxy.

**Chosen: A.** apt already verifies packages with Ubuntu's GPG signatures, so the choice is not about package integrity. It is about firewall policy. HTTPS needs no change to §4, while opening port 80 would widen the NACL and nftables policy for all traffic, not only updates. HTTPS also hides which packages a host installs from anyone watching the network. C gives the most control but adds a service to run and pay for. Marko wants to discuss it after Tier 1, so it is parked as an open item.

**Trade-off accepted.** A new instance starts with `http://` sources, so every Ansible role must set HTTPS before installing anything.

**Verify once built.** `grep -rh '^URIs:' /etc/apt/sources.list.d/` shows only `https://`, and `sudo apt-get update` finishes with no `Err:` or `Failed to fetch`.

---

## 21. Offline VPN CA (2026-11-01)

**Problem.** OpenVPN trusts any certificate the CA signed, and the name in a certificate selects the user or admin pool. Whoever holds the CA private key can issue an admin identity. The docs did not say where that key lives.

**Options.** A: CA on the laptop, with an encrypted backup in SSM. B: CA on fw-ips, with a backup in SSM. C: CA in SSM, fetched to fw-ips only for signing.

**Chosen: A.** fw-ips is the only internet-facing host, and it does not need the CA key: it verifies clients with the public `ca.crt` and needs only its own server key and the CRL. With an offline CA, full compromise of fw-ips does not give the attacker the power to mint certificates. B loses the whole PKI on that compromise. C has the same exposure as B, because the fw-ips role must be allowed to read the key. The backup uses `/vpn/`, not `/mailbridge/`, because the app role can read `/mailbridge/*`. The key is passphrase-encrypted before it reaches SSM, and decision 22 removes parameter read from the instance roles. Without decision 22 the passphrase would be the only protection, because `AmazonSSMManagedInstanceCore` can read and decrypt the backup.

**Trade-off accepted.** Issuing and revoking happen on the laptop, and each revocation needs a new CRL copied to fw-ips, which slows the response measured in scenario 2.2. Losing the laptop or the passphrase means restoring from the backup or rebuilding the PKI. The CRL also has an expiry, and OpenVPN rejects clients once it lapses, so it must be re-signed in time. The backup holds the encrypted key and `ca.crt`, not easy-rsa's certificate database, so a restore brings back signing but not the record of issued certs; those would be reissued.

**Verify once built.** `sudo find / -name 'ca.key' -not -path '/proc/*' -not -path '/usr/share/doc/*'` on fw-ips prints nothing (OpenVPN ships a sample `ca.key` under `/usr/share/doc`). `pki/private/ca.key` on the laptop starts with `ENCRYPTED PRIVATE KEY`. `aws ssm describe-parameters` shows the `/vpn/` parameter as `SecureString`.

---

## 22. Minimal SSM policy for instance roles (2026-11-01)

**Problem.** §7 gave every host `AmazonSSMManagedInstanceCore`, assumed to be the SSM minimum. Reading the policy showed `ssm:GetParameter` and `ssm:GetParameters` on `Resource: *`, and the IAM simulator returned `allowed` for the fw-ips role. The `aws/ssm` KMS key policy decrypts through SSM for any principal in the account, so `SecureString` adds no restriction here. Any host could read the CA backup and every `/mailbridge/*` secret, which defeats one role per instance.

**Options.** A: a customer-managed copy of the policy without the two parameter actions, plus a narrow grant per host. B: keep the AWS policy and add an explicit `Deny` per host and path. C: encrypt secrets with a customer-managed KMS key.

**Chosen: A.** It removes the cause on every host, costs nothing and fails safe: a new host reads nothing until it is granted access. B fails open, because one forgotten `Deny` exposes the secrets again. C also fails safe but costs about $1 a month per key and leaves the broad permission in place.

**Trade-off accepted.** The policy is maintained here, so AWS's updates to the managed policy do not arrive automatically. If a future agent feature needs another action, it has to be added by hand.

**Verify once built.** `aws iam simulate-principal-policy` for the fw-ips role returns `implicitDeny` on `/vpn/ca/key` and `/mailbridge/*` and `allowed` on `/vpn/fw-ips/*`. Session Manager still connects and the instance stays `Online`.

---

## 23. Dynamic VPN user addresses (2026-11-01)

**Problem.** §5 places certificates in pools with `client-config-dir`, but did not say how user devices get addresses or what happens to a valid certificate with no `ccd` file.

**Options.** A: `ccd-exclusive` with a fixed address per device. B: a dynamic user pool, with a `ccd` file only for admin devices.

**Chosen: B.** Users draw from a pool in 10.8.0.0/24 and the admin device keeps a fixed address in 10.8.1.0/24. A would map each address directly to one device and refuse any certificate with no file. B fits Marko's goal for the attack scenarios: after a stolen certificate is used, the investigation has to prove who held an address at a given time from OpenVPN's connection logs in Wazuh, as it would in a larger VPN.

**Trade-off accepted.** OpenVPN logs become required evidence, so losing them loses attribution. Alerts and connection events must be matched by time, which depends on NTP. nftables and Suricata cannot target one user device by address. Any valid certificate can connect, so revocation is the only way to cut one off. An admin certificate with a missing `ccd` file lands in the user pool.

**Verify once built.** A user certificate gets an address in 10.8.0.0/24, `marko-laptop` gets 10.8.1.10, and `journalctl -u openvpn-server@server` shows each certificate's name with its address. Attribution must use the `primary virtual IP` line, because `MULTI_sva: pool returned` is logged before the `ccd` file is applied and can show an address the client never used.

---

## 24. Stop fw-ips between sessions during the hand build (2026-11-01)

**Problem.** The method says paid hand-built resources are removed after each session, but terminating fw-ips would delete its hand-made OpenVPN config, which is not yet in Ansible.

**Options.** A: stop the instance and release the Elastic IP. B: stop the instance and keep the Elastic IP. C: terminate and rebuild by hand each session.

**Chosen: A, as a documented exception.** Stopping ends compute charges and keeps the config on the disk. Releasing the Elastic IP removes its hourly charge. Client profiles use `vpn.<domain>`, so only the DNS record changes. C would repeat the build each session. The exception ends when the Ansible role can rebuild fw-ips, and then `terraform destroy` applies as §12 says.

**Trade-off accepted.** The disk bills about $2 a month while stopped. Each session starts by allocating a new address and updating the record, and until then the `vpn` record points at an address AWS may give to someone else. Clients would still refuse it, because `verify-x509-name` and `tls-crypt` fail.

**Verify once built.** After stopping, `aws ec2 describe-addresses` returns nothing and the instance state is `stopped`.

## 25. Forwarding and NAT on a single interface (2026-11-01)

**Problem.** fw-ips has one ENI, so internet and VPC traffic both enter and leave on `ens5`. Interface matches can't tell them apart. VPN pools must also stay un-NATed, because §2 needs the real client address on every event.

**Options.** A: match on addresses and `snat` private subnets to 10.0.1.10. B: `masquerade` everything in `10.0.0.0/16`. C: add a second ENI to separate the traffic.

**Chosen: A.** The rules match private sources and non-VPC destinations, on TCP 443 and UDP 123 as §4 allows. `snat` suits a fixed address, and the internet gateway maps it to the session's Elastic IP, so the rule survives address changes. `send_redirects` is off, because Linux would otherwise tell senders to bypass the firewall. C costs nothing extra but adds a subnet design change for no Tier 1 benefit.

**Trade-off accepted.** 10.0.1.10 and `ens5` are hardcoded in `define` lines. Until 1.9b, there is no `input` chain, so `sg-fw` alone protects fw-ips itself. Drop logs are rate limited, so a flood can lose entries.

**Verify once built.** `sudo nft list ruleset` shows both chains; a private test host shows `Online` in SSM; `FW-EGRESS` entries appear in the journal.

## 26. NFQUEUE in a separate chain (2026-11-01)

**Problem.** Suricata (1.11) must see every packet in a flow. A queue rule after the `established` accept would see only the first packets, and a packet Suricata accepts skips the rest of its chain, so a queue rule before the policy rules could bypass them.

**Options.** A: a separate base chain at a later priority. B: queue at the top of the policy chain. C: queue after the `established` accept.

**Chosen: A.** Packets pass the firewall first, and only allowed traffic reaches Suricata. The 1.9a ruleset needs no rewrite.

**Trade-off accepted.** There are two forward chains to reason about, and the order depends on their priorities. What happens if Suricata stops is still to be decided in 1.11.

**Verify once built.** `suricata -T` passes, and `eve.json` shows a full `tun0` flow, not just its first packets, while dropped traffic never reaches it.

## 27. VPN clients reach Unbound (2026-11-01)

**Problem.** Clients are pushed DNS 10.0.1.10, but the pushed routes cover only `10.0.2.0/24` and `10.0.5.0/24`, and §4 had no rule allowing the VPN pools to reach Unbound. `mail.<domain>` could not resolve over the VPN.

**Options.** A: allow port 53 from the pools to 10.0.1.10 and push a /32 route. B: move DNS to the tunnel address 10.8.0.1. C: leave it blocked.

**Chosen: A.** §5 and §6 keep one DNS address, and 1.10's check stays the same. A /32 route exposes no other host in the public subnet. B depends on `tun0` existing when Unbound starts. C breaks the app.

**Trade-off accepted.** A stolen user cert can now query Unbound, which adds a DNS path alongside the proxy. Forwarded traffic is still limited to the proxy on 443.

**Verify once built.** From the VPN, `dig @10.0.1.10 mail.<domain> +short` returns 10.0.2.10.

## 28. Input policy on fw-ips (2026-11-01)

**Problem.** §4 covers forwarded traffic but says little about fw-ips itself, the highest-risk host. The input rules must protect it without breaking the VPN, SSM or its own network settings.

**Options.** A: `input` drops by default, `output` stays open, ping for admins only, load-tested from a separate file. B: also restrict `output` now. C: leave `input` open and rely on `sg-fw`.

**Chosen: A.** `sg-fw` doesn't filter VPN clients, because their traffic arrives on `tun0` after decryption, so C would leave services exposed to them. DHCP replies are allowed so the lease renews. B risks breaking SSM, apt and DNS, which all start from fw-ips.

**Trade-off accepted.** A compromised fw-ips can send traffic anywhere. Restricting `output` is left as possible later hardening.

**Verify once built.** After loading, the VPN, SSM and `ping 10.8.0.1` still work, and a test to a closed port on fw-ips logs `FW-INPUT-DROP`.

## 29. Unbound configuration (2026-11-01)

**Problem.** `mail.<domain>` must resolve only inside the VPN, while every other name keeps working, and the real domain must stay out of the public repo.

**Options.** A: a `static` local zone for the exact name, with the domain in an untracked vars file. B: a `transparent` local zone. C: a local zone for all of `<domain>`, or the domain stored in SSM.

**Chosen: A.** `static` answers that name and nothing else, so the `vpn` record and `_acme-challenge` still resolve publicly. C's wider zone would break the DNS-01 check. SSM adds a read and an IAM grant for a value that isn't a secret. `ip-freebind` lets Unbound start before its address exists. Query logging stays off, because §8 doesn't list it.

**Trade-off accepted.** `make up` needs the vars file on the laptop. Scenario 2.2 can't show which names a stolen cert looked up, and Suricata can't see VPN DNS, because those queries end at fw-ips and only forwarded traffic is queued.

**Verify once built.** From the VPN, `dig @10.0.1.10 mail.<domain> +short` returns 10.0.2.10 and a public name resolves.

## 30. Private hosts keep AmazonProvidedDNS (2026-11-01)

**Problem.** Private hosts use 10.0.0.2 by default, and security groups and NACLs don't filter that traffic. A compromised host can leak data through DNS without crossing fw-ips.

**Options.** A: leave it and record a known gap. B: point DHCP at Unbound. C: turn off `enableDnsSupport`, or add Route 53 Resolver DNS Firewall.

**Chosen: A.** B only changes the default, so a host can still query 10.0.0.2 directly, and fw-ips would need its own DNS pinned to avoid depending on itself. C changes more of the design while TCP 443 to any address remains an easier way out.

**Trade-off accepted.** Private host DNS stays invisible until a fix is added. Scenario 2.2 tests the bypass and records it as a finding. Resolver query logging is the likely first fix.

**Verify once built.** From a private host, `dig @10.0.0.2 example.com +short` answers, and no matching entry appears on fw-ips.

## 31. No DNSSEC validation in Unbound (2026-11-01)

**Problem.** Ubuntu's Unbound validates DNSSEC by default. AmazonProvidedDNS returned no `RRSIG` records for the root or `example.com`, even with `+dnssec`, so Unbound couldn't confirm the root keys and answered `SERVFAIL` for every forwarded name.

**Options.** A: turn off validation with `module-config: "iterator"`. B: A, plus Route 53 Resolver DNSSEC validation on the VPC. C: resolve directly or use a public resolver, opening DNS out.

**Chosen: A.** It's one line and keeps §6. The path to 10.0.0.2 stays inside AWS's network, and TLS means a forged address still fails the certificate check. C changes §4, the NACLs and §6. B needs testing and can be added later without undoing A.

**Trade-off accepted.** Nothing in the lab validates DNSSEC, so Unbound trusts what 10.0.0.2 returns. Until production certs arrive in 2.6, `curl -k` skips the check that TLS would otherwise provide.

**Verify once built.** From the VPN, `dig @10.0.1.10 example.com +short` returns addresses, and `sudo journalctl -u unbound` shows no new trust anchor failures.

## 32. What Suricata can see (2026-11-01)

**Problem.** §11 tested SQLi and XSS against "WAF + Suricata", but VPN traffic to the proxy is TLS that ends at Nginx, past fw-ips. On `tun0`, Suricata sees addresses, ports, TLS details and traffic patterns, not web payloads.

**Options.** A: change §11, so ModSecurity handles web attacks and Suricata handles network behaviour. B: decrypt on fw-ips. C: add a sensor between proxy and app.

**Chosen: A.** It describes how the design really works. B puts private keys on the most exposed host, against the reasoning behind decision 21. C adds a component Tier 1 doesn't have.

**Trade-off accepted.** Suricata can't catch an attack inside TLS, so web detection depends on one layer, ModSecurity.

**Verify once built.** A SQLi test appears in the ModSecurity audit log and not as a payload alert in `eve.json`. A scan of blocked ports appears as `FW-DROP` and not in `eve.json`, because the firewall drops it before the queue.

## 33. Suricata fails closed (2026-11-01)

**Problem.** NFQUEUE needs a decision when Suricata isn't running: drop queued traffic or let it through.

**Options.** A: plain `queue`, which drops. B: `queue bypass`, which passes traffic unscanned.

**Chosen: A.** Stopping the IPS shouldn't open an unscanned path. VPN and SSM use `input` and `output`, which aren't queued, so recovery stays possible.

**Trade-off accepted.** A Suricata crash cuts VPN traffic to the proxy and `mgmt`, including during upgrades.

**Verify once built.** With Suricata stopped, forwarded VPN traffic stops, and the VPN and SSM stay up.

## 34. Suricata package, rules and logging (2026-11-01)

**Problem.** Suricata needs a source, a ruleset and a log volume that suit a t3.small with 2 GB of RAM and a 20 GB disk.

**Options.** A: Ubuntu's package, ET Open alert only, and limited rotated logs. B: the OISF PPA, no rules until 1.12, all event types. C: ET Open with drop enabled.

**Chosen: A.** Ubuntu's package needs no extra trusted source. ET Open gives broad detection, and alert-only keeps false positives from cutting traffic, leaving drops to the custom rules in 1.12.

**Trade-off accepted.** The package is older than upstream, and ET Open uses more memory, which must be measured on this host. ET Open alerts don't block anything.

**Verify once built.** `suricata -T` passes, `free -m` shows spare memory after loading, and `eve.json` shows only the chosen event types.

## 35. Custom Suricata rules (2026-11-01)

**Problem.** Task 1.12 needs custom rules, including inline blocking, but no proxy exists yet, so no real TLS can be captured. The rules see only allowed traffic, as metadata and behaviour.

**Options.** A: one `drop` rule for floods, the rest `alert`, with synthetic captures. B: all rules `drop`. C: no `drop`, or wait for the proxy.

**Chosen: A.** Rule mistakes can't block real traffic. This mattered at once: the first version of the protocol rule fired on clean TLS, and the clean capture caught it. Using `app-layer-protocol:failed` fixed that, and plain HTTP needed its own rule, because Suricata recognises it. The flood threshold of 60 in 10 seconds is well above what a browser opens.

**Trade-off accepted.** Synthetic captures can't prove behaviour against real TLS, so 1.15 re-tests them. A rule on the server name doesn't fire when a client sends no name. The threshold is a first guess, to tune in 2.2.

**Verify once built.** Each capture raises only its intended rule, `clean-tls.pcap` raises nothing, and a live flood raises `ips.blocked` in `stats.log`.

## 36. How Ansible reaches the hosts (2026-11-02)

**Problem.** Ansible is agentless: for each task it connects, copies a Python module, runs it and reads the JSON result. Its default transport is SSH, but no security group, NACL or nftables rule allows port 22, and none should. Every host already runs the SSM agent, which holds an outbound 443 connection to AWS that `aws ssm start-session` can ride back in on.

**Options.** A: normal SSH carried inside an SSM session (`ProxyCommand` with the `AWS-StartSSHSession` document), with a laptop-only key. B: the `community.aws.aws_ssm` connection plugin, which needs no SSH but moves files through an S3 bucket. C: SSH over the VPN from the admin pool.

**Chosen: A.** The SSH traffic reaches sshd on the host's loopback, which nftables already accepts, so no network path to port 22 is opened. sshd is set to listen on loopback only, so a later firewall mistake still finds nothing listening. The instance role needs nothing new. B would add a bucket and S3 read and write to `mailbridge-lab-ssm-min`, undoing part of decision 22, and the plugin is slower and less reliable. C needs port 22 opened in three places, and on fw-ips Ansible would be managing OpenVPN over OpenVPN, so one bad push could cut the connection it runs on.

**Trade-off accepted.** There is a key to manage. A stolen key alone reaches nothing, because SSM also needs a valid AWS session, but a lost key means installing a new one through SSM. fw-ips was launched without a key pair, so its key is added once by hand through SSM. Later instances get it from Terraform's `aws_key_pair`, where changing the key replaces the instance.

**Verify once built.** `ansible fw_ips -m ping` returns `pong`; `ss -tlnp` on the host shows sshd on `127.0.0.1:22` only; `nc -zv` to the host's port 22 from the admin pool fails; the instance role's policies are unchanged.

## 37. How the role manages suricata.yaml (2026-11-02)

**Problem.** The live `suricata.yaml` is Ubuntu's 2,150-line default with three hand edits: `HOME_NET`, the `eve-log` types, and `local.rules` in `rule-files`. The repo held only an `eve` fragment, so a rebuilt fw-ips would get the default file and lose all three.

**Options.** A: own the whole file in the role. B: targeted edits to the package file with `lineinfile`, `replace` or `blockinfile`. C: keep the package file and override settings with `--set` in the systemd drop-in.

**Chosen: A.** The file in the repo is exactly the file on the host, so `--check --diff` shows any drift, as it did for nftables and Unbound. It's committed in two steps, the untouched package file and then our edits, so `git log -p` shows only the three changes. B depends on the shape of lines we don't control, and replacing a list in the middle of `outputs:` is hard to make idempotent. C relies on list positions such as `outputs.1`, and splits the config across two files. The file goes in with `copy`, because two upstream log-format comments contain `{%`, which Jinja would read as a block.

**Trade-off accepted.** A large file tied to Suricata 7.0.3. After a major upgrade, the new upstream default is compared and our three edits carried over by hand. `HOME_NET` is written in the file rather than coming from a variable.

**Verify once built.** `--check --diff` reports no change on a host built by hand; `suricata -T` passes on the installed file; `git log -p` on the file shows the three edits in one commit.

## 38. Suricata rule updates and the reload refusal (2026-11-02)

**Problem.** ET Open was downloaded once and never updated. On 2026-11-01, `suricatasc -c reload-rules` was refused, so new custom rules needed a restart. A restart is costly here: Suricata fails closed (decision 33) and loads 53,000 rules first, so forwarded VPN traffic stops for about 30 seconds.

**Cause found.** With the default config, any `suricata -r <pcap>` run also opens a command socket at `/var/run/suricata-command.socket`. It replaces the daemon's socket file and leaves a dead one when it exits. From then on `reload-rules` and the unit's `ExecStop` get `Connection refused`. This was reproduced on fw-ips: the socket's inode changed and `suricatasc` was refused. With `--set unix-command.enabled=no` the socket stayed working. `suricata -T` doesn't touch the socket.

**Options.** A: a daily systemd timer running `suricata-update` with `reload-rules`. B: the same timer with a restart. C: update by hand when needed.

**Chosen: A.** `suricata-update` tests the new ruleset with `suricata -T` before installing it, and `reload-rules` then swaps rules in the running engine without dropping traffic. `Persistent=true` runs a missed update at the next boot, which matters because fw-ips is stopped between sessions. A random delay of up to an hour avoids fetching at the same minute every day. B pauses traffic daily for no gain, and C leaves the rules stale.

**Trade-off accepted.** During an update the `-T` test loads ET Open a second time, about 500 MB, next to the running engine's 530 MB, on a host with 2 GB. A reload also holds the old and new engines briefly. A forced update on 2026-11-02 left 209 MB available at its lowest point: it works, but it's the tightest moment on this host and must be re-measured when the Wazuh agent arrives in 1.17, with t3.medium as the fallback. A ruleset that passes `-T` but behaves badly still loads automatically.

**Verify once built.** `systemctl list-timers suricata-update.timer` shows the next run; a manual start of the service logs a download, a test and a reload; `suricatasc -c ruleset-reload-time` shows a new time; `suricatasc -c version` still answers.

## 39. Who fetches the VPN secrets (2026-11-02)

**Problem.** The `fw_ips` role must put five files on fw-ips: the CA cert, server cert, server key, `tls-crypt` key and CRL. Two are secrets, held as SecureString under `/vpn/fw-ips/*`. None may reach the public repo or Ansible's output.

**Options.** A: fw-ips pulls them with its own instance role. B: the laptop reads them with the `amazon.aws.ssm_parameter` lookup and pushes them with `copy`. C: Terraform `user_data`.

**Chosen: A.** The host's role can already read `/vpn/fw-ips/*` and nothing else (decision 22), so the secret goes from SSM to the host and nowhere else. A small helper, `fetch-ssm-param`, pipes the value into a 0600 temp file in the same directory, because the snap `aws` writes 0 bytes to a file (1.7b). It compares the result with `cmp`, replaces the file with an atomic `mv` only if it differs, and prints only `changed` or `unchanged`. In check mode it only compares. Tasks also use `no_log`. B puts the key in laptop memory and the SSH channel, needs a collection and boto3 on the laptop, and `--diff` would print it unless disabled. C stores the secret in instance metadata that console users can read, and in Terraform state.

**Trade-off accepted.** A shell helper instead of a pure Ansible module, and a dependency on the `aws` CLI snap, which the role installs. The AMI doesn't ship it: the hand-built host got it by hand, and the first rebuild failed until the role installed it. A failed `aws` call is caught by an empty-file check, since `sh` has no `pipefail`. Rotating a key means updating SSM and rerunning the role, which restarts OpenVPN and drops VPN clients for a few seconds; a CRL update needs no restart.

**Verify once built.** A dry run on the hand-built host reports all five files unchanged; output shows only `censored due to no_log`; a second run reports `changed=0`; keys are 0600 root; a VPN client reconnects after the role restarts OpenVPN.

## 40. Rebuild fw-ips from code (2026-11-02)

**Problem.** fw-ips was built by hand without a key pair. Task 1.6 puts it in Terraform, and the `fw_ips` role now covers its configuration. The question was whether to adopt the running instance or replace it.

**Options.** A: import IAM and the Elastic IP, and build a new instance from code. B: import everything, including the instance. C: import the instance now and rebuild in 1.20.

**Chosen: A.** Adding `key_name` replaces an instance anyway, so B could only work by leaving the key out of the code, and then the code wouldn't describe how a fresh host gets its key. A tests today's role on a clean host now rather than in 1.20. IAM is imported, because a role can't be recreated under the same name without deleting it first. The Elastic IP is imported so the `vpn` address doesn't change. An audit of the old host before the rebuild found one gap the role didn't cover, the HTTPS apt sources, which was fixed first.

**Trade-off accepted.** The ENI is the old instance's primary interface, and AWS never detaches a primary interface, so the old instance must be terminated, not stopped, before the new one launches. Its AMI is the fallback, at about a dollar a month until it's deleted. Its attachment has `DeleteOnTermination` off, so the ENI and its routes survive. The VPN is down between the termination and the new host's Ansible run.

**Verify once built.** The plan shows 7 imports, 3 additions and nothing changed; a second plan after apply shows no changes; the ENI's source/dest check stays off; `ansible-playbook site.yml` then reports `changed=0` on its second run; the VPN, DNS, Suricata and nftables checks from 2026-11-02 pass again.

## 41. Session switch for fw-ips (2026-11-02)

**Problem.** Decision 24 stopped fw-ips and released the Elastic IP by hand between sessions, because only one disk held the hand build. Now the instance, Elastic IP and `vpn` record are in Terraform state, so releasing the address by hand would be drift, and the code can rebuild the host.

**Options.** A: a `fw_enabled` variable with `count` on the instance, Elastic IP, association and record. B: `terraform destroy -target` on those resources. C: stop the instance and keep the Elastic IP.

**Chosen: A.** Ending a session is a normal plan and apply that shows exactly four resources destroyed, and starting is a plain apply. The record goes with the address, so the name never points at an IP someone else may now hold. Every session rebuilds fw-ips from code, which keeps proving that Terraform and the role are complete. B relies on `-target`, which Terraform reserves for exceptional use and which is easy to mistype. C keeps paying for an idle IP and disk. IAM and the key pair stay, because they're free and recreating the role would need an import each time. `moved` blocks keep the running resources when `count` is added.

**Trade-off accepted.** Each session starts about 10 minutes later and gets a new Elastic IP, and the instance ID changes, so the untracked inventory needs the new ID. Suricata and VPN logs on the host are lost at each teardown until Wazuh collects them (1.17).

**Verify once built.** With the default, the plan shows only moves; with `fw_enabled=false` it shows 4 to destroy and nothing else; afterwards no instance or Elastic IP exists in the region; the next `terraform apply` and Ansible run restore a working VPN.

## 42. Who owns the fw-ips ENI's security groups (2026-11-02)

**Problem.** The fw-ips ENI carried `mailbridge-lab-fw` and the VPC `default` group, while §4 says sg-fw only. An ENI always has at least one group, so AWS gave it `default` when it was created without any. `aws_network_interface_sg_attachment` (decision 7) then added sg-fw, but that resource manages one membership, not the list, so nothing ever removed `default`. `default` has no rules and granted nothing, but the live state didn't match the design, and an audit would flag it.

**Options.** A: declare the full list on the ENI with `security_groups`, and drop the attachment with a `removed` block. B: move the ENI into `modules/security`, next to its group. C: remove `default` by hand with the CLI.

**Chosen: A.** Setting `security_groups` makes Terraform authoritative for the whole list, so `default` goes, and any group added by hand later shows up as drift. The attachment is dropped with `removed { lifecycle { destroy = false } }`, because destroying it would detach sg-fw: the ENI could be left with no group from §4 and the VPN would break until the next apply. B only reverses the dependency, because the network's private routes target the ENI, and it adds a `moved` block between modules. C is drift that the next network rebuild (1.20) would undo.

**Trade-off accepted.** Decision 7 kept dependencies flowing one way (network to security). Now `modules/network` takes sg-fw's ID from `modules/security`, which takes `vpc_id` from network. Terraform allows this because it orders individual resources, not modules: VPC, then sg-fw, then the ENI, with no loop. checkov can't follow the group across modules, so sg-fw keeps its `CKV2_AWS_5` skip with a new reason.

**Verify once built.** The plan shows `1 to change` (the ENI, in place, removing only `default`), the attachment as no longer managed, and `0 to destroy`. After the apply, `aws ec2 describe-network-interfaces --network-interface-ids <eni> --query 'NetworkInterfaces[].Groups[].GroupName' --output text` prints only `mailbridge-lab-fw`; the VPN ping to 10.0.1.10 still works; the next plan shows no changes.

## 43. Account ID in the fw-ips grant (2026-11-02)

**Problem.** The fw-ips grant allowed `ssm:GetParameter` on `arn:aws:ssm:eu-central-1:*:parameter/vpn/fw-ips/*`. The `*` in the account field matches a parameter of that name in any account, so the grant was wider than it needed to be. An IAM policy can't reach another account's parameters without that account's consent, so this was tidiness, not an open hole. The role description still said "SSM access only", although decision 39 added the parameter grant.

**Options.** A: look the account ID and region up with the `aws_caller_identity` and `aws_region` data sources. B: write the account ID into the code or a committed `tfvars`. C: pass it as a variable from the untracked `terraform.tfvars`.

**Chosen: A.** The ARN names exactly this account, and nothing has to be written down. B puts an account ID in a public repo, which CLAUDE.md rules out. C works, but it's one more untracked value to keep in sync, and Terraform already knows which account it's running in. The description now says the role runs the SSM agent and reads its own `/vpn/fw-ips/*` parameters.

**Trade-off accepted.** The account ID appears in plan output and state, which are local and gitignored. Plans pasted into docs or PRs must keep it masked.

**Verify once built.** The plan shows 2 changed in place (the description and the policy `Resource`) and nothing replaced. `aws iam get-role-policy --role-name mailbridge-lab-fw-ips --policy-name fw-ips-read-own-secrets` shows the account ID in the ARN. The IAM simulator allows `/vpn/fw-ips/*` and still denies `/vpn/ca/key`. A third Ansible run reports `changed=0`, so fw-ips can still pull its files.

## 44. Deploying custom rule changes (2026-11-02)

**Problem.** A change to `local.rules` notified `Restart Suricata`. Suricata fails closed, so every restart stops forwarded VPN traffic while it loads, about 30 seconds with ET Open. Nothing checked the file first. `init-failure-fatal` isn't set, so Suricata skips a rule that doesn't parse and starts anyway: the rule we think protects the proxy would silently not exist, and only `suricata.log` would say so. `suricata.yaml` was already validated with `-T`. Decision 38 had moved ET Open updates to `reload-rules`, and the handler's comment still blamed the earlier refusal on an unknown cause.

**Options.** A: validate the new file with `suricata -T -S` through `copy`'s `validate`, and notify a handler that runs `suricatasc -c reload-rules`. B: keep the restart and only add validation. C: leave it, because nothing sits behind fw-ips yet.

**Chosen: A.** Validation turns a silent skip into a failed Ansible task, while the running engine keeps its old rules. A test on fw-ips confirmed `-T` exits 1 on a rule that doesn't parse and 0 on the current file. `-S` loads only the new file, so the test checks the custom rules without touching the live config. `--set unix-command.enabled=no` keeps the test from replacing the daemon's socket, which is what caused the decision 38 refusal. The reload swaps rules with no pause, the same mechanism the daily ET Open update uses. B keeps a pause that will hit real users once `proxy` exists. C leaves the trap in place for Phase 2, when rules change under time pressure.

**Trade-off accepted.** `suricatasc` returns exit code 0 even when the engine refuses, so the handler reads `"return": "OK"` from the reply. On a fresh host both handlers fire, and the reload runs after the restart. It retries for up to two minutes until the new process opens its socket. The extra reload is harmless.

**Verify once built.** A rule change makes `site.yml` show `Install the custom rules` changed and `Reload Suricata rules` run, with no `Restart Suricata`. `sudo suricatasc -c uptime` keeps counting instead of resetting, which shows the engine and its traffic never stopped, and `sudo suricatasc -c ruleset-stats` shows 0 failed. A deliberately broken rule fails the task at `validate`, and the live rules stay unchanged.

## 45. How Ansible finds the hosts (2026-11-02)

**Problem.** Ansible reaches hosts through SSM, which targets them by instance ID. fw-ips gets a new ID every session (decision 41), and the ID was copied into an untracked `hosts.yml` with `sed`. With one host that works. Tier 1 has five, and a stale or swapped ID either fails the connection or, worse, applies one host's role to another.

**Options.** A: the `amazon.aws.aws_ec2` dynamic inventory plugin, which asks EC2 at run time. B: Terraform writes `hosts.yml` with a `local_file` resource. C: a script turns `terraform output -json` into `hosts.yml`.

**Chosen: A.** A static inventory is a copy of the IDs, refreshed at certain moments. A dynamic one keeps no copy: each run asks EC2 for running instances tagged `Project=mailbridge-lab` and makes the `Role` tag the group, so `Role=fw_ips` lands in `fw_ips`. Ansible already needs the admin's AWS credentials for the SSM `ProxyCommand`, so the lookup adds no new kind of access. A new host needs only its tags in Terraform. B couples Terraform to Ansible's folder, adds the `local` provider, and leaves a file that exists only where the apply ran. C is still a static file between runs, and one more step to forget until the Makefile (0.6) exists.

**Trade-off accepted.** Tags are now part of security: whatever carries `Role=db` gets the `db` role, so only Terraform sets them, and only the admin user can change them. The laptop needs `boto3` and `botocore[crt]` inside Ansible's pipx venv (`pipx inject ansible boto3`, then `pipx inject --force ansible "botocore[crt]"`). The CRT part is needed for `aws login` credentials. The host is named after its `Name` tag (`mailbridge-lab-fw-ips`). amazon.aws 11.4.0 warns on every run that the `tags` host variable is deprecated, and core warns that `tags` is a reserved name. Both come from the plugin itself (`parse()` warns unconditionally), and our file uses only `ec2_tags`. They are left visible, because `deprecation_warnings = False` would also hide warnings about our own code.

**Verify once built.** `ansible-inventory --graph` lists each host under its role group. `ansible fw_ips -m ping` returns `pong`, `site.yml` reports `changed=0`, and after a teardown and rebuild the new instance appears without any edit.

## 46. Where the database password is created (2026-11-02)

**Problem.** §7 puts the DB password in SSM Parameter Store as a SecureString under `/mailbridge/*`, and §13 puts secrets in the `persistent` stack. Something has to generate the value. Terraform records every attribute it manages in its state file, so a plain `aws_ssm_parameter.value` puts the password into state in plain text, and into every saved plan. Marking an attribute `sensitive` only hides it from the terminal.

**Options.** A: an `ephemeral "random_password"` written to `aws_ssm_parameter.value_wo`, a write-only attribute. B: create the parameter by hand with `aws ssm put-parameter`, as for `/vpn/ca/key`. C: a normal `random_password` resource written to `value`.

**Chosen: A.** An ephemeral resource exists only while Terraform runs: it is never written to state or a plan (Terraform 1.10, random provider 3.7). A write-only attribute is sent to the provider during apply and never recorded (Terraform 1.11, `value_wo` in our AWS provider 6.71.0). Together they give a password that is in code and created by `make up`, but stored only in SSM. Nobody sees it, not even the admin. B also keeps it out of state, but it lives outside code, and the value passes through a terminal. The CA key has to be made by hand because the CA is offline on the laptop; a random password has no such reason. C is the common tutorial pattern, and it leaves a plain-text copy in the state bucket and in plan files where nothing needs one.

**Trade-off accepted.** Terraform can't detect drift in the value, because it never knows it. A new random value is generated on every run but sent only when `value_wo_version` changes, so rotating means bumping the version and then re-running the `db` and `app` roles. The password is letters and digits only, 40 of them (about 238 bits), so it never needs escaping in a connection string. It uses the AWS-managed `aws/ssm` key like `/vpn/*`; checkov's CMK check is skipped with that reason. `persistent` uses the same state bucket as `lab` under its own key, so a lab teardown can't reach it.

**Verify once built.** The plan shows `1 to add`, with `value_wo` as `(write-only attribute)`, and `terraform show -json` of the saved plan contains no `value_wo` or `value`. After apply, `aws ssm describe-parameters` lists `/mailbridge/db-password` as `SecureString`, and the state (`terraform state pull`) has `value_wo` null and no password. Reading the value back works only for the admin, and later for the `db` and `app` roles.

## 47. How the `db` host gets its password (2026-11-02)

**Problem.** Decision 46 put the DB password in SSM, where nobody has seen it. PostgreSQL needs it to set the password of the app's database user, and later `app` needs it to connect. Something has to carry the value from SSM to the db host, and every component it passes through is another place it can leak: memory, logs, terminal output.

**Options.** A: db reads it with its own instance role, granted that one parameter, and a helper on the host sets the password without printing it. B: Ansible reads it on the laptop with the `aws_ssm` lookup and pushes it over the SSM tunnel, hidden with `no_log`. C: no password at all; the app authenticates with a client certificate.

**Chosen: A.** It is the pull pattern from decision 39, already proven on fw-ips: the instance role gives temporary credentials through IMDSv2, and the value goes from SSM straight into PostgreSQL on the same host. The laptop never holds it. B puts the value inside the laptop's Ansible process, where one missing `no_log` or a `-vvv` run prints it. C is stronger but needs a second PKI (or reuse of the VPN CA) and certificate handling in the app, which is too much for Tier 1. It stays a possible hardening finding.

**Trade-off accepted.** db can read the password for its whole life, not only during setup. That adds little, because db already holds what the password protects, and PostgreSQL keeps only a SCRAM-SHA-256 hash of it. The grant names one ARN with the account and region from data sources (decision 43). The `aws/ssm` key needs no extra KMS grant, because its key policy allows use through SSM by any principal in the account that IAM allows. §7 no longer lists the S3 backup grant for db; T2.3 adds it with the bucket.

**Verify once built.** The IAM policy simulator allows the db role `ssm:GetParameter` on `/mailbridge/db-password` and denies `/mailbridge/` siblings and `/vpn/*`. An Ansible run shows no password in its output, even with `-v`. On db, a login as the app user with the SSM value works, and a wrong password fails.

## 48. Verifying `db` before `app` and `proxy` exist (2026-11-02)

**Problem.** Task 1.13's check was "connect succeeds from app, is refused from proxy", but the build order (§13) puts db first, so neither host exists. Three layers decide whether a connection reaches PostgreSQL: the network (sg-db and the data NACL), PostgreSQL's listener (`listen_addresses`), and `pg_hba.conf` (which address may log in as which user, and how). A good test shows which layer allowed or refused.

**Options.** A: split the check. 1.13 proves db's own layers, 1.14 adds the app connection, 1.15 the proxy refusal. B: throwaway probe VMs with sg-app and sg-proxy, deleted after the test. C: create bare app and proxy instances in Terraform now, without their roles.

**Chosen: A.** Each host is tested against its real dependency, as §13 says, and no resource exists outside code. B would prove the whole path today for a few cents, but it is a hand build, and the last temporary VM launched with the wrong role (2026-11-01). C builds two layers early and leaves their IAM half-done until their own tasks.

**Trade-off accepted.** Until 1.14, the app→db network path is proven only on paper: the sg-db and data NACL rules were checked line by line against §4 in 1.4, but no packet has crossed them. If 1.14 fails, the cause could be in db or the network, and the layered checks below narrow it down.

**Verify once built.** On db: `ss -ltn` shows PostgreSQL on 10.0.4.10:5432 (and loopback), and the `pg_hba` file allows only the app user to its database from 10.0.3.10/32 with `scram-sha-256`. A local login with the SSM value works. From the VPN admin pool, `nc -zv -w 3 10.0.4.10 5432` times out, and fw-ips logs the drop. In 1.14, `psql` from app connects. In 1.15, the same command from proxy times out.

## 49. What happens to the database between sessions (2026-11-02)

**Problem.** Decision 41 destroys every paid instance at the end of a session. fw-ips holds no state, but db keeps PostgreSQL's data on its root disk, so destroying the instance deletes the data. The underlying idea is the split between compute and state: servers should be disposable, while data has its own lifecycle on a separate volume or in backups.

**Options.** A: accept an empty database each session until T2.3 brings backups and a restore. B: a separate EBS data volume (about 5 GB, about $0.50 a month) mounted at `/var/lib/postgresql` and reattached to each new instance. C: stop db between sessions instead of destroying it.

**Chosen: A.** Tier 1 uses only test accounts in testing mode, so an empty database costs a minute of re-linking per account. Each session then proves that db builds from clean, the same way fw-ips does. T2.3 adds nightly `pg_dump` to S3 and a tested restore, and restoring at session start becomes a real recovery drill rather than a disk that never goes away. B is the production pattern, but it adds a volume lifecycle, a stack to own it, a mount in Ansible and a guard so `initdb` never runs over existing data, which is too much for the first private host. C goes back to a host carried by hand between sessions, the problem decision 41 removed.

**Trade-off accepted.** Nothing in the database survives a session: app users, linked mailboxes and stored tokens are recreated each time. A Phase 2 scenario that needs data across several days would have to wait for T2.3 or bring B forward. This is revisited at 1.14 if re-linking proves a burden.

**Verify once built.** After an end-of-session teardown, no db instance or volume is left (`aws ec2 describe-volumes` filtered by `Project=mailbridge-lab` is empty). At the next start, the `db` role creates the user and database again, and the login from decision 48 works with the same SSM password.

## 50. Boot order for private hosts (2026-11-02)

**Problem.** A session starts with one `terraform apply`, which now creates fw-ips and db together. fw-ips forwards nothing until Ansible installs its nftables NAT rules, after the apply. For its first minutes db has no route out: a `package_upgrade` in its cloud-init would fail and leave `cloud-init status` at `error`, and its SSM agent can't register, so Ansible can't reach it yet. The concept is the split of duties: Terraform makes resources exist, and Ansible makes hosts behave. Order between hosts' configuration is a configuration concern.

**Options.** A: one apply; db's first boot needs no network, `site.yml` runs the `fw_ips` play first, and the `db` play waits for the connection before its role upgrades the host. B: two applies, fw-ips first, then the private hosts behind a second switch. C: keep `package_upgrade` in db's cloud-init and add a `bootcmd` loop that waits for the network.

**Chosen: A.** Ansible already runs plays in order, so the dependency is written where it belongs, and the SSM agent's own retries cover the gap until NAT works. The session routine keeps one plan and one approval. B doubles the plans and approvals each session and adds a variable the Makefile (0.6) would have to sequence. C hides a fw-ips failure as a vague cloud-init timeout on another host.

**Trade-off accepted.** db is upgraded by its role instead of at first boot, unlike fw-ips; each method fits its host, because fw-ips has internet at boot and db doesn't. The first `site.yml` run on a fresh session takes longer while it waits for db to register. `wait_for_connection` has a timeout, so a broken fw-ips fails the db play with a clear message instead of hanging.

**Verify once built.** After the apply, `cloud-init status` on db reports `done`, not `error`. The first `site.yml` shows the `fw_ips` play, then the `db` play waiting and connecting. `apt list --upgradable` on db is empty after the run, and the second run reports `changed=0`.

## 51. One session switch for every host (2026-11-02)

**Problem.** Decision 41's `fw_enabled` removed fw-ips between sessions. db (and later app, proxy and siem) also bill while idle and must go at the same time. fw-ips's AMI variable was also named for one host.

**Options.** A: rename the switch to `hosts_enabled` and put every session host behind it. B: one switch per host (`fw_enabled`, `db_enabled`, ...). C: keep the name `fw_enabled` and reuse it for db.

**Chosen: A.** A session needs all of its hosts or none, so one switch matches how the lab is used, and a teardown can't miss a host. B allows partial states nobody needs and one more variable to forget per host. C works, but the name would lie about what it removes. `fw_ami_id` becomes `ubuntu_ami_id` for the same reason: every host runs the same pinned image, and a second variable would let them drift.

**Trade-off accepted.** A single host can't be removed on its own with the switch; that would take a targeted plan, which the lab doesn't need. Renaming a Terraform variable doesn't touch state, because resource addresses (`aws_instance.fw[0]`) don't contain variable names. The untracked `terraform.tfvars` has to be renamed too, or Terraform warns about an undeclared variable and fw-ips loses its AMI.

**Verify once built.** With fw-ips running, the plan after the rename shows only db's resources to add, nothing to change or destroy on fw-ips. At the end of the session, `-var hosts_enabled=false` shows fw-ips's 4 resources plus db's instance to destroy, and IAM stays.

## 52. How the password gets into PostgreSQL (2026-11-02)

**Problem.** Decision 47 has db pull `/mailbridge/db-password` with its own role, and Ansible's output and the laptop must never see it. The last step, from SSM into PostgreSQL, can still leak. Command-line arguments are visible to every user through `ps`. Files on disk end up in snapshots and AMIs. A failing SQL statement is written to the server log by default. Any Ansible variable travels back to the laptop. Environment variables and stdin are safer: `/proc/<pid>/environ` is readable only by the process owner and root, and a pipe leaves no trace.

**Options.** A: a small helper on db that holds the value in a shell variable, tests a login, and sets the password through stdin only when needed. B: `fetch-ssm-param` writes it to a 0600 root file, and psql reads the file. C: `community.postgresql.postgresql_user` with `password:`.

**Chosen: A.** The helper fetches the value, checks it is letters and digits only (decision 46), and tries `psql -h 127.0.0.1 -U mailbridge` with `PGPASSWORD`. If the login works, nothing changes and it prints `unchanged`. Otherwise it pipes `ALTER ROLE mailbridge PASSWORD '...'` into `psql` as the postgres user, using `printf`, a shell builtin, so the value never appears in argv. Two `SET` lines first turn off `log_statement` and `log_min_error_statement` for that session, so even a failing statement isn't logged. It then logs in again to prove the change, and prints `changed`. That is the same contract as `fetch-ssm-param`, including a read-only `check` mode. B leaves the password on disk for the life of the host, and in any image taken of it. C forces the value into an Ansible variable, through a lookup on the laptop or a `slurp` back to it, which is exactly what decision 47 rules out.

**Trade-off accepted.** One more script to own. The plain value briefly reaches the PostgreSQL server, which hashes it with SCRAM-SHA-256. That happens on the same host, and only `pg_authid` keeps the hash. The loopback login line in `pg_hba.conf` exists partly for this test. CI now installs the pinned collections from `ansible/requirements.yml` before ansible-lint, because ansible-lint brings only ansible-core.

**Verify once built.** The first run shows `Set the mailbridge password from SSM` changed, and the second run shows it `ok`. `ansible-playbook site.yml -v` contains no password. `PGPASSWORD` with a wrong value fails, and the SSM value works (tested on db without printing it). `grep -c` for the value in `/var/log/postgresql/` returns 0.

## 53. How the ECR repository is configured (2026-11-02)

**Problem.** app runs the Mailbridge image from ECR, pinned by digest (§3). An image has two kinds of name: a tag (`mailbridge:v1.2`) is a label that by default can be moved to another image, and a digest (`mailbridge@sha256:...`) is a hash of the content that can never point anywhere else. The repository settings decide whether tags can be trusted, what is scanned, and how much storage accumulates.

**Options.** A: immutable tags, basic scanning on push, KMS with the AWS-managed key, and a lifecycle policy. B: mutable tags, relying on the digest pin in Ansible. C: immutable tags with an exclusion filter that keeps `latest` movable.

**Chosen: A.** With `IMMUTABLE`, once `v1.2` is pushed no one can push a different image under that tag, so a tag seen in a log or commit always names one image, and someone with push rights can't silently replace a release. Basic scanning is free and checks each push against a CVE database; enhanced scanning (Inspector) is billed. `KMS` with the AWS-managed `aws/ecr` key is free and passes checkov's encryption check without a skip. The lifecycle policy expires untagged images after a day and keeps the last 5 tagged ones, under ECR's free 500 MB a month. The repository is in `persistent` with no `force_delete`, so a lab teardown can't delete images. B is simpler day to day, but a tag then proves nothing. C brings B's weakness back for the tag people use most.

**Trade-off accepted.** Every build needs a new tag, such as a version or the git commit, so `latest` can't be re-pushed. The untagged rule could remove the child manifests of a multi-platform image index or a build attestation. The build decision in 1.14 has to check this: build a single `linux/amd64` image, or confirm ECR keeps manifests that an index references.

**Verify once built.** `aws ecr describe-repositories --repository-names mailbridge` shows `IMMUTABLE`, `scanOnPush: true` and `KMS`. `aws ecr get-lifecycle-policy` returns both rules. Pushing the same tag twice fails with `ImageTagAlreadyExistsException`, and a push shows a scan result in `aws ecr describe-image-scan-findings`.

## 54. One database role or two (2026-11-02)

**Problem.** In PostgreSQL a table's owner can always alter or drop it, including its triggers. Mailbridge's migration 010 makes `audit_events` insert-only with a trigger. If the app connects as the owner, anyone with its credentials (SQL injection, a leaked environment, a shell in the container) can drop the trigger and rewrite the audit log. The concept is separation of duties: an owner used only by the short migration step, and a runtime role with row access only, used by the long-running app. The app's ADR 0008 describes the split and its grants (`deploy/db-roles.sql`).

**Options.** A: two roles; db creates `mailbridge_app` and sets its password, and app applies the grants after migrating. B: two roles, with db applying the grants, so `site.yml` runs db, then app, then db again. C: one role, the app running as the owner.

**Chosen: A.** db's role already runs as `postgres`, so it can create the runtime role, the only step that needs `CREATEROLE`. The `set-db-password` helper is generalized to both roles, and db's IAM grant names the two parameters. On app, each start runs the migrate container as the owner, then `psql` (from `postgresql-client`) applies `db-roles.sql` as the owner once the tables exist, then the app container as `mailbridge_app`. The running app never holds the owner password. The app's own test on PostgreSQL 16 shows the runtime role gets "must be owner" for `DROP TRIGGER` and "permission denied" for `UPDATE audit_events`, DDL and `pgmigrations`. B keeps no secret off app, because migration needs the owner password, and it makes the playbook bounce between hosts. C protects the audit log only from the app's own code.

**Trade-off accepted.** The app host holds both passwords, and its start has one more step. `db-roles.sql` must match the app's migrations, so the Ansible copy is pinned to the image's commit and updated with it.

**Verify once built.** On db, `\du` lists `mailbridge_app` without `Superuser`, `Create role` or `Create DB`. As `mailbridge_app`: `DROP TRIGGER audit_events_guard_row ON audit_events` fails with "must be owner", `UPDATE audit_events SET ...` and `CREATE TABLE x()` fail with "permission denied", and the app's `/healthz` returns 200. The app container's environment (`docker inspect`) holds no owner password.

## 55. The app's generated secrets (2026-11-02)

**Problem.** Mailbridge needs a session secret, a token encryption key and, after decision 54, a runtime database password. The app accepts raw text of at least 32 characters for the first two and requires them to differ. The OAuth client secrets come from the Google and Microsoft consoles and can't be generated.

**Options.** A: generate the three in `persistent` with the decision 46 pattern, and defer the OAuth secrets to 1.19. B: create all of them by hand with `aws ssm put-parameter`. C: wait and create everything together once the OAuth apps exist.

**Chosen: A.** An ephemeral `random_password` written to `value_wo` keeps each value out of state, plans and the laptop, as for the owner's password. The runtime password uses the owner's format (40 letters and digits), which `set-db-password` checks. The session secret and token key are 64 letters and digits each, about 380 bits, generated independently. The app treats both OAuth providers as optional, so app can be built and tested in 1.14 without them. B puts values through a terminal for no reason. C blocks 1.14 on the provider consoles.

**Trade-off accepted.** Rotating the token key makes stored mailbox tokens unreadable, so users must reconnect their mailboxes. With the database rebuilt each session (decision 49) this costs nothing today. The OAuth secrets still need their own decision in 1.19, because they can't come from Terraform's random provider.

**Verify once built.** The plan shows the three values as `(write-only attribute)`, and the plan JSON contains no `value_wo` string. `aws ssm describe-parameters` lists the three as `SecureString`, and `terraform state pull` contains none of the values.

## 56. How app's secrets reach the container (2026-11-02)

**Problem.** Mailbridge reads its secrets from environment variables. Two facts shape the choice. Docker stores a container's configuration, env included, in `/var/lib/docker/containers/<id>/config.v2.json` for as long as the container exists, even when stopped, and `docker inspect` shows it to root. And root on app can read SSM anyway through the instance role, so hiding values from root gains nothing. What matters is keeping them out of argv, logs, Ansible output, and anything that outlives the service: files, AMIs, backups.

**Options.** A: root-owned start scripts that pull values from SSM at each start and run `docker run --rm -e NAME`, under a systemd unit. B: Ansible writes a 0600 `app.env` and Docker uses `--env-file`. C: change the app to read `*_FILE` variables, with values as files on a tmpfs mounted into the container.

**Chosen: A.** `mailbridge.service` runs the migration and the grants as `ExecStartPre` and the app as `ExecStart`. Each step pulls only the values it needs into its own environment; `-e NAME` without `=value` makes Docker copy the value from that environment, so it never appears in argv. The owner password reaches only the migration and the `psql` grant step, and the app container gets only `mailbridge_app`'s (decision 54). Containers run with `--rm`, and systemd's `Restart=on-failure` replaces Docker's `--restart`, so a stopped container and its stored config disappear at once. Each start re-reads SSM, so a rotation needs only a restart. B leaves a file on disk for the host's whole life. C is the cleaner Docker secrets pattern, but it needs an app change for little gain while root can already reach SSM; it stays a hardening idea.

**Trade-off accepted.** While the app runs, root can see its env with `docker inspect`, and Docker keeps that copy under `/var/lib/docker` until the container stops. An image of the running host would contain it.

**Verify once built.** `ps -ef` on app shows no secret in any command line. `docker inspect` of the app container lists `POSTGRES_USER=mailbridge_app` and no owner password. After `systemctl stop mailbridge`, `docker ps -a` is empty. Ansible's `-v` output contains none of the values.

## 57. How the image is built and pushed (2026-11-02)

**Problem.** app pulls Mailbridge from ECR by digest (§3, decision 53). Some machine must build the image and push it, and whoever can push decides what app runs, so this is a supply-chain decision as much as a convenience one.

**Options.** A: build and push by hand from the laptop with the admin's short-lived `aws login` session, and automate later. B: the app repo's GitHub Actions pushes through an IAM role trusted with OIDC, limited to `main`. C: build on the app instance itself.

**Chosen: A, for now.** From the merged app commit: `docker build --platform linux/amd64 --provenance=false`, tagged with the git commit, then `docker push` after `aws ecr get-login-password`. A single-platform image with no attestation manifest can't lose parts to decision 53's untagged rule, and a commit tag is unique, as immutable tags require. The pushed digest is pinned in the lab's Ansible variables. No new credential is created. B is the intended end state (T2.2), but it adds an OIDC provider, a role and a trust policy now, and ties a repo's CI to the account before Tier 1 works and before the repo's visibility is settled. C puts build tools, source and npm's internet access on a production host and loses registry digest pinning.

**Trade-off accepted.** A manual step, and the laptop's Docker is part of the supply chain. The app's CI has built and scanned the same commit with Trivy, which limits the risk.

**Verify once built.** `aws ecr describe-images --repository-name mailbridge` lists one image with the commit tag and `imageManifestMediaType` `application/vnd.docker.distribution.manifest.v2+json` or the OCI manifest type, not an index. A scan result appears in `describe-image-scan-findings`. Pushing the same tag again fails with `ImageTagAlreadyExistsException`. On app, `docker inspect` shows the pinned digest.

## 58. Where ModSecurity and the CRS come from (2026-11-04)

**Problem.** The proxy's WAF has three parts: the engine (libmodsecurity v3), the Nginx connector (a dynamic module that hands each request to the engine), and the OWASP Core Rule Set (text rule files). They can come from different sources. On Ubuntu 24.04 the packages are `libmodsecurity3t64` 3.0.12, `libnginx-mod-http-modsecurity` 1.0.3 and `modsecurity-crs` 3.3.5, all in universe; upstream's current CRS line is 4.x.

**Options.** A: engine and connector from Ubuntu, CRS 4 from a pinned upstream release checked against a SHA-256. B: all three from Ubuntu, CRS 3.3.5. C: the official `owasp/modsecurity-crs:nginx` container, or engine and connector built from source.

**Chosen: A.** apt installs the engine and the connector, so the module always matches the Nginx binary it loads into and gets apt's updates. The role downloads one CRS 4.x release, compares its SHA-256 with the value in `defaults/main.yml` before unpacking, and installs it into a versioned directory that Nginx's ModSecurity config includes. The exact release is chosen in the role PR. B is simpler, but 3.3 is the line the project has moved past: 4.x adds the plugin mechanism used for application exclusions and is what current documentation and Phase 2's bypass testing target. C puts a second Docker host in the DMZ, and Certbot, the certificate files and the logs Wazuh reads would all cross a container boundary; a source build needs a compiler on the DMZ host and loses apt updates.

**Trade-off accepted.** The CRS doesn't update by itself; a new release is a PR changing the version and hash, like the Mailbridge digest. The engine and connector are in universe, which gets Canonical's security fixes only with Ubuntu Pro; without Pro, `unattended-upgrades` may fix them late or not at all. Enabling Pro is a separate decision, not taken now.

**Verify once built.** `nginx -t` passes and the ModSecurity module is loaded (`/etc/nginx/modules-enabled` lists it). The role fails if the downloaded archive's SHA-256 differs from the pinned value. A request with `?id=1' OR '1'='1` returns 403 and the audit log names a CRS 4 rule (942xxx, SQL injection) and the CRS version.

## 59. The ACME client: lego instead of Certbot (2026-11-04)

**Problem.** proxy needs a Let's Encrypt certificate for a name that is never public, so it uses the DNS-01 challenge: the client writes a TXT record at `_acme-challenge.mail.<domain>` in the public Route 53 zone, using the instance role (§6, §7). Something must request the certificate, renew it before its 90 days run out, and reload Nginx afterwards, without any stored credential.

**Options.** A: Certbot and `python3-certbot-dns-route53` from Ubuntu (2.9.0, universe), with the packaged `certbot.timer`. B: the Certbot snap with the Route 53 plugin snap, as EFF recommends. C: a standalone client, acme.sh or lego.

**Chosen: C, lego.** lego is a single static Go binary with a built-in Route 53 provider that uses the AWS SDK's default credential chain, so it picks up the instance role through IMDSv2. The role downloads one release, compares its SHA-256 with the value in `defaults/main.yml`, and installs it. Before a new version's hash is committed, its GitHub build provenance is checked on the laptop with `gh attestation verify`, so the pinned hash is known to come from lego's own release workflow. Given the zone ID, lego doesn't list hosted zones, which narrows the grant (decision 3 of 1.15). The role also writes `lego-renew.service` and `lego-renew.timer`: the timer runs daily with a random delay, the service runs `lego renew` (which renews only within 30 days of expiry) and reloads Nginx only when a certificate was renewed. A's main advantage, updates through apt, is weak because universe packages get Canonical's security fixes only with Ubuntu Pro; it also puts Python, Certbot and boto3 on the DMZ host. B's plugin requires `trust-plugin-with-root=ok`, and snaps update themselves from the Snap Store without review. acme.sh was rejected: a large shell script that self-installs and self-upgrades by default, and CVE-2023-38198 let a malicious CA's response run code on the client.

**Trade-off accepted.** We maintain the systemd units ourselves and update lego by PR. lego is less common than Certbot, and its file layout (`/var/lib/lego/certificates/`) differs from the familiar `/etc/letsencrypt/live/`.

**Verify once built.** The role fails on a wrong SHA-256. `lego list` shows `mail.<domain>`; `openssl x509 -noout -issuer -enddate` on the certificate shows a staging issuer (`(STAGING)` in the name) and a date about 90 days ahead. `systemctl list-timers lego-renew.timer` shows the next run; `systemctl start lego-renew.service` exits 0 and logs that no renewal was needed. CloudTrail shows `ChangeResourceRecordSets` by the proxy role and no `ListHostedZones`.

## 60. proxy's IAM grant for DNS-01 (2026-11-04)

**Problem.** lego on proxy (decision 59) writes and deletes one TXT record in the public zone. proxy is the host facing users, so it is the likeliest to be compromised, and whatever its role can do, an attacker there can do. A zone-wide `ChangeResourceRecordSets` would let them repoint `vpn.<domain>` at their own server and intercept VPN connections, stopped only by `tls-crypt` and the server-certificate check.

**Options.** A: the narrowest grant IAM can express: `ChangeResourceRecordSets` on this zone with conditions on the record name, type and action; `ListResourceRecordSets` on this zone; `GetChange`. B: `ChangeResourceRecordSets` on the zone with no conditions. C: the AWS-managed `AmazonRoute53FullAccess`.

**Chosen: A.** The change statement uses `ForAllValues:StringEquals` on `route53:ChangeResourceRecordSetsNormalizedRecordNames` (`_acme-challenge.mail.<domain>`: lower case, no trailing dot), `route53:ChangeResourceRecordSetsRecordTypes` (`TXT`) and `route53:ChangeResourceRecordSetsActions` (`UPSERT`, `DELETE`), so every record in a request must match. `ListResourceRecordSets` can't be limited below the zone; lego uses it to merge existing TXT values, and it reveals nothing that public DNS doesn't. `GetChange` has no resource scoping beyond `change/*`. lego is given the zone ID, so `ListHostedZones` isn't granted. The domain and zone ARN come from Terraform data sources (as in decision 43), and Ansible looks up the zone ID from the laptop at run time with `amazon.aws.route53_info` and writes it into lego's environment file, like the dynamic inventory (decision 45). B and C give an attacker on proxy control of the lab's public names; C also allows creating zones.

**Trade-off accepted.** The policy is longer and depends on condition keys whose exact semantics (normalized names, `ForAllValues` on multi-valued keys) must be right, so it is tested with the simulator before any host runs. Adding a second certificate name means editing the condition.

**Verify once built.** `aws iam simulate-principal-policy` against the proxy role, with context entries for the three keys: TXT `UPSERT` of `_acme-challenge.mail.<domain>` is allowed; `UPSERT` of `vpn.<domain>` type A, TXT at another name, and `CREATE` are denied (`implicitDeny`); `route53:ListHostedZones` is denied. After the first certificate, CloudTrail shows only `ChangeResourceRecordSets`, `ListResourceRecordSets` and `GetChange` from the proxy role.

## 61. TLS versions on proxy (2026-11-04)

**Problem.** Nginx terminates TLS for `mail.<domain>`. Every protocol version and cipher it accepts is something to defend. TLS 1.3 removed RSA key exchange, CBC ciphers and renegotiation, and always gives forward secrecy; TLS 1.2 is still safe only when limited to ECDHE with AEAD ciphers.

**Options.** A: TLS 1.3 only (Mozilla "modern"). B: TLS 1.2 and 1.3 with the ECDHE/AEAD list (Mozilla "intermediate"). C: Nginx's defaults on noble, which allow 1.2 and 1.3 with a broader cipher list.

**Chosen: A.** The only clients are the admin's own current browsers inside the VPN, so 1.2's compatibility has no user. TLS 1.3 needs no cipher list (Nginx's 1.3 defaults are all AEAD), it matches the VPN's `tls-version-min 1.3`, and "1.2 is refused" is a simple, checkable claim for Phase 2. Alongside: `server_tokens off` so Nginx doesn't advertise its version; HSTS with a short `max-age` while certificates are staging, raised when production certificates arrive (2.6), so a mistake can't lock browsers out for long; no OCSP stapling, because Let's Encrypt has ended its OCSP service. B is the right answer for a public site with unknown clients, not this one. C would be a configuration nobody chose.

**Trade-off accepted.** Any old client or tool without TLS 1.3 can't connect. Test tools in Phase 2 must support 1.3, which current curl, OpenSSL, nmap and ZAP do.

**Verify once built.** From the VPN: `openssl s_client -connect 10.0.2.10:443 -servername mail.<domain> -tls1_2` fails with a handshake alert; with `-tls1_3` it succeeds, showing `TLSv1.3` and an ECDSA certificate. `curl -skI https://mail.<domain>` shows `Strict-Transport-Security` and a `Server: nginx` header with no version.

## 62. Who sets HSTS (2026-11-04)

**Problem.** The first request through proxy returned two `Strict-Transport-Security` headers: `max-age=31536000` from the app and `max-age=300` from Nginx. Nginx's `add_header` adds a header and never replaces one from the upstream. RFC 6797 §8.1 says a browser processes only the first HSTS header, which was the app's. So decision 61's short staging `max-age` wasn't in force: one certificate mistake could have pinned the admin's browser to HTTPS-only for a year, with no way to click through.

**Options.** A: Nginx owns the header. `proxy_hide_header Strict-Transport-Security` drops the app's copy, and `add_header` sends ours. B: the app owns it. Remove the Nginx header and configure the app's HSTS to 300 s, in the Mailbridge repo. C: leave both.

**Chosen: A.** HSTS is a promise about the TLS endpoint, and Nginx is that endpoint; the app speaks plain HTTP on port 3000 and can't know the edge's certificate state. The value stays one variable (`proxy_hsts_max_age`) in this repo, so moving to production certificates (2.6) is a one-line change. B ties the lab's edge policy to app code in another repo. C leaves decision 61 documented but untrue.

**Trade-off accepted.** If the app's HSTS policy changes, the lab won't follow it; that's intended, but it means the app's header is never what a browser sees behind this proxy. Each other security header the app sends (CSP and the rest) still passes through unchanged and needs the same check.

**Verify once built.** From the VPN: `curl -sk -D - -o /dev/null https://mail.<domain>/healthz | grep -i strict-transport` prints exactly one line, `strict-transport-security: max-age=300`.

## 63. Which CRS release, and the engine it needs (2026-11-04)

**Problem.** Decision 58 put Ubuntu's ModSecurity engine under a pinned upstream CRS. The CRS 4.25 LTS line's changelog for 4.25.1 says: "Requires libmodsecurity v3.0.16 or later". Rule 901181 uses a `ctl` target with `@`, which older engines can't parse. Ubuntu 24.04 ships 3.0.12, 26.04 LTS ships 3.0.14 and Debian 13 ships 3.0.14. In a 24.04 container, CRS 4.25.2 stopped Nginx from loading ("Rules error ... REQUEST-901 ... Line 333").

**Options.** A: CRS 4.25.0, the last release that loads on 3.0.12, with the missing fixes documented. B: the CRS project's `owasp/modsecurity-crs:nginx` image, pinned by digest, with a current engine and CRS. C: build libmodsecurity 3.0.17 and the connector as `.deb` packages in CI.

**Chosen: A.** It keeps decision 58's split and was tested end to end on the real packages. It misses three groups of fixes. The XML attribute fix doesn't apply, because the CRS now accepts only `application/json` bodies (`tx.allowed_request_content_type`), so an XML body gets 403 from rule 920420 before any XML parsing matters. The ReDoS hardening (933160, 933161, 933180, 941140) is capped by `SecPcreMatchLimit 1000`, which stops runaway backtracking with an error that rule 200005 turns into a deny. The JSON-encoding bypass fix (4RI-250413), in the SQLi, RCE, LDAP and generic rules, is a real gap on a JSON API. It's accepted and becomes a Phase 2 measurement. B reverses decision 58's rejection: Docker on the DMZ host, and TLS, lego's reload and the logs crossing a container boundary, which means reworking PR 54. C means owning a C library's security patches.

**Trade-off accepted.** A known, published fix is missing, and the pin is a dead end: every later 4.25.x needs 3.0.16. The move to B, or to an LTS engine ≥ 3.0.16, is a Tier 2 task.

**Verify once built.** The audit log names `OWASP_CRS/4.25.0`. `nginx -t` passes. A `Content-Type: application/xml` body gets 403 with rule 920420. The role fails if the archive's SHA-256 differs. On the laptop, `gpg --verify` of the `.asc` shows a good signature from key `36006F0E0BA167832158821138EEACA1AB8A6E72`.

## 64. Block, or only detect (2026-11-04)

**Problem.** The CRS uses anomaly scoring. Each matching rule adds points by severity (critical 5, error 4, warning 3, notice 2), and REQUEST-949 blocks once the inbound total reaches the threshold. `SecRuleEngine` decides whether that block happens (`On`) or is only logged (`DetectionOnly`).

**Options.** A: `On` from the first deploy, with the default thresholds (inbound 5, outbound 4). B: `DetectionOnly` for a tuning period, then `On`. C: `On` with higher thresholds to absorb false positives.

**Chosen: A.** The only client is the admin, over the VPN. A false positive costs a 403 and an audit entry, and blocking surfaces it while building, as the profile photo did (rule 10010 and its exclusion). B is the standard rollout for a public site with unknown traffic. Here it would only delay the check that matters. C hides false positives instead of fixing them, and it weakens every rule at once.

**Trade-off accepted.** A false positive breaks a feature until it's tuned. Each tuning step is a narrow, commented exclusion in `exclusions-before.conf`, not a threshold change.

**Verify once built.** `?id=1' OR '1'='1` returns 403, and the audit log shows 942100 then 949110. Normal pages and `/healthz` return 200.

## 65. Paranoia level (2026-11-04)

**Problem.** CRS rules are grouped into paranoia levels 1 to 4. Each level adds stricter rules, so it detects more and produces more false positives.

**Options.** A: PL1. B: PL2. C: PL1 blocking, with PL2 rules logged only (`tx.detection_paranoia_level=2`).

**Chosen: A.** It's the default and the CRS's recommendation for most sites. Its false-positive rate fits a JSON API with free-text mail fields, and it's the baseline that bypass testing usually targets. B would need exclusions for compose and send straight away. C is the right next step once PL1 is quiet, and it's the Phase 2 experiment: the same attacks at PL1 and PL2, comparing detection.

**Trade-off accepted.** PL1 misses some evasions that PL2 catches, and those show up as bypasses in Phase 2.

**Verify once built.** `crs-setup.conf` sets `tx.blocking_paranoia_level=1`, and the audit log entries show only `paranoia-level/1` tags on matched rules.

## 66. What the audit log keeps (2026-11-04)

**Problem.** ModSecurity's audit log is made of parts: A (transaction), B (request headers, including cookies), C and I (request body), E (response body), F (response headers), H (matched rules), Z (end). It's sent to Wazuh in task 1.17, and libmodsecurity v3 can't mask individual fields. Upstream's recommended config logs `ABIJDEFHZ` for every 4xx and 5xx.

**Options.** A: parts `ABFHZ`, only for flagged transactions and 5xx, response bodies not inspected. B: `AHZ`, no headers. C: upstream's default.

**Chosen: A.** Rules and headers are what a finding needs: which rules matched, the request line, client, `User-Agent` and `Host`. Bodies are excluded, so mail text, drafts and OAuth codes never enter the log. `SecResponseBodyAccess Off` also keeps mail out of memory on a t3.micro. The RESPONSE-95x data-leak rules then have nothing to read, which is accepted. `SecAuditLogRelevantStatus "^5"` keeps server errors, because an attack that makes the app fail is a finding, and drops the app's normal 4xx answers, which would carry the admin's cookie. libmodsecurity 3.0.12 ignores `SecAuditLogFileMode`, so Ansible creates the file `0600` inside a `0700` directory. Logrotate uses `copytruncate`, because Nginx's reopen signal doesn't reach libmodsecurity's file handle. B loses the request line. C copies mail and tokens into the SIEM.

**Trade-off accepted.** A false positive on the admin's own request logs their session cookie. It expires, and Wazuh access is admin-only. No request bodies means a finding can't show the exact payload of a body attack, only the rule and its matched data in part H.

**Verify once built.** `stat -c '%a %U' /var/log/modsecurity/audit.log` shows `600 root`. After the SQLi test, the newest entry has `messages` with 942100, no `body` in `request`, and `OWASP_CRS/4.25.0`. A normal 401 from the app adds no entry.

## 67. Where Juice Shop runs (2026-11-04)

**Problem.** Phase 2 needs ground truth: a target with known vulnerabilities, so every miss and every block can be attributed to a layer. OWASP Juice Shop has RCE, SSRF, XXE and file upload challenges by design, so whatever can reach it must be treated as compromised. Mailbridge holds OAuth tokens, its token encryption key and two DB passwords.

**Options.** A: a second container on the app host. B: its own host in its own subnet, with its own route table, security group, NACL and IAM role. C: the app host, with a separate Docker network whose egress is locked by host firewall rules.

**Chosen: B, with C's container lock added as a second layer.** In A, the container shares Mailbridge's kernel and Docker daemon, the app role that reads `/mailbridge/*`, the disk with `app.env`, and sg-app's egress to 5432. Container traffic is also NATed to 10.0.3.10, the one address `pg_hba` trusts. C fixes the container's egress, but the controls run on the host being attacked, so one escape removes them. In B, the host has nothing worth taking: `mailbridge-lab-ssm-min` plus pull from its own ECR repository (decision 69), no secrets, and a subnet that SG, NACL and nftables all refuse to db, app and mgmt. Inside the host, `DOCKER-USER` drops new connections from the container network, and the container's DNS server routes nowhere. Without that, DNS through AmazonProvidedDNS would be an exfiltration path that security groups can't filter (decision 30). Juice Shop runs with `--cap-drop ALL`, `no-new-privileges`, memory and pids limits and its image's non-root user, with IMDS hop limit 1. The host, role, security group, switch and DNS name are the generic `vuln` (`vuln.<domain>`), so another deliberately vulnerable app, such as DVWA, can replace or join Juice Shop without renaming the infrastructure; the ECR repository is named after the image it holds, `juice-shop`.

**Trade-off accepted.** One more host (t3.small, about $0.024/hour while enabled), subnet and role to maintain. The host itself keeps TCP 443 egress for SSM and ECR, which an escape could use; it's logged (`FW-EGRESS`) and accepted.

**Verify once built.** From inside the container: `curl` to 10.0.4.10:5432, 10.0.3.10:3000, 169.254.169.254 and any internet address all fail, and `DOCKER-USER` logs the drops. From the host: the IAM simulator denies `ssm:GetParameter` on `/mailbridge/*` and ECR pull on `mailbridge`. `nc` from the host to 10.0.4.10:5432 times out and fw-ips logs the drop.

## 68. East-west inspection through fw-ips (2026-11-04)

**Problem.** TLS ends at Nginx, so Suricata on `tun0` sees only TLS metadata, never payloads. The proxy→Juice Shop hop is plain HTTP, but VPC traffic between subnets normally takes the `local` route and never crosses fw-ips.

**Options.** A: more-specific VPC routes that send the hop through fw-ips. AWS allows a route more specific than `local` when its destination is a whole subnet CIDR. B: VPC Traffic Mirroring to a Suricata sensor. C: Suricata in IDS mode on proxy.

**Chosen: A.** It's free, inline (Suricata can drop), and reuses the existing fail-closed NFQUEUE path. It also puts nftables between the target and everything else. The private route table gets `10.0.6.0/24 → fw ENI`, and the vuln table gets `0.0.0.0/0`, `10.0.2.0/24` and `10.0.5.0/24 → fw ENI`. The routes must be symmetric. The private table is shared with mgmt, so siem's replies to the Juice Shop agent go through fw-ips, and if the agent's requests went direct, fw-ips would see half a connection and drop it. AWS doesn't let security groups reference another group through a middlebox route, so the rules on these paths name addresses (10.0.2.10/32, 10.0.6.10/32, 10.0.5.10/32). Mailbridge's proxy→app path stays direct, so mail never reaches `eve.json`. B bills per mirror session hour. C adds Suricata's memory to a t3.micro already running two CRS bundles.

**Trade-off accepted.** A wrong route blackholes traffic, so plans are checked line by line. If Suricata stops, Juice Shop is unreachable, which is the fail-closed design.

**Verify once built.** `aws ec2 describe-route-tables` shows the routes. A request to `https://vuln.<domain>/rest/products/search?q=test` appears in `eve.json` as an `http` event with the URL. A request to `mail.<domain>` adds no `http` event. The Wazuh agent on vuln shows active.

## 69. Where the Juice Shop image comes from (2026-11-04)

**Problem.** The host needs the image, pinned and scanned, without a registry password and without opening the host to arbitrary internet registries.

**Options.** A: a separate ECR repository `juice-shop`, filled by hand on the laptop, with a pull-only grant on that repository. B: pull from Docker Hub by digest on the host. C: put it in the existing `mailbridge` repository.

**Chosen: A.** It's the same pattern as Mailbridge (decisions 5, 53, 57). The laptop pulls `bkimminich/juice-shop` by digest, checks it, and pushes it. ECR then scans it on push, and the tag can't be moved. The host role gets `ecr:GetAuthorizationToken`, which can't be scoped to a repository, plus `BatchGetImage`, `GetDownloadUrlForLayer` and `BatchCheckLayerAvailability` on the `juice-shop` repository ARN only. The host never contacts Docker Hub. B needs no IAM, but it would make the host depend on Docker Hub at run time. C would mean a grant that covers the Mailbridge image.

**Trade-off accepted.** An update is a manual mirror and a digest change in a PR. Storage is a few hundred MB, so pennies a month beyond the free tier.

**Verify once built.** `aws ecr describe-images --repository-name juice-shop` shows one digest with a scan result. `docker inspect` on the host shows that digest. The IAM simulator allows `ecr:BatchGetImage` on `juice-shop` and denies it on `mailbridge`.

## 70. Juice Shop on the shared proxy, with its own certificate (2026-11-04)

**Problem.** Juice Shop needs a name, TLS and the WAF in front of it. The only proxy today serves `mail.<domain>`.

**Options.** A: a second server block on the shared proxy, with its own certificate. B: the same, with a SAN certificate covering both names. C: a second proxy host.

**Chosen: A.** C doubles the proxy's cost and role for a lab whose only user is the admin. B would present `mail.<domain>` to anyone on the window listener. lego runs once per name from a templated `lego-renew@<name>` service, and decision 60's IAM condition adds `_acme-challenge.vuln.<domain>` and nothing else. Unbound adds `vuln.<domain> → 10.0.2.10`. Staging certificates only, as for mail.

**Trade-off accepted.** Attacks on Juice Shop pass through the same Nginx and ModSecurity as mail. A proxy crash, ReDoS or RCE caused through Juice Shop affects Mailbridge too.

**Verify once built.** `openssl s_client -servername vuln.<domain>` shows a staging certificate whose SAN list has only `vuln.<domain>`. The simulator allows the TXT `UPSERT` on `_acme-challenge.vuln.<domain>` and still denies `vpn.<domain>`. Both timers are listed.

## 71. ModSecurity per server, and the measurement matrix (2026-11-04)

**Problem.** The experiment needs Juice Shop's WAF mode and paranoia level changed many times, while Mailbridge keeps decisions 63 to 66. A rules file loaded once for all servers can't do that.

**Options.** A: one bundle per server (engine settings, CRS settings, exclusions, and the CRS rules), each loaded by its own `modsecurity_rules_file`. B: one shared bundle, with per-server overrides through `modsecurity_rules`. C: one bundle, with the mode switched by request host in a rule.

**Chosen: A.** Each bundle sets its own `SecRuleEngine` and `tx.blocking_paranoia_level`, so changing Juice Shop is one variable and a `--limit proxy` run. B and C depend on override order inside one rule set, which is easy to get wrong silently. Juice Shop's bundle allows JSON, form, multipart and XML bodies, because its challenges use them. That makes CRS 4.25.0's missing XML attribute fix (decision 63) live on that server, which is a measurement. Its audit log keeps request bodies (`ABCFHZ`) in `vuln-audit.log`, because the data is fake and the payload is the evidence. The matrix is {DetectionOnly, On} × paranoia level 1 to 4. Each run replays the same corpus: GoTestWAF, scripted Juice Shop challenges (the scoreboard confirms a bypass), and a benign browsing capture for false positives. In DetectionOnly, "would block" is read from the anomaly score in the audit log.

**Trade-off accepted.** The CRS is loaded twice, which costs memory on a t3.micro, so it's measured in the container harness before AWS.

**Verify once built.** With Juice Shop at DetectionOnly and mail at On, the same SQLi gets 403 on mail and 200 on Juice Shop, and both audit logs record it. `vuln-audit.log` entries contain `request.body`, and mail's don't.

## 72. The Juice Shop test window (2026-11-04)

**Problem.** Scenario 2.1 needs an outside view, but a public, deliberately vulnerable app gets found and exploited by internet bots within minutes. Mailbridge must never be reachable from outside.

**Options.** A: DNAT internet 443 to a separate proxy listener (10.0.2.10:8443) that has only a handshake-refusing default server and the Juice Shop server, with the source limited to Marko's /32. B: DNAT to proxy's normal 443 listener and rely on SNI. C: no outside window for Juice Shop.

**Chosen: A.** `mail.<domain>` has no server block on 8443, so asking for its name from outside gets a refused handshake. The separation is structural, not a rule that could be mistyped. The source is Marko's public /32 in sg-fw, the public NACL, the dmz NACL and sg-proxy. A public `vuln.<domain>` A record exists only during the window. Suricata gets the forwarded window traffic through nftables (written by Marko). B would leave mail one wrong `server_name` away from the internet. C loses the outside position.

**Trade-off accepted.** §4's "0.0.0.0/0 — test windows only" becomes "Marko's /32", so the test is "from the internet" only in the sense of crossing it. Mailbridge's SQLi and XSS tests in 2.1 move inside the VPN.

**Verify once built.** During a window from Marko's IP: `curl https://vuln.<domain>/` returns 200, and `openssl s_client -servername mail.<domain> -connect <eip>:443` gets a handshake alert. From any other IP, the port times out. After closing the window, `terraform plan` shows the rules and the record removed.

## 73. A separate attacker identity (2026-11-04)

**Problem.** If attacks come from the admin's VPN address, attack traffic and administration are mixed in every log, and the admin pool can reach more than a VPN user can.

**Options.** A: a separate attacker device certificate in the user pool. B: the admin certificate. C: an attack box in AWS.

**Chosen: A.** Logs attribute each attack to the attacker certificate's 10.8.0.x address, and the user pool reaches only proxy:443, like a real VPN user. B mixes the evidence. C costs money and needs its own egress.

**Trade-off accepted.** One more certificate to issue on the offline CA and revoke after Phase 2.

**Verify once built.** Connected with the attacker profile, the address is in 10.8.0.0/24. `nc -zv 10.0.5.10 443` times out. Attack requests in Nginx's log show that address.

## 74. The `vuln_enabled` switch (2026-11-04)

**Problem.** Most sessions don't attack Juice Shop, but the session routine (decision 41) brings up every host.

**Options.** A: a separate `vuln_enabled` variable (default `false`), with the host created only when it and `hosts_enabled` are both true. B: always on with `hosts_enabled`. C: a separate root stack.

**Chosen: A.** One variable, the same apply. Sessions without Juice Shop cost nothing extra and keep the routine unchanged. C duplicates the backend and providers for one host.

**Trade-off accepted.** Plans differ depending on the variable, so the routine's expected counts must say which.

**Verify once built.** `plan` with the default shows no vuln resources. `-var vuln_enabled=true` shows its instance. `-var hosts_enabled=false` removes it in either case.

## 75. Tool scope and rate limits (2026-11-04)

**Problem.** Tools like sqlmap, ffuf, Nuclei and hydra will attack whatever they're given, at whatever rate they're set to. AWS lets customers test their own EC2 without approval, but it prohibits DoS and "request flooding (login and API)", and C2 testing needs prior approval. CLAUDE.md limits attacks to own targets.

**Options.** A: a committed scope file and a wrapper that refuses any target other than proxy 10.0.2.10 with SNI `vuln.<domain>` (or `mail.<domain>` for Mailbridge scenarios), with rate caps per tool. B: tool-level scope settings only. C: no tooling controls.

**Chosen: A.** The wrapper resolves the target and checks the address and name before running anything. Caps: `ffuf -rate 20`, `nuclei -rl 20 -c 5 -ni` (no interactsh), `hydra -t 2` with a short list, sqlmap `--delay`, GoTestWAF with few workers and a send delay. ZAP and Burp get a context or scope set. There are no reverse shells or C2, which the egress design blocks anyway, no Burp Collaborator, and no load testing. B depends on remembering each tool's flags.

**Trade-off accepted.** Slower scans and some challenges that can't be solved (out-of-band SSRF). That's recorded as a containment result, not a gap.

**Verify once built.** The wrapper refuses `10.0.0.2`, `mail.<domain>` in a Juice Shop run, and any public address, exiting non-zero. Nginx's log shows request rates under the caps.

## 76. A separate browser profile for Juice Shop (2026-11-04)

**Problem.** Juice Shop's XSS challenges run attacker JavaScript in the tester's browser at `vuln.<domain>`, a sibling of `mail.<domain>`. For the browser they are the same site, so Mailbridge's `SameSite=Lax` session cookie is still sent on same-site requests. `__Host-` stops cookie tossing, and Mailbridge's same-origin check stops cross-origin POSTs, but neither is a reason to mix the two.

**Options.** A: a separate browser profile for Juice Shop, never signed in to Mailbridge. B: a different registrable domain for Juice Shop. C: nothing.

**Chosen: A.** It removes the cookie from the browser that runs the attacks, at no cost. B needs a second domain and zone. C leaves the admin's mail session one same-site request away from attacker scripts.

**Trade-off accepted.** It's a procedure, not a technical control, so it's written into task 2.14 and the scope notes.

**Verify once built.** In the Juice Shop profile, the browser's storage shows no cookie for `mail.<domain>`.

## 77. Rate limits on proxy (2026-11-04)

**Problem.** Mailbridge throttles sign-in, registration, password reset and sending in the app (for example, login: 50 per IP and 10 per account per 15 minutes). Each check is an `INSERT ... ON CONFLICT` in Postgres, so a fast flood of guesses turns into a flood of database writes on a t3.micro. Task 1.15 also asks for a rate limit at the edge.

**Options.** A: two `limit_req` zones keyed by client address, a general one and a stricter one for POSTs to the auth paths. B: the auth zone only. C: the general zone only.

**Chosen: A.** `limit_req` is a leaky bucket. Requests drain at the zone's rate, `burst` lets that many extra through, `nodelay` serves the burst at once instead of queueing it, and the rest get rejected before reaching the app. The general zone (20 r/s, burst 50) is far above a page load, which fetches the HTML and its assets. The auth zone (6 per minute, burst 5) counts only POSTs, through a `map` that gives other methods an empty key, so guessing gets 429 after about six tries without the database seeing the rest. The two layers do different jobs: Nginx cuts bursts cheaply, and the app enforces long windows and per-account counts it alone can see. The key `$binary_remote_addr` works because VPN pools aren't NATed. The proxy settings move into a snippet, because a location with its own `limit_req` doesn't inherit the server's. B leaves spiders and scanners pushing every request through ModSecurity and the app. C gives password guessing the same allowance as browsing. A connection limit isn't added, because Suricata rule 1000004 drops SYN floods per source.

**Trade-off accepted.** ModSecurity still evaluates a limited request's headers, because the connector runs in Nginx's rewrite phase, before `limit_req` (preaccess). Several clients behind one address would share a bucket, which doesn't happen here. Fast scans in Phase 2 will see 429s, which is the control working, and is recorded as such.

**Verify once built.** From the VPN, 30 quick POSTs to `/auth/login` give about six non-429 answers and then 429. GETs to the same path, a page load and other POSTs stay unaffected. The error log shows `limiting requests ... by zone "mail_auth", client: 10.8.x.x`. Tested on 2026-11-04 in the Ubuntu 24.04 container harness: 6 passed and 24 got 429; 40 parallel asset GETs all got 200; 120 back-to-back GETs gave 73 passed and 47 limited.

## 78. What an over-limit client gets (2026-11-04)

**Problem.** Nginx answers a limited request with 503 by default, and logs rejections at `error` and delays at one level below.

**Options.** A: `429 Too Many Requests`, logged at `error`. B: the default 503. C: 429, logged at `warn`.

**Chosen: A.** 429 is the HTTP status for exactly this, and clients and attack tools recognise it. 503 claims the service is down, which would mislead you and Tier 2's monitoring. C was the first plan, but Ubuntu's `nginx.conf` sets `error_log` to the default threshold, `error`, so `warn` lines are dropped. The container test showed 0 log lines at `warn` and 71 at `error`. Raising the whole server to `warn` would also admit unrelated notices.

**Trade-off accepted.** Rate-limit lines are labelled `[error]` although nothing failed. The Wazuh rules in 1.17 match on `limiting requests`, not on the level.

**Verify once built.** `curl -s -o /dev/null -w '%{http_code}'` on a limited request prints `429`. `grep 'limiting requests' /var/log/nginx/error.log` finds the client's VPN address.

## 79. One alert per non-TLS flow, and keeping 1000001 (2026-11-04)

**Problem.** Re-testing the 1.12 rules against real Nginx showed that Nginx answers any non-TLS bytes on 443 with an HTTP 400. Suricata's protocol detection looks at both directions, so that reply labels the flow `http`: text garbage (`hello`) gave only 1000005, and 64 random bytes gave both 1000001 and 1000005. 1000005, a protocol rule without a content match, also fired several times per flow.

**Options.** A: keep both rules and make them share one flowbit, so whichever matches first is the only alert on that flow. B: retire 1000001 and keep 1000005. C: keep both unchanged.

**Chosen: A.** Both rules test and set `mb.nontls`. Suricata orders rules that set a flowbit before rules that check it, so each flow gives one alert. In the Suricata 7.0.3 container replay, every capture gave exactly one. 1000001 is kept for streams that neither side makes recognisable. With Nginx in front, binary garbage usually ends as 1000005, because Nginx's reply labels the flow first, but a tunnel whose server answers differently, or doesn't answer, still reaches 1000001. B was the first recommendation, made before the binary test showed 1000001 does fire. C leaves duplicate alerts that would inflate Phase 2 counts. 1000005's message now says what it detects: "non-TLS or plain HTTP on proxy 443".

**Trade-off accepted.** Which rule fires depends on how far detection got. For a finding, "non-TLS on 443" is the fact, and the sid only shows how it was recognised.

**Verify once built.** From the VPN: `curl http://10.0.2.10:443/`, `printf 'hello\n' | nc`, and `head -c 64 /dev/urandom | nc` each add exactly one line to `fast.log`, for 1000005 or 1000001.

## 80. TLS without a server name (2026-11-04)

**Problem.** Rule 1000003 alerts on an SNI that doesn't start with `mail.`. A ClientHello without SNI has no `tls.sni` buffer, so `content:!` has nothing to test and the rule doesn't match. The re-test showed this: `openssl s_client -tls1` without `-servername` raised 1000002 but not 1000003.

**Options.** A: a new alert rule for a ClientHello without SNI. Suricata 7.0.3 (Ubuntu 24.04) has no `absent` keyword, so a silent helper rule sets a flowbit when `tls.sni` has content, and the alert fires on `ssl_state:client_hello` from a flow without that flowbit. B: wait for a Suricata version with `absent`. C: accept the gap.

**Chosen: A.** Every legitimate client sends SNI, because Nginx's default server refuses handshakes for unknown or missing names. The helper (1000007) uses `flowbits:noalert`, and the alert (1000006) sets its own flowbit, so it fires once per flow. B depends on a package Ubuntu doesn't ship. C leaves "connect to the IP address" as an unalerted way past 1000003.

**Trade-off accepted.** Two rules for one idea, and one of them never alerts, which a reader must understand from the comment. It's alert-only until Phase 2 shows no false positives.

**Verify once built.** `openssl s_client -connect 10.0.2.10:443 </dev/null` (no `-servername`) adds one 1000006 line. With `-servername mail.<domain>`, it adds none. In the container replay, `no-sni.pcap` gave one 1000006 and `clean-tls.pcap` gave nothing.

## 81. Which rules drop (2026-11-04)

**Problem.** Since 1.12, only 1000004 (the SYN flood) has dropped. The others were alert-only until they had been tested against real TLS, and fw-ips is inline and fails closed, so a `drop` with false positives breaks the site.

**Options.** A: promote 1000002 (TLS 1.0) and 1000005 (non-TLS on 443), and keep 1000001, 1000003 and 1000006 as alerts. B: promote everything that fired correctly. C: keep alerts only until the Phase 2 baselines.

**Chosen: A.** An IPS `drop` belongs on high-confidence rules that describe traffic with no legitimate use. 1000002 and 1000005 matched real traffic correctly with no false positive in the re-test or the replay, and Nginx refuses both anyway. The drop stops them one hop earlier and records them in Suricata. 1000001 depends on detection failing, which is a weaker signal. 1000003 must allow `vuln.<domain>` in 2.9 before it can block. 1000006 is new. B would block on those weaker or unfinished rules. C waits for evidence the re-test already provides for these two.

**Trade-off accepted.** A browser or tool that only speaks TLS 1.0 gets a silent drop instead of Nginx's handshake alert. That's harder to diagnose, but it shows in `fast.log` as `[Drop]`.

**Verify once built.** `fast.log` shows `[Drop]` for 1000002 and 1000005 after the Step T commands. `curl -sk https://mail.<domain>/healthz` still returns 200. In the container replay with `--simulate-ips`, `tls10`, `http`, `text-nginx400` and `binary-nginx400` were marked `[Drop]` and `clean-tls` gave nothing.

## 82. The 1000002 outage, and when a rule may drop (2026-11-04)

**Problem.** Minutes after decision 81 made rule 1000002 (TLS 1.0 client) a `drop`, `https://mail.<domain>` timed out from the VPN. `fast.log` showed `[Drop]` 1000002 for each normal `curl`. Service came back after the rule was set to `alert` by hand on fw-ips and the rules were reloaded. The count by minute showed the rule had been firing on some normal connections ever since 1.12, which went unnoticed while it only alerted, because every check read `tail -8`. A replay in the Suricata 7.0.3 container reproduced it. A TLS 1.3 ClientHello with a 1216-byte key share (X25519MLKEM768, the default in current OpenSSL) is about 1,300 bytes, and when it is split over two TCP segments, 1000002 matches on the first segment, where only the record header is known. Every client's record header says 0x0301 ("TLS 1.0", RFC 8446). The same hello in one segment, and a small hello, don't match. The synthetic captures from 1.12 used small hellos with record version 0x0303, so they couldn't show this.

**Options.** A: add `ssl_state:client_hello` to 1000002 so it waits for the whole hello, keep it `alert`, disable 1000006 (which showed the same split-hello false positive), and add realistic TLS 1.3 captures that every rule change is replayed against. B: delete 1000002 and 1000006. C: keep both as alerts unchanged and accept the false positives.

**Chosen: A.** With `ssl_state:client_hello`, 1000002 matched the real TLS 1.0 capture and none of the three realistic TLS 1.3 captures. 1000006 fired on the two-segment capture even though that hello carries an SNI. The likely cause is that `ssl_state:client_hello` is true before the helper rule has seen the name, but that isn't proven and no fix is tested, so it's disabled. The no-SNI gap is open again as a TASKS item. B throws away a rule that now works. C would pollute Phase 2's numbers with alerts on normal traffic. The rule for the future: a TLS-metadata rule may become `drop` only after a replay of the realistic captures stays silent and a live check shows no alerts on normal traffic over a whole session.

**Trade-off accepted.** No Suricata rule now blocks old TLS versions or non-SNI clients. Nginx still refuses everything below TLS 1.3 and handshakes without a known name, so the control remains, one hop later. The outage lasted about 10 minutes in a lab whose only user is the admin.

**Verify once built.** The container replay of all twelve captures: `tls13-small`, `tls13-big-1seg`, `tls13-big-2seg` and `clean-tls` raise nothing, `tls10` raises 1000002 without `[Drop]`, and `no-sni` raises nothing (known gap). On fw-ips after deploying, `curl -sk https://mail.<domain>/healthz` returns 200 ten times in a row, and `fast.log` gains no 1000002 line.

## 83. Close-out after the Juice Shop block (2026-11-04)

**Problem.** Decision 67 gated the Juice Shop block after 1.17 and 1.19, so the close-out tasks (1.18 CloudTrail and GuardDuty, 1.19 the end-to-end OAuth check, 1.20 the rebuild from clean, 1.21 the docs pass) stood between the detection stack and the first measured attack.

**Options.** A: close-out after the Juice Shop block. B: close-out before it, as decision 67 had it. C: split the close-out, with 1.18 before and 1.19 to 1.21 after.

**Chosen: A.** Marko's goal is to measure attacks on the full stack as soon as it exists. With A, the rebuild from clean (1.20) and the outside scan (1.19) cover every host, the vuln target included, instead of being repeated after it's added. B finishes Tier 1's build first but delays the measurements for checks that don't affect them. C splits CloudTrail from the rest for little gain.

**Trade-off accepted.** Juice Shop runs before GuardDuty and CloudTrail are confirmed, so AWS-level evidence of those sessions may be missing, and the Mailbridge OAuth path isn't tested end to end until later. The Juice Shop block doesn't need either.

**Verify once built.** `TASKS.md` lists the order 1.16 → 1.17 → 1.22, 1.23 → Juice Shop block → 1.18 to 1.21 → 2.2 to 2.5, and 1.20's rebuild includes the vuln and mon hosts.

## 84. Monitoring in Tier 1 (2026-11-04)

**Problem.** Wazuh answers "is something malicious happening?". Nothing in Tier 1 answers "is everything healthy?". Today's session showed the gap: fw-ips's CPU credits were exhausted for the first hour after the rebuild, and two Ansible runs took 12 minutes, and only a CloudWatch query after the fact explained part of it. Attacks such as brute force or a WAF matrix run also have a health side: CPU, latency, 429 rates and availability.

**Options.** A: move `mon` (former T2.1) into Tier 1, after 1.17 and before the Juice Shop block. B: Tier 1, but after the Juice Shop block. C: keep it in Tier 2.

**Chosen: A.** Each Juice Shop run is then measured once with both views, security in Wazuh and health in Grafana, instead of replayed later for the health column. The design already exists in §4 and §8 (sg-mon, node_exporter, postgres_exporter, blackbox). It needs three additions. sg-proxy and the dmz NACL accept 443 from 10.0.5.20 for the blackbox probe. The probe targets 10.0.2.10 with the TLS server name set, because `mail.<domain>` resolves only through Unbound. The vuln host is scraped across fw-ips, with an nftables rule written by Marko and a security group rule naming mon's IP (decision 68). An Alertmanager rule on CPU credit balance near 0 covers the t3 `standard` credits. B leaves the Juice Shop runs without health data. C keeps today's blind spot through Phase 2.

**Trade-off accepted.** About $0.024/hour more per session, with siem and mon together roughly $0.17/hour for the full set. One more host, role and rebuild. Retention on a session-only host is an open design question for 1.22, like Wazuh's data.

**Verify once built.** Grafana answers from the admin pool and not from the user pool. Every Prometheus target is `up`, including the vuln host across fw-ips. The blackbox probe of `https://mail.<domain>` succeeds, and a forced failure fires and clears an alert.

## 85. Which Wazuh version (2026-11-04)

**Problem.** Wazuh is the SIEM every Phase 2 finding depends on. On 2026-11-04 the stable release is 4.14.9 (15 October 2026), with 4.14.10 and 5.0 both at release candidate.

**Options.** A: 4.14.9, pinned. B: 5.0 once it's released. C: always the latest release.

**Chosen: A.** It's stable, the documentation targets it, and pinning means the version only changes through a reviewed PR, like lego, the CRS and the app image. B would wait for, and then build on, a new major version early in its life. C changes the measurement base without review.

**Trade-off accepted.** Fixes in 4.14.10 and later arrive only when the pin is bumped, so the version needs checking at each session start, like the other pins.

**Verify once built.** `apt-cache policy wazuh-manager wazuh-indexer wazuh-dashboard` shows 4.14.9 installed and held. The dashboard's About page shows 4.14.9.

## 86. How Wazuh is installed (2026-11-04)

**Problem.** Wazuh has four components on one host: the manager, Filebeat, the indexer (an OpenSearch fork) and the dashboard. They're tied together by TLS certificates and internal users. The quick path is one installer script.

**Options.** A: Wazuh's apt repository with its signing key checked, and our own role following the step-by-step guide. B: the all-in-one script `wazuh-install.sh -a`. C: Wazuh's Ansible collection, or its Docker images.

**Chosen: A.** Every package, file and setting is in the role, so a second run reports `changed=0`, drift shows up, and each line can be defended. That's the same approach as the Suricata, Unbound and Nginx roles. B is fast but isn't idempotent, configures many things at once, and writes every generated password to `wazuh-install-files.tar` on the host. That breaks CLAUDE.md's idempotency rule and the no-secrets-on-disk design. C is large generic code to pin and understand anyway, and Docker would put the SIEM behind a container boundary for its logs, certificates and data.

**Trade-off accepted.** More work than the script: the role must reproduce the guide's steps in order (indexer, security initialisation, manager, Filebeat, dashboard), and a Wazuh update can change them.

**Verify once built.** A second `site.yml` run on siem reports `changed=0`. `/etc/apt/sources.list.d/` shows only the Wazuh repository with a `signed-by` key whose fingerprint matches the one in the role. No `wazuh-install-files.tar` exists on the host.

## 87. siem's size (2026-11-04)

**Problem.** Wazuh recommends 4 vCPU and 8 GB of RAM for an all-in-one with up to 25 agents, and the indexer's Java heap at half the RAM. ARCHITECTURE planned a t3.medium (2 vCPU, 4 GB), with a t3.large if the indexer struggles. A new t3 with `standard` credits also starts with none, so it runs at its 20 % baseline until it earns some, as fw-ips showed on 2026-11-04.

**Options.** A: t3.medium with a 1.5 GB heap, measured, with t3.large as the fallback. B: t3.large from the start. C: a non-burstable type.

**Chosen: A.** Six lab agents produce a few events per second. The heap leaves about 2.5 GB for the manager, Filebeat, the dashboard (Node.js) and the OS. If the indexer runs out of heap or the dashboard is too slow, the fallback is one variable. It costs about $0.05/hour instead of $0.10. The first install gets long timeouts instead of a larger instance, because the slowness is the credit start, not lack of capacity. C costs more and breaks the t3 `standard` guardrail.

**Trade-off accepted.** Less headroom: a Phase 2 run that floods events could push the indexer to its limit, and that is itself a measurement. The first boot of each session is slow.

**Verify once built.** `GET _nodes/stats/jvm` shows a 1.5 GB heap, and the cluster health is green. `free -m` keeps available memory above about 300 MB during a test burst. The Alertmanager rule from 1.23 watches the credit balance.

## 88. Where Wazuh's data lives (2026-11-04)

**Problem.** Every host is destroyed at the end of each session (decision 41), siem included, so the indexer's alerts would be lost each time. Comparing one session's findings with the next, which is the point of Phase 2, needs them to persist.

**Options.** A: a separate encrypted EBS volume in `persistent`, attached to each session's siem host by `lab` and mounted at the indexer's data path. B: no persistence, with a script exporting alerts to the laptop before each teardown. C: accept the loss.

**Chosen: A.** A 20 GB gp3 volume costs about $1.90 a month and keeps the indexer's data, with its search and dashboards, across sessions. It must be in the same Availability Zone as the mgmt subnet, and `lab` owns only the attachment, so `hosts_enabled=false` detaches it without deleting it. The end-of-session routine stops the indexer before the apply, so its data is flushed cleanly. B loses search and adds a step every session. C makes the SIEM forget everything nightly.

**Trade-off accepted.** A small permanent cost, and a resource that must never be destroyed by mistake (`prevent_destroy` in `persistent`). An unclean detach could need the indexer's recovery on the next start. Raw host logs (`eve.json`, kernel logs) still go with their hosts, unless the remaining open item decides otherwise.

**Verify once built.** After a teardown and a new session, an alert from the previous session is still searchable. `terraform plan -var hosts_enabled=false` shows the attachment, not the volume, being destroyed. `lsblk` on siem shows the volume mounted at the indexer's data path.

## 89. Wazuh's certificates and passwords (2026-11-04)

**Problem.** The indexer, manager, Filebeat and dashboard authenticate each other with certificates from `wazuh-certs-tool`, and the indexer and API have internal users with passwords. Where they're made and kept decides whether they leak and whether they change every session.

**Options.** A: passwords generated by `persistent` into write-only SSM values under `/siem/`, and certificates made once on the laptop and stored by hand under `/siem/`; siem's role reads `/siem/*` only. B: generate everything on the host at each build. C: put them in Ansible Vault in the repo.

**Chosen: A.** It's the pattern the lab already uses: write-only values keep passwords out of Terraform state (decisions 46, 55), hand-stored parameters keep keys out of state (`/vpn/*`, decision 39), and a narrow grant limits who can read them (decision 22). The certificates stay the same across sessions, so the browser trusts Wazuh's CA once and the agents' view of the manager doesn't change. Each PEM file fits a standard SSM parameter (4 KB). B changes the dashboard certificate and passwords every session and leaves them on the host's disk. C puts encrypted secrets in a public repo.

**Trade-off accepted.** Making the certificates is a manual laptop step, like signing VPN certificates. Their expiry must be tracked, and renewing them is a documented procedure.

**Verify once built.** The IAM simulator allows siem's role `ssm:GetParameter` on `/siem/*` and denies `/mailbridge/*` and `/vpn/*`. Terraform state contains no Wazuh password. `grep -r` of the `-v` Ansible log finds no password value. The dashboard's certificate fingerprint is the same in two sessions.

## 90. Where the Wazuh CA key lives (2026-11-05)

**Problem.** Decision 89 put "the Wazuh certificates and keys" under `/siem/`, and siem's instance role reads `/siem/*`. `wazuh-certs-tool` makes ten files, one of them the root CA's private key. Every Wazuh component trusts anything that key signs: the indexer accepts any certificate whose subject is `CN=admin` as its security administrator. Read literally, decision 89 hands the signing key to the host most likely to be targeted once an attacker is inside, since disabling the SIEM is how attackers hide.

**Options.** A: encrypt the CA key with a passphrase and back it up to `/wazuh-ca/key`, outside any instance role's grant; siem gets only the CA certificate and the certificates and keys it presents, under `/siem/certs/*`. B: store the CA key under `/siem/` as decision 89 reads. C: keep the CA key only on the laptop, with no backup.

**Chosen: A.** It's the VPN's offline-CA split (decision 39): fw-ips holds its own certificate and key, never the CA key, and the encrypted backup sits under a path no instance role can read. The IAM simulator shows siem allowed on `/siem/certs/*` and `implicitDeny` on `/wazuh-ca/key`. `parameter/siem/*` can't match `/wazuh-ca/key`, because the wildcard follows the literal `siem/`. The passphrase stays off AWS, so a leaked admin credential or a copy of the SSM value alone can't sign anything. B saves nothing and gives a compromised SIEM a way to sign trusted certificates. C fails if the laptop is lost: every certificate would have to be reissued and the browser would have to trust a new CA, which breaks decision 89's "same certificate every session" goal.

Wazuh's default node names are kept so the role can follow the install guide line for line. All three nodes share the one IP, so each certificate's SAN is `IP:10.0.5.10` and the dashboard is opened at `https://10.0.5.10`. Wazuh publishes no checksum or signature for the tool. It was read before running (bash around `openssl`, no network calls while generating), and its SHA-256 is recorded in `siem-certs/README.md`. Keys are written to a temporary folder inside the laptop PKI folder (`-tmp`), never to `/tmp`.

**Trade-off accepted.** The admin certificate and key are on siem, because `securityadmin` runs there. A compromised siem could rewrite the indexer's users. That's no worse than what root on siem already has, since the indexer runs there. The certificates last ten years (the tool's fixed `-days 3650`), far longer than public practice. It's a private CA with one client, and rotation is a documented, tested procedure instead of a calendar event. While re-signing, the tool copies the CA key into its output in plaintext, so the procedure shreds it.

**Verify.** `openssl verify -CAfile root-ca.pem` gives OK for all four certificates. Each certificate's public key matches its key. Each SSM value's SHA-256 equals the laptop file's, read with `jq -j` because `--output text` adds a newline. The simulator allows siem's role on `/siem/certs/admin-key` and `/siem/certs/indexer-key` and gives `implicitDeny` on `/wazuh-ca/key`, `/vpn/ca/key` and `/mailbridge/db-password`. After the role is built: the indexer's `admin_dn` is `CN=admin,OU=Wazuh,O=Wazuh,L=California,C=US`, and the dashboard's certificate fingerprint is the same in two sessions.

## 91. Trusting Wazuh's apt repository (2026-11-05)

**Problem.** Wazuh ships its packages from its own repository. Whatever a repository's key signs, apt installs as root. Ubuntu's repositories already supply most packages on siem, and a third-party repository that published `openssl` or `curl` with a higher version would replace them on the next upgrade.

**Options.** A: pin the key by the SHA-256 of its file, limit the repository to Wazuh's four packages with an apt preference, and install each at a pinned version with a hold. B: the guide's way, which imports the key with `gpg` into a keyring and adds the repository with no limits. C: download the four `.deb` files and pin each by SHA-256, like lego.

**Chosen: A.** The key check follows the same pin-and-verify pattern as lego and the CRS. If Wazuh replaces or extends its key, the run fails, and the new fingerprint is checked in a PR. The preference (`Pin-Priority: -1` for `origin packages.wazuh.com`, 500 for the four names) means apt can never take another package from that origin. The hold keeps a routine `apt upgrade` from moving the version under the measurements (decision 85). C needs no repository at all, but the indexer `.deb` is close to a gigabyte, its dependencies would have to be resolved by hand, and apt already verifies each package against the signed index.

**Trade-off accepted.** The key expires on 2027-05-15. Before then, Wazuh publishes an extended key, and the pinned hash has to be updated in a PR. Security fixes in Wazuh arrive only through a version bump PR, never automatically.

**Verify.** `apt-mark showhold` lists `wazuh-indexer`. `apt-cache policy` shows the Wazuh origin at priority -1 for any package outside the four.

## 92. Finding and protecting the Wazuh data volume (2026-11-05)

**Problem.** The data volume from `persistent` is attached as `/dev/sdf`, but on Nitro instances it shows up as an NVMe disk whose number depends on probe order. The first session must format it. Every later session must never format it again, and must never start the indexer without it.

**Options.** A: look up the volume ID by its tag from the laptop and use the `by-id` link that names that ID; format only when `blkid -p` finds nothing; mount through fstab with `ansible.posix.mount`; add `RequiresMountsFor` to the indexer. B: assume `/dev/nvme1n1`. C: a hand-written systemd mount unit and the `community.general.filesystem` module.

**Chosen: A.** The ID is the only stable name, and the run first asserts that exactly one volume with that tag is attached to this instance. `blkid -p` probes the raw disk and exits 2 only when there is no filesystem and no partition table. Any other result means the volume has history, so it's mounted, never formatted. `RequiresMountsFor` makes the indexer depend on the mount. Without it, a failed mount would leave an empty directory on the root disk, and the indexer would start a new, empty cluster there, which would look like lost data. B would format whichever disk enumerates second. C adds a large collection for one task, and its module formats on a `force` flag rather than on a probe we can read; `ansible.posix` (pinned in `requirements.yml`) is small and already on the laptop.

**Trade-off accepted.** `nofail` lets the host boot if the volume is missing, so a missing volume shows up as a stopped indexer, not as an unreachable host.

**Verify.** On the first session, the format task changes and `df` shows the 20 GB volume. On the next session, the format task is skipped and a search from the previous session still returns its documents. `systemctl show wazuh-indexer -p RequiresMountsFor` includes `/var/lib/wazuh-indexer`.

## 93. Where the indexer listens (2026-11-05)

**Problem.** The package's `opensearch.yml` sets `network.host: "0.0.0.0"`, so the REST port 9200 and the node-to-node port 9300 listen on every interface.

**Options.** A: bind to 10.0.5.10, the address in the indexer's certificate. B: keep `0.0.0.0` and rely on sg-siem. C: bind to loopback.

**Chosen: A.** Filebeat and the dashboard run on the same host, but they verify the indexer's certificate, which names 10.0.5.10, so loopback (C) would fail TLS verification unless the certificates were reissued. B leaves one control where two are cheap: sg-siem already refuses 9200 and 9300 from everything, and the bind makes the host agree. Everything else in the file is the package's text, so a version bump shows a clean diff. The heap goes in `jvm.options.d/heap.options`, which OpenSearch reads after `jvm.options`, so the package's file stays untouched.

**Trade-off accepted.** A process on siem reaches 9200 at 10.0.5.10, not at localhost. That's only a naming detail.

**Verify.** `ss -ltn` shows 9200 and 9300 on `10.0.5.10` only. `_cat/nodes?h=heap.max` shows `1.5gb`.

## 94. The indexer's internal users (2026-11-05)

**Problem.** The package's `internal_users.yml` defines seven users: `admin` and `kibanaserver` with demo passwords, and five demo accounts (`anomalyadmin`, `kibanaro`, `logstash`, `readall`, `snapshotrestore`) with passwords that are public. The guide changes passwords afterwards with `wazuh-passwords-tool`, which puts them in its output and leaves the demo accounts in place. The security index lives on the persistent volume, so the users must stay right across sessions without being re-applied blindly.

**Options.** A: a helper that tests both logins and the user list, and only if they differ writes a two-user file with fresh bcrypt hashes and runs `securityadmin`. B: template `internal_users.yml` in Ansible and run `securityadmin` when it changes. C: Wazuh's password tool.

**Chosen: A.** It's the `set-db-password` pattern (decision 52). The passwords stay in shell variables: `curl -K -` takes the credentials on stdin, and Python's `bcrypt` reads the password on stdin, so nothing appears in argv, a file other than the hash file, or Ansible output. The test login is the idempotence check, so no hash has to be stored for comparison. B can't be idempotent, because bcrypt salts every hash, so the template would change on every run. And the hashes would pass through Ansible. C leaves the demo accounts and prints the passwords. `securityadmin` runs as `wazuh-indexer` with the bundled JDK and `-icl -nhnv`, exactly like the package's `indexer-security-init.sh`, and it authenticates with the admin certificate, never a password.

**Trade-off accepted.** Each apply uploads every file in `opensearch-security/`, so a change made in the dashboard's security UI is overwritten the next time a password changes. Code is the source of truth. The `own_index` mapping (any user owns an index named after itself) is left at the default, because only two users exist.

**Verify.** The user list, read with the admin certificate, is `['admin', 'kibanaserver']`. Every demo user and `admin:admin` get 401. `set-indexer-users check` prints `unchanged`. `securityadmin.log` ends in `Done with success` and contains no hash.

## 95. The manager's credentials (2026-11-05)

**Problem.** Three components need secrets after the manager is installed. Filebeat logs in to the indexer from its own keystore. The manager's indexer connector logs in from Wazuh's keystore. The API ships two users, `wazuh` and `wazuh-wui`, whose passwords are their own names. All three must come from SSM, stay out of argv and logs, and survive a run that changes nothing.

**Options.** A: one helper on the host that checks each with the cheapest real test and changes only what fails. B: Ansible tasks with `no_log`, rewriting the keystores on every run. C: Wazuh's `wazuh-passwords-tool`.

**Chosen: A.** Filebeat's check is `filebeat test output`, which logs in with the keystore's values, so the check is the real thing. The API's check is a login with the SSM password. If it fails, the helper logs in with the shipped default, finds the user's ID and sets the password. The JSON body is built from stdin, and the token goes in through a process-substitution header, so it never appears on a command line. Wazuh's keystore is write-only and offers no check, so the helper keeps a SHA-256 of `admin:<password>` in a root-only file and rewrites the keystore only when the SSM value changes. The password is 40 random letters and digits, about 238 bits, so the hash can't be reversed. B would show `changed` on every run, so drift would be invisible, and `no_log` hides errors along with the values. C prints the new passwords.

**Trade-off accepted.** Filebeat and the connector both use the indexer's `admin` user (decision 94). A Filebeat user that can only write to `wazuh-alerts-*` is better least privilege, but root on siem already controls the indexer. It's a Tier 2 hardening item.

**Verify.** `set-manager-credentials check` prints `unchanged`. `wazuh:wazuh` and `wazuh-wui:wazuh-wui` get 401 from the API. `filebeat test output` shows `talk to server... OK` over TLS 1.3. The manager's log shows `IndexerConnector initialized successfully`.

## 96. Wazuh's vulnerability detection is off in Tier 1 (2026-11-05)

**Problem.** The manager ships with vulnerability detection on. It inventories each agent's packages and matches them against Wazuh's CVE feed. At siem's first start the feed (a 436 MB `.tar.xz`) unpacked to a 9.3 GB tar plus 2.8 GB of partly extracted data, and the 20 GB root disk filled up (`No space left on device`). siem is rebuilt every session, so this would happen at every session start.

**Options.** A: turn it off for Tier 1. B: keep it and grow the root disk to about 40 GB. C: keep it and move `/var/ossec/queue/vd` onto the persistent volume, grown to about 30 GB, so the feed downloads once.

**Chosen: A.** Nothing in ARCHITECTURE or TASKS uses it. It was on only because it's the package default. It measures **posture** (known-vulnerable packages), while the lab measures **detection** of attacks across nftables, Suricata, ModSecurity and Wazuh. It isn't T3.2 either: T3.2 is network scanning from outside (Nuclei, Greenbone), while this is agent-based and looks from inside. B makes every session download and unpack about 14 GB on a host with no CPU credits, right when the indexer is starting (decision 87's risk). C is the right design if posture becomes a goal, but it's complexity built ahead of need.

**Trade-off accepted.** There's no CVE view of the lab hosts. If a Tier 2 finding needs one, C is how to turn it on: a bind mount for `queue/vd` on the data volume, owned by `wazuh`, and a bigger volume in `persistent`.

**Verify.** The manager's log shows `Vulnerability scanner module is disabled.` No `vd_*` files appear in `/var/ossec/tmp`. The root disk stays at about 6 GB used after a fresh build.

## 97. Manager addresses, the API, enrollment and start order (2026-11-05)

**Problem.** The package's `ossec.conf` sends the indexer connector to `https://0.0.0.0:9200`. Its API listens on 55000 on every interface. Its authd accepts agent enrollment on 1515 with `use_password no`. The first build also showed two ordering faults: the manager was started and immediately restarted by the config handlers, and Filebeat started before its keystore existed.

**Options.** For each default, change it now or leave it for 1.17. For the order, add retries, or order the tasks so each service starts once, after its inputs exist.

**Chosen.** The connector and Filebeat point at 10.0.5.10, the name in the indexer's certificate (decision 93). The API listens on 127.0.0.1, because only the dashboard on this host uses it and sg-siem never opens 55000. authd is off: with it on and no password, any host in the VPC could enroll as an agent and feed the SIEM false events. 1.17 designs enrollment and its password. The handlers are flushed before the manager's start task, so on a fresh host the handler's restart is its first start. The helper retries while the API warms up. Filebeat starts after the helper has written its keystore. The double start had left an API process holding 55000 that survived `systemctl stop wazuh-manager`, so every later API failed with `address already in use`, and the pool broke ("child processes terminated abruptly"). It was cleared by killing that process by its exact path.

**Trade-off accepted.** Until 1.17, nothing can enroll, which is intended. The stale-process fault was cleared by hand, and the new order is proven only on the next fresh siem.

**Verify.** `ss -ltn` shows 1514 on all interfaces, 55000 on 127.0.0.1, and no 1515. On a fresh siem the first run needs no hand fix, and `pgrep -fc wazuh_apid.py` matches the API's normal pool (5 processes). `systemctl is-active filebeat` shows `active` on the first run.

## 98. The Wazuh dashboard (2026-11-05)

**Problem.** The dashboard (OpenSearch Dashboards with the Wazuh plugin) is the only Wazuh component a person uses. The package listens on `0.0.0.0:443` and accepts TLS 1.2. It reaches the indexer at `localhost:9200`, which no longer exists after decision 93. It checks only the indexer certificate's chain, and it ships with the default `kibanaserver` password in its keystore. The plugin creates `wazuh.yml` with the API user `wazuh-wui` and its default password.

**Options.** A: bind 10.0.5.10, TLS 1.3 only, `verificationMode: full`, and a helper that sets both credentials before the first start. B: keep the package's network and TLS settings and change only the passwords. C: put the dashboard behind Nginx on proxy.

**Chosen: A.** It's the same edge policy as proxy and the VPN (decision 61): only the admin's browsers connect, over the VPN, so TLS 1.2 adds attack surface for no client. `full` verification is free, because the indexer's certificate names 10.0.5.10 (decision 90). The helper follows decisions 94 and 95. `kibanaserver` goes into the keystore on stdin, checked against a root-only SHA-256 because the keystore can't be read back. It runs before the first start, so the dashboard never logs in with the shipped password. The plugin reads the API password only from `wazuh.yml`, in plain text. The helper writes that file `0600`, owned by `wazuh-dashboard`, and the API it unlocks listens on loopback only (decision 97). C would put SIEM traffic through the DMZ host that the Juice Shop attacks target, and add a hop to the one tool used to watch them.

**Trade-off accepted.** The `wazuh-wui` password is on disk in plain text, readable by the dashboard user and root. The dashboard's login uses the indexer's `admin` user, so the person at the dashboard has full indexer rights. A read-mostly analyst user is a Tier 2 item.

**Mistake caught while building.** The helper's first version made the config directory with `install -d`, which also created the missing parent `data/wazuh` owned by root. The dashboard then couldn't create `data/wazuh/downloads` and restarted 17 times (`EACCES`). Each level is now created as `wazuh-dashboard`.

**Verify.** From the admin pool, `curl --cacert root-ca.pem https://10.0.5.10/` returns 302 to `/app/login`, and `openssl s_client` reports `Verify return code: 0`. `-tls1_2` gets `alert protocol version`. A login as `admin` with the SSM password gets 200, and `admin:admin` gets 401. The plugin's `/api/check-stored-api` returns 200 as `wazuh-wui`. `set-dashboard-credentials check` prints `unchanged`. `ss -ltn` shows 443 on 10.0.5.10 only.

## 99. siem on a t3.large (2026-11-05)

**Problem.** Decision 87 started siem as a t3.medium (2 vCPU, 4 GB) with a 1.5 GB heap, and named the t3.large as the fallback "if the indexer struggles". After 1.16 was built, it was measured. The CPU credit balance stayed at 2.6–8 for the whole session, with average use up to 38 %. A `standard` t3 with no credits is held at its baseline, 20 % for a t3.medium, which is why every siem run was slow. 819 MB of 3.8 GB was available, with the indexer's Java at 1.97 GB and no agents connected yet. There's no swap. If memory runs out, the kernel kills the largest process, which is the indexer.

**Options.** A: t3.large (2 vCPU, 8 GB, 30 % baseline, 36 credits an hour) with a 3 GB heap. B: stay on the t3.medium until 1.17 shows a failure. C: `unlimited` credits on the t3.medium.

**Chosen: A.** 1.17 adds five agents and the §8 log sources. The Juice Shop block then pushes Suricata's `eve.json` and the ModSecurity audit log at attack rate. Those are the moments the SIEM exists for, and the worst time to lose the indexer. 8 GB is Wazuh's own all-in-one recommendation. A 3 GB heap stays under OpenSearch's "at most half of RAM" rule and leaves about 5 GB for Lucene's page cache, the manager and the dashboard. B waits for a failure during exactly the measurement the lab is for. C breaks the cost guardrail in CLAUDE.md (`standard` credits), and its cost has no upper limit.

**Trade-off accepted.** About $0.048 an hour more, roughly $0.19 for a four-hour session. A new instance still starts with no credits, so its first install is still slow (decision 87).

**Verify.** `terraform plan` shows siem updated in place, `instance_type` t3.medium → t3.large, nothing replaced. After the apply siem keeps its private IP and the data volume stays attached, and all three Wazuh services come back by themselves. `_cat/nodes?h=heap.max` shows `3gb`, and the cluster is green. `free -m` shows about 8 GB total.

## 100. How Wazuh agents enroll (2026-11-05)

**Problem.** A Wazuh agent talks to the manager in two steps. First it **enrolls** with authd on TCP 1515, over TLS, and receives its own key. From then on it sends events on TCP 1514, encrypted with that key. Anything that can enroll can send the SIEM events under any name it chooses: it can flood it, impersonate a host, or bury a real attack in noise. The package's authd accepts anyone who reaches 1515, so decision 97 turned it off until this decision.

**Options.** A: authd with a password from SSM; siem reads it, and each agent host reads that one parameter with its own instance role. B: A plus agent certificates signed by the Wazuh CA (authd's `ssl_agent_ca`), so enrollment also needs a valid client certificate. C: no authd; Ansible registers each agent through the API and writes the agent's `client.keys`.

**Chosen: A.** It's the lab's secret pattern. `persistent` generates the value write-only (decision 46), and hosts pull their own secrets with their instance roles (decisions 39, 47), so the value never passes through the laptop, Ansible's output or Terraform state. Each agent host's grant names one ARN. The IAM simulator should show `/siem/agent-enrollment-password` allowed and `/siem/indexer-admin-password` denied for fw-ips, db, app and proxy. The network already narrows who can reach 1515: sg-siem and the mgmt NACL accept it only from the VPC (§4). B is stronger, because a leaked password alone wouldn't be enough, but it adds a certificate per host to make, store and rotate. That belongs to Tier 2 hardening. C moves every agent key through the laptop and Ansible, which the lab avoids everywhere else.

**Trade-off accepted.** Root on any agent host can read the password and enroll a fake agent from inside the VPC. In Tier 1 that's accepted, because root on a lab host is already a compromise the SIEM should show. A Phase 2 scenario can test exactly that: does a second agent enrolling from db raise an alert?

**Verify.** `terraform plan` for `persistent` shows 1 to add and for `lab` 4 to add (one inline policy per agent host). The IAM simulator allows each agent role on the enrollment password and denies it every other `/siem/` value. After 1.17's role is built, authd on siem refuses an enrollment without the password (`Invalid password`), and the four agents show `active`.

## 101. The Wazuh agent role (2026-11-05)

**Problem.** Four hosts (fw-ips, db, app, proxy) need the same agent, connected to the same manager, each collecting its own logs. The agent enrolls the moment it starts, so it needs a running manager with authd. The package's installer also writes `localfile` entries for software it finds: on proxy it added Nginx's logs in Apache format, and on the other hosts it added nothing.

**Options.** A: one shared `wazuh_agent` role in a final play, with shared pins in `group_vars/all` and each host's log list in `group_vars`. B: add the agent tasks to each host's role. C: Wazuh's Ansible collection.

**Chosen: A.** The final play runs after siem's, so the manager and authd exist when the agents start. One role means one place to review the agent. `group_vars/all/wazuh.yml` holds `wazuh_version`, the key hash and the manager's address, used by both roles, so an agent can never be newer than its manager (Wazuh's compatibility rule). The agent hosts' apt preference admits only `wazuh-agent`, so a compromised or mistaken run on db can't pull in the manager or the indexer. The template is the package's generic `ossec.conf` (db's, which had nothing detected) with three changes: the manager address, an `<enrollment>` block (agent name `fw-ips`, `db`, `app` or `proxy`, and `etc/authd.pass`), and the host's `wazuh_agent_localfiles`. Collection is then an explicit, reviewed list per host, and it doesn't depend on what happened to be installed when the agent was. B would repeat the same tasks in four roles. C is a large generic collection, the same reason decision 86 gave for the manager.

**Trade-off accepted.** Until 1.17 PR 2 fills in the lists, proxy collects less than the installer would have given it (no Nginx logs). PR 2 adds them back in the formats the decoders expect.

**Verify.** All four agents show `active` in `agent_control -l` on siem, under their short names. `apt-cache policy wazuh-manager` on an agent host shows no candidate. Agents and manager both report version 4.14.9. A second run reports `changed=0`.

## 102. Ansible's connection timeout (2026-11-06)

**Problem.** The session's first `site.yml` stopped on fw-ips with `Timeout (12s) waiting for privilege escalation prompt` and `UNREACHABLE`, twice, at different tasks (once at the sshd restart handler, once at a plain file copy). Ad-hoc `become` commands failed the same way minutes later, then ten in a row succeeded in about 2 s each. fw-ips's journal settled where the time went: at 19:15:22 the `sudo` from a failed command opened and closed within 2 ms, yet Ansible waited 12 s for its reply and gave up. Plain `ssh … sudo -n true` through the same SSM proxy took 2.5–3.7 s. The laptop was on a phone hotspot, and every Ansible task crosses SSH, the SSM WebSocket, AWS's SSM endpoint and the agent on the host; a stall longer than the timeout anywhere on that path looks like a dead host.

**Options.** A: `timeout = 60` in `ansible.cfg` `[defaults]`, which is both the SSH connect timeout and the wait for `sudo`'s answer. B: `retries = 3` in `[ssh_connection]`, which retries failed connections but not a `become` wait on a channel that is already open, so not this failure. C: change nothing and export `ANSIBLE_TIMEOUT=60` by hand on a bad network.

**Chosen: A.** It fixes the measured cause, the wait, in code that every run uses. A timeout only costs time when something is slow, so on a good network nothing changes. C depends on remembering it, and B adds a mechanism that wouldn't have helped.

**Trade-off accepted.** A host that is really down, or an SSM session that never opens, is reported after 60 s instead of 12 s. A run that hangs on a slow host waits longer before failing, which is minor next to a full first run of about 17 minutes.

**Verify.** From `ansible/`, `ansible-config dump --only-changed | grep TIMEOUT` prints `DEFAULT_TIMEOUT(…/ansible.cfg) = 60`. A full `site.yml` on the hotspot finishes without `UNREACHABLE` (the 2026-11-06 run used the same value through `ANSIBLE_TIMEOUT`).

## 103. fw-ips's kernel settings without a handler (2026-11-06)

**Problem.** The `fw_ips` role copied `/etc/sysctl.d/99-fw-ips.conf` and notified a handler that ran `sysctl --load`. In the session's first run, the copy succeeded, and the `flush_handlers` that followed ran the common role's sshd restart first. That one hit the connection timeout (decision 102), Ansible marked fw-ips unreachable, and the handlers still pending were dropped. The next runs saw the file already correct, reported `ok`, notified nothing, and the kernel kept `net.ipv4.ip_forward = 0`. fw-ips's own play then finished green (`changed=26`, `failed=0`), while db, app, proxy and siem stayed unregistered in SSM, because their traffic to the internet arrived at fw-ips and was never forwarded. db's `wait_for_connection` failed after 600 s. `tcpdump` on fw-ips showed their SYNs to port 443 arriving and nothing leaving. A handler is "do this once, if something changed", and that memory lives only in the running playbook.

**Options.** A: `ansible.posix.sysctl` for each key with `sysctl_set: true`, which reads the live value with `sysctl -n` on every run, sets it with `sysctl -w` if it differs, and keeps the line in `99-fw-ips.conf` for boot. B: keep the copy and handler, and add a task that compares the live values with the file and loads it when they differ. C: `force_handlers = True`, which runs pending handlers after a failed task.

**Chosen: A.** It turns the setting into desired state that's checked every run, rather than an event that has to be remembered. It's one module from a collection the lab already pins. B does the same in two tasks of our own. C doesn't cover this case: it helps when a task *fails*, but an *unreachable* host can't run anything, so its handlers are lost anyway.

**Trade-off accepted.** The file is now written by the module, so its explanations move into the task's comments. On a fresh host the module creates the file with the four keys and no comments. The same handler weakness still exists elsewhere (for example a reload after a config change), but there the next run's service checks or failing tests make the drift visible. Here the play was green while the host didn't route.

**Verify.** `site.yml --limit fw_ips` twice: the second run reports `changed=0`. Then `sysctl -w net.ipv4.ip_forward=0` by hand, and run again: the task reports `changed` for `ip_forward` only, and `sysctl net.ipv4.ip_forward` prints `1` again. `/etc/sysctl.d/99-fw-ips.conf` holds the four keys. Verified 2026-11-06 on the session's fw-ips: two runs `changed=0` (the module reads the old file's `key = value` lines as equal); after `sysctl -w net.ipv4.ip_forward=0`, the next run reported `changed` for `ip_forward` only, and the kernel was back at `1`.

## 104. Pinning Wazuh's packages by version (2026-11-06)

**Problem.** The session's first siem run failed at `Install the indexer at the pinned version` with `no available installation candidate for wazuh-indexer=4.14.9-1`. The version was there: `apt-cache policy` listed `4.14.9-1` next to `4.14.10-1`, which Wazuh had published that afternoon, and `apt-get install -s wazuh-indexer=4.14.9-1` worked. The `apt` module, run on its own in check mode, failed the same way. The cause is how apt chooses a candidate. Decision 91's file gave the four packages priority 500 *by origin*, so the candidate was the newest version from Wazuh. For `name=version`, the module adds a temporary pin for that version, but apt uses only the *first* specific record that matches a package version, and the file's record came first. The candidate stayed 4.14.10, and the module refused to install anything else. `apt-get` with `=version` on its command line overrides pinning, which is why it worked. Until 4.14.10 existed, the newest version and our version were the same, so nothing showed.

**Options.** A: pin by version: `Pin: version 4.14.9-1` for the three Wazuh packages and `Pin: version 7.10.2-2` for filebeat, priority 500, and keep the general `Package: *` origin record at -1, templated from the role's version variables. B: install with `apt-get install pkg=version` in a `command` task. C: bump to 4.14.10.

**Chosen: A.** apt takes a version's priority from the first specific record that matches it, else from the general record. With A, 4.14.9-1 matches 500, 4.14.10-1 matches only the general record and gets -1, and any other package from Wazuh's origin gets -1 as before. The candidate is exactly the reviewed version, so the module installs it and nothing can move it, even without the hold. That's decision 91's intent ("only the packages we chose, at the version we reviewed") written the way apt evaluates it. The version stays in one variable, so a bump is still one reviewed PR. B gives up the module's idempotency and check mode. C only postpones the failure to the next release and skips the review a version change needs.

**Trade-off accepted.** A version bump now changes the pin file too (through the template), so the first run after a bump rewrites it. That's correct, because the bump is the reviewed change.

**Verify.** On siem, `apt-cache policy wazuh-indexer` shows `Candidate: 4.14.9-1`, with `4.14.9-1` at 500 and `4.14.10-1` at -1. `apt-cache policy curl` shows no Wazuh entry above -1. `site.yml --limit siem` installs all four packages, and a second run reports `changed=0`.

## 105. Which logs the Wazuh agents read (2026-11-06)

**Problem.** After PR 1b, every agent read only the package defaults: journald, `active-responses.log` and `dpkg.log`. §8 lists the sources the Juice Shop block and the scenarios depend on: Suricata's EVE output, the nftables drops, Nginx's access and error logs, the ModSecurity audit log, auth logs, OpenVPN connects and disconnects, and file integrity monitoring. Each one has to be collected in a format Wazuh can decode, without collecting the same event twice.

**Options.** A: an explicit list per group in `group_vars/<group>/wazuh_agent.yml`, rendered by the role's `wazuh_agent_localfiles` loop, with journald covering the kernel and unit logs. B: also read the classic text logs (`/var/log/syslog`, `auth.log`, `kern.log`). C: let the agent's installer detect the software and add its own blocks.

**Chosen: A.** fw-ips gets `/var/log/suricata/eve.json` as `json`. proxy gets `/var/log/nginx/access.log` and `error.log` as `syslog`, which is how Wazuh's Nginx guide reads the combined format, and `/var/log/modsecurity/audit.log` as `json`, because decision 66's Serial JSON writes one transaction per line. The nftables `log prefix` lines go to the kernel log, OpenVPN logs to its unit, and sshd and sudo log to the journal, so journald already carries them, decoded by the same decoders the text files would use. B would send every kernel, auth and unit event twice, doubling alerts and the indexer's disk use. C is what decision 101 rejected: unreviewed, different per host, and Nginx in Apache format.

**Trade-off accepted.** Collection isn't detection. A source can arrive and decode cleanly but match only a level-0 grouping rule, so it's never stored as an alert. The nftables drops are like that (rule 4100, because Wazuh's child rules match the action `DROP` exactly and ours are `FW-DROP`, `FW-EGRESS` and `FW-INPUT-DROP`), so are OpenVPN disconnects (81800), and the JSON audit log has no built-in rule; ModSecurity's blocks are still alerted from Nginx's error log (31333). Those are PR 3's custom rules, kept separate so each rule is reviewed against a test event.

**Verify.** On fw-ips and proxy, `ossec.log` shows `Analyzing file:` for each new path, and `wazuh-logcollector` runs as root (the audit log is `0600 root`). Test events from the admin pool on 2026-11-06: a plain-HTTP request to proxy:443 gave rule 86601 from `eve.json` (our Suricata rule 1000005) and 31101 from `access.log`; an SQL injection in the query string gave a 403 with 31164 from `access.log` and 31333 (`ModSecurity rejected a query`) from `error.log`; sudo and PAM sessions gave 5402, 5501 and 5502 from journald. A drop from the admin pool to 10.0.2.10:8080 logged `FW-DROP`, and `wazuh-logtest` decodes it (`action: FW-DROP`, source and destination address and port) but stops at rule 4100, level 0: PR 3. OpenVPN through journald: a VPN reconnect gave 81801 (`OpenVPN: User logged in`), and an internet scanner rejected by tls-crypt gave 81803 (`Connection Certificate Failed`, MITRE T1133). Disconnects have no built-in rule: the client's `Ctrl+C` is a hard `SIGINT` that sends no exit notice, so the server logged only `MULTI: new connection … previous active sessions … dropped` at the reconnect, and that line, a clean `SIGTERM[soft,remote-exit] … client-instance exiting` and an `Inactivity timeout (--ping-restart)` all stop at 81800, level 0 in `wazuh-logtest`: PR 3.

## 106. The lab's own Wazuh rules (2026-11-06)

**Problem.** PR 2 (decision 105) proved that every §8 source reaches the manager and decodes, but three kinds of event never became alerts. The nftables lines decode fully (`action`, addresses, ports, protocol) yet stop at rule 4100, level 0, because Wazuh's child rules match the action `DROP` exactly and ours are `FW-DROP`, `FW-INPUT-DROP` and `FW-EGRESS`. OpenVPN's three session-end lines stop at the grouping rule 81800. The ModSecurity audit JSON decodes into every field but lands on the generic 1002 ("Unknown problem", level 2), only because its text contains the word "Attack". Wazuh stores alerts from level 3 up, so none of these was searchable.

**Options.** A: one rule file of our own, each rule a child (`if_sid`) of the built-in parent that already decodes the event, IDs in Wazuh's local range. B: new decoders and rules for our prefixes and the audit log from scratch. C: change the sources instead: an nftables prefix of plain `DROP`, so the built-in 4101 fires, and Wazuh's log-all archive for the rest.

**Chosen: A.** The parsing already works, so a child rule only adds the decision "this is worth an alert" and a readable description built from the decoded fields (`$(srcip) to $(dstip):$(dstport)`, `$(transaction.request.uri)`). Children inherit the parent's groups, so dashboards and later rules find them the same way as Wazuh's own. 100103 is a frequency rule over the `firewall_drop` group: 10 drops from one address in 60 s. nftables logs at most 10 drops a second (§4), so that count is never background noise, and it maps to MITRE T1046. Egress (100102) is stored at level 3 because an SSRF or a reverse shell to an allowed 443 destination would show up nowhere else. B duplicates parsing that works. C gives up our prefixes, which tell three different chains apart at a glance, and the archive stores every event without deciding which ones matter.

**Trade-off accepted.** Egress alerts are frequent (each private host's SSM agent and updates), a few thousand a day, on an indexer sized for it (decision 99). A single drop is level 5 and a burst is level 10, so a real scan stands out. Our descriptions depend on Wazuh's field names, which a Wazuh upgrade could change, and an upgrade PR has to re-run the logtest below.

**Verify.** `wazuh-logtest` on siem with a real line of each kind returns 100100, 100101, 100102, 100110, 100111, 100112 and 100201, with the decoded fields in each description. An unrelated OpenVPN line (`primary virtual IP`) still gets 81800, so the matches aren't too broad. Live on 2026-11-06 from the admin pool: an XSS request got a 403 and alert 100201 from the audit log (method, URI and client), next to the built-in 31333 and 31105; a connect attempt to 12 blocked ports on proxy gave 11 × 100100 and one 100103 (level 10) in the indexer. The manager restarted cleanly with the file, and the next two siem runs reported `changed=0`.

## 107. Exporting raw evidence before teardown (2026-11-06)

**Problem.** Every host except siem's data volume is destroyed at teardown, and with it every raw log. Wazuh keeps the alerts (decision 88), but only events a rule stored. The findings report needs the misses too: the request that ModSecurity let through, the flow Suricata didn't flag, the drop that happened before a rule existed. Marko decided on 2026-11-04 that raw host logs go to the laptop, outside the repo, before each teardown, and the design was left to 1.17.

**Options.** A: an Ansible playbook, `evidence.yml`, that runs a read-only collector on each host, fetches one archive per host through the existing SSH-in-SSM connection, and writes checksums on the laptop. B: SSM Run Command on each host, uploading to an S3 bucket in `persistent`. C: no export, and rely on Wazuh.

**Chosen: A.** It uses the inventory, connection and `become` the lab already has, adds no AWS resource or IAM grant, and runs in about a minute. The collector takes, from every agent host, the session's `sshd` and `sudo` journal; from fw-ips, the kernel lines with our three prefixes, OpenVPN's unit journal and `eve.json`; and from proxy, Nginx's logs and the ModSecurity audit log, rotated copies included. Hosts live for one session, so the whole journal is that session's. Archives go to `~/mailbridge-evidence/<UTC time>/<host>.tar.gz` with `SHA256SUMS`, so a later copy can be shown to be unchanged. B needs a bucket, a lifecycle and a write grant on every instance role: more cost and more permissions to defend. C loses exactly the evidence a miss needs.

**Trade-off accepted.** The archives hold sensitive material: Mailbridge's audit log has request headers (part B, decision 66), which can include session cookies, and the logs hold VPN client addresses. The folder is `0700`, the files `0600`, and nothing is ever copied into the public repo. siem is skipped: its alerts are on the persistent volume, and its own logs aren't evidence for the scenarios. A playbook run is an action, not configuration, so it reports `changed` every time.

**Verify.** `ansible-playbook evidence.yml` from `ansible/` fetches four archives. `sha256sum -c SHA256SUMS` in the new folder prints `OK` four times. `stat` shows `700` on the folder and `600` on the files. `tar -tzf fw-ips.tar.gz` lists `kernel-fw.log`, `openvpn.log`, `eve.json` and `auth.log`, and `proxy.tar.gz` lists `nginx/` and `modsecurity/`. `/var/tmp` on each host has no `evidence` file left. Verified on 2026-11-06: the session's scan test appears as 16 lines in `kernel-fw.log`, both ModSecurity blocks in `audit.log`, and the VPN reconnect in `openvpn.log`.

## 108. How mon installs its software (2026-11-06)

**Problem.** mon (task 1.22, decision 84) runs Prometheus, Alertmanager and Grafana. Each install method decides how much third-party code runs as root, how a version is chosen, and what can change without review.

**Options.** A: Prometheus and Alertmanager from the official release tarballs, pinned by SHA-256, with our own systemd units; Grafana from Grafana's apt repository with a pinned key, version pin and hold. B: Docker Compose with images pinned by digest, as on app. C: Ubuntu's packages.

**Chosen: A**, decided by Marko. Prometheus and Alertmanager are single static Go binaries, so a checksum-pinned download and a hand-written unit (a dedicated user, `ProtectSystem=strict`, only its data directory writable) is the whole install, the same pattern as lego (decision 59). Grafana is a larger package with plugins and a web server, and its apt repository gets the same treatment as Wazuh's: key pinned by hash, the repository limited to `grafana` at one version (decisions 91, 104), held. B adds Docker and a container boundary to a host whose job is to watch the others. C ships an old Prometheus 2.x and no Grafana at all.

**Trade-off accepted.** We maintain three systemd units and the checksum list, and upgrades are manual PRs. That's the point: each version change is reviewed.

**Verify (once built).** `systemctl show prometheus -p User` isn't root. `prometheus --version` matches the pin, and a changed checksum in `defaults` fails the run before anything is installed. `apt-cache policy grafana` shows the pinned version at 500 and any other at -1, and `dpkg -l grafana` shows `hi`.

## 109. Where Prometheus keeps its data (2026-11-06)

**Problem.** mon is destroyed at every teardown like every session host. Prometheus stores its time series on local disk, so by default each session starts with no history.

**Options.** A: a 10 GB encrypted gp3 volume in `persistent`, attached each session, as for Wazuh. B: nothing kept, and graphs exported into the evidence folder per run. C: Amazon Managed Prometheus through remote write.

**Chosen: A**, decided by Marko. The Juice Shop block measures the same attacks under different settings, often in different sessions, and Grafana can only put two runs side by side if both are in one database. The volume reuses decisions 88 and 92 exactly: found by its ID under `/dev/disk/by-id`, formatted only when `blkid -p` finds nothing, mounted with `nofail`, and Prometheus's unit gets `RequiresMountsFor`, so it can never start an empty database on the root disk. B makes every comparison a manual job with screenshots. C bills per sample ingested and per query, an open-ended cost the guardrails rule out.

**Trade-off accepted.** About $0.80 a month between sessions, and one more volume to stop cleanly before teardown (Prometheus is stopped before the apply, like Wazuh). Retention is set by size (`--storage.tsdb.retention.size`) below the volume's capacity, so the disk never fills.

**Verify (once built).** After a teardown and rebuild, a query over the previous session's time range in Grafana returns data. `findmnt /var/lib/prometheus` shows the volume, and stopping the mount makes the unit refuse to start.

## 110. Where alerts go (2026-11-06)

**Problem.** Alertmanager decides who hears about host down, disk over 80 %, a certificate under 14 days, a failing probe and CPU credits near zero (task 1.23). An alert nobody receives is the same as no alert.

**Options.** A: a Discord webhook, its URL stored by Marko in SSM as a `SecureString`, pulled by mon with a one-parameter grant. B: email over SMTP. C: no external channel, only the Alertmanager and Grafana UIs.

**Chosen: A**, decided by Marko. Alertmanager supports Discord natively. The webhook URL is a bearer secret (anyone holding it can post to the channel), so it follows the lab's secret pattern: put in SSM by hand like `/wazuh-ca/key` (decision 90), pulled by the host with its own role (decisions 39, 47), written `0600` for Alertmanager's user, and never in the repo, Terraform state or Ansible output. Its traffic goes to Discord on 443, which fw-ips already allows and logs as `FW-EGRESS` (rule 100102). B needs SMTP credentials and outbound 587, which means a change to Marko's nftables ruleset and a mail account to protect. C defeats the purpose.

**Trade-off accepted.** Alerts depend on a third-party service, and a leaked URL lets someone post fake alerts (it can't read anything). The URL can be rotated in Discord in seconds.

**Verify (once built).** The IAM simulator allows mon on the webhook parameter only. A forced test alert (stop a node_exporter) reaches the channel within the group wait and clears when the exporter starts. `ps` and the journal never show the URL.

## 111. mon's network rules in the first Terraform PR (2026-11-07)

**Problem.** §4 gave sg-mon only an inbound row (Grafana, TCP 3000 from the admin pool). Security group egress is explicit in this lab, so a group with no egress rules can't start any connection: mon couldn't reach SSM, apt, Grafana's repository or Discord. The mgmt NACL had no row for 3000 at all, and the scrape and probe paths in §4 (9100 and 9187 on every host, 443 from 10.0.5.20 to proxy) had no NACL rows yet.

**Options.** A: in PR 1, give sg-mon the private hosts' baseline egress plus the Wazuh agent ports, add an explicit allow and deny for 3000 on the mgmt NACL, and leave the scrape and probe rules for 1.23. B: add every mon rule now, scrapes and probe included. C: copy only the rows §4 already had.

**Chosen: A**, approved by Marko. mon joins `private_groups` in the security module, so it gets exactly the rules proxy, app, db and siem get: TCP 443 and UDP 123 out through fw-ips, DNS to Unbound, and the agent ports to sg-siem. It also joins the enrollment grant (decision 100), because 1.17's rule is that every host feeds Wazuh. The NACL point is subtle. NACLs are stateless, so mgmt's rule 120 allows TCP 1024–65535 from anywhere in order to let replies back in. Port 3000 is inside that range, so rule 120 would also admit a *new* connection to Grafana from any VPC address, for example from a compromised proxy. Rule 112 allows the admin pool and 115 denies everyone else before 120 is reached. This is the same pattern app and data use for 3000 and 5432 at 105. B would add rules nothing can test until exporters exist, and would need NACL rows designed before the exporters are. C leaves mon unable to install anything and Grafana reachable past the NACL.

**Trade-off accepted.** §4 is incomplete for mon until 1.23 adds the scrape and probe rows; TASKS 1.23 lists them. The NACL now has one more pair of rules to keep in step with the security group.

**Verify.** `aws ec2 describe-security-group-rules` for sg-mon shows one ingress rule (3000 from 10.8.1.0/24) and six egress rules. `aws ec2 describe-network-acls` for mgmt shows 112 allow and 115 deny on 3000 before 120. The IAM simulator allows `mailbridge-lab-mon` on `/siem/agent-enrollment-password` and returns `implicitDeny` on `/siem/indexer-admin-password`. Once Grafana runs (PR 2): `curl` to 10.0.5.20:3000 answers from the admin pool and times out from the user pool.

## 112. Grafana's admin password (2026-11-07)

**Problem.** Grafana creates a local `admin` user with the password `admin` on first start. Anyone on the admin pool could log in before it's changed, and a password set by hand isn't reproducible on a host rebuilt every session.

**Options.** A: `persistent` generates `/mon/grafana-admin-password` (write-only, like decision 46), mon's role gets `ssm:GetParameter` on `/mon/*`, and a helper sets the password and verifies it with a test login. B: the same parameter, but a grant per parameter ARN. C: set it in `grafana.ini` from an Ansible variable.

**Chosen: A**, approved by Marko. It's the `/siem/*` pattern (decision 89) and the helper pattern of decisions 52 and 94: idempotent through a test login, so no hash is stored, and the value reaches Grafana on stdin, never in a command line or a log. The Discord webhook URL of decision 110 goes in as `/mon/discord-webhook-url` under the same grant, so the path holds exactly mon's own secrets. B is tighter but needs an IAM change for every secret mon ever gets. C puts the password in a file Ansible renders, so it passes through the laptop and lands on disk in plain text.

**Trade-off accepted.** Decision 110 said a grant on one parameter; it becomes a grant on a path. Any secret later put under `/mon/` is readable by mon, so nothing else may ever be stored there.

**Verify (once built).** The IAM simulator allows mon on `/mon/grafana-admin-password` and returns `implicitDeny` on `/siem/indexer-admin-password` (mon may read the enrollment password, decision 111, but nothing else under `/siem/`). `admin:admin` gets 401, the SSM password gets 200, and the second run prints `unchanged`.

## 113. TLS for Grafana (2026-11-07)

**Problem.** The VPN encrypts traffic only between the laptop and fw-ips. From fw-ips to 10.0.5.20 the traffic crosses the VPC in clear, so Grafana's login password and session cookie would be readable by anyone controlling fw-ips or the path.

**Options.** A: TLS 1.3 with a certificate signed on the laptop by the existing Wazuh root CA, SAN `IP:10.0.5.20`, stored under `/mon/certs/*` (certificate `String`, key `SecureString`). B: a self-signed certificate generated by the role. C: plain HTTP.

**Chosen: A**, approved by Marko. The browser already trusts that CA for the Wazuh dashboard (decision 89), so Grafana gets a valid certificate with no new warning, and the CA key never leaves its encrypted backup in `/wazuh-ca/key`, which no instance role can read (decision 90): mon holds the certificate it presents, never the key that signs it. TLS 1.3 only, as decision 61 and 98, because the admin's own browser is the only client. B produces a warning every session, and clicking through warnings is the habit an attacker's interception relies on. C leaves credentials readable inside the VPC and is inconsistent with the dashboard.

**Trade-off accepted.** The CA named "Wazuh" in its subject becomes the lab's internal CA for management UIs; documented here rather than creating and trusting a second offline CA. Re-signing follows the procedure tested in 1.16.

**Verify (once built).** From the admin pool, `openssl s_client -connect 10.0.5.20:3000` returns `Verify return code: 0` against the Wazuh root CA; `-tls1_2` is refused.

## 114. Prometheus and Alertmanager on loopback (2026-11-07)

**Problem.** Prometheus's UI and API (9090) and Alertmanager's (9093) have no authentication by default. Anything that can reach them can read every metric, silence alerts or delete series through the admin API if it's enabled.

**Options.** A: listen on 127.0.0.1; Grafana on the same host queries them locally. B: listen on 10.0.5.20 and rely on sg-mon, which doesn't open those ports.

**Chosen: A**, approved by Marko. Grafana is the only client, and Prometheus pulls metrics outbound, so nothing needs to connect in. A loopback bind makes that true on the host as well as at the security group, so a later SG mistake can't expose them, the same reasoning as the Wazuh API (decision 97) and the indexer bind (decision 93).

**Trade-off accepted.** Looking at Prometheus's own UI means an SSH or SSM port forward, or going through Grafana's Explore view.

**Verify (once built).** `ss -tlnp` on mon shows 9090 and 9093 on 127.0.0.1 only; `curl` to 10.0.5.20:9090 from siem is refused.

## 115. Splitting the mon role into three PRs (2026-11-07)

**Problem.** The mon role installs three services with different patterns: a tarball and our own unit (Prometheus, Alertmanager), and an apt package with a certificate and a password helper (Grafana).

**Options.** A: three PRs, 2a Prometheus with the data volume and the Wazuh agent, 2b Grafana, 2c Alertmanager without receivers. B: one PR with everything.

**Chosen: A**, approved by Marko. Each PR is one service that can be reviewed and verified on its own (CLAUDE.md: one role, module or rule set per step), and 2a doesn't wait on the certificate signing that 2b needs.

**Trade-off accepted.** More PRs and three verification passes, and mon runs part-built between them.

**Verify.** Each PR's own checks in TASKS 1.22; the last one ends with a full `site.yml` run at `changed=0`.

## 116. Which Prometheus version (2026-11-07)

**Problem.** Prometheus releases a minor version every six weeks; a minor is supported only until the next one. The pin must be updated by hand (decision 108).

**Options.** A: 3.13.5, the current LTS line (released 2026-07-01, fixes for CVSS 7.0+ until 2027-07-31). B: 3.16.0, the newest release (2026-11-05).

**Chosen: A**, approved by Marko. The Juice Shop block compares runs across weeks, so the measuring tool should stay the same while the settings under test change, the reason decision 85 picked a stable Wazuh. Updates within 3.13 are a checksum in a PR. B would need a new pin about every six weeks to stay supported. Alertmanager has no LTS line, so it's pinned to the newest, 0.34.2. The release publishes only `sha256sums.txt` (no signature or attestation): the pin proves the file is the one reviewed, and trust in its origin rests on GitHub's TLS when the pin was taken. The archive was downloaded and hashed on the laptop before pinning (`0388822a…0699`), and holds only `prometheus`, `promtool`, a sample config and licences.

**Trade-off accepted.** No features after 3.13. The next LTS (mid-2027) will need a planned upgrade with a TSDB compatibility check.

**Verify (once built).** `prometheus --version` prints 3.13.5; changing one digit of the checksum in `defaults` fails the run at the download.

## 117. Which Grafana version (2026-11-07)

**Problem.** Grafana is pinned by version (decision 108), so a version must be chosen and later updated by hand. Grafana patches several minor lines at once (on 2026-10-27 it released 13.3.0, 13.2.5, 13.1.9, 13.0.12 and 12.4.14 together).

**Options.** A: 13.2.5, a minor line on its fifth patch. B: 13.3.0, the newest, 11 days old with no fixes yet.

**Chosen: A**, approved by Marko. The same reasoning as Prometheus's LTS (decision 116) and Wazuh (decision 85): the measuring tool should be stable while the settings under test change, and a `.0` release carries the bugs nobody has reported yet. The repository is handled like Wazuh's: the key pinned by the SHA-256 of the armored file (fingerprint `B53A E77B ADB6 30A6 8304 6005 963F A277 1045 8545`, expires 2027-08-22, checked with `gpg --show-keys` on the laptop), an apt preference that gives every package and version from `apt.grafana.com` priority -1 except `grafana` at 13.2.5, and `dpkg` hold.

**Trade-off accepted.** 13.2 will stop getting patches some months before 13.3; the update is a reviewed PR that changes one version string.

**Verify (once built).** `apt-cache policy grafana` shows 13.2.5 at 500 and every other version at -1; `dpkg -l grafana` shows `hi`; `grafana server -v` prints 13.2.5.

## 118. How Grafana gets its first admin password (2026-11-07)

**Problem.** Grafana creates its `admin` user at the first start with the password `admin`. A helper that sets the real password can only run after that start, which leaves a window, and running the CLI before the first start depends on behaviour that couldn't be tested in time (the test image was still downloading on a slow link).

**Options.** A: write the SSM password to `/etc/grafana/admin-password` (`0640 root:grafana`) and point `admin_password` at it with Grafana's `$__file{}` expansion, so the first start creates `admin` with the real password; the helper then only verifies it with a test login and resets through the CLI if it ever differs. B: start Grafana and reset the password straight after, accepting a few seconds of `admin:admin`. C: put the password in `grafana.ini` itself.

**Chosen: A**, a refinement of decision 112 proposed by Claude during the build and approved by Marko. There's never a moment with the public default password, and the result doesn't depend on the order of a start and a reset. The helper still makes the role converge after a rotation: change the SSM value, and the next run's test login fails and the CLI resets it. B leaves a short window, reachable only from the admin pool, but a window. C mixes a secret into a settings file the role templates from the laptop.

**Trade-off accepted.** The password lives in a file on mon, readable by root and the grafana group. This is the same accepted cost as the plugin's `wazuh.yml` (decision 98), and whoever controls the grafana process can already change the admin password in its own database. The file is written by `fetch-ssm-param`, so it never passes through the laptop or Ansible's output.

**Verify (once built).** `stat -c '%a %U %G' /etc/grafana/admin-password` shows `640 root grafana`; from the admin pool `admin:admin` gets 401 and the SSM password gets 200 on `/api/user`; the helper prints `unchanged` on the first and second run.

## 119. Alertmanager without cluster mode, state on the root disk (2026-11-07)

**Problem.** Alertmanager is built for high availability: by default it starts a gossip listener on `0.0.0.0:9094`, TCP and UDP, to share silences and notification state with peers. Decision 114 put its web port on loopback, but that flag doesn't touch the cluster port. It also needs a directory for its state, and mon has a root disk that disappears at teardown and a persistent volume that belongs to Prometheus.

**Options.** A: `--cluster.listen-address=` (empty, the documented way to disable it) and state on the root disk. B: cluster on, bound to 127.0.0.1. C: state on the persistent volume as well.

**Chosen: A**, approved by Marko. There is one Alertmanager and no peers, so the cluster has nothing to do; switching it off removes the listener instead of narrowing it, and found during the build, from `alertmanager --help`, before any host ran it. B keeps a gossip port that serves no purpose. The state is only silences and the notification log: losing them at teardown means a silence must be set again in a new session, while the metric history that matters lives in Prometheus on its volume. C would mix two services' data on one filesystem and make Prometheus's retention-by-size share space with something else.

**Trade-off accepted.** Silences don't survive a teardown, and adding a second Alertmanager later means turning the cluster back on with authentication or TLS.

**Verify (once built).** `ss -tulnp` on mon shows Alertmanager only on `127.0.0.1:9093` and nothing on 9094 over TCP or UDP; Prometheus's `/api/v1/alertmanagers` lists `127.0.0.1:9093` as active; the `alertmanager` scrape target is `up`. Tested locally first with the release binary and the unit's flags: only `tcp 127.0.0.1:19093` listened.

## 120. How the exporters are installed and reached (2026-11-08)

**Problem.** 1.23 adds an exporter on every host. Each one is a new listening port on a host that so far listened only where its job required, and each needs a path from mon through the security groups, the NACLs and, for fw-ips, nftables.

**Options.** Install: A, checksum-pinned release tarballs with our own units; B, Ubuntu's `prometheus-node-exporter`. Reach: plain HTTP on the private address, limited by the network layers, or TLS with certificates on every exporter.

**Chosen: A and plain HTTP on the private address**, approved by Marko. A is the pattern of decision 108, so the whole Prometheus stack is reviewed the same way and runs one version everywhere; Ubuntu's package sits in universe, which has community-only security support on 24.04. node_exporter binds to `ansible_default_ipv4.address:9100`, never `0.0.0.0`, and its unit is sandboxed (no capabilities, read-only system). The path is opened layer by layer: SG ingress on proxy, app, db and siem referencing sg-mon, matching egress on sg-mon (and to fw-ips's address); on the NACLs, 9100 is inside the ephemeral range that rules 110/120 open for replies, so dmz, app and data get `106 allow 9100 from 10.0.5.20/32` and `107 deny 9100 from 0.0.0.0/0` before those rules, and `170` outbound for the replies to mon. mgmt needs nothing new: its outbound 160 and inbound 120 already cover the ephemeral ranges. fw-ips's group already admits the VPC, so its nftables input chain decides, and that rule is Marko's to write. TLS would need a certificate per exporter for metrics that hold no secrets.

**Trade-off accepted.** Metrics cross the VPC in clear; anyone already able to sniff inside the VPC learns load and disk figures. A pinned version means manual updates.

**Verify (once built).** Every `node` target `up` in Prometheus; `ss -tlnp` on each host shows 9100 on its private address only; from the admin pool 9100 on app times out (NACL 107, SG); the second run `changed=0`.

## 121. CPU credits through YACE (2026-11-08)

**Problem.** §9 asks for an alert when a t3's CPU credit balance nears zero. The balance is kept by the hypervisor and published only to CloudWatch; the guest OS never sees it.

**Options.** A: YACE (prometheus-community's CloudWatch exporter) on mon reading `CPUCreditBalance`. B: node_exporter's steal time, which rises when the hypervisor throttles. C: CloudWatch alarms with SNS email.

**Chosen: A**, approved by Marko. It shows the balance itself, so the alert fires before throttling, which is when it's useful: siem's balance was measured at 2.6 to 8 on 2026-11-05. mon gets read-only `cloudwatch:GetMetricData`, `cloudwatch:ListMetrics` and `tag:GetResources`; these actions can't be limited to resources, so the policy names `*` with a documented checkov skip, and it grants no write. Polling a handful of instances every 5 minutes costs fractions of a cent per session. B reacts only after the credits are gone. C splits alerting across two systems and bills alarms while no hosts exist.

**Trade-off accepted.** One more exporter and a broad-looking, read-only IAM statement; CloudWatch data lags by about 5 minutes.

**Built (3d, 2026-11-08).** YACE 0.68.0 on 127.0.0.1:5000 discovers `AWS/EC2` instances by `Project=mailbridge-lab` and reads `CPUCreditBalance` (minimum per 5 minutes) every 300 s, the rate basic monitoring publishes it. The inline policy `mon-read-cloudwatch` allows exactly `cloudwatch:GetMetricData`, `cloudwatch:ListMetrics` and `tag:GetResources`; YACE's README lists more for other services and `GetMetricStatistics` for a mode we don't use, all left out. Prometheus drops the `account_id`, `name` (an ARN with the account ID) and `dimension_InstanceId` labels at scrape time, so neither the account nor a live resource ID can reach a dashboard screenshot in the public repo, and copies `tag_Name` into `host` to match node_exporter.

**Verify (once built).** The IAM simulator allows the three read actions and returns `implicitDeny` on `cloudwatch:PutMetricData`, `cloudwatch:DeleteAlarms`, `logs:GetLogEvents` and `ec2:DescribeInstances`; Prometheus has `aws_ec2_cpucredit_balance_minimum` for all six hosts with none of the dropped labels. Tested on the laptop with read-only access: six balances (42 to 128) and only `host`, `instance`, `job`, `region`, `tag_Name` left after relabeling.

## 122. One dashboard of our own (2026-11-08)

**Problem.** Grafana starts empty. The Juice Shop block needs host health next to the security layers at a glance.

**Options.** A: one small provisioned dashboard written for the lab. B: a community dashboard such as "Node Exporter Full". C: none until the Juice Shop block.

**Chosen: A**, approved by Marko. A few panels (CPU, memory, disk, network per host, credit balance, probe status, certificate days left) that each answer a question the lab asks, provisioned from the repo so they can't drift. B is about 15,000 lines of JSON nobody here has reviewed. C leaves the stack untested end to end.

**Trade-off accepted.** Fewer panels than a community dashboard; more can be added per need.

**Built (3f, 2026-11-08).** `lab-health.json` (uid `lab-health`), ten panels in three rows that each answer one question. *Is everything up?*: `up` for every scrape target and `probe_success` for both probes, as UP/DOWN tiles. *How busy are the hosts?*: CPU used, CPU **steal** (the guest's only view of credit throttling, next to the credit balance it explains), memory used (MemAvailable already counts reclaimable cache), network in and out without loopback. *Will something run out?*: disk used on real filesystems with the alert's 80 % as the red step, the credit balance with a line at the alert's 10, and the certificate's days left coloured at 14 and 30. Each panel's description names the alert and decision it belongs to. The file provider has `disableDeletion` and `allowUiUpdates: false`, so the repo is the only source. Every query was run against the real Prometheus on mon before the PR: all ten return data.

**Verify (once built).** The dashboard loads from provisioning, every panel shows data, and it can't be saved over in the UI.

## 123. Splitting 1.23 (2026-11-08)

**Problem.** 1.23 adds four exporters, network rules on every layer, alert rules, a receiver and a dashboard.

**Options.** A: six PRs, 3a node_exporter with its network rules, 3b postgres_exporter, 3c blackbox with proxy's 443 from mon, 3d YACE, 3e alert rules and Discord, 3f the dashboard. B: three larger PRs.

**Chosen: A**, approved by Marko. Each PR adds one thing that is proven by its own target `up`, the CLAUDE.md rule of one role or rule set per step; 3a waits on Marko's nftables rule and 3e on his webhook, without holding up the others.

**Trade-off accepted.** More PRs and verification passes.

**Verify.** TASKS 1.23 lists each PR's checks.

## 124. How postgres_exporter logs in (2026-11-08)

**Problem.** postgres_exporter needs a PostgreSQL login to read statistics. Every login so far has used a password from SSM (decisions 47, 52, 54), because the app logs in over the network.

**Options.** A: peer authentication on the local Unix socket: the exporter runs as the OS user `postgres_exporter`, and `pg_hba.conf` maps it to the database role of the same name. B: a password generated in `persistent` and set by `set-db-password`, used over TCP on 127.0.0.1.

**Chosen: A**, approved by Marko. On a Unix socket the kernel reports the connecting process's user to PostgreSQL (`SO_PEERCRED`), so PostgreSQL knows who is calling without being told a secret. The exporter sits on the same host as the database, so there's nothing to generate, store, rotate or leak, the same mechanism the `postgres` admin login already uses. The role is `LOGIN` with every other attribute off and membership in the built-in `pg_monitor`, which reads `pg_stat_*` views and settings but no table, so mail stays out of reach even if the exporter were compromised. The `pg_hba.conf` line names the `postgres` maintenance database only. `stat_statements` stays off (its default), because query texts could contain data. B adds a secret that exists only because of a network hop that isn't there.

**Trade-off accepted.** Anyone who can run a process as the OS user `postgres_exporter` gets its statistics; that already requires root on db.

**Verify (once built).** The `postgres` target is `up` and `pg_up` is 1; `ss -tlnp` shows 9187 on 10.0.4.10 only; `sudo -u postgres_exporter psql -h /var/run/postgresql -d mailbridge` is refused by `pg_hba.conf`; `psql -U postgres_exporter -d postgres` as `ubuntu` fails with `Peer authentication failed`; as `postgres_exporter`, `SELECT` on a Mailbridge table is refused.

## 125. What blackbox_exporter probes, and how (2026-11-08)

**Problem.** §9 asks for a probe of `https://mail.<domain>` and an alert when the certificate has fewer than 14 days left. mon can't resolve `mail.<domain>`: private hosts use AmazonProvidedDNS (decision 25), and only Unbound on fw-ips knows the private name. The proxy's certificate is from Let's Encrypt staging, which no system trust store accepts.

**Options.** A: probe proxy by address with the expected name in SNI and `Host`, verify against the pinned staging root, and probe Unbound separately for the name. B: point mon's resolver at Unbound. C: an `/etc/hosts` line on mon.

**Chosen: A**, approved by Marko. The HTTPS probe reaches exactly what a VPN user reaches: Nginx picks the server by SNI and `Host`, ModSecurity inspects the request, and `/healthz` answers from app, so a 200 proves the whole chain. The certificate is verified, not skipped: the staging root "(STAGING) Pretend Pear X1" is downloaded by mon from letsencrypt.org and pinned by SHA-256 like the apt keys; when Let's Encrypt moves to production the variable points at the system store and the download is skipped. The DNS probe asks Unbound for the name and passes only on `10.0.2.10`, so a broken resolver and a broken proxy show up as different failures. B changes DNS for one host to fix a gap that belongs to all of them (scenario 2.2). C is a second copy of DNS that goes stale without warning. The network rows were already in §4 (decision 84): sg-proxy and dmz NACL 105 admit 443 from 10.0.5.20/32; replies use dmz's outbound 170 from decision 120.

**Trade-off accepted.** The HTTPS probe doesn't test name resolution itself, which is why the DNS probe exists. It adds two requests a minute to Nginx's logs.

**Verify (once built).** `probe_success` is 1 for both modules, `probe_http_status_code` 200, `probe_tls_version_info{version="TLS 1.3"}` 1, and the days left from `probe_ssl_earliest_cert_expiry` match `openssl x509 -enddate`. Tested from the laptop in the admin pool first: 200 over TLS 1.3, 63.8 days left, DNS answer matched; the same probe against the system store failed with `x509: certificate signed by unknown authority`.

## 126. The alert rules and how they're proven (2026-11-08)

**Problem.** §9 lists five conditions to alert on. An alert rule that never fires is indistinguishable from one that's broken, and most of these conditions (a full disk, an expiring certificate, credits at zero) can't be produced on demand without damaging the lab.

**Options.** A: `promtool test rules` unit tests with synthetic series for every rule, run on mon in each Ansible run, plus live tests for the conditions that are safe to cause (a stopped exporter, a test alert). B: live tests only. C: no tests; trust the expressions.

**Chosen: A**, approved by Marko. Each test feeds made-up time series into the real rule file and checks the exact alerts and labels at given times: the rule must fire after its `for` period and must stay quiet for the healthy series beside it (a disk at 50 %, a tmpfs at 95 %, 40 credits, 60 days of certificate). A mutation test showed the tests bite: raising the disk threshold to 95 % and the credit threshold to 3 made both fail. The role copies rules and tests to mon and runs the tests on every deploy, so a threshold can't drift from its test. The thresholds: `up == 0` and `probe_success == 0` for 2 minutes (eight missed scrapes, not one); disk over 80 % for 10 minutes on real filesystems (snap squashfs images are always 100 %); certificate under 14 days for an hour (lego renews at 30 days, so this means two weeks of failed renewals); credits under 10 for 15 minutes (siem ran at its 20 % baseline with 2.6–8 on 2026-11-05). Alertmanager uses its native Discord integration with `webhook_url_file`, so the bearer URL lives only in SSM and a `0640 root:alertmanager` file. B can't safely cover three of the five rules. C leaves the alerting untested, which defeats having it.

**Trade-off accepted.** Unit tests prove the rule logic, not the metric pipeline; the live tests and the targets being `up` cover that part.

**Verify (once built).** `promtool test rules` reports `SUCCESS` on mon; stopping node_exporter on app sends `TargetDown` to Discord within about 3 minutes and `RESOLVED` after it starts; an `amtool alert add` test reaches the channel; the URL appears in no log, no `ps` output and no Ansible output.

## 127. Building the vuln network in code first (2026-11-08)

**Problem.** Decision 11 builds each layer by hand, compares it with code and rebuilds it, and TASKS 2.8 said "built by hand, then imported". The vuln network is a subnet, a route table, a security group, a NACL and additions to existing ones.

**Options.** A: write it in Terraform and review the plan, then prove the one new concept live. B: build it in the console and import it, as TASKS said.

**Chosen: A**, decided by Marko. Every resource type here was built by hand and imported in 1.5a, so a second hand build repeats steps already learned; decision 11's purpose, knowing what the console does before automating it, is met. The new concept is routing: a route for a whole subnet's CIDR that is more specific than the VPC's `local` route, which AWS has allowed since 2021, so the longest prefix wins and traffic between vuln and the rest of the VPC goes through fw-ips. That is proven better on the wire than in the console: a capture on fw-ips shows proxy's SYN to 10.0.6.10 arriving there (and nftables dropping it until 2.9), while proxy's traffic to app never appears. The plan was reviewed line by line: 31 resources, nothing changed or destroyed. Rules on the vuln paths name addresses, not groups: after the detour a packet arrives from fw-ips's ENI, so a group reference can't match its original sender (decision 68). The vuln NACL also gets mon's 9100 pair and replies (decision 120), so the host can be scraped like the others.

**Trade-off accepted.** No console practice for route tables with more specific routes; the import step of decision 11 is skipped for this layer.

**Verify.** The plan's 31 resources exist; `tcpdump` on fw-ips sees proxy → 10.0.6.10:3000 and nftables logs it as `FW-DROP` (until 2.9); proxy → app traffic is absent from fw-ips's capture; the next plan is clean.

## 129. Juice Shop as a regular application (2026-11-08)

**Problem.** Decisions 67 to 76 planned Juice Shop as a measurement target: its own ModSecurity bundle with a separate mode and paranoia level, request bodies in its audit log, an eight-configuration matrix, an internet window, and (proposed while building 2.9) Suricata variables changed so proxy counted as external on its path. Testing that last change showed how much special handling this needed: one form of the variable was rejected by Suricata and would have disabled every rule using it, and ET Open had no rule for a generic SQL injection on Juice Shop's URLs anyway.

**Options.** A: exactly like Mailbridge, isolation included: proxy reaches it over the `local` route and nothing special exists. B: the same defences as Mailbridge, but kept isolated. C: keep the measurement plan.

**Chosen: B**, decided by Marko. Juice Shop runs behind proxy with the same Nginx and ModSecurity configuration as Mailbridge (decisions 63 to 66), and the pentest asks what a real attacker achieves against that, not how tuned test settings behave. What stays is safety, not measurement: the subnet routed through fw-ips with vuln → VPC dropped (decision 68), the container hardening and `DOCKER-USER` (decision 69), because Juice Shop contains deliberate code execution that must not reach db or Mailbridge, as a real company would isolate a known-weak app; and the attacker certificate, scope wrapper with rate caps and separate browser profile (decisions 73, 75, 76), because attacks must stay on Marko's own deployment within AWS's rules. Suricata still inspects the path, as it inspects all forwarded traffic, with its configuration unchanged. Dropped: decision 71 (bundles, mode, level, matrix) and decision 72 (the window and its listener); 2.1 and 2.16 go, 2.12 and 2.15 are rewritten. A would let an RCE in Juice Shop open connections to db. C answers a WAF-tuning question Marko no longer wants to ask.

**Trade-off accepted.** No comparison of ModSecurity modes or paranoia levels, and no request bodies as evidence for Juice Shop; Suricata's ET rules will rarely match proxy → Juice Shop traffic, which is itself a finding about signature IDS inside a network.

**Verify.** ARCHITECTURE and TASKS no longer mention the window, the 8443 listener or the per-server bundles; 2.12's check shows the same SQLi blocked on both servers; 2.15's findings name a layer for every step.
