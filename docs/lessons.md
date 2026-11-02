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
