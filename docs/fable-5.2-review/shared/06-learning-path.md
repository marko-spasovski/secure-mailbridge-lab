# 06 · Learning path: from this lab to a career across cybersecurity

> **Status: PROPOSED.** A catalogue of what to learn and how to practise it in the lab, then a
> semester-by-semester plan for five years of study (three bachelor, two master), mapped to the
> lab stages, certifications and portfolio pieces.

> **Assumptions**
>
> 1. **Your current semester is unknown.** The plan lists ten semesters, B1–B6 and M1–M4. Section
>    4.2 explains how to start in the middle.
> 2. You want to keep every direction open (red, blue, engineering, cloud, AppSec, GRC) until
>    roughly the end of the bachelor, then lean towards one.
> 3. Certification names, exam codes, prices and renewal rules change often. Every one below is
>    marked (verify); check the vendor's page before paying.
> 4. Value ratings are the author's judgment of entry-level job relevance in Europe, not data.

**Effort key:** **S** = one or two weekends · **M** = several weekends · **L** = a semester-long
side project. **Value key:** High · Medium · Nice-to-have.

---

## 1. How to think about breadth

Security careers are **T-shaped**: broad understanding of everything, depth in one or two areas.
The breadth is what lets a pentester write a fix a sysadmin will accept, and lets a SOC analyst
understand what the attacker was trying. The lab gives you the breadth almost for free, because
you play every role against the same systems.

Three rules for choosing what to learn next:

1. **Fundamentals before tools.** Networking, operating systems, one scripting language and how
   authentication works outlast every product.
2. **Build it, break it, detect it, fix it.** A topic isn't learned until you've done all four
   on the same system. This is the lab's purple loop, and it's also the best interview story.
3. **Write it up.** Unwritten work doesn't exist for an employer.

---

## 2. The idea catalogue

### 2.1 Offensive

| Idea | What it is, and why companies need it | Role | Practise in the lab | Value | Effort |
|---|---|---|---|---|---|
| Web application testing | finding flaws in web apps by hand with a proxy tool. Most companies' exposed surface is web | pentester, AppSec | Juice Shop, then Mailbridge (tasks 2.15, 2.3, 2.4). Both platforms | High | M |
| API testing | the OWASP API Top 10, above all broken object level authorisation. Modern apps are APIs | pentester, AppSec | Mailbridge's JSON API; write an OpenAPI description and test from it. Both | High | M |
| AD and Kerberos attacks | Kerberoasting, delegation abuse, ACL paths, DCSync. The core of internal pentests | internal pentester, red team | Stage 2. Both | High | L |
| AD CS attacks | abusing certificate templates and enrolment. Very common real finding | internal pentester | `ca01`, `W2-03`. Both | High | M |
| Cloud attacks | IAM privilege escalation, metadata theft through SSRF, storage misconfiguration | cloud pentester, cloud security | the sandbox account in `aws/03-attack-ranges.md`. AWS | High | M |
| Phishing and initial access | credential pages, payload delivery, how MFA gets phished through a relaying proxy | red team, awareness lead | GoPhish at Stage 1; a relaying-proxy test against your own `kc01` only at Stage 2. Both | Medium–High | M |
| C2 and OPSEC | operating implants through a framework while staying unseen | red team operator | Sliver on `c2-01`, redirector on `sim-inet`. Proxmox | Medium (High for red team) | L |
| Linux privilege escalation | sudo rules, SUID files, capabilities, cron, weak permissions | pentester | a "privesc playground" role with one toggle per misconfiguration, on a throwaway VM. Both | High | S |
| Windows privilege escalation | service misconfigurations, token privileges, stored credentials | pentester | the same idea on a throwaway Windows VM. Both | High | M |
| Password attacks | cracking with hashcat, word lists and rules; spraying | pentester | hashes from the lab, cracked offline on your laptop. Both | High | S |
| Layer-2 and relay attacks | ARP spoofing, rogue DHCP, LLMNR poisoning, NTLM relay, IPv6 tricks | internal pentester | `proxmox/03-attack-ranges.md`. Proxmox only | Medium–High | M |
| Container and Kubernetes attacks | escaping containers, abusing cluster RBAC | cloud pentester | Stage 3 k3s, `W3-02`. Both | Medium–High | M |
| Secure code review | reading source for flaws; writing Semgrep rules | AppSec | Mailbridge's own code. Laptop | High for AppSec | M |
| Exploit development and reversing basics | stack overflows, return-oriented programming, reading binaries in Ghidra | exploit developer, malware analyst | small vulnerable programs in `sandbox`. Proxmox or laptop | Medium | L |
| Wireless attacks | WPA2 handshakes, evil twins, enterprise Wi-Fi | pentester (on-site work) | an access point and adapter you own, in a shielded range of the lab. Proxmox | Nice-to-have | M |
| Reporting and client communication | turning technical results into decisions | every offensive role | every engagement in `05-offensive-engagements.md` | **High** | M |

### 2.2 Defensive

| Idea | What it is, and why companies need it | Role | Practise in the lab | Value | Effort |
|---|---|---|---|---|---|
| SOC triage with runbooks | deciding quickly and consistently what an alert means. The entry-level blue job | SOC analyst L1 | one runbook per rule at level 8+ (`04-security-operations.md`). Both | High | S |
| Windows event and Sysmon literacy | knowing which event proves what | SOC, DFIR, detection | Stage 1 onwards. Both | High | M |
| Detection engineering | writing, testing and maintaining rules as code | detection engineer | the lifecycle in `04`; Sigma in CI at Stage 3. Both | High | M |
| Network security monitoring | Suricata tuning, Zeek, reading captures in Wireshark | SOC, NDR engineer | Suricata (built); Zeek on a mirror port (Proxmox) or Traffic Mirroring (AWS) | High | M |
| A second query language | Wazuh is rare in job adverts; Splunk, Microsoft Sentinel and Elastic are common | SOC analyst | vendor training sandboxes for KQL or SPL (their own platforms, their rules). Outside the lab | Medium–High | M |
| Threat hunting | hypothesis-driven search for what rules missed | hunter, L2/L3 | the six hunts in `04`. Both | Medium–High | M |
| Memory forensics | finding injected code and credentials in RAM with Volatility 3 | DFIR | RAM-included snapshots on Proxmox; in-guest capture on AWS | High for DFIR | M |
| Disk forensics and timelines | artefacts (prefetch, registry, event logs), super-timelines with Plaso | DFIR | a disk image of `ws02` after the Stage 3 operation. Both | High for DFIR | M |
| Velociraptor | querying and collecting from many endpoints at once | DFIR, hunter | `velo01`, Stage 3. Both | High | M |
| Malware analysis basics | static and dynamic analysis in a sandbox | malware analyst, DFIR | `remnux` and `flare` in `sandbox`; start with your own Sliver implants as "samples". Proxmox | Medium | L |
| Threat intelligence | collecting, judging and using indicators and reports | CTI analyst | `misp01`; feed indicators into Suricata and Wazuh lists. Both | Medium | M |
| Deception | honey accounts, a honey SPN, canary files and tokens you host yourself | detection engineer | Stage 2. Tiny effort, near-zero false positives. Both | **High** | S |
| EDR concepts | what an endpoint agent sees and how attackers evade it | SOC, red team | Sysmon + Wazuh active response as a minimal EDR; then compare with an open agent | High | M |
| Cloud detection | turning CloudTrail and GuardDuty into alerts; testing them | cloud security | CloudTrail into Wazuh; trigger detections with an attack-emulation tool in the sandbox account. AWS | High | M |
| E-mail security | SPF, DKIM, DMARC; spam and phishing filtering | mail admin, SOC | Rspamd on `mail01`; records on your own names, internal only. Both | Medium–High | S |
| SOAR and case management | automating response steps; tracking incidents | SOC engineer | `shuffle01`, `thehive01` at Stage 3 (check current editions and licences, verify). Both | Medium | M |

### 2.3 Engineering

| Idea | What it is, and why companies need it | Role | Practise in the lab | Value | Effort |
|---|---|---|---|---|---|
| Hardening and CIS benchmarks | measurable secure configuration | sysadmin, security engineer | Wazuh's configuration assessment; OpenSCAP; hardening roles; score before and after. Both | High | M |
| PKI and certificate lifecycle | issuing, renewing, revoking; offline roots | security engineer | built: easy-rsa, Wazuh CA, ACME. Add `step-ca` or AD CS with auto-enrolment. Both | High | M |
| Secrets management | central, audited, short-lived secrets | security engineer, DevSecOps | `vault01`: dynamic PostgreSQL credentials for Mailbridge, a PKI engine, the "secret zero" problem. Both | High | M |
| Zero trust | access decided per request from identity and device, not from network position | security architect | an identity-aware proxy in front of Grafana and Wazuh via `kc01`; mutual TLS between `proxy` and `app` | Medium–High | M |
| Container security | least-privilege containers; image scanning | DevSecOps | largely built (read-only, no capabilities, digest pins). Add seccomp profiles and rootless mode. Both | High | S |
| Kubernetes security | RBAC, network policies, admission control, runtime detection | cloud security, platform | k3s at Stage 3 (T3.1): Pod Security, Kyverno, Falco, kube-bench. Both | High | L |
| Supply-chain security | knowing and proving what you run: SBOM, signing, provenance | DevSecOps, AppSec | SBOM with Syft, sign images with cosign, verify at deploy; the lab already pins and verifies checksums. Both | High | M |
| CI/CD security | pipelines as attack surface | DevSecOps | T2.2 with OIDC instead of keys; protected environments; `W3-03` | High | M |
| Logging architecture | from source to storage: parsing, normalising, retention, integrity | SIEM engineer | document the pipeline; add a log-silence alert; plan retention tiers. Both | High | M |
| Backup and ransomware resilience | backups an attacker with admin rights can't destroy | sysadmin, security engineer | `bkp01` isolation; a harmless "ransomware" script on a test share in `sandbox`, then recover against the RTO | High | M |
| Network engineering | routing, VLANs, IPsec and WireGuard, 802.1X | network or security engineer | every stage. Proxmox for layer 2 | High (foundation) | M |
| Policy as code | rules that fail a build when infrastructure breaks policy | cloud security, DevSecOps | custom checkov policies for the guardrails in `CLAUDE.md` (no NAT Gateway, IMDSv2 required). AWS | Medium–High | S |
| Database security | roles, TLS, auditing, row-level security | DBA, security engineer | built: two roles. Add `pgaudit` and TLS between `app` and `db` | Medium | S |
| Linux internals for security | systemd sandboxing, AppArmor, auditd, eBPF | Linux security engineer | built: sandboxed units. Add AppArmor profiles and auditd rules shipped to Wazuh | High | M |
| Scripting and tooling | Python, PowerShell, Bash: writing your own small tools | everyone | the scope wrapper, exporters, evidence scripts. Ongoing | High | ongoing |

### 2.4 Governance, risk and compliance

| Idea | What it is, and why companies need it | Role | Practise in the lab | Value | Effort |
|---|---|---|---|---|---|
| A controls baseline per size | the CIS Controls define three implementation groups by company maturity | everyone | map Stage 1 to IG1, Stage 2 to IG2, Stage 3 to IG3 and tick what the lab implements | High | S |
| ISO 27001 | a management system for security: scope, risk assessment, Statement of Applicability, internal audit | GRC analyst, security lead | task T3.3: start the controls map at Stage 1 as a living document, finish at Stage 3 | High (for GRC) | M |
| Risk assessment | finding, rating and treating risk; the risk register | GRC, security lead | a register with ten real entries from the lab (the accepted CRS gap is entry one) | High | S |
| GDPR | lawful processing of personal data. Mailbridge processes other people's e-mail, which is as personal as data gets | GRC, privacy, every engineer in the EU | write a record of processing and a data protection impact assessment for Mailbridge; a breach-notification draft in an incident exercise | High | M |
| NIS2 | EU rules for security and incident reporting in important sectors | GRC, security lead | a one-page applicability analysis for Quillmere and a map of its measures to lab controls | Medium–High | S |
| Policies | short written rules that controls then enforce | GRC | six one-page policies: access control, authentication, backup, change, incident response, acceptable use. Each links to the control that enforces it | Medium | M |
| Internal audit | checking that a control really operates, by sampling evidence | auditor | audit yourself: pick five leavers, five changes, five patches and look for the evidence | Medium–High | S |
| Business continuity and disaster recovery | keeping the business running when IT fails | GRC, sysadmin | a business impact analysis for Mailbridge; a DR exercise: rebuild `prod` in another region or on the other platform, timed | Medium–High | M |
| Security awareness | changing staff behaviour, measured | awareness lead | the phishing campaign's numbers; a ten-minute training; a second campaign | Medium | S |
| Third-party risk | judging suppliers and sub-processors | GRC | on paper only: list Quillmere's suppliers, read their public assurance reports, write the assessment | Medium | S |
| Compliance as code | evidence produced by pipelines instead of screenshots | GRC engineer | map checkov and Wazuh checks to control IDs; generate the evidence list | Medium | M |

### 2.5 Other

| Idea | What it is, and why companies need it | Role | Practise in the lab | Value | Effort |
|---|---|---|---|---|---|
| AI security | attacks on applications that use language models, above all prompt injection through untrusted content | AppSec, security researcher | add an optional "summarise this e-mail" feature to Mailbridge behind a flag and test indirect prompt injection through incoming mail; see `07-extra-ideas.md` | High and rising | M |
| Purple-team programme | scheduled, measured red-blue cooperation | detection lead | a quarterly schedule of atomic tests with the coverage matrix as the report | High | S |
| CTFs | timed practice and a team | everyone, early on | a university team; write up every challenge you solve | Medium–High | ongoing |
| Community contributions | fixes and rules upstream | everyone | the lab already found real things worth reporting or documenting (CRS false positives, a Suricata keyword's timing). Sigma rules, documentation fixes | High for visibility | S each |
| Writing and speaking | blog posts; a talk at a student or local meetup | everyone | one post per stage; one talk per year | High | S each |
| OT and ICS basics | industrial protocols and why they are fragile | OT security | an isolated VLAN with a soft PLC and a Modbus honeypot. Proxmox | Nice-to-have (High if you aim at industry or energy) | M |
| Mobile security | testing Android and iOS apps | mobile pentester | only if Mailbridge gets a mobile client: emulator, static analysis, an instrumentation tool | Nice-to-have | M |
| Cryptography in practice | how TLS, key derivation and signatures fail when misused | AppSec, architect | university courses, plus review Mailbridge's token encryption design | High (foundation) | course |
| Interviewing | explaining your own decisions under questions | you | `08-interview-prep.md`; mock interviews with a colleague | High | S |

### 2.6 If time is short: the twelve that matter most

1. Web and API testing with a written report.
2. Windows AD administration, then AD attacks, on the same domain.
3. Windows event and Sysmon literacy.
4. Detection engineering with tests.
5. SOC triage runbooks.
6. Cloud IAM: least privilege, then privilege escalation.
7. Hardening measured against a benchmark.
8. Secrets management and PKI.
9. CI/CD and supply-chain security.
10. One second query language (KQL or SPL).
11. Risk assessment and one framework (ISO 27001 or CIS Controls) well understood.
12. Writing: reports, runbooks, postmortems.

---

## 3. Certifications: what each is for

Certificates open filters in hiring. The lab and its write-ups prove the skill. You need a few
of the first and a lot of the second. **Don't collect them all; pick one per direction.**

| Certification (verify all) | Direction | What it proves | Fits after | Comment |
|---|---|---|---|---|
| CompTIA Security+ | general | broad vocabulary | Stage 0 | useful as an HR filter in some markets; skip if money is tight and you have a degree in progress |
| CCNA | networking | real networking fundamentals | any time | undervalued by security students; makes everything else easier |
| AWS Solutions Architect Associate | cloud | how AWS fits together | Stage 0 | you already do most of it |
| AWS Security Specialty | cloud security | IAM, logging, detection, encryption on AWS | Stage 2–3, AWS track | strong signal for cloud security roles |
| HashiCorp Terraform Associate | IaC | Terraform basics | Stage 0 | easy for you; low cost |
| eJPT | offensive entry | basic practical pentesting | Stage 0 | a gentle first practical exam |
| PNPT | offensive | an external and internal AD test with a report and a debrief | Stage 1–2 | closest in format to real consulting work |
| CRTP | AD attacks | AD enumeration and attack paths | Stage 2 | affordable, focused |
| OSCP (now issued as OSCP+) | offensive | hands-on exploitation under time pressure | Stage 2, around M1 | the most recognised name in job adverts; expensive |
| CRTO | red team | operating with a C2, evasion | Stage 3 | for a red team direction |
| Burp Suite Certified Practitioner | web | advanced web exploitation | after Stage 0, if AppSec appeals | pairs with the free Web Security Academy |
| BTL1 | defensive entry | practical SOC and investigation | Stage 1 | a good practical blue start |
| HTB CDSA or CyberDefenders CCD | defensive | SOC analysis, DFIR basics | Stage 2 | alternatives to BTL1's next level |
| Microsoft SC-200 | SOC on Microsoft's stack | Sentinel, Defender, KQL | Stage 2 | high job relevance: many SOCs run this stack |
| Microsoft SC-300 | identity | Entra ID administration | Stage 2–3 | for an identity direction |
| CKA, then CKS | Kubernetes | cluster administration, then security | Stage 3 | CKS requires CKA |
| ISO 27001 Lead Implementer or Lead Auditor | GRC | understanding the standard | Stage 3 | for a GRC direction |
| ISC2 CC, later CISSP | general, management | breadth; CISSP needs years of experience (an associate status exists) | after graduation | CISSP is a mid-career goal, not a student one |
| GIAC certifications | specialist | deep, respected | when an employer pays | too expensive to self-fund |

**Options for a main certification line**

| Option | Line | For whom |
|---|---|---|
| **A (recommended while undecided)** | BTL1 → PNPT or CRTP → AWS Security Specialty or SC-200 → OSCP | keeps offence, defence and cloud open |
| B Offensive | eJPT → PNPT → OSCP → CRTO | you're sure about pentesting or red team |
| C Defensive | BTL1 → SC-200 → a DFIR-oriented exam | you're sure about SOC, detection or DFIR |
| D Cloud and DevSecOps | AWS SAA → AWS Security Specialty → CKA → CKS | you're sure about cloud security |
| E GRC | Security+ → ISO 27001 Lead Implementer → later CISA or CISSP | you're sure about governance |

**The concept behind option A:** hiring managers for junior roles look for evidence that you
can do the practical work and that you understand the other side. One practical blue exam, one
practical red exam and one platform exam show that with three purchases.

---

## 4. The semester plan

### 4.1 Ten semesters

| Semester | Main theme | Lab stage and platform | Skills from the catalogue | Certification (optional) | Portfolio piece |
|---|---|---|---|---|---|
| **B1** | foundations | none yet: a Linux VM on your laptop | networking, Linux, Python, Git | — | a public Git profile with small scripts |
| **B2** | cloud and infrastructure as code | **Stage 0 blue** (done): the built lab | Terraform, Ansible, firewalls, VPN, PKI, SIEM basics | Terraform Associate or AWS SAA | the Tier 1 write-up (exists) |
| **B3** | web security and first detections | **Stage 0 red and purple**: tasks 2.17, 2.14, 2.15, 2.2–2.5, then T2.2–T2.4 | web and API testing, WAF tuning, SOC triage runbooks, reporting | eJPT, or start the Web Security Academy | web and cloud pentest report; blog post 1; first CTF write-ups |
| **B4** | Windows, AD and operations | **Stage 1 blue**: office network, AD, files, mail, workstations | AD administration, GPO, LAPS, hardening, the eight operations flows, Windows logging | BTL1 | runbooks; a restore-test record; a CIS score before and after |
| **B5** | first intrusion, first investigation | **Stage 1 red and purple**; start **Stage 2 blue** | phishing, password attacks, Windows privilege escalation, detection engineering, deception | PNPT or CRTP | external and assumed-breach reports; first ATT&CK layer; blog post 2 |
| **B6** | bachelor thesis; segmentation and SSO | **Stage 2 blue** complete | segmentation, Keycloak, AD CS, patch and vulnerability management, access review | — (thesis first) | the thesis; a vulnerability-management dashboard |
| **M1** | internal attack and coverage | **Stage 2 red and purple** | AD and AD CS attacks, layer-2 attacks (Proxmox), Atomic Red Team, threat hunting, a second query language | OSCP, or SC-200 | internal pentest report with before-and-after paths; published Sigma or Wazuh rules |
| **M2** | cloud security and DevSecOps | **Stage 3, part 1**: k3s, `vault01`, CI/CD and supply chain, AWS multi-account | Kubernetes security, secrets, signing, IAM attack paths, cloud detection | AWS Security Specialty, or CKA/CKS | a signed, SBOM-tracked delivery pipeline; a cloud attack-and-detect write-up |
| **M3** | red team, DFIR and GRC | **Stage 3, part 2**: tier model, PAM, SOC tooling, branch | C2 and OPSEC, memory and disk forensics, Velociraptor, IR plan and tabletop, ISO 27001 map, GDPR documents | CRTO, or ISO 27001 Lead Implementer | red team report with executive summary; blue postmortem; controls map |
| **M4** | master thesis | the lab as the experiment platform | whatever the thesis needs | — | the thesis; a conference or meetup talk |

### 4.2 Starting in the middle

Find the first row whose **lab stage** you haven't finished and start there, whatever your real
semester is. Stage 0 blue is done, so today that row is **B3**.

| Semesters you have left | How to compress |
|---|---|
| 8 or more | follow the table from B3 as written |
| 6 | merge B4+B5 (Stage 1 in one semester) and M2+M3 (Stage 3 without the branch office and SOAR) |
| 4 | Stage 1 in one semester; Stage 2 in two; from Stage 3 take only k3s, Vault and the tier model, as a thesis platform |
| 2 | finish Stage 0's Tier 2 tasks and build Stage 1. A finished small thing beats an unfinished large one |

**The rule that outranks the calendar:** don't start a stage before the previous stage's
write-up exists. A lab with four half-built stages shows nothing.

### 4.3 A sustainable rhythm

| Per week | What |
|---|---|
| 1–2 sessions | lab work, one roadmap step each, ending with the `progress.md` and `lessons.md` updates you already do |
| 1 short block | one practice exercise outside the lab (a web lab, a CTF challenge, a forensic image) |
| 30 minutes | reading: one incident report or one vendor's technical write-up, and note which lab control would have helped |

| Per semester | What |
|---|---|
| 1 | a stage milestone with a write-up |
| 1 | a public piece: blog post, talk or upstream contribution |
| 0–1 | a certification, never during exam weeks |

---

## 5. Portfolio: what to show an employer

| Piece | From | Shows | Aimed at |
|---|---|---|---|
| The repository itself: decisions, rationale, write-ups | all stages | engineering judgment; you explain trade-offs | everyone |
| Tier 1 write-up | Stage 0 (exists) | building and verifying a layered design | engineering, cloud |
| Web and cloud pentest report with per-layer detection | Stage 0 | attack and defence in one piece | pentest, AppSec, SOC |
| Runbooks and a restore-test record | Stage 1 | you can operate, not only build | sysadmin, security engineering |
| Assumed-breach report with an attack-path diagram | Stage 1 | consulting-style reporting | pentest |
| ATT&CK Navigator layer with test dates | Stages 1–3 | honest coverage measurement | detection, SOC |
| Detection rules with tests, some upstream | Stages 1–3 | detection as code | detection engineering |
| Internal AD pentest report, before and after | Stage 2 | the most in-demand internal testing skill, and the fix | pentest, identity |
| Vulnerability-management report over three cycles | Stage 2 | process over time | vulnerability management, GRC |
| A pipeline with SBOM, signing and policy checks | Stage 3 | DevSecOps | AppSec, cloud |
| Red team report with a one-page executive summary, plus the blue postmortem | Stage 3 | communication to management | red team, IR, senior roles |
| ISO 27001 controls map with evidence links; GDPR documents for Mailbridge | Stage 3 | compliance grounded in real controls | GRC |
| Two theses | B6, M4 | sustained, supervised work | everyone |

**How to present it.** One landing page (the repository README) with a diagram, the stage you've
reached, and links to four or five pieces. A reviewer gives you two minutes; make the first
screen show what you built and what you measured.

---

## 6. What to leave out on purpose

- **Every tool in a category.** One SIEM deeply, one second query language for the job market.
- **Advanced exploit development** before you can explain Kerberos. It is a specialisation.
- **Stage 3 tools at Stage 1.** SOAR without alerts and PAM without admins teach the install,
  not the purpose.
- **Certificates as a hobby.** Each one costs weeks. Pick by the direction you chose in section 3.
- **A second platform too early.** Finish a stage on one platform before repeating it on the
  other (`comparison.md`).
