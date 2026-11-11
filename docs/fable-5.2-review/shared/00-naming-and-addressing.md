# 00 · Naming and addressing

> **Status: PROPOSED**, except rows marked **Stage 0 (built)**, which repeat `docs/ARCHITECTURE.md`.
> This file is the single source for names, addresses, VLAN IDs and groups. Every other file in
> the set must agree with it. If you change something, change it here first.

> **Assumptions**
>
> 1. "Quillmere" is an invented name (verify that no real company uses it before publishing).
> 2. The office uses 10.20.0.0/16 and the branch 10.30.0.0/16, as the prompt suggested.
> 3. The AD DNS name is `corp.<domain>`, a subdomain of the lab's existing delegated subdomain.
>    It is never published in public DNS.
> 4. People in this file are invented personas. They are not real persons.

---

## 1. The company

| Fact | Value |
|---|---|
| Name | **Quillmere** (fictional) |
| Business | Sells Mailbridge, a unified Gmail and Outlook inbox, as a hosted product |
| Why it is a good subject | It handles other people's mail tokens, so confidentiality matters; it starts cloud-only and later needs an office, which is how many software companies really grow |
| Public DNS name | `<domain>` (the existing delegated subdomain; the real name never appears in the repo) |
| Internal AD DNS name | `corp.<domain>` |
| AD NetBIOS name | `CORP` |

**Why `corp.<domain>` and not `quillmere.local`.** A made-up top-level name such as `.local`
collides with multicast DNS, can't get public certificates, and is a classic interview question.
Microsoft's guidance is a subdomain of a name you own. The subdomain is served only by the
domain controllers, so the internal names never leak into public DNS.

---

## 2. Sites and address plan

| Site | CIDR | What it is | Platform |
|---|---|---|---|
| `prod` | 10.0.0.0/16 | Cloud production: Mailbridge, SIEM, monitoring. **Stage 0 (built)** | AWS VPC; on Proxmox-only, a copy with the same addresses |
| VPN users | 10.8.0.0/24 | OpenVPN user pool. **Stage 0 (built)** | `fw-ips` |
| VPN admins | 10.8.1.0/24 | OpenVPN admin pool. **Stage 0 (built)** | `fw-ips` |
| VPN staff | 10.8.2.0/24 | **PROPOSED, Stage 1:** staff remote access to office resources; certificate plus AD credentials | `fw-ips` |
| tunnel | 10.9.0.0/24 | Site-to-site tunnel addresses only: `fw-ips` .1, `hq-fw` .2, `br-fw` .3 | all |
| `hq` | 10.20.0.0/16 | Headquarters office | AWS second VPC, or Proxmox VLANs |
| `branch` | 10.30.0.0/16 | Branch office (Stage 3) | AWS third VPC, or Proxmox VLANs |
| `sim-inet` | 198.51.100.0/24 | Simulated internet between sites. Proxmox only | Proxmox VLAN 900 |
| `sandbox` | 10.66.0.0/24 | Malware analysis. No gateway, no route anywhere | Proxmox, on its own bridge `vmbr66` (VLAN 966 is only its label) |

**Why these ranges.** The three sites don't overlap, so they can be routed together through
tunnels, and an address tells you the site at a glance: second octet 0 is production, 20 is HQ,
30 is the branch. 198.51.100.0/24 is TEST-NET-2, reserved for documentation, so it can never
collide with a real internet address and is safe to print in a public repository.

**One improvement over the prompt's suggestion.** The prompt's plan had no address space for the
tunnels themselves or for a simulated internet. Both are added above. A separate tunnel range
keeps tunnel endpoints out of every site's firewall rules; a simulated internet gives the external
pentest somewhere realistic to start from on Proxmox.

### 2.1 Subnets and VLANs

**VLAN ID rule:** site digit (1 = prod, 2 = HQ, 3 = branch) followed by the third octet as two
digits. 10.20.30.0/24 is VLAN 230. On AWS there are no VLANs; the same names are subnets.

| VLAN | Name | CIDR | From stage | Purpose |
|---|---|---|---|---|
| 101 | `public` | 10.0.1.0/24 | 0 (built) | `fw-ips` only |
| 102 | `dmz` | 10.0.2.0/24 | 0 (built) | `proxy` |
| 103 | `app` | 10.0.3.0/24 | 0 (built) | `app`; k3s nodes at Stage 3 |
| 104 | `data` | 10.0.4.0/24 | 0 (built) | `db` |
| 105 | `mgmt` | 10.0.5.0/24 | 0 (built) | `siem`, `mon` |
| 106 | `vuln` | 10.0.6.0/24 | 0 (built) | `vuln` (Juice Shop) |
| 200 | `hq-edge` | 10.20.0.0/24 | 1 | AWS only: the public subnet that holds `hq-fw` |
| 210 | `hq-mgmt` | 10.20.10.0/24 | 1 | IT administration hosts |
| 220 | `hq-servers` | 10.20.20.0/24 | 1 | domain controllers, file, mail and application servers |
| 230 | `hq-users` | 10.20.30.0/24 | 1 | workstations |
| 240 | `hq-dmz` | 10.20.40.0/24 | 2 | hosts that accept traffic from outside the office |
| 250 | `hq-guest` | 10.20.50.0/24 | 2 | visitors: internet only |
| 260 | `hq-iot` | 10.20.60.0/24 | 2 | printers and other unmanaged devices |
| 270 | `hq-backup` | 10.20.70.0/24 | 2 | backup server, isolated from the domain |
| 280 | `hq-sec` | 10.20.80.0/24 | 3 | SOC tooling |
| 290 | `hq-paw` | 10.20.90.0/24 | 3 | privileged access workstations |
| 299 | `hq-red` | 10.20.99.0/24 | 1 | the attacker's foothold and red infrastructure |
| 300 | `br-edge` | 10.30.0.0/24 | 3 | AWS only: the public subnet that holds `br-fw` |
| 320 | `br-servers` | 10.30.20.0/24 | 3 | branch domain controller |
| 330 | `br-users` | 10.30.30.0/24 | 3 | branch workstations |
| 900 | `sim-inet` | 198.51.100.0/24 | 1 | Proxmox only: simulated internet |
| 966 | `sandbox` | 10.66.0.0/24 | 2 | Proxmox only: malware analysis, no gateway |

**Addressing rules inside a subnet**

| Range | Use |
|---|---|
| .1 | gateway (`hq-fw` or `br-fw` on Proxmox; the VPC router on AWS) |
| .10–.99 | servers, fixed addresses |
| .101–.199 | workstations (fixed in the lab so logs are easy to read; a DHCP pool on Proxmox) |
| .200–.254 | spare |

**Lab vs real.** A real 30-person company usually has one flat /24 for everything. The plan gives
Stage 1 separate `hq-servers` and `hq-users` networks from the start, **with an allow-all rule
between them** (weakness `W1-02`). This keeps the realistic weakness, flat trust, while letting
Stage 2 fix it by changing firewall rules rather than renumbering a domain controller, which is
painful and teaches little.

---

## 3. Hosts

One name, one address, on every platform. "OS" is a proposal; versions are (verify).

### 3.1 Production site, 10.0.0.0/16: Stage 0 (built)

| Host | Address | Role |
|---|---|---|
| `fw-ips` | 10.0.1.10 | OpenVPN, nftables, NAT, Suricata inline, Unbound; from Stage 1 also the tunnel endpoint 10.9.0.1 |
| `proxy` | 10.0.2.10 | Nginx, ModSecurity with the CRS, lego |
| `app` | 10.0.3.10 | Mailbridge in Docker |
| `db` | 10.0.4.10 | PostgreSQL |
| `siem` | 10.0.5.10 | Wazuh manager, indexer, dashboard |
| `mon` | 10.0.5.20 | Prometheus, Alertmanager, Grafana |
| `vuln` | 10.0.6.10 | OWASP Juice Shop |
| `k3s01`–`k3s03` | 10.0.3.21–23 | **PROPOSED, Stage 3:** k3s nodes for the app tier (task T3.1) |

### 3.2 Headquarters, 10.20.0.0/16: PROPOSED

| Host | Address | Stage | OS | Role |
|---|---|---|---|---|
| `hq-fw` | .1 on every HQ VLAN (Proxmox); 10.20.0.10 (AWS) | 1 | OPNsense (Proxmox); Ubuntu with nftables and Suricata (AWS) | perimeter firewall, inter-VLAN routing, IPS, tunnel endpoint 10.9.0.2 |
| `dc01` | 10.20.20.10 | 1 | Windows Server | first domain controller: AD DS, DNS, and DHCP on Proxmox |
| `fs01` | 10.20.20.20 | 1 | Windows Server | file server: SMB shares, plus plain FTP as `W1-01` |
| `mail01` | 10.20.20.30 | 1 | Ubuntu Server | internal mail: Postfix, Dovecot, Rspamd, Roundcube |
| `ws01` | 10.20.30.101 | 1 | Windows client | Finance workstation |
| `ws02` | 10.20.30.102 | 1 | Windows client | Engineering workstation |
| `ws03` | 10.20.30.103 | 1 | Ubuntu Desktop | Linux workstation joined to AD |
| `kali-int` | 10.20.99.10 | 1 | Kali Linux | attacker foothold inside the office |
| `phish01` | 10.20.99.20 | 1 | Ubuntu Server | GoPhish, lab users only |
| `vault01` | 10.20.10.50 | 3 on AWS; **1 on Proxmox** | Ubuntu Server | secret store (Vault or OpenBao); on Proxmox it replaces SSM Parameter Store from the start |
| `dc02` | 10.20.20.11 | 2 | Windows Server | second domain controller |
| `ca01` | 10.20.20.15 | 2 | Windows Server | AD CS enterprise CA |
| `wsus01` | 10.20.20.40 | 2 | Windows Server | patch management |
| `kc01` | 10.20.20.50 | 2 | Ubuntu Server | Keycloak: SSO |
| `glpi01` | 10.20.20.60 | 2 | Ubuntu Server | tickets and asset inventory |
| `intra01` | 10.20.20.70 | 2 | Windows Server | internal line-of-business web app (IIS, SQL Server Express) running as `svc-intra` |
| `mx01` | 10.20.40.10 | 2 | Ubuntu Server | mail gateway in the DMZ, relays to `mail01` |
| `ops01` | 10.20.10.10 | 2 on AWS; **1 on Proxmox** | Ubuntu Server | automation host: Ansible control node, where merged changes are applied; on Proxmox also the container registry, so it is needed from the start |
| `gvm01` | 10.20.10.30 | 2 | Ubuntu Server | Greenbone vulnerability scanner (task T3.2) |
| `bkp01` | 10.20.70.10 | 2 | Ubuntu Server (AWS: restic to S3) or Proxmox Backup Server | backup server |
| `prn01` | 10.20.60.10 | 2 | Linux | simulated printer with default credentials (`W2-08`) |
| `ws04`, `ws05` | 10.20.30.104–105 | 2 | Windows client | Sales and HR workstations |
| `pam01` | 10.20.10.40 | 3 | Ubuntu Server | privileged access management (Teleport or JumpServer) |
| `radius01` | 10.20.10.60 | 3 | Ubuntu Server | FreeRADIUS for 802.1X (Proxmox) |
| `thehive01` | 10.20.80.10 | 3 | Ubuntu Server | case management |
| `shuffle01` | 10.20.80.20 | 3 | Ubuntu Server | SOAR |
| `misp01` | 10.20.80.30 | 3 | Ubuntu Server | threat intelligence |
| `velo01` | 10.20.80.40 | 3 | Ubuntu Server | Velociraptor server |
| `paw-t0` | 10.20.90.10 | 3 | Windows client | Tier 0 admin workstation |
| `paw-t1` | 10.20.90.11 | 3 | Windows client | Tier 1 admin workstation |
| `c2-01` | 10.20.99.30 | 3 | Ubuntu Server | C2 server (Sliver), no internet route |

### 3.3 Branch, 10.30.0.0/16: PROPOSED, Stage 3

| Host | Address | OS | Role |
|---|---|---|---|
| `br-fw` | .1 on every branch VLAN (Proxmox); 10.30.0.10 (AWS) | as `hq-fw` | branch firewall, tunnel endpoint 10.9.0.3 |
| `dc03` | 10.30.20.10 | Windows Server | read-only domain controller in the AD site `Branch` |
| `ws-br01` | 10.30.30.101 | Windows client | branch workstation |

### 3.4 Proxmox-only hosts: PROPOSED

| Host | Address | Stage | Role |
|---|---|---|---|
| `pve01` | home LAN address `<pve-home-ip>`; from Stage 2 optionally also 10.20.10.5 | 1 | the Proxmox host itself |
| `isp-rtr` | 198.51.100.1, plus `<isp-rtr-home-ip>` | 1 | the only VM connected to the home network; NAT for the simulated internet; the kill switch |
| `fw-ips` (copy) | 198.51.100.10 outside, 10.0.1.10 inside | 1 | the production firewall's simulated public address |
| `hq-fw` | 198.51.100.20 outside | 1 | the office firewall's simulated public address |
| `br-fw` | 198.51.100.30 outside | 3 | the branch firewall's simulated public address |
| `kali-ext` | 198.51.100.66 | 1 | the external attacker on the simulated internet |
| `redir01` | 198.51.100.80 | 3 | C2 redirector on the simulated internet |
| `pbs01` | 10.20.70.10 (it **is** `bkp01` on Proxmox) | 2 | Proxmox Backup Server |
| `nsm01` | 10.20.10.70, plus a capture interface with no address | 2 | network sensor (Zeek, Suricata in detection mode) on a mirror of the office VLANs |
| `remnux` | 10.66.0.10 | 2 | malware analysis, Linux tools |
| `flare` | 10.66.0.20 | 2 | malware analysis, Windows |

---

## 4. Active Directory names: PROPOSED

### 4.1 Structure

| Item | Value |
|---|---|
| Forest and domain | one forest, one domain: `corp.<domain>` |
| NetBIOS name | `CORP` |
| AD sites | `HQ` (10.20.0.0/16); `Branch` (10.30.0.0/16) from Stage 3 |
| Functional level | the highest your Windows Server version supports (verify) |

```
corp.<domain>
├── OU=Quillmere
│   ├── OU=Staff                users, by department
│   │   ├── OU=Management
│   │   ├── OU=Engineering
│   │   ├── OU=Finance
│   │   ├── OU=HR
│   │   ├── OU=Sales
│   │   └── OU=IT
│   ├── OU=Groups
│   │   ├── OU=Roles            who people are
│   │   ├── OU=Access           what a group may touch
│   │   └── OU=Apps             which role a group holds in a tool
│   ├── OU=Workstations
│   ├── OU=Servers
│   └── OU=ServiceAccounts
├── OU=Admin                    Stage 3: tier model
│   ├── OU=Tier0
│   ├── OU=Tier1
│   └── OU=Tier2
└── OU=Disabled                 leavers, kept 30 days
```

### 4.2 Groups

Three kinds of group, following AGDLP: people go into **role** groups, role groups go into
**access** and **app** groups, and only access and app groups appear in permissions.

| Kind | Prefix or name | Examples |
|---|---|---|
| Role (global) | plain names | `All-Staff`, `Management-Staff`, `Engineering-Staff`, `Finance-Staff`, `HR-Staff`, `Sales-Staff`, `IT-Helpdesk`, `IT-Admins`, `Server-Admins`, `Network-Admins`, `SOC-Analysts`, `SOC-Engineers`, `Auditors` |
| Access (domain local) | `ACL-` | `ACL-FS-Finance-RW`, `ACL-FS-Finance-RO`, `ACL-FS-HR-RW`, `ACL-FS-Public-RO`, `ACL-FS-Engineering-RW` |
| App (domain local) | `APP-` | `APP-Wazuh-ReadOnly`, `APP-Wazuh-Admin`, `APP-Grafana-Viewer`, `APP-Grafana-Editor`, `APP-Grafana-Admin`, `APP-Firewall-ReadOnly`, `APP-Firewall-Admin`, `APP-PVE-Auditor`, `APP-PVE-Admin`, `APP-AWS-ReadOnly`, `APP-AWS-Admin`, `APP-GLPI-Technician`, `APP-VPN-Users`, `APP-VPN-Admins` |
| Tier (Stage 3) | `T0-`, `T1-`, `T2-` | `T0-Admins`, `T1-Admins`, `T2-Admins` |

`SOC-Analysts` is a member of `APP-Wazuh-ReadOnly` and `APP-Grafana-Viewer`: read-only, as the
prompt asked. The full matrix is in `shared/02-identity-and-access.md`, section 4.

### 4.3 Personas and accounts

Invented people. Sign-in names follow `initial.surname`; admin accounts are separate and
prefixed.

| Persona | Sign-in | Department | Role groups | Notes |
|---|---|---|---|---|
| Mira Castell | `m.castell` | Management | `Management-Staff` | the CEO; the phishing test's high-value target |
| Jonas Brandt | `j.brandt`, plus `adm-j.brandt` | IT | `IT-Admins` | the IT generalist: this is you in the blue role |
| Lena Voss | `l.voss` | Finance | `Finance-Staff` | uses `ws01` |
| Tomas Rhee | `t.rhee` | Engineering | `Engineering-Staff` | uses `ws02`; a developer with too many rights |
| Nadia Okoro | `n.okoro` | HR | `HR-Staff` | starts the joiner and leaver flows |
| Omar Haddad | `o.haddad` | Sales | `Sales-Staff` | Stage 2 |
| Petra Lindqvist | `p.lindqvist` | IT | `SOC-Analysts` | Stage 2: the first security hire |
| Ivo Maren | `i.maren` | IT | `IT-Helpdesk` | Stage 2: helpdesk |

| Account type | Pattern | Examples |
|---|---|---|
| Standard user | `initial.surname` | `l.voss` |
| Admin, Stages 1–2 | `adm-` + user | `adm-j.brandt` |
| Admin, Stage 3 | `t0-`, `t1-`, `t2-` + user | `t0-j.brandt`, `t1-j.brandt` |
| Service account | `svc-` + service | `svc-intra`, `svc-backup`, `svc-ldap-wazuh`, `svc-ldap-grafana`, `svc-glpi`, `svc-scan` |
| Break-glass | `bg-` + number | `bg-01`: password sealed offline, alert on every use |
| Attacker (VPN certificate) | `attacker` | **Stage 0 (built)**, decision 73 |

---

## 5. DNS names

| Name | Resolves to | Served by | Visible publicly? |
|---|---|---|---|
| `vpn.<domain>` | the public address of `fw-ips` | Route 53. **Stage 0 (built)** | yes |
| `mail.<domain>` | 10.0.2.10 | Unbound on `fw-ips`. **Stage 0 (built)** | no |
| `vuln.<domain>` | 10.0.2.10 | Unbound on `fw-ips`. **Stage 0 (built)** | no |
| `<host>.corp.<domain>` | the host's HQ or branch address | `dc01`, `dc02` | no |
| `webmail.corp.<domain>` | 10.20.20.30 | DCs | no |
| `sso.corp.<domain>` | 10.20.20.50 | DCs | no |
| `tickets.corp.<domain>` | 10.20.20.60 | DCs | no |
| `intranet.corp.<domain>` | 10.20.20.70 | DCs | no |

**Note on the name "mail".** `mail.<domain>` is the Mailbridge product (Stage 0). The company's
own internal mail server is `mail01`, reached as `webmail.corp.<domain>`. Don't confuse them: one
is what Quillmere sells, the other is what Quillmere's staff use.

Resolution between sites uses **conditional forwarders**: the DCs forward `mail.<domain>` and
`vuln.<domain>` to Unbound at 10.0.1.10; Unbound forwards `corp.<domain>` to 10.20.20.10 and
10.20.20.11. Both directions cross the site-to-site tunnel.

---

## 6. Naming rules

| Object | Rule | Example |
|---|---|---|
| Host | role + two digits, lower case, no site prefix at HQ; `br-` prefix at the branch | `dc01`, `ws-br01` |
| Firewall | site + `-fw` | `hq-fw`, `br-fw` (the built `fw-ips` keeps its name) |
| Terraform stack | one per site and lifetime | `terraform/persistent`, `terraform/lab` (built); `terraform/hq`, `terraform/branch` (PROPOSED) |
| Ansible role | host role with underscores (decision 26) | `hq_fw`, `dc`, `fs`, `mail_internal`, `workstation_windows` |
| Ansible group | the role name, from the host's `Role` tag (decision 45) | `dc`, `fs`, `workstation` |
| AWS tag | `Project=mailbridge-lab`, `Role=<role>`, and PROPOSED `Site=prod` / `hq` / `branch`, `Stage=0`…`3` | |
| GPO | `GPO-` + scope + purpose | `GPO-Workstations-Baseline`, `GPO-Servers-Audit` |
| Weakness | `W` + stage + number | `W2-01` |
| Roadmap step | `S` + stage + platform + number | `S1-A04`, `S1-P04` |
| Wazuh local rule IDs | 100100–100299 used (built); PROPOSED 100300–100499 for Windows and AD, 100500–100699 for mail and identity | |
| Suricata local SIDs | 1000001–1000007 used (built); PROPOSED 1000100–1000199 for HQ rules | |

---

## 7. What differs between platforms

The names and addresses above are the same everywhere. These are the only differences.

| Item | AWS | Proxmox |
|---|---|---|
| "VLAN" | a subnet; no VLAN tags exist | a VLAN on a VLAN-aware bridge |
| Gateway of a subnet | the VPC router at .1; route tables send traffic to the `hq-fw` interface | `hq-fw` itself at .1 |
| `hq-fw` software | Ubuntu, nftables, Suricata (the `fw_ips` role's pattern) | OPNsense with Suricata |
| `hq-fw` outside address | an Elastic IP in `hq-edge` | 198.51.100.20 on `sim-inet` |
| DHCP | AWS hands out addresses; the DC can't be a DHCP server | `dc01` serves DHCP |
| Windows client | Windows Server standing in for a workstation, or WorkSpaces | Windows client evaluation media |
| Secret store | SSM Parameter Store (built) | `vault01` |
| Container registry | ECR (built) | a registry on `ops01` |
| Backup server | restic or `pg_dump` to S3 | `pbs01` |
| `sim-inet`, `sandbox`, `kali-ext`, `redir01`, `radius01` | don't exist | exist |
