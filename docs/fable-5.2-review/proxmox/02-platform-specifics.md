# Proxmox 02 · Platform specifics

> **Status: PROPOSED.** Hardware, networking, the replacements for AWS services, infrastructure
> as code, backups, isolation, and the "reset the whole range" procedure for the Proxmox version.

> **Assumptions**
>
> 1. **Every price, wattage and noise description is a rough estimate from memory and marked
>    (verify).** Hardware prices, and memory prices in particular, move a lot; check current
>    listings in your country before deciding.
> 2. Your electricity tariff, the room the server will stand in and your budget are unknown.
> 3. Product features (Proxmox VE, Proxmox Backup Server, the Terraform provider, OPNsense) are
>    from memory (verify against current documentation and versions).
> 4. Windows evaluation licence terms are from memory (verify the current terms on Microsoft's
>    site; evaluation media are for testing, which is what this is).

---

## 1. Hardware

### 1.1 Memory decides everything

CPU is rarely the limit in a lab: most VMs idle. Memory is. Size it from the host list.

| Group | VMs and memory (GB) | Subtotal |
|---|---|---|
| Hypervisor | Proxmox itself, plus the ZFS cache if you use ZFS (cap it) | 6–10 |
| Production copy | `fw-ips` 2 · `proxy` 1 · `app` 2 · `db` 1 · `siem` 8 · `mon` 2 · `vuln` 2 | 18 |
| Platform services | `isp-rtr` 0.5 · `ops01` 2 · `vault01` 1 | 3.5 |
| **Stage 1** | `hq-fw` 2–4 · `dc01` 4 · `fs01` 4 · `mail01` 3 · `ws01` 4 · `ws02` 4 · `ws03` 4 · `kali-int` 4 · `kali-ext` 2 · `phish01` 1 | 32–34 |
| **Stage 2** | `dc02` 4 · `ca01` 2 · `wsus01` 6 · `kc01` 3 · `glpi01` 2 · `intra01` 6 · `mx01` 1 · `gvm01` 6 · `pbs01` 4 · `prn01` 0.5 · guest 2 · `ws04`, `ws05` 8 · `remnux` 4 · `flare` 6 | about 55 |
| **Stage 3** | PAWs 8 · `pam01` 4 · `radius01` 0.5 · `thehive01` 8 · `shuffle01` 6 · `misp01` 6 · `velo01` 3 · k3s 9 · `br-fw` 1 · `dc03` 4 · `ws-br01` 4 · `c2-01` 2 · `redir01` 0.5 | about 56 |

| Stage | Everything running | With exercise profiles (only what a session needs) | Sensible host memory |
|---|---|---|---|
| 0 copy | about 30 GB | — | 32 GB works; 64 GB if Stage 1 follows |
| 1 | about 62 GB | about 45 GB | **64 GB** (tight with everything on) |
| 2 | about 117 GB | about 70–80 GB | **96 GB** with profiles; **128 GB** for comfort |
| 3 | about 173 GB | about 90–110 GB | **128 GB** with profiles; 192–256 GB to run it all |

**Two techniques that stretch memory**, and their price:

| Technique | What it does | Cost |
|---|---|---|
| Kernel same-page merging | identical memory pages of similar VMs are stored once; several Windows VMs share a lot | some CPU; a known side channel between VMs, irrelevant in a single-user lab but worth knowing as a concept |
| Ballooning | the hypervisor reclaims unused guest memory | guests can stall if the host really runs out |

**Lab vs real.** A real company doesn't overcommit memory on its domain controllers. You will.
State the sizing honestly in your write-ups.

### 1.2 CPU, storage, network ports

| Part | Stage 1 | Stage 2 | Stage 3 | Notes |
|---|---|---|---|---|
| CPU | 6–8 cores | 8–12 cores | 12–16 cores | virtualisation extensions required; three or four virtual CPUs per physical thread is fine for idle lab VMs. A password-cracking rig isn't needed: crack on your laptop or accept slower runs |
| Storage | 500 GB–1 TB NVMe | 1–2 TB NVMe | 2 TB NVMe | **solid-state storage is essential**; a dozen Windows VMs on a spinning disk are unusable. Thin provisioning and linked clones keep use far below the sum of disk sizes |
| Second disk | optional | recommended | recommended | a mirror, or a separate disk for backups (section 6) |
| Network ports | 2 | 2–3 | 3 | port 1: home side. Port 2: lab trunk to the optional switch. Port 3: a mirror port for a sensor, or a spare |
| Extras | — | a small managed switch | plus a USB Wi-Fi adapter that supports monitor mode and an access point | used managed switches are cheap; needed for 802.1X and real port-level attacks |

**Storage layout options**

| Option | For | Against |
|---|---|---|
| **A. ZFS mirror on two NVMe drives (recommended if the budget allows)** | checksums, cheap snapshots, replication, survives one drive failing | uses memory for its cache (cap it at 4–8 GB); consumer drives wear faster under it (verify the drive's endurance rating) |
| B. One NVMe with LVM-thin | cheapest; snapshots work | a drive failure loses the lab; the backup matters more |
| C. ZFS on one drive | snapshots and checksums | no redundancy |

### 1.3 What to buy

| Option | Example class | Memory ceiling | Rough cost (verify) | Idle power (verify) | Noise | Fits |
|---|---|---|---|---|---|---|
| A. Used business mini PC | 8th–10th generation desktop-class CPU | usually 64 GB | €250–450 plus memory | 10–25 W | silent | Stage 0 copy and Stage 1 |
| **B. Used tower workstation (recommended for value)** | a Xeon workstation with registered DDR4 memory | 128–256 GB | €400–900 with 128 GB | 60–120 W | a quiet fan hum | Stages 1–3 |
| C. Used rack server | 1U or 2U, dual Xeon | 256 GB and more | €300–800 | 100–200 W | **loud**; not for a room you sleep or study in | Stages 1–3, if you have a basement |
| D. New mini PC or small-form-factor | current mobile-class CPU, two DDR5 slots | 96–128 GB (verify per model) | €900–1,600 | 15–40 W | quiet | Stages 1–2; Stage 3 with profiles |
| E. New desktop build | current desktop CPU, four DDR5 slots | 128–192 GB | €1,500–2,500 | 40–80 W | quiet | all stages |

**The concept behind the recommendation.** Old registered server memory is cheap on the used
market, because data centres retire it in bulk. A used workstation therefore gives the most
memory per euro, at the price of power draw. A new mini PC reverses the trade: low power and
silence, expensive memory, a hard ceiling.

**Running cost.** Power in watts × hours ÷ 1,000 × your tariff per kWh.

| Idle draw | Running 24/7, per month | Running 40 hours a month |
|---|---|---|
| 25 W | 18 kWh | 1 kWh |
| 80 W | 58 kWh | 3.2 kWh |
| 150 W | 108 kWh | 6 kWh |

Multiply by your tariff. The second column is the realistic one for a lab: **shut the server
down when you aren't using it**, and wake it over the network when you are. A lab that runs
only during sessions costs a few euros a month in power on any of these machines.

**Options for when to buy**

| Option | When | For | Against |
|---|---|---|---|
| **A. Buy for Stage 2 now (96–128 GB)** | before Stage 1 | no migration later; headroom for mistakes | more money up front |
| B. Buy small for Stage 1, upgrade later | — | cheapest start | 64 GB machines usually can't be upgraded; you buy twice |
| C. Start Stage 1 on AWS, buy at Stage 2 | — | delays the purchase until you know you'll use it | Stage 1's layer-2 exercises wait |

`comparison.md` picks between these.

---

## 2. Networking in detail

### 2.1 The host

| Item | Setting | Why |
|---|---|---|
| `vmbr0` | bridge on port 1, with the host's management address | the home side: host management and `isp-rtr` only |
| `vmbr1` | VLAN-aware bridge on port 2 (or no port), **no address on the host** at Stage 1 | the lab trunk. Without a host address, no lab VM can reach the hypervisor over it |
| `vmbr66` | bridge with no port and no address | the sandbox |
| Host firewall | Proxmox firewall enabled at datacentre and node level; 8006 and 22 from your laptop's address only | the UI is never reachable from the lab or the internet |
| VM NICs | VirtIO; one VLAN tag each; the firewall option enabled per NIC | the per-interface filtering layer |
| MAC and IP filters | on by default for ordinary VMs; **deliberately off on the layer-2 range** (`hq-users` during engagements) | the Proxmox firewall can stop spoofing, which is a control to demonstrate both ways (`03-attack-ranges.md`) |

### 2.2 `isp-rtr`: the one door

An illustrative ruleset. **PROPOSED and unreviewed**: under the convention in `CLAUDE.md`,
Claude drafts firewall rules and you review each one before it's used. Interface names are
placeholders: `home0` faces your home LAN, `lab0` faces `sim-inet`.

```
table inet isp {
  chain forward {
    type filter hook forward priority filter; policy drop;

    meta nfproto ipv6 drop                                                      # 1
    ct state established,related accept                                         # 2
    iifname "lab0" oifname "home0" ip saddr 198.51.100.80 \
        log prefix "ISP-C2-DROP " drop                                          # 3
    iifname "lab0" oifname "home0" \
        ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } \
        log prefix "ISP-HOME-DROP " drop                                        # 4
    iifname "lab0" oifname "home0" tcp dport { 80, 443 } accept                 # 5
    iifname "lab0" oifname "home0" udp dport 123 accept                         # 6
    iifname "home0" oifname "lab0" ip daddr 198.51.100.10 udp dport 1194 accept # 7
    log prefix "ISP-FWD-DROP "                                                  # 8
  }
  chain prerouting {
    type nat hook prerouting priority dstnat;
    iifname "home0" udp dport 1194 dnat ip to 198.51.100.10                     # 9
  }
  chain postrouting {
    type nat hook postrouting priority srcnat;
    oifname "home0" masquerade                                                  # 10
  }
}
```

| # | What it matches | Why | What it would miss |
|---|---|---|---|
| 1 | every forwarded IPv6 packet | rules 5 and 6 match on ports only, so without this an IPv6 packet from the lab to a home device's global address would be accepted. Home networks often have IPv6 you never configured | nothing, as long as the lab doesn't need IPv6 out. If you add an IPv6 exercise, this rule must be replaced by proper IPv6 rules |
| 2 | replies to connections already allowed | stateful filtering | a connection allowed by mistake stays allowed until it ends |
| 3 | anything from the C2 redirector heading out | a second guarantee, beside routing, that C2 traffic never leaves | a redirector given a different address. Check the address in the RoE |
| 4 | lab traffic to any private or link-local destination on the home side | **the isolation rule.** It comes before the allow rules, and it names the interface, so it holds even though the lab uses private ranges itself | a home network that uses public addresses internally (rare); traffic to your home's *public* address, which reaches your router's outside (add your public address if your router answers on it) |
| 5 | web traffic from the lab to the internet | updates, package and image downloads | it doesn't restrict *which* sites. A compromised lab VM can reach the internet on 443. The office and production firewalls in front of it are stricter; this is the outer net |
| 6 | time | NTP | — |
| 7 | the VPN from your laptop | the only inbound path | a home device other than your laptop can also try; `tls-crypt` on `fw-ips` makes the port silent to it |
| 8 | everything else, logged | evidence of what was refused | logging without a rate limit can fill the disk during a scan; add a limit |
| 9 | the VPN port arriving on the home side | rewrites the destination to `fw-ips` | — |
| 10 | everything leaving to the home side | hides lab addresses behind `isp-rtr`'s home address | — |

DNS doesn't appear: `isp-rtr` runs its own recursive resolver for the lab at 198.51.100.1, so
no forwarded DNS rule is needed and the lab never talks to your home router.

**Verify:** from a lab VM, `ping` and `curl` an address on your home LAN (both fail, a line with
`ISP-HOME-DROP` appears); from the same VM, an HTTPS download works.

### 2.3 OPNsense as `hq-fw`

| Topic | Setting | Why, and what goes wrong |
|---|---|---|
| Interfaces | WAN on VLAN 900; one trunk NIC with a VLAN interface per office network | one virtual NIC carries all inside VLANs: a router on a stick |
| Hardware offloading | disabled on the VM | offloading and inline inspection don't mix; a classic cause of "the IPS drops everything" (verify the current guidance for VirtIO) |
| Suricata | inline (IPS) mode on the inside interfaces; ET Open; **alert first** | the lab's own lesson (decision 82): nothing drops until realistic captures stay silent. Inside interfaces see real client addresses; the outside sees only NATed ones |
| DHCP | relay to `dc01` for `hq-users`; OPNsense's own server for guest and IoT | guests shouldn't depend on, or learn about, the domain controller |
| DNS | clients use the DCs; guests use OPNsense's resolver | the fix for `W2-07` is a rule here: block port 53 to anything else |
| WireGuard, IPsec | tunnel to `fw-ips`; later IPsec to `br-fw` | keys from `vault01`, never typed in the UI and left there undocumented |
| Logs | syslog to a Wazuh agent or collector; NetFlow optional | without this the office firewall is invisible to the SIEM |
| Admin access | UI on `hq-mgmt` only; sign-in by LDAP groups (`APP-Firewall-*`); a local break-glass account | the UI is never on a user-facing VLAN |

Keeping OPNsense as code is section 5.3.

### 2.4 Three filtering layers on this platform (P1)

| Layer | AWS equivalent | Tool here | Scope |
|---|---|---|---|
| Per interface | security group | Proxmox firewall security groups, attached to VM NICs | stateful; defined once, reused; managed in Terraform |
| Routing firewall | nftables on `fw-ips` | `fw-ips`, `hq-fw`, `br-fw` | between VLANs and sites |
| Per host | (was the NACL's role as an independent second opinion) | nftables or Windows Firewall on each VM, from the baseline roles | what the host itself accepts |

The same principle as Stage 0: one mistake in one layer doesn't open a path.

---

## 3. What replaces each AWS service

| On AWS (built) | On Proxmox | Notes |
|---|---|---|
| SSM Session Manager; Ansible over SSH-in-SSM | SSH from `ops01` (P4) | port 22 from one address; keys on `ops01`, which is therefore Tier 0 |
| SSM Parameter Store | `vault01`: Vault or its open-source fork OpenBao (verify licences) | section 4 |
| Instance roles through the metadata service | a per-host identity in Vault | section 4 |
| ECR | a registry on `ops01`: immutable tags, pulls by digest, images scanned with Trivy before push | the digest pin and its reasoning (decisions 5, 53) carry over unchanged |
| Route 53 with DNS-01 for Let's Encrypt staging | **Option A (recommended):** keep it. lego on `proxy` still uses the existing public zone; its AWS credentials come from a certificate-based temporary-credential mechanism for hosts outside AWS, or, more simply, a narrowly scoped key held in `vault01`. **Option B:** an internal ACME CA (`step-ca`) for every name | A keeps the rule "Let's Encrypt staging until I say otherwise" and the narrow IAM condition (decision 60). B is fully self-contained and teaches running a CA, but **differs from that rule**: decide it explicitly. Internal office names use AD CS or `step-ca` either way |
| `vpn.<domain>` and an Elastic IP | the fixed address 198.51.100.10, and `isp-rtr`'s home-side address in the client profile | a separate client profile for the Proxmox lab |
| S3 for state | **Option A:** keep the existing S3 state bucket (it's just storage). **Option B:** a local backend backed up by `pbs01` | A is simplest and already built |
| S3 for backups | `pbs01`, plus an off-host copy | section 6 |
| CloudTrail | Proxmox task and access logs; Vault's audit log; OPNsense's configuration history; Git | no single control-plane trail exists. Send all four to Wazuh from Stage 2 |
| VPC flow logs | flow events from Suricata on each firewall; optional NetFlow | no record of traffic *inside* a VLAN unless a sensor is on it |
| GuardDuty | nothing | managed detection is a cloud feature |
| CloudWatch CPU credits (YACE) | a Proxmox exporter for host and VM metrics | credits don't exist; host memory pressure is the thing to alert on |
| Budgets | a plug-in power meter | — |
| `aws_ec2` dynamic inventory | a Proxmox dynamic inventory, grouped by VM tags | keep the group names identical to the `Role` tag groups |
| The metadata service for first boot | cloud-init with a configuration drive | — |

**Effort warning.** The production copy isn't a free by-product. Every row above is a change to
an existing role, behind a platform variable so the AWS path keeps working. Budget several
sessions for it, and take them one role at a time with the usual verify steps.
`comparison.md` weighs this against keeping production in AWS (the hybrid).

---

## 4. Secrets without a cloud: `vault01`

**The problem.** On AWS, a host proves who it is through its instance role, with no secret on
the host. Outside a cloud nothing vouches for a machine, so the first credential has to come
from somewhere. This is the **secret-zero problem**.

| Option | How a host gets its first credential | For | Against |
|---|---|---|---|
| **A. A role identifier baked in, a one-time secret delivered at build (recommended)** | Terraform or Ansible on `ops01` requests a single-use, short-lived secret for that host's role and hands it over at first boot; the host exchanges it for a token | no long-lived secret at rest; each host can read only its own path | `ops01` can mint these, which makes it Tier 0 (it already is) |
| B. One token per host in a root-only file | set at build | simple | a long-lived secret on disk, exactly what the AWS design avoided |
| C. Certificate authentication | each host has a certificate from the internal CA | strong; pairs with the PKI work | needs the PKI first |

**Keep the patterns already decided:** the host pulls its own secret (decisions 39, 47); values
never pass through Ansible output (decision 52); one path per host (`/mailbridge/*`, `/siem/*`,
`/mon/*`, `/vpn/fw-ips/*`) with a policy that reads only that path. The paths can keep their
names.

**Vault's own problems, which are the lesson:**

| Topic | What to decide |
|---|---|
| Unsealing | Vault starts sealed. Unseal keys split among "people" (you, three envelopes), or auto-unseal. Where do the keys live? Not in the repo, not on `vault01` |
| Backup | storage snapshots, encrypted, off the host. A lost Vault is a lost lab |
| Audit | the audit device on from the first day, shipped to Wazuh |
| Availability | every host depends on it at start. One node is a single point of failure; accept and document it |
| Its own tier | Tier 0 |

---

## 5. Infrastructure as code

### 5.1 Terraform

| Topic | Proposal |
|---|---|
| Provider | the `bpg/proxmox` provider (verify the current version and resource names) |
| Credentials | an API token for a dedicated user with a custom role limited to what Terraform manages; stored in `vault01`, never in the repo. Some operations may still need SSH to the node (verify) |
| What it manages | bridges and VLANs, firewall security groups, pools, users, roles and ACLs, image downloads, VMs cloned from templates, cloud-init settings |
| What it doesn't | guest configuration (Ansible), templates (Packer) |
| Rule | the existing hard rule stands: **no `apply` or `destroy` without your approval**; saved, reviewed plans only (decision 142) |
| Checks | `terraform fmt`, `validate`, tflint as today. checkov has little Proxmox coverage (verify), so write a few custom policies: every NIC has a VLAN tag; the firewall is enabled on every NIC; no VM sits on `vmbr0` except `isp-rtr` |

### 5.2 Packer templates

| Template | Builder input | Must contain |
|---|---|---|
| Ubuntu Server | the vendor's cloud image, or an ISO with an automated install | cloud-init, the guest agent, the Ansible user's public key |
| Ubuntu Desktop | ISO, automated install | the same, plus the desktop |
| Windows Server | evaluation ISO, an answer file, the VirtIO driver ISO | VirtIO drivers, the guest agent, OpenSSH Server or WinRM, Sysprep as the last step |
| Windows client | evaluation ISO, an answer file, VirtIO drivers | the same |
| Kali | the vendor's image | pinned tool versions for repeatable engagements |

**Evaluation licences as a feature.** Windows Server evaluations run for a limited period and
client evaluations for a shorter one (verify the current terms). When one expires, you rebuild
from the Packer template and Ansible. A lab that can't survive that rebuild has drifted from
its code, so the timer is a free drift test.

### 5.3 OPNsense as code

| Option | How | For | Against |
|---|---|---|---|
| **A. Its API, from Ansible (recommended)** | a community Ansible collection for OPNsense (verify which is maintained) drives rules, aliases, VLANs and VPNs | reviewed changes; idempotent | not every setting is covered |
| B. Template the whole `config.xml` | generate the file, restore it | complete | brittle across versions; secrets inside the file |
| C. The UI, with an export to Git after every change | — | covers everything | the review happens after the fact |

**Recommendation:** A for everything it covers, C for the rest, and in both cases the drift
check from `shared/03-operations-flows.md`: export `config.xml` at session start and diff it
against the last committed export (with secrets stripped before committing).

### 5.4 Snapshots and clones

| Tool | Use | Caution |
|---|---|---|
| Template + linked clone | a new workstation in seconds, sharing the template's disk | the template can't be deleted while clones exist |
| Snapshot | a restore point before an exercise | not a backup: it lives on the same disk |
| Snapshot with memory | freezes a running machine, RAM included | the forensic gift of this platform: memory evidence without touching the guest |
| Named snapshot sets | `pre-engagement-<date>` on every VM in scope | section 7 |

**Domain controllers and snapshots.** Reverting one DC to an older state while another DC kept
running can break replication. Snapshot and revert **all DCs together, powered off**, or rebuild
from code. The hypervisor passes Windows a generation identifier that lets a DC detect a revert
(verify), which helps but isn't a licence to revert DCs one at a time.

---

## 6. Backups

| Layer | What | Tool | Where |
|---|---|---|---|
| Whole VMs | every VM, deduplicated and incremental | Proxmox Backup Server (`pbs01`) | a dedicated disk passed through to the `pbs01` VM, or better a small separate machine |
| Off-host copy | a second copy that survives the server | an external disk synced and then **unplugged**; or an encrypted sync to S3 | off the host; ideally off-site |
| Application data | the same as on AWS: `pg_dump`, mail stores, system state | the operations flow in `shared/03` | into `pbs01` |
| The hypervisor's own configuration | `/etc/pve`, network configuration, the firewall | a small scheduled archive | with the off-host copy |
| Vault | storage snapshots | Vault's own snapshot command | encrypted, off-host |
| Everything else | code and docs | Git | already there |

| Option for where `pbs01` runs | For | Against |
|---|---|---|
| A. A VM on `pve01` with its own disk | no extra hardware | the host dies, the backups die with it unless the off-host copy exists |
| **B. A VM on `pve01` plus a rotated external disk (recommended to start)** | cheap; a true offline copy | a manual step you must actually do |
| C. A separate small machine | real separation | more hardware and power |

**Controls that make the backups ransomware-resistant** (and that Stage 2's red role should try
to defeat):

- `pbs01` isn't joined to the domain; its accounts aren't in AD.
- The hypervisor pushes backups with a token that can **create but not delete**.
- Pruning runs on `pbs01` itself, on its own schedule.
- Backups are encrypted on the client side; the key is in `vault01` and on paper.
- Verification jobs run weekly; a failed or **missing** job alerts.
- The off-host disk is connected only while syncing.

**Restore test**, as in `shared/03` flow 5: quarterly, from the off-host copy, into an isolated
bridge, timed.

---

## 7. Resetting the range

Four levels, from quick to total.

| Level | Name | When | How | Time |
|---|---|---|---|---|
| 1 | Revert one host | an exercise broke a VM | roll back to its last snapshot | a minute |
| 2 | Revert an exercise set | after every engagement | roll back every VM in scope to `pre-engagement-<date>`; DCs together and powered off | 10–15 minutes |
| 3 | Rebuild from code | a stage milestone; an expired evaluation; a drift finding | destroy the stage's VMs, `terraform apply` from a reviewed plan, run Ansible twice (`changed=0`), run `make verify` | hours; the proof that the code is the lab |
| 4 | Bare metal | a new disk; a compromised hypervisor; once a year as a drill | reinstall Proxmox from documented steps, restore host configuration, level 3 for everything, restore data from `pbs01` | a day; this is your disaster-recovery exercise |

**Runbook: after an engagement (level 2)**

- [ ] Stop the engagement; red's operation log is closed.
- [ ] Export evidence first (`evidence.yml`, memory snapshots, captures). **Evidence before
      revert**, always.
- [ ] Confirm the list of VMs in scope from the RoE.
- [ ] Power off the DCs together.
- [ ] Roll back every VM in scope to the named snapshot.
- [ ] Start in order: firewalls, DCs, servers, workstations.
- [ ] `repadmin /replsummary`; agents `Active`; targets `up`.
- [ ] Remove engagement-only firewall rules; check the diff against Git is empty.
- [ ] Delete the snapshot set once the report is written (old snapshots slow storage).

**Why level 3 still matters here.** Snapshots tempt you to stop rebuilding from code. A lab that
only ever reverts drifts silently, and after a year nobody can rebuild it. Schedule level 3 at
every stage gate; it is the Proxmox equivalent of the per-session teardown that keeps the AWS
lab honest.

---

## 8. Handling malware and C2 safely

| Rule | Detail |
|---|---|
| Two places only | malware analysis in `sandbox` (`vmbr66`); C2 in `hq-red` and on `sim-inet`. Nowhere else |
| No path out | `vmbr66` has no gateway and no host address. `hq-red` has no internet route. `isp-rtr` drops the redirector's address (rule 3) |
| No conveniences | no shared folders, no shared clipboard, no USB pass-through to analysis VMs, no second NIC |
| One-way transfer | samples and tools enter as an ISO image you attach; results leave as screenshots, notes, or an ISO you create and inspect |
| A fake internet | a network-simulation tool on `remnux` answers DNS and web requests so samples reveal behaviour without reaching anything real |
| Snapshot, detonate, revert | every analysis starts from a clean snapshot and ends with a revert |
| Start with your own | your first "samples" are implants you generated with `c2-01`. Real-world samples come later, if at all, and only by the one-way path |
| Check before and after | a capture on `vmbr0` and `isp-rtr`'s counters show nothing from these segments |
| The hypervisor is the boundary | keep Proxmox patched. A VM escape is rare but it's the one failure that reaches your home network |

**Lab vs real.** Professional malware labs use physically separate machines and networks for
exactly the reason in the last row. Your separation is logical. That is acceptable for implants
you built yourself and for well-understood samples; it's a reason to be conservative about what
you detonate.

---

## 9. Hardening the hypervisor itself

| Control | How |
|---|---|
| Updates | the community repository; patch monthly with the rest (the patch flow) |
| Sign-in | two-factor for every UI account; no shared `root` use; named accounts |
| API | tokens with their own minimal role; separate tokens for Terraform, backups, the exporter |
| SSH | keys only; from your laptop only |
| Firewall | enabled at all three levels; default deny inbound |
| Console rights | the VM console is a keyboard on any machine, including the DCs. Limit it; alert on use at Stage 3 |
| Disk encryption | the server is in your home; encrypt the data pool if theft matters to you (and plan how it unlocks after a power cut) |
| Logs | from Stage 2, the host's logs to Wazuh over its lab-side address |
| Physical | firmware password; boot order locked |

---

## 10. How to verify the platform pieces

| Claim | Check | Expected |
|---|---|---|
| The lab can't reach home | from three different VLANs, try a home LAN address | all fail; drops logged on `isp-rtr` |
| The hypervisor UI is closed | from a lab VM and from another home device: connect to port 8006 | both fail |
| Only `isp-rtr` touches `vmbr0` | list VM NICs by bridge | one VM |
| Every NIC is tagged and filtered | the custom Terraform policy; `bridge vlan show` | no untagged VM NIC; firewall enabled everywhere |
| A host reads only its own secrets | on `proxy`, try to read `/mailbridge/` in Vault | denied; the attempt is in the audit log |
| The registry pins hold | try to push a different image under an existing tag | refused |
| Backups can't be deleted from the domain | with a Domain Admin account, try | no access at all |
| A restore works | the quarterly test | timed, recorded |
| The range rebuilds | level 3 | second Ansible run `changed=0`; `make verify` passes |
| The sandbox is sealed | capture on `vmbr0` during a detonation | nothing from 10.66.0.0/24 |
