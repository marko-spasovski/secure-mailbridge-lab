# Prompt for Fable 5.2: company-growth plan, flows and learning path

Read this whole file before doing anything, then follow it from start to finish.

---

## 0. Your role and the rules for this task

You are a senior infrastructure and security architect, an experienced red teamer and blue teamer,
and a patient university lecturer. You write a complete, well-organised documentation set with flow
diagrams for a learning lab. I am a student. I will use these documents as long-term context, both
for myself and for AI coding assistants, while I build the lab step by step. I must be able to
understand and defend every part in job interviews and at university.

**Rules for working in this repository (follow every one):**

1. **Write only inside `docs/fable-5.2-review/`.** Create new files and folders there. Do **not**
   modify, rename, move or delete any existing file anywhere in the repository, including this
   prompt.
2. **Do not run git commands that change state**: no `git checkout`, `git switch`, `git branch`,
   `git commit`, `git stash`, `git add`, `git reset`, `git push`. This working tree is shared and
   must stay on `main`. I will commit your files myself. Read-only commands (`git log`,
   `git show`, `git diff`) are fine.
3. **Do not run any infrastructure or network commands against the lab**: no Terraform, no
   Ansible, no AWS CLI, no SSH, no scans, no Proxmox API. This is a writing task.
4. **Read for context first (read only):** `CLAUDE.md`, `docs/ARCHITECTURE.md` (the source of
   truth for what exists today), `docs/TASKS.md`, `docs/decisions.md`, `docs/tier1-writeup.md`,
   `docs/findings-report.md`, `docs/threat-model.md`, and skim `docs/rationale.md`. Follow the
   ideas in CLAUDE.md about learning and documentation style. Where your proposal differs from
   `ARCHITECTURE.md`, say so explicitly and explain why. Don't silently contradict it.
5. **The repository is public.** Never write secrets, passwords, keys, account IDs, live resource
   IDs, real public IPs, e-mail addresses or personal data. Use placeholders such as `<domain>`,
   `corp.<domain>`, `<home-public-ip>`, `<aws-account-id>`.
6. **Do not use or mention any VPS.** The only hosting options in this task are AWS and a home
   Proxmox server.
7. Mark every design element as **PROPOSED**. Do not invent decision numbers. Where you make an
   assumption, put it in an "Assumptions" box. Where you name a tool version, a price or a
   certification detail you can't verify, mark it "(verify)".
8. If the output is too large for one reply, finish the current file, stop at a file boundary,
   list what is left, and wait for me to say "continue".

---

## 1. What already exists ("Stage 0", built and verified on AWS)

A summary. `docs/ARCHITECTURE.md` has the full details.

A segmented AWS lab in eu-central-1 that runs "Mailbridge", my own web app (a unified Gmail/Outlook
inbox). Infrastructure is Terraform (shared modules plus a `persistent` stack and a `lab` stack);
configuration is Ansible, one idempotent role per host.

- VPC 10.0.0.0/16, single AZ. The only entry point from the internet is OpenVPN on UDP 1194.
  VPN pools: users 10.8.0.0/24 and admins 10.8.1.0/24, routed (not NATed) so every event is
  attributable to a device certificate (easy-rsa PKI, offline CA, CRL).
- Subnets: public 10.0.1.0/24 (fw-ips), dmz 10.0.2.0/24 (proxy), app 10.0.3.0/24 (app),
  data 10.0.4.0/24 (db), mgmt 10.0.5.0/24 (siem, mon; admin VPN pool only),
  vuln 10.0.6.0/24 (OWASP Juice Shop, a deliberate target).
- fw-ips: OpenVPN, nftables firewall + NAT (no NAT Gateway), Suricata inline IPS (NFQUEUE),
  Unbound DNS.
- proxy: Nginx + ModSecurity v3 with the OWASP CRS (blocking, PL1), ACME certificates via lego
  using the Let's Encrypt staging endpoint.
- app: Mailbridge in Docker, image pinned by digest from ECR. db: PostgreSQL with separate owner
  and runtime roles.
- siem: Wazuh all-in-one with agents on every host and custom rules. mon: Prometheus +
  Alertmanager (Discord) + Grafana.
- Baseline: IMDSv2, least-privilege IAM role per instance, secrets only in SSM Parameter Store,
  admin access through SSM (port 22 never open), CloudTrail, VPC flow logs, budgets, and every host
  torn down after each session.
- Ways of working: a branch per change, Conventional Commits, merge only on green CI (terraform fmt
  and validate, tflint, checkov, ansible-lint, gitleaks). Every design decision gets a one-line
  entry in `decisions.md` and a half-page rationale (problem, options, choice, trade-off,
  verification).
- Next planned step (Tier 2): a threat model, then a pentest of Juice Shop and Mailbridge from a
  dedicated attacker VPN certificate, with a findings report (attack → detection or miss → fix →
  re-test).

---

## 2. The plan to document: "one company that grows"

The lab becomes **one fictional company that grows through stages**. Invent a neutral fictional
company name. It must not resemble a real company. At every stage I play three roles:

- **BLUE:** build, operate, maintain and secure the infrastructure the way a company of that size would.
- **RED:** pentest or red-team it, with a scope and method realistic for that size of company.
- **PURPLE:** attack → detect (or miss) → fix → re-test, mapped to MITRE ATT&CK.

Stages (starting point; improve them if you see a better progression):

- **Stage 0, startup (~10 people):** what exists today. Red = web app and cloud pentest.
- **Stage 1, small company (~30):** perimeter firewall, one domain controller (AD, DNS, DHCP),
  a file server (SMB, plus plain FTP as a deliberate legacy finding), internal company mail
  (for example Postfix + Dovecot + Rspamd with Roundcube), 2–3 Windows/Linux workstations with
  Sysmon and Wazuh agents. Processes: joiner/mover/leaver, password resets, monthly patching,
  backups with restore tests. Baseline: MFA, LAPS, CIS benchmarks, Wazuh/Grafana roles mapped to
  AD groups (for example SOC-Analysts = read-only). Red = external pentest plus an assumed-breach
  phishing test (GoPhish, against my own lab users only).
- **Stage 2, mid-size (~300):** segmentation (users, servers, mgmt, DMZ, guest, IoT), a second
  DC, GPO hardening, patch management (WSUS or equivalent), vulnerability scanning (Greenbone),
  SSO (Keycloak), a backup server, a ticket system (GLPI or GitHub Issues), change management
  (PR = change request), L1 SOC runbooks, vulnerability management with patch deadlines, access
  reviews. Red = internal network pentest: AD attack paths (BloodHound), Kerberoasting, AS-REP
  roasting, lateral movement to Domain Admin, DNS tunneling, and layer-2 attacks where the
  platform allows them. Purple = ATT&CK coverage map with Atomic Red Team.
- **Stage 3, a slice of a large company:** the AD tier model (Tier 0/1/2) with admin workstations
  (PAWs), PAM (for example Teleport or JumpServer), a branch office with its own AD site,
  802.1X/FreeRADIUS where possible, SOAR (Shuffle) + case management (TheHive), detection rules as
  code (Sigma in CI), Vault, Kubernetes (k3s), GRC (risk register, policies, ISO 27001/NIS2
  controls map), incident response plan and tabletop exercises. Red = goal-driven red team
  (assume breach, a C2 such as Sliver inside the lab only), measuring MTTD/MTTR, a report with an
  executive summary.

UI principle: use read-only UIs for visibility (EveBox for Suricata, Grafana for firewall
dashboards, Wazuh for the SIEM). Configuration changes go through reviewed code, not web UIs, so
the code never drifts from what is running. Explain this principle, and where a real company would
accept a UI anyway.

---

## 3. Two separate platform versions: AWS and Proxmox

Write **two complete, independent versions** of the platform-specific design. Don't limit either
one to what exists today.

### 3a. AWS version (`aws/`)
The whole company lives in AWS and extends the existing lab.
- How to run Windows domain controllers and workstations on EC2 (costs, licensing included in the
  price, automation through SSM/WinRM), and alternatives such as AWS Managed Microsoft AD, IAM
  Identity Center and WorkSpaces. Compare their cost and how much each teaches.
- The AWS limits a security lab runs into: no layer 2 (no broadcast, ARP, customer DHCP,
  LLMNR/NBT-NS multicast), outbound port 25 blocked by default, AWS's penetration-testing policy
  (verify the current rules). What can't be practised there, and what to do instead (Traffic
  Mirroring, GuardDuty, VPC flow logs, a cloud-native attack path such as IAM privilege
  escalation, SSRF to IMDS, S3 misconfiguration, with tools like Pacu and Prowler against my own
  account).
- Cloud security topics only AWS can teach: IAM, Organizations/SCPs, CloudTrail detections,
  GuardDuty, Security Hub, Config, KMS, cross-account roles, landing zones.
- Network per stage, cost per stage (hourly and per session, with the teardown model), and keep
  the existing cost guardrails (no NAT Gateway, no ALB, no interface endpoints, t3 standard
  credits) or explain clearly when a stage would justify breaking one.

### 3b. Proxmox version (`proxmox/`)
The whole company, including a copy of the Mailbridge stack, lives on one home Proxmox server.
- Hardware sizing per stage (CPU, RAM such as 64/96/128 GB, storage, NICs), with rough costs for
  new or used hardware (verify), power use and noise.
- Networking: Linux bridges, VLANs, OPNsense or pfSense as the perimeter firewall, Suricata inline,
  a WAN/LAN design that keeps the lab isolated from my home network, and remote access only
  through a VPN (never expose the Proxmox UI).
- Everything AWS can't do: real layer 2 (rogue DHCP, ARP spoofing, LLMNR/NBT-NS poisoning,
  VLAN hopping), 802.1X, wireless where possible, physical-style network attacks.
- Infrastructure as code: the bpg/proxmox Terraform provider, cloud-init templates, Packer images
  for Windows and Linux, Ansible for Linux and Windows, snapshots and resets between exercises.
- Backups (Proxmox Backup Server), safe malware and C2 handling (isolated segments, no internet),
  and a "reset the whole range" procedure.

### 3c. Comparison and hybrid (`comparison.md`)
A side-by-side table (cost, realism, what each teaches, job relevance, effort, risk), plus a
**hybrid design**: AWS as cloud production, Proxmox as the HQ office, joined by a site-to-site VPN
(IPsec or WireGuard). Give a clear recommendation of which version to build first and why.

Suggested address plan: AWS stays 10.0.0.0/16, HQ on Proxmox 10.20.0.0/16 split into VLANs,
branch office 10.30.0.0/16. Improve it if needed and explain why. Use the same host names, VLAN
names, groups and IPs consistently across all files.

---

## 4. Go beyond this prompt: explore broadly

**Don't stop at what is written above.** Explore broadly what would be most useful for a student
who will finish **5 years of university (3 years bachelor + 2 years master)** and wants a career
across **all of cybersecurity**: red team, penetration testing, blue team (SOC, DFIR, detection
engineering, threat hunting), security engineering, cloud security, AppSec/DevSecOps and GRC.

Propose additional lab components, exercises and skills that make me genuinely job-ready,
including the ones I haven't thought of. For example (extend and challenge this list):

- **Offensive:** web and API testing, AD and Kerberos attacks, cloud attacks, phishing and initial
  access, C2 and OPSEC, privilege escalation (Linux and Windows), basic exploit development and
  reversing, password attacks, reporting and client communication.
- **Defensive:** SOC triage, threat hunting with hypotheses, DFIR (memory forensics with
  Volatility, disk forensics, Velociraptor, timeline analysis), malware analysis basics in a
  sandbox, threat intelligence (MISP, OpenCTI), deception (honeypots, canary tokens), EDR
  concepts, detection-as-code.
- **Engineering:** hardening and CIS benchmarks, PKI and certificate lifecycle, zero trust, secrets
  management, container and Kubernetes security, supply chain security (SBOM, signing), CI/CD
  security, logging architecture, backup and ransomware resilience.
- **GRC:** ISO 27001, NIS2, GDPR, risk assessment, policies, audits, business continuity, and
  security awareness.
- **Other:** OT/ICS basics, mobile, wireless, purple-team programmes, CTFs, community
  contributions, writing blog posts and talks, master-thesis topics that use this lab.

For every idea, give: what it is, why companies need it, which job role uses it, how to practise
it in this lab (AWS, Proxmox or both), its value (high / medium / nice-to-have) and its effort.
Then turn the best ideas into a **semester-by-semester learning path** for the remaining years of
study. Map it to the lab stages, to well-known certifications (for example OSCP, CRTO, PNPT,
BTL1, SC-200, AWS Security Specialty; verify current names and value) and to portfolio pieces I
can show employers.

---

## 5. Deliverables (folder structure)

Markdown files with **Mermaid diagrams** (flowchart, sequenceDiagram, stateDiagram, gantt where
useful). Every diagram must render in GitHub Markdown. Every diagram is followed by a short
explanation of each step: who does it, which tool, which log or evidence it produces, and what can
go wrong.

```
docs/fable-5.2-review/
├── PROMPT_FABLE.md                 (this file; do not modify it)
├── README.md                       index, how to read the set, stage map, glossary of every acronym
├── comparison.md                   AWS vs Proxmox vs hybrid, with a recommendation
├── shared/                         platform-independent content
│   ├── 01-company-profiles.md      how small/mid/large companies organise IT and security,
│   │                               org charts per stage, typical weaknesses, job roles per stage
│   ├── 02-identity-and-access.md   AD design per stage, groups and RBAC (Wazuh, Grafana, firewall,
│   │                               hypervisor or cloud), tier model, SSO flows (LDAP, OIDC, Kerberos)
│   ├── 03-operations-flows.md      change management, joiner/mover/leaver, password reset,
│   │                               patching, backup and restore test, certificate renewal,
│   │                               onboarding a new server, decommissioning (flow + runbook each)
│   ├── 04-security-operations.md   alert lifecycle, incident response (NIST SP 800-61) with a
│   │                               postmortem template, detection engineering lifecycle,
│   │                               vulnerability management, log sources per stage,
│   │                               ATT&CK coverage matrix template, threat hunting
│   ├── 05-offensive-engagements.md engagement flow, one engagement plan per stage, rules of
│   │                               engagement template, findings template, purple-team loop
│   ├── 06-learning-path.md         the broad exploration from section 4 and the semester plan
│   ├── 07-extra-ideas.md           everything else you found valuable that doesn't fit elsewhere
│   └── 08-interview-prep.md        per stage, 10 questions with model answers tied to the lab
├── aws/
│   ├── 01-architecture-per-stage.md  network diagram + address plan + allowed flows per stage
│   ├── 02-platform-specifics.md      identity on AWS, cloud security topics, AWS limits
│   ├── 03-attack-ranges.md           what can and can't be attacked on AWS, engagement adjustments
│   └── 04-roadmap-and-cost.md        phased roadmap (gantt), entry/exit criteria, costs
└── proxmox/
    ├── 01-architecture-per-stage.md
    ├── 02-platform-specifics.md      hardware, networking, IaC, backups, isolation
    ├── 03-attack-ranges.md
    └── 04-roadmap-and-cost.md
```

You may add files if they clearly help, but list them in `README.md`.

Requirements for the roadmaps: keep every step small (one role, module or rule set). Give entry
and exit criteria, where "done" means deployed from code, verified with stated commands, and
documented. Map each step to the existing Tier 2/Tier 3 tasks in `docs/TASKS.md`.

Requirements for the network sections: least privilege, one hop at a time, a table of allowed
flows (source → destination → port → reason) per stage, and the trust boundaries drawn in the
diagrams.

---

## 6. Hard constraints (apply to every document)

- Attacks target only my own lab, never third-party services (no Google or Microsoft APIs, no
  scanning outside the lab). Every red activity starts from a written scope and rules of
  engagement. Malware and C2 run only in isolated segments.
- Everything is infrastructure as code (Terraform, Ansible, Packer). Ansible roles must be
  idempotent.
- Let's Encrypt staging until I decide to switch to production.
- Secrets live in a secret store (SSM Parameter Store on AWS; Vault or an equivalent on Proxmox),
  never in the repository.

---

## 7. Style

- Write like a lecturer teaching a strong student: what it is, why companies do it, the
  alternatives, the trade-off, how I would verify it in the lab.
- Present choices as options A/B/C with the recommendation first, and explain the concept behind
  the choice so I can defend it in an interview.
- Prefer tables for comparisons and checklists for runbooks.
- Point out where a lab simulation differs from a real company, and why that matters.
- Be honest about effort and cost. Mark anything uncertain "(verify)".

## 8. Order of work

1. Read the files listed in rule 4.
2. Reply with the file tree, a one-paragraph summary of each file, and the list of assumptions you
   are making. Then start writing immediately, without waiting for approval.
3. Write `README.md`, then `shared/`, then `aws/`, then `proxmox/`, then `comparison.md`.
4. Finish with a short summary: what you wrote, the top 5 recommendations, and the open
   questions I need to decide.
