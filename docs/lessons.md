# Lessons

One section per session date, written as a lecture to study from.

## 2026-10-31

### Today's topic: building a private network, then proving it with code

You started with three documents and an empty AWS account. You finished with a segmented network that you built by hand and that Terraform now manages. No servers exist yet, so nothing is running, but every road, gate and guard is in place.

### The big picture

The goal of the lab is to run an app so that its only entry point is a VPN, then attack it and measure what gets detected. Before any app can run safely, it needs somewhere to live. That is what today built.

The core idea is **defence in depth**: several independent layers, so one mistake doesn't expose everything. Your layers now are:

1. **Routing:** decides where a packet can travel at all.
2. **Network ACLs:** a stateless filter at each subnet's edge.
3. **Security groups:** a stateful filter on each network interface.
4. **nftables and Suricata, later on fw-ips:** inspect and filter traffic that crosses the firewall.

An attacker now has to defeat several unrelated controls, not just one.

The second idea is **segmentation**: splitting hosts into zones so that compromising one doesn't give access to the others. The public zone holds only fw-ips. The DMZ holds the web proxy, then come app, data and mgmt. Traffic may only move one hop at a time: proxy to app, app to database.

### How we chose to work

We compared three approaches and chose to build each layer by hand, compare it with code, and then rebuild from code.

- **Why by hand first:** clicking through each option shows you what exists and why. You must be able to defend every choice in an interview.
- **Why code as well:** a hand build can't be reproduced reliably. Code can be reviewed, versioned and redeployed.
- **What the compare step gives you:** it detects **drift**, a difference between what the code says and what really exists.

You later chose to keep your hand-built network and defer the rebuild test to task 1.20. That is a reasonable call, because the network is free while idle. The trade-off to remember: `No changes` proves the code *describes* the network, not that it can *create* it. Only a rebuild proves that.

### Part 1: Securing the AWS account

The **root user** has unlimited power and IAM policies can't restrict it, so it is protected with MFA and then avoided. Daily work uses an **IAM user**, `marko-admin`, which can be limited, audited and removed.

**The Budget:** AWS does not stop spending at a limit. A Budget only warns you. You excluded credits from it, because otherwise your spending can look like about $0 while your credits drain, and the alert never fires.

### Part 2: The VPC

A **VPC** is your private network inside AWS. `10.0.0.0/16` means the first 16 bits are fixed, leaving 65,536 addresses. The `10.0.0.0/8` block is private and isn't routed on the internet.

The choices that matter:

- **VPC only, not "VPC and more":** the wizard hides how the pieces connect and can add a paid NAT Gateway.
- **No IPv6:** AWS IPv6 addresses are publicly routable, and your rules cover IPv4 only. An IPv6 path could bypass the firewall completely. Sometimes the secure choice is simply not enabling something.
- **Default tenancy:** dedicated hardware costs far more, for a compliance need a lab doesn't have.
- **DNS hostnames on:** off by default in a VPC you create yourself.

### Part 3: Subnets and routing

A **subnet** is a slice of the VPC in one Availability Zone. A subnet isn't public by nature: **its route table is what makes it public**. That is one of the most useful ideas from today.

AWS reserves 5 addresses in every subnet. That's why the VPC's DNS resolver sits at `10.0.0.2`.

An **internet gateway** is the VPC's door to the internet. Route tables send traffic to it, and the most specific matching route wins, so `10.0.x.x` stays local while everything else matches `0.0.0.0/0`.

Your two route tables tell the whole design:

- **Public:** `0.0.0.0/0` goes to the internet gateway.
- **Private:** `0.0.0.0/0` and `10.8.0.0/16` both go to the fw-ips network interface.

So every private host's internet traffic is forced through your firewall. You avoided a NAT Gateway because it bills hourly. The `10.8.0.0/16` route exists because VPN addresses sit outside the VPC. Keeping them un-NATed means the proxy sees the real client IP, so every event can be traced to one device certificate.

The **main route table** only has the `local` route, and you deliberately left it alone. A subnet you forget to associate falls back to it and gets no internet, which fails safely.

### Part 4: The network interface and source/destination check

An **ENI** is a virtual network card. You created it separately so routes could point at it before the instance exists, and so replacing the instance won't disturb the routes.

The **source/destination check** makes an ENI drop any packet not addressed to it. A router's whole job is handling other hosts' packets, so it must be off. If you left it on, everything would fail and it would look like a firewall problem. This is a classic AWS mistake, and you hit it: the check showed `True` until it was changed.

Your private routes show `blackhole`. That's expected: nothing is attached to the ENI yet.

### Part 5: VPC flow logs

Flow logs record metadata about traffic: addresses, ports, bytes, and whether it was accepted or rejected. They contain no packet contents.

They matter because Suricata and nftables only see traffic crossing fw-ips. Two hosts in the same subnet talk directly, so an attacker moving sideways there would be invisible without flow logs. The bucket sits outside the lab stack so the evidence survives a teardown.

### Part 6: Security groups

A security group is a **stateful** firewall on a network interface. Stateful means replies are allowed automatically, so you write rules only for the side that starts a connection. That's why `db` needs no rule for `app`.

Rules can reference another group, like "anything wearing `sg-proxy`". That's stronger than an IP range, because it follows a host's role rather than its address.

Terraform removes the default allow-all outbound rule, so you stated egress explicitly. Security groups are enforced outside the instance, so even root on a compromised host can't change them. `sg-fw` is the exception, with all egress allowed, because it forwards traffic for the whole VPC and nftables applies the policy.

You also emptied the VPC's default group, so attaching it by accident grants nothing.

### Part 7: Network ACLs

| | Security group | NACL |
|---|---|---|
| Applies to | A network interface | A whole subnet |
| State | Stateful | **Stateless** |
| Rules | Allow only | Allow and deny, first match wins |

Stateless means replies need their own rules. A reply lands on a random high port, the **ephemeral range** (1024-65535).

The subtle problem: private subnets must accept replies from the internet, and that range also includes ports 3000, 5432, 1514 and 1515. A simple return rule would reopen them to everyone. The fix uses rule order: 100 allows the legitimate source, 105 denies that port from everywhere, and 110 allows ephemeral ports. Because the first match wins, the service port stays protected.

Remember too that a NACL does nothing until it is **associated** with a subnet. The default NACL allows everything, so an unattached NACL is a false sense of security.

### Part 8: Terraform, state and import

A **module** is reusable code. A **root stack** is the folder you run Terraform from, and it connects modules by passing one module's outputs into another. That reference also tells Terraform the order to build things.

**State** is Terraform's record of which real resources it manages. It can hold sensitive values, so it lives in an encrypted, versioned, private S3 bucket and never in Git. A stack can't create the bucket that holds its own state, which is why you built that bucket by hand.

**`aws login`** gives short-lived credentials, so no permanent access key sits on your laptop. A leaked credential that expires does limited damage.

**`terraform plan`** compares code, state and reality. It's read-only. **`terraform import`** links a real resource to your code and changes nothing in AWS. **Import blocks** preview every import in `plan`, and only `apply` saves them.

Your first plan showed `114 to add`, which looked alarming but was correct, because the state was empty. Applying then would have built a duplicate network. After importing, the only drift was two missing `Name` tags. All 83 rules you typed matched, descriptions included. The final result was `No changes`.

**A rule for `for_each`:** keys must be known before anything is created. Use fixed values like names as keys, and let IDs be values. Our code broke this rule, and the import exposed it.

### Part 9: Continuous integration

**CI** runs your checks automatically on GitHub, so a rule like "merge only on green" is enforced by a system, not by memory. Six checks run on each pull request: `terraform fmt`, `terraform validate`, `tflint`, `checkov`, `ansible-lint` and `gitleaks`.

Actions are pinned by **commit SHA** rather than a tag. A tag can be moved to different code, while a SHA identifies exact content, which protects against a **supply chain attack**. CI never gets AWS credentials: `validate` runs with `-backend=false`, so it checks code without touching your account.

A **false positive** is a warning about something that isn't really wrong. The right response is a narrow skip with a written reason, next to the resource. Turning a check off everywhere would hide real problems later.

### Part 10: What costs money in AWS

Most networking building blocks are free: VPCs, subnets, route tables, internet gateways, security groups, NACLs and unattached ENIs. Costs come from things that run or hold capacity: instances, disks, public IPv4 addresses, NAT Gateways and load balancers.

Stopping an instance ends the compute charge, but its disk still bills. A terminated instance can leave disks, snapshots or IPs behind. That's why we scanned every region for those, not just for instances. The scan found none, so your earlier EC2 spending has stopped.

### Part 11: Logging in without SSH

**Session Manager** gives you a terminal with no inbound port. The SSM agent on the VM connects outbound to AWS, and your session travels through that connection. Two identities are involved: the **instance role** lets the VM register with SSM, and **your AWS login with MFA** decides whether you may connect. Don't mix them up: the role is for the machine, not for you.

You asked whether SSH over the VPN would be better. It's a sound idea and doesn't expose port 22 to the internet, but it adds to SSM rather than replacing it. The key concept is **out-of-band access**: a way in that doesn't depend on the thing you might break. fw-ips runs the VPN, so a mistake there would also take down SSH over the VPN, while SSM takes a separate path. Also, SSH over VPN only works from a device holding your profile and key, so it isn't truly "from anywhere".

### Part 12: The plan for fw-ips

fw-ips will use your existing ENI, so its address, security group and routes are already in place. Attaching an instance turns the `blackhole` routes `active`. The configuration order is PKI, OpenVPN, IP forwarding and NAT, the full nftables policy, Unbound, then Suricata. Each step depends on the last and gets tested before moving on.

### Mistakes and what they taught

| What happened | The lesson |
|---|---|
| Source/destination check stayed on | Verify settings with a command, don't trust the click |
| Rule 100 was TCP instead of UDP | OpenVPN here uses UDP; always check the protocol |
| NACLs weren't associated | Rules that aren't attached protect nothing |
| Region set to `eu-central-1b` | That's an Availability Zone, not a region |
| Bucket created in `us-east-1` | Buckets can't move, and a deleted name takes time to free up |
| Files saved in the module folder | Check the path; root stacks and modules are different things |
| Generated passwords pasted into chat | Treat anything pasted as exposed, and replace it |
| `grep '^Plan:'` found nothing | Terraform's color codes break matching; use `-no-color` |

### Decisions from today

The full reasoning is in `rationale.md`.

| Topic | Choice | Why |
|---|---|---|
| App image | ECR, pinned by digest | No registry password, and the exact image is guaranteed |
| DNS | Route 53 | The IAM role replaces a stored API token |
| VPN address | Elastic IP in `lab`, DNS name in profiles | No idle IP cost, and profiles survive rebuilds |
| Build order | db, app, proxy | Each layer is tested against the real one below it |
| NAT | Split from the full ruleset | Private hosts reach SSM through fw-ips |
| Repo | Public | Free branch protection can enforce green CI |
| Flow logs | S3 | Cheapest way to keep evidence past a teardown |
| Network | Kept up, rebuild deferred | Free while idle, and you chose to keep the hand build |

### Interview questions to practise

1. What makes a subnet public?
2. What's the difference between a security group and a NACL?
3. Why does a NACL need rules for ephemeral ports, and what problem does that create?
4. Why must source/destination check be off on a software router?
5. Why does VPN traffic stay un-NATed in this design?
6. Why did you skip IPv6?
7. What do flow logs show that Suricata can't?
8. What is Terraform state, and why isn't it stored in Git?
9. What does `terraform import` change in AWS?
10. Why isn't `No changes` the same as proving a rebuild works?
11. Why use temporary credentials rather than access keys?
12. How can Session Manager work with no inbound port?
13. What's the difference between an instance role and your own login?
14. Why keep out-of-band access if you also have SSH over a VPN?
15. What does stopping an instance save, and what still bills?

### What comes next

Task 1.6 builds fw-ips, your first EC2 instance. Running costs begin there. Before launch, decide what happens to the instance between sessions. Then come OpenVPN and the NAT rules you'll write yourself.

## 2026-11-01

### Today's topic: building the front door, and checking what a policy really allows

Yesterday you built roads with nothing on them. Today you launched your first server, fw-ips, gave it an identity, built a private certificate authority and got real devices connecting through OpenVPN. fw-ips doesn't route traffic yet. That starts with your NAT rules.

The most valuable moment wasn't a build step. A statement in our own docs turned out to be false, and checking it uncovered a design flaw that would have exposed every secret to every host.

### The big picture

Everything entering the lab passes through fw-ips, so it's the highest-risk host. It's internet-facing, so assume it could one day be compromised, and ask "what would an attacker get?" That question drove the main decisions today: the CA lives elsewhere, the host can only read its own secrets, and it has no SSH key to steal.

This idea is **assume breach**: design so that one compromised host doesn't hand over everything.

### Part 1: Closing tasks honestly

Tasks 1.3 and 1.4 were closed by checking what their verify steps required: no paid resources in the code, checkov green on main, and every security group and NACL rule compared with §4. `terraform plan` couldn't run because the login had expired. Rather than skip that silently, we checked the Terraform history and found that only comments had changed since the last clean plan, and recorded that in `progress.md`.

The habit to keep: when you can't run a check, say so, and state what evidence you used instead.

### Part 2: The instance role

An instance role gives a VM temporary credentials through the metadata service, so no keys are stored on disk. It has two parts: a **trust policy** saying who may use the role (here, `ec2.amazonaws.com`) and **permission policies** saying what it can do. The console also creates an **instance profile**, the wrapper that actually attaches a role to an instance.

### Part 3: Launching fw-ips

The settings that matter, and why:

- **No key pair:** Session Manager doesn't need one, so there's no key file to steal.
- **Existing ENI, no auto-assigned public IP:** the address, `sg-fw` and routes already existed. Attaching the instance turned the `blackhole` routes `active`.
- **Encrypted gp3:** the disk holds private keys.
- **Shutdown behavior Stop:** "Terminate" would delete the VM on an internal shutdown.
- **Credit specification Standard:** the t3 default is Unlimited, which can bill extra. Standard slows down instead.
- **IMDSv2 required, hop limit 1:** this blocks the classic attack where a forged web request steals a host's role credentials. A request without a token now gets `401`, which we confirmed.

SSM only came `Online` after the Elastic IP was attached, because the agent connects outbound and a host in a public subnet still needs a public address to reach the internet.

### Part 4: The package mirror test

The public NACL allows outbound 443 but not 80, and Ubuntu's sources used `http://`. The test proved it: HTTP timed out, and HTTPS returned 200. We switched apt to the HTTPS regional mirror rather than opening port 80.

A subtle point: apt already verifies packages with GPG signatures, so HTTPS wasn't needed for package integrity. The choice was about firewall policy, because opening port 80 widens the rules for all traffic, not only updates. An own mirror or proxy is parked for after Tier 1.

### Part 5: Delegating a subdomain

NS records say which servers answer for a name. Moving a whole domain would have broken the email forwarding on it, so you delegated one subdomain instead, by adding NS records for it at the parent's DNS provider. Everything else stayed put, which `dig` confirmed. This limits **blast radius**: a mistake in the lab zone can't touch the parent.

### Part 6: The offline CA

OpenVPN accepts any certificate your CA signed, and a certificate's name picks its pool. So whoever holds the CA private key can mint themselves an admin. The server never needs that key, because it verifies clients with the public `ca.crt`.

So the CA stays on your laptop, passphrase-protected, and fw-ips receives only `ca.crt`, its server cert and key, the CRL and the `tls-crypt` key. Taking over fw-ips doesn't give an attacker the ability to issue certificates. The cost is that revoking means signing a new CRL on the laptop and copying it over, which scenario 2.2 will measure.

We chose EC keys on `secp384r1` for small keys and fast handshakes. The server key has no passphrase because OpenVPN must start unattended after a reboot, which is why it's the one unencrypted key and has strict permissions. Server and client certificates are marked differently, so a stolen client cert can't impersonate the server.

A CRL is a signed list of revoked serials. `revoke` alone changes nothing on the server, because only a new `gen-crl` and a copy to fw-ips tell it anything. If a CRL expires, OpenVPN rejects everyone, so it must be re-signed before then.

### Part 7: The finding of the day

Writing up the CA backup, we stated that no instance role could read `/vpn/`. Nobody had checked. Reading `AmazonSSMManagedInstanceCore` showed `ssm:GetParameter` on `Resource: *`, and the IAM simulator returned `allowed`. Encryption didn't help either, because the default `aws/ssm` KMS key decrypts through SSM for anyone in the account allowed to call it.

So every host could have read every secret, including the proxy reading the database password. That defeats "one role per instance", and it was in the design from the start.

The fix was a customer-managed copy of the policy, minus those two actions, plus a narrow inline grant for `/vpn/fw-ips/*`. Now a new host reads nothing until granted, which is called **failing safe**. An explicit `Deny` per host would have failed open: forget one and the secrets are readable. The simulator then returned `implicitDeny` for the CA key, and a real call from fw-ips returned `AccessDeniedException`.

The lessons: a managed policy's name tells you nothing about what it grants, "encrypted" doesn't mean "restricted", and a test from the real host beats a simulator.

### Part 8: tls-crypt and OpenVPN

`tls-crypt` encrypts and authenticates the handshake with a shared key. A packet without it is dropped before TLS starts, so scanners get nothing and your certificates stay hidden. The weakness is that the key is shared by all clients, so a stolen profile exposes it, though it still doesn't let anyone in without a valid cert.

`tun0` uses a `/23`, covering both pools. Automatic addresses come only from the user range, and a `ccd` file gives the admin device its fixed address and an extra route.

You chose dynamic user addresses over `ccd-exclusive`, so that scenario 2.2 has to prove who held an address from the logs. Know the cost: those logs become required evidence, and any valid cert can connect, so revocation is the only way to cut one off.

The log taught something too. `MULTI_sva: pool returned` showed the admin device with a user address, but that line comes before the `ccd` file is applied. The final address is on the `primary virtual IP` line, and Wazuh must use that one.

### Mistakes and what they taught

| What happened | The lesson |
|---|---|
| Docs claimed no role could read `/vpn/` | A security claim needs a test, not an assumption |
| First simulator query printed a strange line | With several resources, results sit in a nested field |
| Steps were checked before they were done | Read each output against the expected one |
| Multi-line pastes lost lines to `sudo` and `apt-get` | Those commands read stdin; paste one command at a time |
| `KEY-MATCHES-CERT` passed with empty files | A comparison of two empty values is true; check for empty first |
| Fetch wrote 0-byte files with exit 0 | Exit 0 isn't proof; the snap `aws` wrote nothing to a file but worked through a pipe. The root cause is still unknown |
| First guess blamed `umask` | Test one thing at a time instead of changing fixes on a guess |
| A `ca.key` turned up on the VM | It was OpenVPN's sample file; look before assuming the worst |
| `pool returned` showed the wrong address | Read the whole log sequence, not one line |

### Decisions from today

Full reasoning is in `rationale.md`, entries 18 to 24.

| Topic | Choice | Why |
|---|---|---|
| fw-ips OS | Ubuntu 24.04 LTS | Long support, SSM agent included |
| `<domain>` | Delegated subdomain | Parent domain stays untouched |
| Packages | HTTPS mirror | Port 80 stays closed |
| VPN CA | Offline on the laptop | Compromising fw-ips can't mint certificates |
| Instance roles | Own minimal SSM policy | The AWS policy reads every parameter |
| VPN addresses | Dynamic users, fixed admin | Attribution has to be proven from logs |
| Between sessions | Stop, release the Elastic IP | Keeps the hand build at almost no cost |

### Interview questions to practise

1. What does IMDSv2 protect against, and why does a hop limit of 1 help?
2. Why does an instance in a public subnet still need a public IP to reach SSM?
3. What's the difference between a trust policy and a permission policy?
4. What is an instance profile?
5. Why doesn't `AmazonSSMManagedInstanceCore` count as least privilege?
6. Why didn't `SecureString` stop a host reading the CA backup?
7. Why does an explicit `Deny` fail open as a design, even though `Deny` beats `Allow`?
8. Why doesn't fw-ips need the CA private key?
9. Walk through revoking a stolen certificate. When does it actually stop working?
10. What happens when a CRL expires?
11. What does `tls-crypt` add on top of TLS, and what's its weakness?
12. Why was HTTPS for apt a firewall decision and not an integrity decision?
13. How does delegating a subdomain limit blast radius?
14. How would you prove which device held a VPN IP at a given time?

### What comes next

You write the 1.9a ruleset: forwarding and NAT for private subnets, with a forward chain that drops by default. Once it's reviewed, a small temporary private VM proves that SSM works through fw-ips. Each session now starts by giving fw-ips a new Elastic IP and updating the `vpn` record.

### Evening session: from a VPN server to a working security gateway

This morning fw-ips could only accept VPN connections. By tonight it routes traffic, enforces the §4 policy, answers private DNS and inspects traffic inline. Nothing else in the lab exists yet, so every later host inherits what you built here.

A note on authorship: `CLAUDE.md` says you write the nftables and Suricata rules. Tonight you explicitly asked me to write them. That was your call, but it raises the bar for you: you must still be able to defend each line, so reread both files slowly with this section beside you.

### Part 9: One interface changes everything

fw-ips has one ENI, so internet and VPC traffic both enter and leave on `ens5`. A rule saying "output interface is the internet" would also match traffic to the VPC, so the rules match on addresses instead. This shape is called a **router on a stick**.

It also explains `send_redirects = 0`. When a packet leaves by the interface it came in on, Linux assumes the sender could go direct and tells it so. On a firewall, that advice means "bypass me". The kernel combines the `all` setting and the interface setting with OR, so both must be 0.

### Part 10: Two NATs and a preserved address

`snat ip to 10.0.1.10` rewrites private sources, and the internet gateway then maps that address to the Elastic IP. Because the gateway does the second step, the Elastic IP can change each session with no firewall change. `masquerade` looks up the address on each new connection, which suits addresses that change; ours doesn't.

NAT applies only to private subnets going to non-VPC addresses. VPN pools are never NATed, and your `FW-DROP` lines proved it, showing `SRC=10.8.1.10`. Without that, every event would look like it came from fw-ips, and scenario 2.2 couldn't attribute anything.

### Part 11: Stateful rules and the three chains

`ct state established,related accept` is why only new connections need rules. `input` handles traffic for fw-ips itself, `forward` handles traffic passing through, and `output` stays open because §4 doesn't define it and SSM, apt and DNS all start from fw-ips.

Two details are easy to miss. `sg-fw` doesn't filter VPN clients, because their traffic arrives on `tun0` after decryption, so `input` is the only protection there. And matching `tun0` as well as the source address means a forged `10.8.x.x` packet on `ens5` fits no rule.

The test where you added a route to `mgmt` by hand matters most. A missing route isn't protection, because a client controls its own routes. Only the firewall stopped it.

### Part 12: Safe changes to a firewall

An `input` drop can lock you out, so we loaded a test file by hand and only then replaced `/etc/nftables.conf`. If it had gone wrong, a stop and start would have restored the last good rules. `nft -f` is also atomic, so a bad file changes nothing. Then a reboot tested what a live load can't: boot order, `iifname` matching a `tun0` that doesn't exist yet, and DHCP under the new policy.

### Part 13: DNS, and a conclusion I got wrong

Unbound answers `mail.<domain>` from a `static` zone for that exact name, so the `vpn` record and `_acme-challenge` still resolve publicly. A zone covering the whole domain would have broken DNS-01.

Clients were pushed DNS 10.0.1.10 with no route to it, which is why `aws` hung with the VPN up. A pushed /32 fixed that without exposing anything else in the public subnet.

Then forwarded names returned `SERVFAIL`. I tested with `+cd`, it still failed, and I told you it wasn't DNSSEC. The Unbound log proved me wrong: `failed to prime trust anchor`. AWS's resolver returned no `RRSIG` records, so validation failed for everything. We turned it off with `module-config: "iterator"`. The argument you can defend is that the path to 10.0.0.2 stays inside AWS, and TLS stops a forged address being trusted. Until production certs arrive, `curl -k` removes that protection.

The known gap: security groups and NACLs don't filter AmazonProvidedDNS, so a compromised private host can query it directly. Changing DHCP wouldn't fix that, because a host can still ask 10.0.0.2. Scenario 2.2 will test it. Also keep the wider point in mind: TCP 443 to anywhere is an easier way out than DNS.

### Part 14: Suricata inline

A rule accepted by Suricata skips the rest of its chain, so the `ips` chain sits at `priority filter + 10`, after the firewall. Your port 22 test proved the order: the firewall dropped it, and it never reached `eve.json`.

The packaged service runs `--af-packet`, which only listens, and `/etc/default/suricata` looks right but isn't read by the service. An empty `ExecStart=` in a drop-in clears the packaged command. Read what actually runs, not what a config file implies.

Plain `queue`, without `bypass`, fails closed. `tcpdump` showed 2 SYNs with Suricata running and 0 with it stopped, while the VPN and SSM stayed up, because `input` and `output` aren't queued. The cost is a gap of about 35 seconds at each start.

Two design truths came out of this, and the first changed §11. TLS ends at Nginx, so Suricata can't see web payloads; only ModSecurity can. And anything the firewall drops never reaches Suricata, so scans of blocked ports appear as `FW-DROP`. I said Suricata would handle scans, and your own test showed that was wrong.

### Part 15: Rules, and why a clean capture matters

Five rules were written, and only the flood rule drops. The clean capture caught a real bug: `app-layer-protocol:!tls` fired on normal TLS, because it matched packets sent before detection finished. In production it would have alerted on every connection. `failed` waits for detection, but plain HTTP is a recognised protocol, so it needed its own rule.

A rule test needs a case that should not fire. Without `clean-tls.pcap`, that rule would have looked perfect.

The live result was exact: 80 attempts gave `ips.accepted` 60 and `ips.blocked` 20.

### Mistakes from tonight and what they taught

| What happened | The lesson |
|---|---|
| The test VM launched with the fw-ips role | Check the identity field on the launch page; CloudTrail proved no parameters were read |
| Docs said B would close the DNS gap | A DHCP option only changes a default, not what a host can do |
| I said `+cd` ruled out DNSSEC | One test isn't proof; read the service's own log |
| I said Suricata would handle scans | Your test disproved it, so trust evidence over the plan |
| `!tls` fired on clean TLS | Always test a case that should not match |
| A long `base64` line was mangled | Terminals corrupt long pastes; a checksum shows it, and SSM `send-command` avoids it |
| nano showed a blank file | Exit without saving; a display fault could have wiped the config, and `sed` avoided the problem |
| Descriptions got pasted with commands | Copy only the command block |
| An empty `grep` looked like a failure | Flow records appear late; read the counters instead of waiting |
| `reload-rules` was refused | Still unexplained; say so instead of inventing a cause |

### Decisions from tonight

Full reasoning is in `rationale.md`, entries 25 to 35.

| Topic | Choice | Why |
|---|---|---|
| Forwarding | Match addresses, `snat` | One interface, fixed address |
| Suricata position | Separate later chain | Firewall rules stay in force |
| VPN DNS | Pushed /32 route | Name resolves, nothing else exposed |
| fw-ips input | Default drop, open output | Protects the host without breaking SSM |
| Private host DNS | Keep AWS resolver | Recorded gap, tested in 2.2 |
| DNSSEC | Off in Unbound | AWS returns no signatures |
| Web payloads | ModSecurity only | TLS ends at Nginx |
| Suricata failure | Fail closed | Can't be stopped to avoid it |
| Custom rules | Only the flood rule drops | A wrong match can't block real traffic |

### Interview questions to practise

1. Why can't interface matching separate internet from VPC traffic on fw-ips?
2. Why must `send_redirects` be off on a one-interface firewall, and why set it in three places?
3. When would you choose `snat` over `masquerade`?
4. Why doesn't changing the Elastic IP require a firewall change?
5. Why doesn't `sg-fw` protect fw-ips from a VPN client?
6. Why isn't a missing route a security control?
7. Why load a firewall from a test file before making it permanent?
8. What does `iifname` allow that `iif` doesn't at boot?
9. What's the difference between `static` and `transparent` local zones?
10. Why did DNSSEC validation fail, and what stops a forged answer now?
11. Why doesn't pointing DHCP at Unbound close the DNS gap?
12. Why does a separate chain matter for NFQUEUE?
13. What does fail-closed cost, and why was it acceptable here?
14. Why can't Suricata see a SQL injection in this design?
15. Why did `!tls` fire on clean traffic?
16. Why does a test suite need cases that must not match?

### What comes next

fw-ips is finished by hand but exists only on one disk. Next, decide how Ansible connects over SSM, write the `fw_ips` role part by part, write 1.6, and rebuild fw-ips from code. Only then start `db`.

## 2026-11-02

### Today's topic: turning a hand-built server into code, and proving it

Yesterday fw-ips worked, but it existed on one disk. If that disk had died, the lab's front door would have gone with it, along with every decision baked into its config files. Today you turned that host into code, Terraform for the AWS side and an Ansible role for everything inside it, and then did the thing that makes code trustworthy: you threw the original away and rebuilt it from the code alone.

The rebuild found a gap that a careful audit had missed. That is the main lesson of the day.

### The big picture

Infrastructure as code has two halves. Terraform describes what exists in AWS: instances, addresses, roles and records. Ansible describes what's inside a host: packages, files and services. Neither is worth much until it has rebuilt something from nothing, because "the plan looks right" is a belief and "a fresh host passed every check" is evidence.

The method we follow for every layer (decision 11) is: build by hand, test, compare with code, destroy, rebuild from code, re-test. Today fw-ips finished that loop.

### Part 1: How Ansible reaches a host with no SSH port

Ansible is agentless. For each task it connects, copies a small Python module, runs it and reads back JSON. Its normal transport is SSH, but no security group, NACL or nftables rule allows port 22, and none should.

Every host already runs the SSM agent, which keeps an outbound 443 connection to AWS. `aws ssm start-session --document-name AWS-StartSSHSession` carries an SSH session inside that connection to sshd on the host's loopback. A `ProxyCommand` in the connection variables makes this automatic, so `ansible fw_ips -m ping` just works.

We compared three options (decision 36). The `aws_ssm` connection plugin needs no SSH, but it moves files through an S3 bucket, which would have meant giving the instance role S3 access and undoing part of decision 22. SSH over the VPN would open port 22 in three places, and on fw-ips Ansible would be managing OpenVPN over OpenVPN: one bad push and the connection it runs on is gone.

Two details are worth knowing:

- **Two independent secrets.** Reaching a host needs an AWS session for SSM and the SSH key. A stolen laptop key alone reaches nothing.
- **`IdentitiesOnly=yes`.** Your agent held five keys. By default SSH offers each one, and sshd disconnects after six failures. It would also have offered your unrelated keys to a lab host.

Then we made sshd listen on `127.0.0.1` and `::1` only. Because the tunnel arrives on loopback, Ansible kept working, and a future firewall mistake would find nothing listening on the network. On Ubuntu 24.04 sshd is **socket-activated**: systemd opens port 22 itself, built from `ListenAddress` by a generator. So a config change needs `daemon-reload` and a restart of `ssh.socket`, not only of the service. We checked this on the host before writing the task, rather than assuming it.

### Part 2: The safe way to bring a live host under configuration management

fw-ips was already running and correct. The danger in writing a role for it is that the role quietly changes something. Each part followed the same pattern:

1. Compare the repo file with the live file (checksums, then `diff`).
2. Run `ansible-playbook --check --diff`, which shows what would change without changing it.
3. Apply, then run again and expect `changed=0`.
4. Check behaviour, not only files.

This caught real drift. The live `nftables.conf`, Unbound config and OpenVPN drop-in differed from the repo only in comments, and the diff showed exactly that before anything was written. For nftables we went further: the loaded ruleset's checksum (`nft -s list ruleset`, without counters) was identical before and after, which proves the reload changed no rule.

Some techniques that appeared along the way:

- **`validate:`** on a `copy` task tests the new file before it replaces the old one (`sshd -t`, `nft -c`, `unbound-checkconf`, `suricata -T`). A broken file never goes live.
- **`meta: flush_handlers`** runs pending handlers immediately. We used it so kernel forwarding is on before the firewall loads, and so the apt cache is refreshed before any package is installed.
- **Handlers that share a `listen` name** run in order from one `notify`, which is how sshd gets `daemon-reload`, then a socket restart, then a service restart.
- **`changed_when`** tells Ansible what "changed" means for a command, which can't know on its own.

### Part 3: Owning a big upstream file

`suricata.yaml` is 2,150 lines, and the hand build changed three of them. We chose to own the whole file (decision 37) and committed it in two steps: Ubuntu's untouched copy, then our edits. Now `git show` on the second commit shows exactly `HOME_NET`, the `eve` types and `local.rules`, which is easy to defend line by line. Targeted `lineinfile` edits would have been smaller but fragile, and `--set` overrides depend on list positions in someone else's file.

Two side effects taught something. The upstream file contains `{%` inside a comment, which Jinja would read as a block, so it's installed with `copy`, not `template`. And `ansible-lint` flagged 270 style issues inside upstream's file, so that one file is excluded, with a comment saying why. Fixing someone else's style would have destroyed the clean diff.

### Part 4: A mystery solved by testing a hypothesis

Yesterday `suricatasc -c reload-rules` was refused, and the cause was unknown. The logs showed the refusal actually happened during a service stop, and a socket file existed with nothing listening on it. The hypothesis was that the `suricata -r <pcap>` tests from 1.12 open their own command socket at the same path, replacing the daemon's.

We tested it: before an offline run, `suricatasc` answered; after it, `Connection refused`, and the socket file had a new inode. With `--set unix-command.enabled=no` the socket survived, and `suricata -T` never touched it. So the cause was the tests, not reloading (decision 38).

There was a second lesson inside this one. After restarting Suricata, my first check said it was still broken, because I checked too early: Suricata opens its socket only after loading 53,000 rules, about 30 seconds after start. My "fix" test ran in that window and proved nothing, so we repeated it. A test that runs before the system is ready is not a result.

Knowing the cause made the update design simple: a daily systemd timer runs `suricata-update`, which tests the new rules with `suricata -T` and then runs `reload-rules`. Reading `suricata-update`'s source showed it reloads only when rules changed, and restores the old rules if the test fails. A forced run kept the same Suricata process, so traffic never paused, unlike a restart, which stops forwarded traffic for about 30 seconds because Suricata fails closed. Measuring memory during the run found the tightest point: 209 MB free on a 2 GB host, because a reload briefly holds two rule engines alongside the test. That number is now in rationale 38, to recheck when Wazuh arrives.

### Part 5: Secrets pulled, not pushed

The OpenVPN server needs two secrets, the server key and the `tls-crypt` key. We chose to have fw-ips pull its own files with its instance role (decision 39) instead of having the laptop push them. The role can read `/vpn/fw-ips/*` and nothing else, so the secret goes from SSM to the host and nowhere else.

A small helper does the work. It pipes the value into a 0600 temp file in the same directory (the pipe works around the snap `aws` writing 0 bytes to a file), compares it with the current file, and replaces it with an atomic `mv` only if it differs. It prints only `changed` or `unchanged`, and the tasks use `no_log`. In check mode it only compares. The dry run on the live host reported all five files unchanged, which proved the SSM copies and the live files were identical, without showing either.

A CRL change needs no restart, because OpenVPN re-reads `crl-verify` on each new connection. A key change does restart OpenVPN, and that's safe because Ansible runs over SSM, not over the VPN it's restarting.

### Part 6: Terraform for fw-ips, and a bug the plan revealed

IAM was imported unchanged, written as `aws_iam_policy_document` blocks that match the live policies by meaning. The instance attaches the standalone ENI through `primary_network_interface`, the provider 6 replacement for the deprecated `network_interface` block. That was checked in the installed provider's schema, not assumed.

The first plan showed `source_dest_check = true` on the new instance. On the primary interface, that flag is the ENI's own check, and with it on, AWS drops every packet fw-ips forwards. The provider refused an explicit `false` alongside `primary_network_interface`, so the fix is `ignore_changes = [source_dest_check]`, leaving the network module as the only owner. The second plan after the rebuild showed no changes, which confirmed it.

CI caught a second problem: `tflint` evaluates `file()`, and the runner has no `~/.ssh`. The public key is now passed as a value in the untracked `terraform.tfvars`, so the code reads nothing outside the repo.

### Part 7: Proving it before trusting it

Before approving the rebuild, you asked for proof that the code would create exactly what was running. That was the right question. We compared the plan's instance attributes with the live instance (all identical except the key pair and cloud-init), scanned every path in the shell history, compared runtime state with saved files, and compared package versions.

That comparison found one real difference: the old host had a full `apt-get upgrade`. So the cloud-init `user_data` now sets the HTTPS mirror, runs a full upgrade and reboots if a new kernel needs it. The mirror line matters more than it looks: the public NACL allows 443 but not 80 (yesterday's Part 4), so an `http://` mirror at first boot would simply have failed.

Then the rebuild itself. The ENI was the old instance's primary interface, which AWS never detaches, so the old host had to be terminated, not stopped. My first plan to keep it stopped as a fallback was wrong, and the fallback became an AMI. The attachment had `DeleteOnTermination` off, so the ENI and its routes survived; the routes showed `blackhole` until the new instance attached it. You ran the apply yourself, because the permission rules block me from doing it.

The first Ansible run failed at the OpenVPN keys. The `aws` CLI snap had been installed by hand on the old host, and my audit had compared apt packages and files but not snaps. Rationale 39 even said the CLI shipped with the AMI, which was a belief, not a fact. The role now installs it, and a full package and snap comparison afterwards showed every apt package and the kernel identical, with no other gap. The third run reported `changed=0`, the nftables checksum matched the old host, and your VPN, ping and private DNS worked.

### Part 8: A session switch instead of a manual routine

With the instance, Elastic IP and record in Terraform state, releasing the IP by hand would have been drift. Now `terraform apply -var fw_enabled=false` destroys exactly four resources at the end of a session (decision 41). The `vpn` record goes too, so the name never points at a released address that someone else might be given. Adding `count` changes each resource's address, so `moved` blocks tell Terraform these are the same resources, not new ones; without them the plan would have replaced the running fw-ips.

### Part 9: What "rebuild from zero" really means

After the rebuild you asked whether Terraform and Ansible could now build everything from nothing. The honest answer was no, and why is worth understanding.

Today proved one layer: fw-ips, given that everything it depends on already exists. The network and security layer is in code but has never been built from clean (decision 16 deferred that to 1.20). The `persistent` stack doesn't exist in code at all: the state bucket that Terraform itself stores its state in, the Route 53 zone the `vpn` record looks up, and the SSM parameters fw-ips pulls its keys from were all made by hand. If any of them disappeared, `terraform apply` would fail before building anything. Some things stay outside code on purpose: the offline CA, the NS delegation at the parent domain, the laptop tools and the untracked files.

The lesson is to be precise about what a test proved. "fw-ips rebuilds from code" is true. "The lab rebuilds from code" isn't yet, and saying so is what tasks 1.2 and 1.20 are for.

We also kept the fallback AMI for one more session. As a rollback it's done its job, but it's the only copy of the hand-built host, useful if a second rebuild reveals another gap like the `aws` CLI. It costs well under a dollar a month, because snapshots bill only the data stored. A rule with a clear end ("delete after the next rebuild passes") beats keeping things "just in case".

Before `db`, the agreed order is: the second rebuild, small fixes (the `default` security group on the ENI, tighter IAM, rule 1000004), a decision on building the inventory from Terraform, and a decision on where the database password lives. Each is small, and each gets harder once more hosts exist.

### Mistakes and what they taught

- **I assumed the AMI shipped the `aws` CLI.** It didn't. Write down facts you checked, not things you expect, and when you audit, list every kind of state: apt packages, snaps, files, services, runtime settings.
- **I said the old instance could stay stopped as a fallback.** The primary ENI made that impossible. I caught it by checking the attachment before acting, which is why we check.
- **I checked Suricata's socket too early** and nearly drew a conclusion from a test that ran before the system was ready.
- **My first `apt-get update` count used the wrong pattern** and returned 0. The real output was the evidence, not the number.
- **The laptop VPN client exited twice** instead of reconnecting. The cause is unknown, and it's recorded as open rather than guessed.

### Decisions from today

Full reasoning is in `rationale.md`, entries 36 to 41.

| Topic | Choice | Why |
|---|---|---|
| Ansible transport | SSH inside SSM | Port 22 stays closed, two secrets needed |
| `suricata.yaml` | Own the whole file, two commits | Exact diff, drift visible |
| Rule updates | Daily timer with `reload-rules` | No fail-closed pause, catches up after downtime |
| VPN secrets | Host pulls with its own role | Laptop out of the secret's path |
| fw-ips in Terraform | Rebuild, import IAM and IP | Proves the code on a clean host |
| Between sessions | `fw_enabled=false` | Nothing idle billed, reviewed plan each time |

### Interview questions to practise

1. How does Ansible reach a host that has no SSH port open to any network?
2. What does an attacker need to reach a host in this design, and why is that two things, not one?
3. Why does `IdentitiesOnly` matter when your agent holds several keys?
4. Why doesn't changing `ListenAddress` take effect with a plain `systemctl restart ssh` on Ubuntu 24.04?
5. What does `--check --diff` prove, and what can't it prove?
6. Why own a whole upstream config file instead of editing three lines in place?
7. How did a test command break Suricata's reload, and how would you prove it?
8. Why reload rules instead of restarting an IPS that fails closed?
9. What is the difference between pushing a secret to a host and having the host pull it?
10. Why can't an instance's primary ENI be moved to a new instance while the old one exists?
11. Why must source/dest check stay off on a NAT or routing instance, and how could Terraform turn it on by accident?
12. What does a `moved` block do, and what happens without one when you add `count`?
13. Why did the rebuild find a gap that a careful audit missed?
14. Why remove the DNS record at the same time as the Elastic IP?
15. What did today's rebuild prove, and what does it not prove yet?
16. Why shouldn't Terraform naively create an SSM SecureString parameter?

### What comes next

Next session starts with the routine in TASKS: `terraform apply`, put the new instance ID in the inventory, wait for cloud-init, run the role, connect the VPN. That is the second build from code. If every check passes, delete the fallback AMI and its snapshot. Then task 1.13: the `db` host and its role, the first private host behind fw-ips.

### Afternoon session: closing "Before db"

The morning turned fw-ips into code. The afternoon worked through the four items agreed before `db`: a second rebuild from code, a set of small fixes, a way for Ansible to find hosts without hand-edited IDs, and a decision on where the database password lives. All four are done, through PRs 26 to 32 and decisions 42 to 46.

There's a common thread. Almost every fix made something **authoritative**: one place in code that states the whole truth, instead of a piece that adds to a truth held somewhere else. The ENI's security groups, the inventory and the password all moved that way.

### Part 10: The second build finds what the first one couldn't

The session routine (decision 41) creates four resources: the instance, an Elastic IP, the association between them, and the `vpn` record. The first apply failed on the association with `IncorrectInstanceState`: AWS won't attach an address to an ENI whose instance is still starting.

The cause is how Terraform orders work. It builds a **dependency graph** from references: if resource B mentions `A.id`, B waits for A. Everything else runs in parallel. The association referenced the Elastic IP (`aws_eip.fw[0].id`) and the ENI (`var.fw_eni_id`, a plain string passed in from the network module). It never mentioned the instance, so Terraform assumed they were independent and started both at once.

The fix is `depends_on = [aws_instance.fw]`. It's meant for exactly this case, where an ordering need is real but invisible in the references. Use it sparingly: every `depends_on` is a dependency Terraform can't infer, so it needs a comment saying why.

Why didn't the morning's rebuild hit this? Then the Elastic IP was imported and already associated. Only today were all four resources created from nothing at the same moment. That's why a second build matters: each build exercises a slightly different path through the code. The evidence for the fix comes at the next session start: one apply, `4 added`, no error.

The rest of the routine passed: cloud-init `done`, a first Ansible run with `failed=0`, a second with `changed=0`, VPN and private DNS working, and a plan with no changes. With two clean rebuilds behind it, the fallback AMI and its snapshot were deleted. We checked first that the running instance came from the stock Ubuntu image, not from the fallback.

A small detail from the idempotency check: the second Ansible run reported `ok=32` where the first reported `ok=42`. The ten missing are **handlers**. A handler runs only when a task that notifies it reports a change, so on a run where nothing changes, no handler runs.

### Part 11: Additive versus authoritative resources

The fw-ips ENI carried two security groups: `mailbridge-lab-fw` and the VPC `default`. §4 says sg-fw only. How did `default` get there?

Every ENI must have at least one security group. Ours was created in the network module without any, so AWS gave it `default`. The security module then used `aws_network_interface_sg_attachment`, which **adds one membership**. It manages "sg-fw is attached to this ENI", not "this ENI's groups are exactly X". Nothing in code ever said `default` shouldn't be there, so nothing removed it.

This pattern is everywhere in Terraform's AWS provider, and it's worth recognising:

| Additive (manages one piece) | Authoritative (manages the whole set) |
|---|---|
| `aws_network_interface_sg_attachment` | `security_groups` on `aws_network_interface` |
| `aws_iam_role_policy_attachment` | `aws_iam_role_policy_attachments_exclusive` |
| `aws_security_group_rule` | inline `ingress`/`egress` blocks |

Additive resources are flexible: several modules can each add their piece. But anything added outside code, by AWS or by hand, survives silently. Authoritative resources remove whatever code doesn't list, so drift becomes visible in the next plan.

We chose to make the ENI declare its full list (decision 42). Two details made that safe:

- **The `removed` block.** Simply deleting the attachment from code would make Terraform *destroy* it, which detaches sg-fw. Depending on the order of operations, the ENI could briefly be left with no group from §4. A `removed { lifecycle { destroy = false } }` block tells Terraform to forget the resource without touching it. The plan showed exactly that: the ENI changed in place, removing one group (looked up first: `default`), the attachment "no longer managed", and `0 to destroy`.
- **Modules that reference each other.** Now network takes sg-fw's ID from security, while security takes `vpc_id` from network. That sounds circular, but Terraform orders individual resources, not modules: VPC, then sg-fw, then ENI. There's no loop, so it's fine.

Verified: the ENI lists only `mailbridge-lab-fw`, the next plan shows no changes, and the VPN ping kept working throughout.

### Part 12: Least privilege, precisely

The fw-ips parameter grant read `arn:aws:ssm:eu-central-1:*:parameter/vpn/fw-ips/*`. The `*` sits in the account field. Was that a hole?

Not really. IAM never lets one account read another account's resources on its own policy alone: the resource's account has to grant access too. But least privilege means a policy should say exactly what it means, and this one said "any account". We replaced the `*` with values looked up from the `aws_caller_identity` and `aws_region` data sources (decision 43). Writing the account ID into the code was ruled out, because the repo is public.

The verification used the **IAM policy simulator**. For `ssm:GetParameter` it answered `allowed` on `/vpn/fw-ips/server.key`, and `implicitDeny` on `/vpn/ca/key` and `/mailbridge/db-password`. `implicitDeny` means no statement allows the call, which is IAM's default answer. Then a real Ansible run (`changed=0`) proved fw-ips could still pull its files under the narrower ARN.

The role's description also said "SSM access only", left over from before decision 39 added the parameter grant. Descriptions are documentation an auditor reads in the console, so they should be accurate too.

### Part 13: Telling Suricata which way a rule looks

Rule 1000004 drops a client that opens more than 60 connections to the proxy in 10 seconds. It matched `flags:S` with no `flow:` keyword.

Suricata tracks each TCP connection as a **flow** with two sides. `flow:to_server` matches packets from the side that opened the connection, and `flow:established` matches only after the three-way handshake has completed. The trap is combining them here. When a SYN arrives, the handshake hasn't happened yet, so `flow:established,to_server` would never match a SYN, and the flood rule would silently stop working. The right form is `flow:to_server` alone. `rev` goes from 1 to 2 because the logic changed, which lets alerts in a SIEM say which version fired.

Running the old and new files side by side on fw-ips showed this wasn't just style. The old rule logged a warning on every load: `SYN-only to port(s) 443:443 w/o direction specified, disabling for toclient direction`. Suricata had been guessing the direction since task 1.12, and nobody had read `suricata.log` closely enough to see it. The new rule fires on the flood capture exactly as before (10 hits), stays silent on clean TLS, and loads with no warnings.

### Part 14: Deploying a rule change safely

Looking at how the rule would be deployed turned up two weaknesses in the role:

1. **A rule change notified `Restart Suricata`.** Suricata fails closed, so while it restarts, all forwarded traffic stops. Decision 38 already used `reload-rules` for ET Open updates, but custom rules still restarted.
2. **Nothing checked `local.rules` before installing it.**

I first claimed that a broken rule would make Suricata fail to start. That was wrong. Our `suricata.yaml` doesn't set `init-failure-fatal`, so Suricata **skips** a rule it can't parse and starts anyway. The real risk is quieter and worse: the rule you think protects the proxy simply doesn't exist, and only a log line says so.

The fix (decision 44) has two parts:

- **Validate before install.** Ansible's `copy` module has a `validate` option: it writes the new file to a temporary path, runs a command on it, and replaces the live file only if the command exits 0. The command is `suricata -T -c /etc/suricata/suricata.yaml -S %s --set unix-command.enabled=no`. `-T` means test and exit. `-S` loads only this rule file. The socket flag keeps the test from replacing the running daemon's command socket, which was the cause of the morning's mystery. Before relying on it, we tested that `-T` really exits 1 on a broken rule and 0 on the current file. It does.
- **Reload instead of restart.** A new handler runs `suricatasc -c reload-rules`. One subtlety: `suricatasc` exits 0 even when the engine refuses. So the handler checks the *reply* for `"return": "OK"`, and retries for up to two minutes in case a restart ran just before it, as on a fresh host where both handlers fire.

The proof was Suricata's own uptime counter. It read 2007 seconds before the deploy and 2258 after. A restart would have reset it. `ruleset-stats` showed 53,265 rules loaded and 0 failed.

CI also caught something my laptop couldn't, because ansible-lint isn't installed there: a role's variables must start with the role name (`fw_ips_suricata_reload`). Linters like this keep variables from different roles from colliding.

### Part 15: Static versus dynamic inventory

Ansible reaches hosts through SSM, which addresses them by instance ID, and fw-ips gets a new ID every session. Until today a `sed` command copied that ID into an untracked `hosts.yml`. That's fine for one host. With five hosts, a stale or swapped ID either fails to connect or applies the `db` role to the wrong machine.

An inventory can be **static**, a file listing hosts, or **dynamic**, a plugin that asks a source of truth at run time. The options were B, Terraform writes the file, or C, a script turns `terraform output` into the file. Both keep a *copy* of the IDs and refresh it at certain moments. The `amazon.aws.aws_ec2` plugin (decision 45) keeps no copy. Each run, it asks EC2 for running instances tagged `Project=mailbridge-lab`, makes the `Role` tag the group, and uses the instance ID as `ansible_host`.

Points to be able to defend:

- **It adds no new access.** Ansible already needs your AWS credentials, because the SSM `ProxyCommand` calls `aws ssm start-session`.
- **Tags become part of security.** Whatever carries `Role=db` gets the `db` role. So only Terraform sets these tags, and only the admin user can change them.
- **Getting it working taught a dependency lesson.** The plugin needs `boto3` inside Ansible's own pipx venv. Then it failed again, because `aws login` credentials need botocore's optional **CRT** part (AWS's Common Runtime). The AWS CLI bundles it, which is why the CLI worked while Ansible didn't. `pipx inject ansible boto3` alone wasn't enough; we also needed `pipx inject --force ansible "botocore[crt]"`. The quotes stop zsh from treating `[crt]` as a filename pattern.
- **Some warnings aren't ours.** amazon.aws 11.4.0 prints a deprecation warning about the `tags` host variable on every run. Reading the plugin's source showed that its `parse()` method prints it unconditionally. Our file uses the new `ec2_tags`. We left the warning visible, because the only switch hides *all* deprecation warnings, including future ones that would concern our own code.

Verified: `ansible-inventory --graph` shows `fw_ips` → `mailbridge-lab-fw-ips`, ping returns `pong`, and `site.yml` reports `changed=0`. The real test is the next session: a brand-new instance should appear with no edit at all.

### Part 16: Secrets and Terraform state, in depth: sensitive, ephemeral, write-only

This part is the one to know cold. Write-only attributes and ephemeral resources are new (Terraform 1.10 and 1.11), many engineers haven't met them yet, and the reasoning behind them is a good test of whether you understand what Terraform actually does.

**What state is for.** Terraform is declarative: you describe the end result, and it works out the steps. To do that it must know three things: what the code says, what exists in AWS, and *which real object each resource in the code corresponds to*. The third lives in the **state file**. On each plan, Terraform refreshes state from AWS, compares it with the code, and proposes the difference. To compare, it stores every attribute of every managed resource. Every attribute: passwords included.

So the classic pattern, a `random_password` resource feeding `aws_ssm_parameter.value`, leaves the password in plain text in the state file. That file sits in our S3 bucket, encrypted and private, but it's still a second copy of the secret, readable by anyone who can read the bucket, and it's in every saved plan file too. Older tutorials accept this as the cost of doing it in code.

**Three different protections, often confused:**

| Kind | Shown in terminal? | Stored in plan file? | Stored in state? | Since |
|---|---|---|---|---|
| Normal attribute | yes | yes | yes | always |
| `sensitive` | no, `(sensitive value)` | yes | yes | 0.14/0.15 |
| Ephemeral resource or value | no | no | no | 1.10 |
| Write-only attribute | no, `(write-only attribute)` | no | no (null) | 1.11 |

- **`sensitive` is only about display.** It stops a value from being printed, and that's all. A common interview trap is "We mark it sensitive, so it's safe." It isn't; it's still in state.
- **An ephemeral resource** exists only while Terraform runs. Our `ephemeral "random_password" "db"` is generated in memory, used, and thrown away. You saw it in the apply output: `Opening...`, then `Closing...`. Because it's never stored, Terraform enforces where it can be used. An ephemeral value may flow only into places that also aren't stored: other ephemeral resources, provider configuration, ephemeral variables and outputs, and write-only attributes. Put it into a normal attribute and `terraform validate` refuses.
- **A write-only attribute** is the bridge to real infrastructure. The provider receives the value during apply and sends it to AWS, and Terraform records `null`. Our AWS provider (6.71.0) offers `value_wo` on `aws_ssm_parameter`.

**Why `value_wo_version` exists.** Normally Terraform decides whether to update something by comparing the code's value with the stored one. With a write-only value there's nothing stored to compare. Worse, our ephemeral password generates a *new* random value on every run. If Terraform sent the value whenever it differed, it would rotate the password on every apply. So the provider pairs the write-only attribute with an ordinary number, `value_wo_version`. The value is sent on create, and afterwards only when the version changes. That's why the second plan said `No changes`, even though it had generated a brand-new password in memory and discarded it.

**Rotation, step by step:**
1. Bump `value_wo_version` from 1 to 2 and apply: SSM gets a new value.
2. Re-run the `db` role, which sets PostgreSQL's password from SSM.
3. Re-run the `app` role, which picks it up.

Between steps 1 and 3 the app holds the old password, so rotation is a short, planned maintenance step. Proper zero-downtime rotation needs two valid credentials at once, which is what Vault-style dynamic credentials or Secrets Manager rotation provide.

**The evidence, not just the theory:**
- The saved plan, read as JSON with `terraform show -json`, had no `value` and no `value_wo`, and not one 40-character alphanumeric string anywhere.
- After apply, the state had `value_wo: null`, `value: ""` and `value_wo_version: 1`.
- The real value, read from SSM into a shell variable that was never printed, appeared in the state **0 times**.
- The plan *displayed* `value = (sensitive value)` before apply. That's the provider's computed attribute, and it ended up empty. Reading the plan's labels is a skill in itself: "sensitive" means stored but hidden, "write-only" means never stored.

**What this doesn't solve.** The password is now protected by IAM instead of by state hygiene. Anyone with `ssm:GetParameter` on that name, plus decrypt rights on the `aws/ssm` key, can read it: today that's only the admin, and later the `db` and `app` instance roles, each granted that one ARN. Terraform also can't detect drift in the value, because it never knows it. If someone changes the parameter by hand, no plan will notice.

**The alternatives, for comparison:**
- **B, by hand with `aws ssm put-parameter`:** also keeps the value out of state, but it's outside code, and the value passes through a terminal. The VPN CA key *must* be made this way, because the CA is offline on the laptop. A random password has no such reason.
- **C, the classic `value`:** the password ends up in state and plan files.

**The new stack.** This also started `terraform/persistent`, the stack for things that outlive the lab. It uses the same state bucket under its own key, `persistent/terraform.tfstate`, so a lab teardown can never reach it. It holds only the password for now. Task 1.2 imports the hand-built buckets, zone and Budget into it, one at a time.

### Mistakes from this afternoon and what they taught

- **The association race.** I assumed references captured every ordering need. Implicit dependencies come only from references. When an order matters and nothing in the code mentions it, say so with `depends_on`.
- **"A broken rule stops Suricata."** I said it before checking the config. Suricata skips the rule instead, which is quieter and worse. The fix was right, but the reason I gave was wrong. Check the failure mode before describing it.
- **A PR body said "reload" when the role restarted.** I read the handler afterwards and corrected the PR. Describe what the code does after reading it, not what you expect it to do.
- **A zsh trap printed the account ID.** In `"...::$A:role/..."`, zsh read `$A:r` as a modifier ("remove extension") and mangled the ARN. The error message echoed the account ID into the session output. Nothing reached the repo. In zsh, always write `${A}` when a colon follows a variable.
- **A merge attempt before CI registered.** `gh pr checks --watch` returned "no checks" for a fresh push, and branch protection correctly refused the merge. Wait for checks to appear before watching them.
- **The deprecation warning.** I first assumed our file triggered it and changed `tags` to `ec2_tags`. That was right to do, but it didn't stop the warning. Reading the plugin source showed the real cause. When a warning persists after a fix, go to the source rather than guessing again.

### Decisions from this afternoon

Full reasoning is in `rationale.md`, entries 42 to 46.

| # | Topic | Choice | Why |
|---|---|---|---|
| 42 | ENI security groups | ENI declares its full list; attachment forgotten with `removed` | Additive attachment left `default` on; forgetting never detaches sg-fw |
| 43 | fw-ips grant | Account and region from data sources | No `*` account, no ID in a public repo |
| 44 | Custom rule deploys | `-T -S` validation, then `reload-rules` | Broken rules fail the task; no fail-closed pause |
| 45 | Inventory | `aws_ec2` plugin by `Project` and `Role` tags | No copy of IDs to go stale; same credentials as SSM |
| 46 | DB password | Ephemeral password into write-only `value_wo` | In code, yet in no state, plan, repo or terminal |

### Interview questions to practise

1. How does Terraform decide the order in which to create resources? When do you need `depends_on`, and why use it sparingly?
2. Why can a second rebuild from code find a bug the first didn't?
3. What's the difference between `aws_network_interface_sg_attachment` and `security_groups` on the ENI? Name another additive/authoritative pair.
4. How do you stop Terraform from managing a resource without destroying it?
5. Two modules reference each other. Why isn't that a dependency cycle?
6. Is `*` in the account field of an IAM resource ARN a cross-account hole? Why or why not?
7. What does `implicitDeny` mean in the IAM policy simulator?
8. Why does a SYN-flood rule need `flow:to_server`, and why would `flow:established,to_server` break it?
9. What does Suricata do with a rule it can't parse, and why is that dangerous?
10. How does Ansible's `validate` option protect a live config file?
11. Why reload rules rather than restart an inline IPS, and how did you prove there was no restart?
12. `suricatasc` exits 0 even on failure. How do you handle a tool like that in automation?
13. Static versus dynamic inventory: what's the trade-off, and what new risk do tags introduce?
14. What is Terraform state for, and why does it end up containing secrets?
15. What does `sensitive` protect against, and what doesn't it protect against?
16. Explain ephemeral resources and write-only attributes. Where may an ephemeral value be used?
17. Why does a write-only attribute need a separate version attribute? How do you rotate the password?
18. How did you *prove* the password isn't in state, without printing it?
19. After this change, what still protects the password, and who can read it?
20. Why is the CA key created by hand while the DB password is created by Terraform?

### What comes next

The next session starts with the routine in TASKS, which no longer has an inventory step: `terraform apply` (expect `4 added` in one go, proving `depends_on`), `ansible-inventory --graph` (expect the new instance under `fw_ips` with no edit), cloud-init, `site.yml` twice, then the VPN checks.

Then task 1.13, `db`, the first private host. It needs:
- a Terraform instance with `Role=db`
- an instance role that may read only `/mailbridge/db-password`
- the `db` role: PostgreSQL, the app user with the password pulled on the host, and access from `app` only

## 2026-11-03

### Today's topic: the first private hosts, and secrets that never leave the host

This session started on the evening of 2026-11-02 and ran past midnight, so its decisions are dated 2026-11-02. It built the two hosts behind the firewall from code: `db` (task 1.13) and `app` (task 1.14). Along the way the lab got its first real data, its first container, a second AI agent working in the Mailbridge repo, and eleven decisions (47 to 57). The common thread is one question asked over and over: where does a secret travel, and who could see it on the way?

### The big picture

Before today, the lab was a network and one firewall. fw-ips had internet access from boot and held only its own VPN files. db and app are different in three ways. They are **private**: no route out except through fw-ips's NAT, so they depend on fw-ips being configured first. They hold **secrets that other hosts need**: the DB password is used by db and by app. And app is a **supply chain**: its code comes from another repository, through a registry, into a container.

The build order in §13 (network → fw-ips → db → app → proxy → siem) exists so each host can be tested against its real dependency. db was tested against the real firewall, and app against the real database. The one test that couldn't happen yet ("proxy can reach app") moved to 1.15, where proxy will exist, instead of being faked with a throwaway VM (decision 48).

### Part 1: The session routine proves the last session's fixes

The session opened with the routine from decision 41: `terraform apply` with a saved plan, the dynamic inventory, cloud-init, two Ansible runs, the VPN checks. Two things were proven for the first time on a brand-new instance:

- **`depends_on` on the Elastic IP association** (PR 26). The apply log showed the association starting only after `aws_instance.fw[0]: Creation complete`, and all 4 resources were created in one run. Last session the same apply failed with `IncorrectInstanceState`.
- **The `aws_ec2` dynamic inventory** (decision 45). The new instance appeared under `fw_ips` without anyone editing a file.

A small lesson came from `dig`: the docs write `mail.<domain>`, and typing that literally in zsh is a parse error, because `<` and `>` are redirection. Placeholders in docs are to be replaced, not typed. And the real name is the delegated subdomain, not the parent domain, which is why `mail.<parent>` returned nothing.

### Part 2: Four decisions before writing any db code

**How db gets its password (decision 47).** The password was created in SSM by Terraform (decision 46) and nobody has seen it. The cleanest path is the one fw-ips already uses (decision 39): db's own instance role reads exactly that one parameter, and a helper on the host uses it. The laptop and Ansible's output never hold it. The alternative, Ansible reading it on the laptop with `no_log`, fails the moment someone forgets `no_log` or runs `-vvv`.

**How to verify db before app exists (decision 48).** PostgreSQL has three gates: the network (security group and NACL), the listener (`listen_addresses`), and `pg_hba.conf` (who may log in as whom, from where, with which method). A good test shows which gate decided. So 1.13 proved db's own gates, and "app connects" and "proxy is refused" moved to the tasks where those hosts are built.

**What happens to the data between sessions (decision 49).** Decision 41 destroys instances after each session. For fw-ips that's free, because it holds no state. db holds data. The concept here is **compute versus state**: servers should be disposable, data should have its own lifecycle (a separate volume or backups). We chose to accept an empty database each session until T2.3 brings `pg_dump` to S3 and a tested restore. That costs nothing, proves the db build from clean every session, and in Tier 1 only test accounts exist.

**Boot order (decision 50).** fw-ips forwards nothing until Ansible installs its NAT rules, which happens after the apply. A private host starting in the same apply has no network for its first minutes. So private hosts' cloud-init only writes the HTTPS mirror config, a local file, and Ansible handles the order: the `fw_ips` play runs first, each private play starts with `wait_for_connection`, and the `common` role upgrades the host. The principle: **Terraform makes resources exist, Ansible makes hosts behave**, and ordering between hosts' configuration is a configuration concern.

### Part 3: Renaming a Terraform variable is free; renaming a resource is not

`fw_enabled` became `hosts_enabled`, and `fw_ami_id` became `ubuntu_ami_id` (decision 51). One switch for every session host means a teardown can't remove fw-ips and forget db, which would keep billing.

Why is this safe? Terraform tracks resources in state by **address**, such as `module.compute.aws_instance.fw[0]`. Variable names aren't part of any address, so renaming one changes nothing in state; the plan showed only db's resources to add. Renaming a *resource*, or adding `count` to one, does change its address. That's why last session needed `moved` blocks: without them Terraform would destroy the old address and create a new one.

### Part 4: Merge first, then run

After the db host code was ready, the plan was saved from the feature branch and an apply was suggested. Marko stopped this: shouldn't PRs be merged before anything runs? He was right. The rule is that AWS and the hosts only ever run code that's reviewed, passed CI and is merged. A plan from a branch could apply code that later changes or is abandoned, leaving resources nobody's code describes. From then on: merge on green CI, switch to `main`, pull, save a fresh plan, apply. Marko also gave a standing go-ahead for merging on green CI.

### Part 5: Extracting a `common` role, and proving a refactor changed nothing

db needed apt over HTTPS, unattended-upgrades, sshd on loopback and the SSM helper, all of which lived in `fw_ips`. Copying them (option B) leaves five copies by the time siem exists, and a fix in one but not the others is exactly the drift Phase 2 would find. So they moved into a `common` role, with `git mv` so their history followed.

A refactor should change nothing on the host. The proof was `ansible-playbook --check --diff --limit fw_ips`: the only changes were the header comments edited from "fw_ips role" to "common role", plus the handlers they trigger. Then the real runs, and `changed=0` on the second.

A surprise: the helper's copy task has `check_mode: false` (needed so later tasks can call it during a dry run), so even `--check` wrote it. Two dry runs swapped its header back and forth. Harmless here, but it means `--check` on this role isn't fully read-only, which is worth knowing before trusting a dry run on a production host.

### Part 6: How a secret leaks, and the password helper

This was the most important design discussion of the session (decision 52). A secret can leak through more paths than people expect:

- **argv**: every user can see every process's command line with `ps`. So `psql -c "ALTER ROLE ... PASSWORD 'x'"` leaks.
- **Files**: they end up in snapshots, AMIs and backups.
- **Logs**: PostgreSQL logs a failing statement together with its error by default (`log_min_error_statement`), so a failed `ALTER ROLE` would write the password to the server log.
- **Ansible variables**: anything Ansible holds travels back to the laptop and can be printed.

Safer channels exist: **environment variables** (`/proc/<pid>/environ` is readable only by the process owner and root) and **stdin** (a pipe leaves nothing behind).

`set-db-password` uses exactly those. It reads the value into a shell variable, checks it contains only letters and digits, tries a login on loopback with `PGPASSWORD`, and only if that fails pipes `ALTER ROLE` into `psql` through stdin, using `printf`, which is a shell builtin and so never appears in argv. Two `SET` lines first turn statement logging off for that session. It prints only `changed` or `unchanged`. The test login makes it idempotent without storing anything to compare against.

Two details worth defending. **Validating instead of escaping**: the password generator only produces letters and digits (decision 46), so the helper refuses anything else instead of trying to escape quotes correctly. Refusing is simpler and impossible to get subtly wrong. **The role name is checked too** (`^[a-z_]+$`) when the helper was generalized to two roles, because it goes into SQL; that's SQL injection prevention in a shell script.

The verification searched for the value in the `-v` run log and in PostgreSQL's logs. To avoid bringing the password to the laptop, the log was copied *to db* and searched there, then deleted. Result: 0 and 0.

### Part 7: Proving a firewall, not a missing route

The 1.13 check said: from the VPN admin pool, port 5432 on db must time out. The first attempt found the VPN down, but the more important point was this: the laptop has **no route** to 10.0.4.0/24. The admin pool only gets routes to the DMZ, fw-ips and mgmt. A packet to 10.0.4.10 would leave through the home Wi-Fi to the internet and time out there. That timeout would prove nothing about the firewall.

The real test plays an attacker with a stolen admin certificate who adds the route by hand (`ip route add 10.0.4.0/24 dev tun0`). Then the packet does enter the tunnel, and `nc` timing out means fw-ips dropped it. The proof is on fw-ips: `FW-DROP IN=tun0 SRC=10.8.1.10 DST=10.0.4.10 DPT=5432 SYN`, three lines for the original SYN and two retries. The same test later showed port 3000 on app is dropped too. **A negative test needs evidence of *why* it failed**, not just that it failed.

### Part 8: Working with a second agent, and checking its claims

Mailbridge lives in its own repo, so a second Claude agent was given a self-contained prompt: the lab's fixed constraints (port 3000 behind one proxy hop, PostgreSQL as a non-superuser owner of an empty database, egress 443 only, secrets as env vars, no registry pushes), and a two-stage task: inventory and gaps first, fixes only after an OK. That structure worked: it found real problems, like `TRUST_PROXY=0` silently breaking logins behind Nginx (the app thought every request was plain HTTP, so it never set its `Secure` cookie), and an app that exited on an empty database instead of creating its schema.

Three lessons from the collaboration:

- **My own placeholder caused a gap.** ARCHITECTURE said the OAuth redirect was `/oauth/callback`, written before anyone looked at the app. The agent proposed adding that route. The cheaper fix was changing the lab doc to the app's real routes, because a redirect URI is just a setting in the provider console.
- **Liveness versus readiness.** CodeQL flagged a new `/healthz` route as "missing rate limiting", because it ran a database query per request. The agent offered three options: dismiss it, add a dependency, or remove the route. The better answer was none of them. A **liveness** check ("is the process alive?") should be cheap and touch nothing. A **readiness** check ("can it serve work?") checks dependencies. Docker's `HEALTHCHECK` fires every 30 seconds and needs only liveness. Making `/healthz` liveness-only removed the alert for a real reason, not a dismissal.
- **Verify claims about safety.** Before re-enabling GitHub Actions in the app repo, the workflows were read: the publish job requires a repo variable `PUBLISH_IMAGE=true`, which doesn't exist, and the release job needs a `v*` tag, which doesn't exist. So "publishes nothing" was true, and now we knew why.

The agent's report also listed a Cyrillic search failure. A one-line query on the live db (`lower('ДОБАР ДЕН Ž')` returning lowercase, on a `C.UTF-8` database) showed it didn't apply to the lab. Checking is often faster than arguing.

### Part 9: The ECR repository: tags versus digests

An image has two names (decision 53). A **tag** like `mailbridge:v1.2` is a label that, by default, can be moved to a different image later. A **digest** like `mailbridge@sha256:...` is a hash of the content and can never point anywhere else. §3 already says app pulls by digest. Making tags **immutable** means a tag seen in a log also always names one image, and someone with push rights can't silently replace a release.

The lifecycle policy expires untagged images after a day and keeps the last 5 tagged ones, staying under ECR's free 500 MB. That created a trap worth knowing: modern `docker build` can produce an **image index** with untagged child manifests (for multiple platforms or build attestations). An "expire untagged" rule could delete those children and break the tagged image. The build therefore used `--platform linux/amd64 --provenance=false --sbom=false`, and the check after the push confirmed the type was a single `application/vnd.oci.image.manifest.v1+json`, not an index.

ECR's free scan reported 5 HIGH findings, while the app's Trivy run reported 0 fixable HIGH. Both are right: the 5 are in Debian base packages with no fix released, and ECR's basic scan doesn't show whether a fix exists. Two tools, two views of the same image.

### Part 10: Two database roles: separation of duties

In PostgreSQL, a table's **owner** can always alter or drop it, including its triggers. Mailbridge protects its audit log with an insert-only trigger. If the app connects as the owner, anyone with its credentials (SQL injection, a leaked environment, a shell in the container) can drop the trigger and rewrite history. So there are two identities (decision 54):

- **`mailbridge`**, the owner, used only by the short migration step.
- **`mailbridge_app`**, row access only, used by the long-running app.

db's Ansible role runs as the `postgres` superuser, so it can create both roles. The grants must be applied **after** each migration, because they name tables the migration creates. So app's start does it: migrate as the owner, then `psql -f db-roles.sql` as the owner, then the app as `mailbridge_app`.

The verification tested what an attacker holding the app's credentials could do: `DROP TRIGGER` → "must be owner"; `UPDATE audit_events`, `CREATE TABLE`, `TRUNCATE` and reading `pgmigrations` → "permission denied"; `ALTER TABLE` → "must be owner"; normal `SELECT` works. One test first failed for the wrong reason: `UPDATE audit_events SET event_id = event_id` gave "can only be updated to DEFAULT", because `event_id` is an identity column and PostgreSQL rejects that before it even checks privileges. **A test must fail for the reason you're testing**, so it was repeated on ordinary columns, which gave "permission denied".

`pg_trgm` was the only extension the migrations needed. PostgreSQL 13 and later mark some extensions **trusted**, which a non-superuser database owner may create; `pg_trgm` is one, so the owner role didn't need superuser.

### Part 11: Getting secrets into a container

The app reads secrets from environment variables (decision 56). Two facts shaped the design:

1. **Docker stores a container's env on disk**, in `config.v2.json` under `/var/lib/docker`, for as long as the container exists, even stopped, and `docker inspect` shows it to root. "Env var" doesn't automatically mean "memory only".
2. **Root on app can read SSM anyway**, by asking the instance role. Hiding values from root gains nothing. What matters is keeping them out of argv, logs, Ansible output and anything that outlives the service.

So each step of `mailbridge.service` is a small root-only script that pulls its own values from SSM into its environment and runs `docker run --rm -e NAME`. `-e NAME` without `=value` makes Docker copy the value from the environment, so it never appears in argv. `--rm` deletes the container, and Docker's stored copy of its env, as soon as it stops, and systemd's `Restart=on-failure` replaces Docker's `--restart`. The verification after `systemctl stop`: 0 containers left.

The image reference contains the account ID, which the public repo leaves out. So Ansible holds only the digest, and the start script builds the registry name on the host with `aws sts get-caller-identity`, a call that needs no permission. Docker pulls from ECR with the **credential helper**, which asks the instance role for a short-lived token on each pull, with caching turned off: no registry password is ever stored on app. Compare that to the laptop push, where `docker login` warned "credentials stored unencrypted", which is why the push ended with `docker logout`.

**The IMDS hop limit proved itself.** The instance has `http_put_response_hop_limit = 1`. A container sits one network hop further from the metadata service than the host, so the token request from inside the container timed out. A compromised app can't steal the instance role's credentials, even though the host can use them.

### Part 12: systemd and Docker, and a one-character bug

`mailbridge.service` chains `ExecStartPre` steps (pull, migrate, grants) before `ExecStart` (the app). Systemd runs them in order, and if any fails the app doesn't start. The app runs in the **foreground** (`Type=exec`, no `docker run -d`), so systemd sees it exit and can restart it.

The first run's journal showed `No such container: mailbridge` and the unit marked failed. The cause: when the app container exits, `--rm` deletes it immediately. Systemd then still runs `ExecStop=docker stop mailbridge`, which finds nothing and exits 1, and systemd counts that as a failure. The fix is one character: `ExecStop=-/usr/bin/docker stop ...`. The `-` prefix tells systemd that this command's failure doesn't matter. Verified: stop gives `Result=success`, start gives `/healthz` 200 (PR 46).

### Mistakes and what they taught

- **Planning from a branch.** Caught by Marko. Merge first, then plan from `main`; it's now a standing rule.
- **An AWS session expired mid-plan**, leaving a stale S3 state lock (`use_lockfile`). The fix is `terraform force-unlock`, but only after confirming three things from the lock info: the operation was a *plan* (not a half-finished apply), it came from this machine, and its timestamp matched the failed run. And no Terraform process was running. Never force-unlock blindly.
- **zsh's `:r` modifier.** `$ACC:role` became the account ID followed by `ole`, because `:r` strips a "file extension". Always write `${ACC}` when a colon follows.
- **Jinja ate a Docker format string.** `docker ps --format '{{.Names}}'` inside an Ansible ad-hoc command is parsed as a template. Use Docker's table output, or escape the braces.
- **`tail -1` cut an error message**, and a `grep` filter hid the column name that was being looked up. Debug output should be filtered less, not more.
- **The `--check` dry run wrote a file** because of `check_mode: false`. Know which tasks ignore check mode before trusting a dry run.
- **ansible-lint in CI doesn't install collections.** The new `community.postgresql` modules failed CI's syntax check until CI installed the pinned collections from `ansible/requirements.yml`. Reproducing CI locally in a clean venv with an empty collection path caught it before pushing.

### Decisions from this session

| # | Topic | Choice | Why |
|---|---|---|---|
| 47 | db's password | db's own role reads one ARN, sets it on the host | Value never on the laptop or in Ansible output |
| 48 | db verification | db's own gates now; app and proxy checks in their tasks | Each host tested against its real dependency |
| 49 | Data between sessions | Empty database each session until T2.3 backups | Free, proves the build from clean |
| 50 | Boot order | One apply; Ansible orders plays, `wait_for_connection` | fw-ips forwards only after its role runs |
| 51 | Session switch | `hosts_enabled` for every host; `ubuntu_ami_id` | A teardown can't forget a host; renames are state-neutral |
| 52 | Setting the password | Helper: test login, `ALTER ROLE` through stdin, logging off | No argv, file, log or Ansible variable |
| 53 | ECR | Immutable tags, scan on push, AWS-managed KMS, lifecycle | Tags always name one image; free |
| 54 | DB roles | Owner for migrations, `mailbridge_app` for the app | App credentials can't touch the audit log or schema |
| 55 | App secrets | Generated in `persistent`; OAuth secrets in 1.19 | Decision 46 pattern; OAuth is optional for 1.14 |
| 56 | Secrets into containers | Start scripts, `docker run --rm -e NAME`, systemd restarts | Out of argv and files; Docker's copy gone on stop |
| 57 | Build and push | By hand from the laptop now; CI with OIDC in T2.2 | No new credential; single-platform image |

### Interview questions to practise

1. Name four ways a secret can leak from a Linux host, and a safer channel for each.
2. Why does `PGPASSWORD=x psql ...` leak less than `psql -c "... PASSWORD 'x'"`? Who can still see it?
3. Why validate a password's characters instead of escaping it before putting it in SQL?
4. What are PostgreSQL's three gates for a network login? Which one gives "no pg_hba.conf entry"?
5. What's the difference between `peer` and `scram-sha-256` authentication?
6. Why can't you prove a firewall drops traffic just because `nc` times out? What evidence do you collect instead?
7. Why does renaming a Terraform variable not touch state, while renaming a resource does?
8. When is `terraform force-unlock` safe, and what do you check first?
9. What's the difference between a liveness and a readiness check? Which should a Docker `HEALTHCHECK` use?
10. Tag versus digest: which do you deploy by, and why make tags immutable as well?
11. Why can an "expire untagged images" lifecycle rule break a tagged image?
12. Why should an app not connect to its database as the table owner? How did you prove the runtime role is limited?
13. What does it mean that `pg_trgm` is a "trusted" extension?
14. Docker stores container env on disk. Where, and how did you limit how long secrets stay there?
15. How does the IMDS hop limit protect an instance role from a compromised container?
16. Why let systemd restart the container instead of Docker's `--restart`?
17. What does the `-` prefix on a systemd `ExecStop=` line do, and why did you need it?
18. Why must PRs be merged before their code is applied to infrastructure?
19. How do you verify a claim like "this CI workflow publishes nothing"?
20. Private hosts have no network at first boot. How does the lab still configure them in one apply?

### What comes next

Task 1.15, proxy: Nginx with TLS from Let's Encrypt staging (DNS-01 through Route 53 with the proxy's instance role), ModSecurity v3 with the OWASP CRS, and rate limits. The app's requirements are written down in its `docs/deployment.md` §3: `X-Forwarded-Proto`, `X-Forwarded-For` and `Host`, request bodies of at least 800 KB, proxy timeouts of at least 60 s, and the CRS JSON body processor. 1.15 also closes the last check left from decision 48: proxy can reach app on 3000.

The next session starts with the routine. Expect a 6-resource apply (fw-ips's 4, db, app). db comes up empty (decision 49), and app's start re-creates the schema and grants, so the routine itself proves both hosts rebuild from clean.

## 2026-11-04

### Today's topic: the edge of the lab, and how a security control breaks the thing it protects

This was the longest session so far. It started just after midnight (the proxy's decisions and code), ran out of usage, and resumed in the evening after a full teardown. It finished task 1.15, the proxy: Nginx, TLS 1.3, a Let's Encrypt certificate through lego, ModSecurity with the OWASP CRS, and rate limits. It then re-tested the Suricata rules against real TLS, which ended in an outage caused by one of those rules. In between it planned a deliberately vulnerable target (Juice Shop on a `vuln` host), reordered the remaining work, moved monitoring into Tier 1, and wrote the first Terraform for Wazuh.

### The big picture

Until today, a request from the VPN reached nothing: the proxy didn't exist. Now the full path works: laptop → OpenVPN → nftables → Suricata (inline) → Nginx (TLS ends here) → ModSecurity → the app → PostgreSQL. Every layer has its own log, its own failure mode and its own way of being wrong. The session's lesson is that each control has to be tested against **real** traffic, because synthetic tests only prove what you thought to put in them. Three times today a real-world detail broke an assumption: an engine too old for its rules, an app sending its own security header, and a TLS handshake split over two packets.

### Part 1: Starting again after losing access to the hosts

The hosts had been torn down, so the session began with the routine. The first Ansible command failed with `agent refused operation`. Two separate problems were stacked. GNOME's `gcr-ssh-agent` lists every key in `~/.ssh` and ignores `ssh-add -D`, and it couldn't sign. Underneath that, the key's passphrase had been forgotten, and a passphrase can't be recovered: it's the key that decrypts the private key.

The fix was a new key pair, and that taught something about Terraform. Changing `aws_key_pair`'s public key replaces only the key pair, because EC2 forces an instance replacement only when the key's **name** changes, and the name stayed the same. EC2 copies the public key into `authorized_keys` once, at launch, so the running hosts would still trust only the lost key. `terraform plan -replace=...` on the four instances rebuilt them in one apply. The fw-ips Elastic IP association wasn't replaced, because it's attached to the standalone ENI (decision 40), not to the instance. That's exactly why that design was chosen.

Small but real: `terraform show` writes colour codes into a pipe, so `grep '^  #'` matched nothing until `-no-color` was added.

### Part 2: The proxy's decisions

- **Where ModSecurity comes from (58).** The engine and Nginx connector come from Ubuntu's packages, so the module always matches the Nginx binary. The CRS comes from one pinned upstream release, checked against a SHA-256. The CRS is where the detection value is, and Ubuntu's 3.3.5 is old.
- **lego instead of Certbot (59).** One static Go binary, pinned by version and hash, with its build provenance checked with `gh attestation verify`. Certbot in noble is in universe without reliable security fixes. lego v5 also changed its CLI (`renew` is gone, `run` does both), which the v4 examples online would have got wrong.
- **The DNS-01 IAM grant (60).** proxy is the most exposed host. An unconditioned `ChangeResourceRecordSets` would let an attacker there repoint `vpn.<domain>`. IAM condition keys (`ChangeResourceRecordSetsNormalizedRecordNames`, `...RecordTypes`, `...Actions`, with `ForAllValues`) limit it to `UPSERT` and `DELETE` of one TXT record. The IAM simulator proved it before any host ran: allowed for the challenge record, `implicitDeny` for the `vpn` A record, another TXT name, `CREATE` and `ListHostedZones`.
- **TLS 1.3 only (61).** The only clients are the admin's own browsers, so TLS 1.2's compatibility buys nothing. An Nginx trap: `ssl_protocols` is taken from the **default** server on that address before Nginx knows the requested name, so both server blocks must set it.

### Part 3: Two headers, one winner (decision 62)

The first end-to-end request returned two `Strict-Transport-Security` headers: the app's one-year header first, then Nginx's 300 seconds. RFC 6797 says a browser obeys only the first. So the short staging value from decision 61, there to avoid pinning a browser to a broken certificate for a year, wasn't in force. `add_header` *adds*; it never replaces an upstream header. The fix is `proxy_hide_header` before `add_header`, so the TLS endpoint, Nginx, owns the header. The general idea: when two layers set the same security header, decide which one owns it.

### Part 4: Test before AWS, and the engine that was too old (decision 63)

The ModSecurity configuration was tested in a throwaway Ubuntu 24.04 container with the real packages before any host saw it. The first run failed: CRS 4.25.2 wouldn't load (`Rules error ... REQUEST-901 ... Line 333`). The CRS changelog for 4.25.1 says it needs libmodsecurity 3.0.16 or later. Ubuntu 24.04 ships 3.0.12, and 26.04 LTS only 3.0.14. A WAF is two pieces that must match, the engine and the rules, and the rules move faster than distribution engines.

The choice was CRS 4.25.0, the last release that loads, with what it lacks written down: an XML attribute fix (closed by accepting only JSON bodies, since the app takes nothing else), ReDoS hardening (capped by `SecPcreMatchLimit`) and a JSON-encoding bypass fix (accepted, and something to measure in Phase 2). Moving to a newer engine is a Tier 2 task. In an interview: "The fix needs an engine my LTS doesn't ship. I measured what I lose, closed the part I could, and scheduled the rest."

The container also caught three things that would have broken the app:
- the CRS's default allowed methods (no PUT, PATCH, DELETE)
- ModSecurity's 128 KB limit for bodies without files (the app's profile photos are 800 KB of JSON)
- random base64 in those photos tripping attack rules

For the last one, the fix wasn't to switch rules off. A local rule enforces the exact data-URL shape the app accepts (a positive security model), and only then are the attack rules skipped for that one field on that one route.

### Part 5: Blocking, paranoia and what a log may hold (64 to 66)

The CRS uses anomaly scoring: each matching rule adds points, and REQUEST-949 blocks at the threshold. With one admin over the VPN, a false positive costs a 403, so blocking started on day one at paranoia level 1. The audit log gets parts `ABFHZ`: headers and matched rules, no bodies. It goes to the SIEM, and v3 can't mask fields, so mail text and OAuth codes must never enter it. libmodsecurity 3.0.12 ignores `SecAuditLogFileMode`, so Ansible creates the file `0600` itself, without changing its timestamps so the run stays idempotent.

### Part 6: Rate limits as a leaky bucket (77, 78)

The app already throttles logins in Postgres, so every guess costs a database write. Nginx's `limit_req` is a leaky bucket: requests drain at a rate, `burst` lets that many extra through, `nodelay` serves them at once, and the rest get `429` before reaching the app. The live test gave six `401`s from the app and then `429`s, with two more `401`s in the middle. Those weren't a bug: 6 per minute means one new token every 10 seconds, and the loop took about 30 seconds. The log line named the zone and the real VPN address (no NAT). Two details: Ubuntu's `error_log` keeps only `error`, so `warn` lines vanish. And ModSecurity's connector runs in Nginx's rewrite phase, before `limit_req` (preaccess), so the limit protects the app, not ModSecurity.

### Part 7: Planning a deliberately vulnerable target (67 to 76)

Juice Shop has RCE and SSRF challenges by design, so placement is about blast radius. Next to Mailbridge it would share the kernel, the instance role, the secrets file and the path to the database. It gets its own host and subnet instead, with egress locked at the container (`DOCKER-USER`, unroutable DNS) and again outside the host (SG, NACL, nftables). Two AWS details came out of the planning. You can route traffic **between subnets** through an appliance with a route more specific than `local`, which gives Suricata the decrypted proxy→Juice Shop HTTP for free. But a security group can't reference another group across such a route, and the routes must be **symmetric**, or the firewall sees half a connection and drops it. That second point was caught while writing ARCHITECTURE: siem's replies would have crossed fw-ips while the agent's requests didn't. Also: two sibling subdomains are the same **site**, so `SameSite=Lax` doesn't separate them. Juice Shop gets its own browser profile.

The work was then reordered: Wazuh (1.16, 1.17), then monitoring (1.22, 1.23, moved into Tier 1), then Juice Shop, then the close-out. Every attack can then be followed through every layer, with its effect on the hosts, in one run.

### Part 8: The outage (decisions 79 to 82)

The Suricata rules from 1.12 were re-tested against real Nginx:
- **One rule never fired**, because Nginx answers any non-TLS bytes with an HTTP 400 and Suricata's protocol detection looks at both directions. The server's reply labelled the flow `http`.
- **Binary garbage did reach the "unidentified protocol" rule**, so it was kept, and the two rules now share a flowbit so each flow gives one alert.
- **A no-SNI rule was added**, because a client without SNI has no `tls.sni` buffer, and a negated content match has nothing to test.

Then two rules were promoted to `drop`, and Mailbridge stopped answering. `fast.log` showed `[Drop]` on the TLS 1.0 rule for normal `curl`s.

The first explanation (every ClientHello's record header says 0x0301) was **disproved** in the container. The real cause was found by changing one variable at a time. Current OpenSSL sends a post-quantum key share (X25519MLKEM768), which makes the ClientHello about 1,300 bytes. When that splits over two TCP segments, Suricata evaluates the rule on the first segment, where only the record header is known. The no-SNI rule had the same timing flaw. Service was restored in a minute by a hand edit and a rule reload, then the fix went through code: `ssl_state:client_hello` on 1000002, alert only, and the no-SNI rule disabled until a rewrite is tested. Three realistic TLS 1.3 captures now have to stay silent on every rule change.

What it teaches:
- an inline IPS fails **closed**, so a false positive is an outage
- `drop` belongs only on rules proven against realistic traffic, over a whole session
- synthetic test data is only as good as its realism
- `tail -8` hides history: the rule had misfired before, but nobody counted

### Part 9: Wazuh's first decisions (85 to 89)

Wazuh 4.14.9, pinned. Installed from its apt repository by our own role, not the all-in-one script, which isn't idempotent and leaves passwords in a tar file. A t3.medium with a 1.5 GB indexer heap, with t3.large as the fallback. The indexer's data lives on an encrypted volume in `persistent`, attached each session, with `stop_instance_before_detaching` so the OS shuts the indexer down cleanly. Passwords are generated into write-only SSM values (the Wazuh API needs its own character set), and certificates are made once on the laptop. A precondition stops the attachment from planning if the volume and the host are in different Availability Zones.

One process slip: the Terraform PR was merged before the teardown, so the teardown plan would have failed looking up a volume that didn't exist yet. Applying `persistent` first fixed it. The lesson is to check what a merge changes for the *next* command, not only for the code.

### Mistakes and what they taught

- **A lost passphrase** can't be recovered. Keep it in a password manager before typing it twice.
- **"Only the key changed" in a plan doesn't mean the hosts get the new key.** Read what forces replacement.
- **`terraform show` adds colour codes in a pipe.** Use `-no-color` for grep.
- **A glob that matched two files** (`mail.*.crt` also matched `.issuer.crt`) broke `openssl -in`.
- **Running Ansible from the repo root** found no inventory. `ansible.cfg` is read from the current directory.
- **`curl -w '%{ssl_version}'`** isn't a curl variable. Check before suggesting one.
- **A predicted 90-day certificate** was 64 days: Let's Encrypt is shortening lifetimes, and staging gets each step first.
- **GitHub Actions lost a PR's trigger event** during an incident. Reopening the PR sent a new one.
- **A rule promoted to `drop` on synthetic evidence** caused the outage. Realistic captures and a live session come first.
- **A hypothesis presented as the cause** was then disproved. Test it before stating it, and say so when it's wrong.

### Decisions from this session

| # | Topic | Choice | Why |
|---|---|---|---|
| 58 | ModSecurity sources | Ubuntu engine and connector, pinned upstream CRS | Module matches Nginx; current rules |
| 59 | ACME client | lego, pinned by hash and provenance | Static binary; no Python on the DMZ host |
| 60 | DNS-01 grant | One TXT record, UPSERT/DELETE, condition keys | An attacker on proxy can't repoint `vpn` |
| 61 | TLS | 1.3 only, HSTS short on staging, no OCSP | Only modern clients; matches the VPN |
| 62 | HSTS owner | Nginx hides the app's header | Browsers obey the first header |
| 63 | CRS version | 4.25.0, JSON-only bodies, engine move in T2.4 | 4.25.1+ needs an engine no LTS ships |
| 64 | Engine mode | Blocking from day one | One admin; false positives found early |
| 65 | Paranoia level | 1 | Baseline for bypass testing |
| 66 | Audit log | `ABFHZ`, flagged and 5xx, root only | No mail or tokens in the SIEM |
| 67–76 | Vuln target | Own host and subnet, routed through fw-ips, own ECR repo, cert, WAF bundle, window, attacker cert, switch, scope, browser profile | Blast radius and measurement |
| 77, 78 | Rate limits | Two zones, 429 logged at `error` | Cheap at the edge; visible to Wazuh |
| 79–82 | Suricata | Shared flowbit; no-SNI rule (disabled); drops amended after the outage | Real-TLS behaviour |
| 83, 84 | Order | Close-out after Juice Shop; mon in Tier 1 | Measure on the full stack once |
| 85–89 | Wazuh | 4.14.9, own role, t3.medium, persistent volume, SSM secrets | Idempotent, survives teardown, no secrets on disk |

### Interview questions to practise

1. Why does changing an EC2 key pair's public key not reach running instances? How did you fix it in one apply?
2. What does `terraform plan -replace` do, and how is it safer than `terraform taint`?
3. How do IAM condition keys limit Route 53 changes to one record? How did you prove it before running anything?
4. Why must `ssl_protocols` be set on Nginx's default server too?
5. Two `Strict-Transport-Security` headers arrive. Which one wins, and how did you make the right one win?
6. Why can a newer OWASP CRS fail to load, and how did you decide which version to run?
7. What's a positive security model, and how did you use one for the photo upload?
8. Explain CRS anomaly scoring and paranoia levels. Why start blocking at PL1?
9. What goes into a ModSecurity audit log, and what did you keep out of it?
10. Explain `limit_req` as a leaky bucket. Why did two `401`s appear in the middle of the `429`s?
11. Why does an app-level login throttle not replace an edge rate limit?
12. Why does Suricata label garbage sent to Nginx as `http`?
13. Why can't a negated `content` match find a missing SNI?
14. How did a TLS 1.3 handshake trigger a "TLS 1.0" rule? How did you find the real cause?
15. When should an inline IPS rule `drop` rather than `alert`?
16. Why does routing traffic between subnets through an appliance require symmetric routes and IP-based security group rules?
17. Why put a deliberately vulnerable app on its own host instead of in a locked container next to the real app?
18. Two subdomains of one domain: same site or same origin? What does that mean for `SameSite=Lax`?
19. Why keep a SIEM's data on its own volume, and how is it shut down cleanly before detaching?
20. Why install Wazuh with your own role instead of its all-in-one script?

### What comes next

Task 1.16, part 2: the Wazuh certificates, made once on the laptop with `wazuh-certs-tool` and stored under `/siem/`. Then part 3, the role: the indexer, its security initialisation, the manager and Filebeat, and the dashboard. The next session starts with a plain `ssh-agent` in the Ansible terminal, then the routine. Expect `9 to add`: fw-ips's 4, db, app, proxy, siem and the volume attachment. siem starts with no CPU credits, so its first run will be slow.

## 2026-11-05

### Today's topic: building a SIEM you can trust, and why "default-on" isn't "designed-in"

Yesterday finished the edge of the lab: VPN, Suricata, Nginx, ModSecurity. Today built the system that watches all of it. Wazuh is three programs with three trust relationships. The **indexer** (OpenSearch) stores events. The **manager** analyses them and runs the API and agent enrollment. The **dashboard** is the human's window. Filebeat carries the manager's alerts into the indexer. Each component authenticates the others with certificates from a private CA, and each has users with passwords. The day's theme was that every default in this stack is built for "it works on first try", not "it's safe". Each one had to be read, judged and either kept or changed on purpose: the listen address, the demo users, the open enrollment port, the vulnerability scanner.

### The big picture

The detection stack is now: nftables → Suricata → Nginx/ModSecurity → app → PostgreSQL, with Wazuh beside them on the mgmt subnet. siem is the one host whose *data* outlives the session (decision 88): its indexer writes to a persistent volume. Everything else about siem, including certificates, passwords and config, is rebuilt from SSM and the repo every session. That split (state on a volume, identity in SSM, behaviour in code) is what makes a disposable SIEM possible. By the end, 5,278 alerts from siem itself were indexed, and the four agents were installed with an enrollment password enforced, waiting for one IAM apply.

### Part 1: A private CA, and where its key must never live (decision 90)

The Wazuh components trust anything signed by their root CA. The indexer even treats any certificate with `CN=admin` as its security administrator. Decision 89 had said "certificates and keys under `/siem/`", and siem's role reads `/siem/*`. Read literally, the SIEM host would hold the key that signs trusted certificates. If an attacker owns siem, they could mint an admin certificate and rewrite the security index.

The fix mirrors the VPN's offline CA. A host holds the certificates it *presents*, never the key that *signs* them. The CA key was encrypted with AES-256 under a passphrase that lives off AWS, and backed up to `/wazuh-ca/key`, which no instance role can read. The IAM simulator proved it: siem is allowed on `/siem/certs/indexer-key` and gets `implicitDeny` on `/wazuh-ca/key`. Note that `parameter/siem/*` can't match `/wazuh-ca/key`, because the wildcard follows the literal `siem/`.

**Testing the procedure, not just the result.** The re-signing steps were run on a throwaway CA, and that showed `wazuh-certs-tool` quietly copies the CA key, in plaintext, into its output folder when re-signing. The README now shreds it. A procedure you've only written down is a guess.

Two shell traps also came up. `aws ssm get-parameter --output text` adds a trailing newline, so a byte-for-byte comparison needs `jq -j`. And in zsh, `$A:parameter` is not "variable A, then `:parameter`": `:p` and `:r` are history modifiers, and they silently corrupted an ARN (`:role` became `ole`). Write `${A}:parameter`.

### Part 2: The indexer, and four defaults that weren't safe (decisions 91 to 94)

- **The repository (91).** A third-party apt repository is trusted as root. Pinning its key by SHA-256 makes a changed key fail the run. An apt preference with `Pin-Priority: -1` for the whole origin and 500 for four package names means Wazuh's repo can never supply `openssl` or `curl`. The packages are held, so a version change is a reviewed PR.
- **The data volume (92).** On Nitro, `/dev/sdf` appears as an NVMe disk whose number depends on probe order. The only stable name is the volume ID, which the NVMe driver puts in `/dev/disk/by-id/`. The laptop looks the ID up by tag, the run asserts exactly one volume is attached to this instance, and `blkid -p` must find *nothing* (exit 2) before `mkfs` runs. A disk with any history is never formatted. `RequiresMountsFor` stops the indexer from starting without its volume. Without that, it would start on the root disk with a new, empty cluster, which looks exactly like lost data.
- **The listen address (93).** The package sets `network.host: 0.0.0.0`. sg-siem blocks 9200 and 9300 anyway, but binding to 10.0.5.10 makes the host agree, which is defence in depth that costs one line. Binding to loopback would have failed TLS verification, because the certificate names the IP.
- **The users (94).** `internal_users.yml` ships seven users, five of them demo accounts with public passwords. The helper writes a file with just `admin` and `kibanaserver`, hashing the passwords with bcrypt read from stdin, and runs `securityadmin` with the admin *certificate*. It's idempotent the `set-db-password` way: it tests the logins, and changes nothing if they work. Templating the file in Ansible can't be idempotent, because bcrypt salts every hash, so every run would produce a new file.

**A false "changed", traced to the second.** After the resize, the users helper reported `changed` with nothing changed. A per-second trace showed the reason: after a start, the admin *certificate* gets cluster health at once, but *password* logins get 503 for about 15 seconds while the security plugin loads its config from the index. The helper had waited for the wrong signal. It now waits until a wrong login gets 401, unless the security index is absent, which means a new volume. Lesson: "the port is open" and "cluster health is green" are not "the service is ready for this request".

### Part 3: The manager, Filebeat, and a process that outlived its own service (decisions 95 and 97)

The manager's defaults: the indexer connector pointed at `https://0.0.0.0:9200`; the API listened on 55000 everywhere, though only the dashboard on the same host uses it; and authd accepted enrollment on 1515 with **no password**. The last one is the serious one: anyone in the VPC could have enrolled a fake agent and fed the SIEM false events. authd was turned off until enrollment was designed (decision 100), and the API was bound to loopback.

Credentials follow one rule: **use the cheapest real test**. Filebeat's check is `filebeat test output`, which logs in with the keystore's values. The API's check is a login. Wazuh's own keystore is write-only, so the helper stores a SHA-256 of what it wrote. That's safe, because a hash of 238 random bits can't be reversed.

**The incident.** The first build started the manager and then immediately restarted it from a config handler. The old API process still held port 55000, every new API failed with `address already in use`, and the worker pool broke ("child processes terminated abruptly"). Then the surprise: that stale process **survived `systemctl stop wazuh-manager`**. It was found by its age (8:51 minutes, older than the restart) and killed by its exact path. The role now flushes handlers *before* the start task, so on a fresh host the first start already has its config. Filebeat had a cousin of the same bug: it started before its keystore existed, crashed on a missing `username`, and systemd gave up after 5 tries. It now starts after the helper. Lesson: **order of operations is part of the design**, and "start, then restart" is not the same as "start once".

### Part 4: Default-on is not designed-in (decision 96)

At its first start the manager downloaded a 436 MB vulnerability feed and unpacked it to a 9.3 GB tar and 2.8 GB of extracted data. The 20 GB root disk filled up. The tempting fix was a bigger disk. The better question was whether we want this feature at all. Wazuh's vulnerability detection measures **posture**: which known-vulnerable packages are installed. The lab measures **detection**: whether an attack is seen. Nothing in the design used it, and it would have repeated a roughly 14 GB unpack every session on a host with no CPU credits. It's off, with the persistent-volume design documented for if posture ever becomes a goal. An honest correction along the way: it was first described as "Tier 3, T3.2", but T3.2 is *network* scanning (Nuclei, Greenbone), which looks from outside. Wazuh's detection is agent-based and looks from inside. Same family, different tool.

### Part 5: The dashboard (decision 98)

TLS 1.3 only, like Nginx and the VPN. `verificationMode: full`, because the indexer's certificate names its IP, so checking the address costs nothing. The `kibanaserver` password goes into the keystore *before the first start*, so the dashboard never logs in with the shipped default. The plugin's API password has to sit in plain text in `wazuh.yml`. That's the plugin's design, accepted with `0600` and an API that only listens on loopback.

**A bug of my own.** The helper made its config directory with `install -d`, which also created the missing *parent* as root. The dashboard couldn't create its own `downloads` folder and restarted 17 times. The journal showed `EACCES`, and the fix was to create each level as the service user. "Permission denied" after you've written a file is often about the directory above it.

### Part 6: Measure before resizing (decision 99)

Decision 87 named the t3.large as a fallback "if the indexer struggles". Today it was measured instead of guessed. The CPU credit balance stayed at 2.6–8 for 2.5 hours, so a `standard` t3 was held to its 20 % baseline, which explains every slow run. 819 MB was free, with **no agents yet**, and there's no swap. When Linux runs out of memory, the OOM killer picks the largest process, which here is the indexer, the one component the measurements depend on. The t3.large doubles RAM, raises the baseline to 30 % and costs about $0.048/hour more. The heap went to 3 GB, under OpenSearch's "at most half of RAM" rule, so Lucene keeps page cache. Terraform changed the type **in place**: stop, modify, start. The volume, IP and config all survived, and every service came back by itself.

### Part 7: Agent enrollment (decisions 100 and 101)

An agent enrolls on 1515 over TLS and receives its own key. Events then travel on 1514, encrypted with that key. **Whoever can enroll can feed the SIEM**, so enrollment is the control. The password lives in SSM, generated by `persistent`. Each agent host's instance role may read that one ARN, and the host pulls it itself, so the value never touches the laptop. The test: from db, an enrollment without the password got `Invalid password`, siem logged `Invalid password provided by 10.0.4.10`, and 0 agents were added. That log line is itself a detection signal for Phase 2.

The agent's installer writes log sources for software it detects. On proxy it added Nginx, in Apache format. That's convenient, but it isn't reviewable and differs per host. The role uses the generic file plus an explicit per-group list. An agent host's apt pin admits only `wazuh-agent`.

### Mistakes and what they taught

- **A broken readiness wait.** `until ss -ltn | grep "10.0.5.10:9200 "` never matched, because `ss` prints `[::ffff:10.0.5.10]:9200`, so the loop spun on siem until it was killed. Poll the service (`curl`), not the formatting of a status tool, and always put a timeout on a wait.
- **`pkill -f` killed its own shell,** because the pattern appeared in its own command line. Use `pgrep -f "[u]ntil …"`: the regex matches the target but not itself.
- **A stray playbook run.** A leftover `--tags never,all` ran the whole `site.yml` on four hosts with its output thrown away. It was harmless only because the roles are idempotent. The honest next step was to check, not assume: a full run showed `changed=0`, `/healthz` was 200 and fw-ips's services were active.
- **Unclear plan hand-off.** A combined `lab` plan was meant to replace an earlier one, and the older one was applied first. That made the newer plan stale (Terraform rejects a saved plan once the state has moved). When a plan supersedes another, say so in the same message.
- **A gitleaks false positive.** A variable named `…_key_sha256` holding a public hash matched the `generic-api-key` rule. Renaming it to `…_gpg_sha256` was cleaner than an ignore file.
- **ansible-lint taught two idioms:** use a handler, not `when: x.changed`; use `ansible.posix.mount`, not `mount` in a shell task. Running CI's exact lint version locally in a venv beat pushing and waiting.

### Decisions from this session

90 (Wazuh CA key out of siem's reach), 91 (Wazuh repo pinned and limited), 92 (finding and protecting the data volume), 93 (indexer on 10.0.5.10), 94 (only two internal users), 95 (manager credentials helper), 96 (vulnerability detection off), 97 (manager addresses, API on loopback, enrollment off, start order), 98 (dashboard), 99 (siem on t3.large), 100 (enrollment with a password from SSM), 101 (the `wazuh_agent` role).

### Interview questions to practise

1. Why must a CA's private key never be on a host that only presents certificates? How did you prove siem can't read it?
2. A third-party apt repository: what can it do to your host, and how do key pinning and apt preferences limit that?
3. How do you find the right EBS volume on a Nitro instance, and how do you guarantee you never format a disk with data on it?
4. Why add `RequiresMountsFor` to a database service whose data is on a separate volume?
5. Why bind a service to a specific IP when the security group already blocks the port?
6. Why can't you template a bcrypt password file idempotently, and how did you make the helper idempotent instead?
7. The indexer answered cluster health but refused logins with 503 for 15 seconds. What was happening, and what is the right readiness signal?
8. What did "address already in use" plus "child processes terminated abruptly" mean, and why does start-then-restart differ from start-once?
9. When is it right to turn off a security feature that's on by default? Explain posture versus detection.
10. How did you decide between a t3.medium and a t3.large? What do CPU credits and the OOM killer have to do with a SIEM?
11. How does Wazuh agent enrollment work, and why is it the security boundary of the whole SIEM?
12. Why not let the agent's installer pick the log sources?
13. How do you keep a secret out of `ps`, logs and Ansible output? Name three techniques you used today.
14. A plan you saved is now "stale". What does that mean, and why is it a safety feature?

### What comes next

Next session, after the routine (expect **9 to add**; siem is now a t3.large): first the three persistence checks. Today's earliest alert (rule 5403 at 2026-11-05T12:04:52) must still be searchable, the dashboard certificate's SHA-256 must still begin `CB:76:56:E8`, and the manager's new start order must need no hand fix. Then finish 1.17 PR 1b (draft PR 74): the agents enroll and show Active, the IAM simulator runs per agent role, a second run shows `changed=0`, then merge. Then PR 2, the §8 log sources with a test event each, and PR 3, decoders and rules where the built-ins miss.
