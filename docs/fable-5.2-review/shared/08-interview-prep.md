# 08 · Interview preparation

> **Status:** Stage 0 answers describe the lab as **built**. Answers for Stages 1–3 describe a
> **PROPOSED** design; use them only once you've built and verified the thing, and replace the
> placeholders with your real numbers. An interviewer who digs will find the difference
> between "I read about it" and "I ran it".

> **Assumptions**
>
> 1. Questions are the kind asked for junior roles in security engineering, SOC, pentesting and
>    cloud security. Wording varies; the concepts don't.
> 2. Model answers are short on purpose: about a minute spoken. Have a longer version ready.

---

## 1. How to answer

Use the same four beats every time:

1. **Claim:** the direct answer, in one sentence.
2. **Mechanism:** why it's true, in terms of how the technology works.
3. **Evidence:** what you did in the lab and what you measured.
4. **Trade-off:** what it cost, or what it doesn't cover.

The fourth beat is what separates you from other candidates. Anyone can recite a best practice.
Few can say what it costs and where it stops working.

**Phrases worth having ready**

- "I chose A over B because…, and the price was…"
- "I verified it by…, and the expected output was…"
- "What it would miss is…"
- "It broke once, here's what I learned."
- "I haven't built that; here's how I'd approach it." (Always better than bluffing.)

---

## 2. Stage 0: cloud production (built)

**1. Walk me through your architecture.**
A segmented VPC with six subnets, where the only thing reachable from the internet is OpenVPN on
one UDP port. Traffic goes one hop at a time: VPN client → reverse proxy with a WAF → application
→ database, and each hop is allowed independently by security groups, network ACLs and an
nftables firewall, so one mistake doesn't open a path. An inline IPS inspects the decrypted VPN
traffic, a SIEM collects from every host, and everything is Terraform and Ansible: I destroyed
the whole lab and rebuilt it from code, and the second configuration run changed nothing. The
trade-off is a single availability zone and one firewall host, accepted for cost.

**2. Security groups and network ACLs: what's the difference, and why use both?**
A security group is stateful and attached to an interface: allow the request and the reply is
allowed automatically. A network ACL is stateless and attached to a subnet: replies need their
own rule, so you open the ephemeral port range. That has a consequence I hit: a service
listening on a high port, such as 3000, sits inside that range, so I added an explicit deny for
it just before the reply rule. I use both because they fail independently; the ACL also gives me
a subnet-wide deny that no single group mistake can undo.

**3. Why are your VPN clients routed instead of NATed?**
So that every log line shows the real client address, which maps to one device certificate. If
the firewall hid clients behind its own address, the proxy, the IPS and the SIEM would see one
source for everyone, and I couldn't attribute an attack or rate-limit per device. The cost is a
route for the VPN pools in the VPC and return paths that must be symmetric.

**4. Your IPS fails closed. Why, and has that hurt you?**
If the IPS process stops, traffic stops, so an attacker can't get uninspected access by crashing
it. It hurt once: I promoted a rule to drop, and it blocked normal TLS 1.3 clients whose first
handshake message spans two packets, because the rule matched before the whole message had
arrived. The application was down until I set the rule back to alert. Since then, no rule may
drop until three realistic captures stay silent against it. Fail-closed trades availability for
assurance; that's right for a security gateway and wrong for, say, a hospital system.

**5. How do you handle secrets?**
They live in a parameter store, and each host reads only its own path with its own role. No
secret is in the repository, in Terraform state or on my laptop: generated passwords are written
through write-only arguments, so state never holds them, and I deliberately didn't import
hand-made keys into Terraform because an import would copy their values into state. Hosts pull
their own secrets at start, so the values don't pass through the machine running Ansible. What
remains is that root on a host can read that host's secrets, which is inherent.

**6. What is IMDSv2 and why require it?**
The instance metadata service hands temporary credentials to an instance. In version 1 a simple
GET is enough, so a server-side request forgery flaw in an application can fetch them. Version 2
needs a session token obtained with a PUT and a header, which a typical SSRF can't send. I also
set the hop limit to 1, so a container on the host can't reach it; I verified that from inside
the container, where the request times out.

**7. Your WAF blocked a legitimate request. What did you do?**
The first Gmail sign-in callback got a 403. I read the audit log instead of guessing: first the
engine had hit its regular-expression step limit on a long URL and correctly failed closed; after
raising the limit, a second rule read `.profile` inside Google's scope name as a hidden file.
I wrote one exclusion: one rule, one argument, one route. Then I re-ran a test set that includes
requests that must still be blocked. The lesson was that fixing one false positive can reveal
the next, and that every tuning change needs a must-block test.

**8. Why pin a container image by digest?**
A tag is a movable label; a digest is a hash of the content. With a digest, the host runs
exactly the image I reviewed and scanned, or fails. I pair it with immutable tags in the
registry, so even a stolen push credential can't silently replace a release. The cost is that
each release needs a pull request to update the digest, which is also the review point.

**9. How do you know your detection works?**
Each rule has a test that must fire and my harnesses include a case that must stay silent. I
then proved them live: a burst of wrong passwords raised the brute-force rule, a port scan
raised the scan rule, and the counts in the alert file matched the indexer. I also know what's
missing: private hosts can query the cloud resolver directly, which nothing filters, so DNS
exfiltration from a compromised host is an expected miss that I documented and will test.

**10. What would you do differently?**
I'd make the verify steps executable tests from the start instead of commands in a document, and
I'd have written the threat model earlier in outline, even though writing it from the finished
system makes it more accurate. I'd also budget for the SIEM's memory from the beginning: I
started it too small and measured my way to the right size.

---

## 3. Stage 1: small company with an office (PROPOSED: use after building)

**1. Explain Kerberos in a minute.**
The client proves its identity to the domain controller once and gets a ticket-granting ticket.
For each service it then asks for a service ticket, encrypted with that service's key, and
presents it to the service. The service never sees the password and doesn't need to ask the
domain controller. It depends on time, because tickets expire, and on DNS, because service names
come from it. Its weak points follow from the design: any user can request a service ticket and
try to crack it offline, and whoever holds the ticket-granting account's key can forge anything.

**2. Why shouldn't an administrator use a Domain Admin account for daily work?**
Because a credential is exposed to every machine where it's used. Reading mail or browsing as
Domain Admin means one phishing page or one infected workstation hands over the domain. In my
lab the IT persona has a normal account and a separate admin account, and my assumed-breach test
shows the difference: with the workstation compromised, the attacker gets the user's rights, not
the domain's.

**3. What does LAPS solve?**
Machines built from one image share one local administrator password, so compromising one
workstation gives administrative access to all of them with the same hash. LAPS gives each
machine a unique, rotated password stored in the directory, readable only by a delegated group.
I measured it: before, the same hash authenticated to the second workstation; after, it failed,
and the attempt appeared as a failed network logon.

**4. A user reports a phishing e-mail they clicked. What do you do?**
Find out what happened without blaming: did they enter credentials, open an attachment, when.
Then contain the identity: reset the password, end their sessions, and check sign-ins since
the click from unusual addresses. Check the mail logs for who else received it and remove it.
Look at the workstation's process and network events around the click. Then write it up and fix
what let it through. In my test the credential worked on webmail and the VPN, which is why
remote access now needs a second factor.

**5. Walk me through your leaver process.**
HR opens a ticket with the last working time. At that time the account is disabled and its
password reset; then the doors AD doesn't control: the VPN certificate is revoked and the
revocation list published, web sessions are ended, tool-local accounts and tokens are checked.
Data goes to the manager, and the account is deleted after thirty days. I verify from outside:
webmail, VPN and single sign-on all refuse. The step people miss is that disabling an account
doesn't close an open VPN tunnel.

**6. Why is a flat network dangerous, and what did you do about it?**
In a flat network every workstation can reach every port on every server, so one compromised
laptop can attack the file server, the mail server and the domain controller directly. My
Stage 1 has that weakness on purpose, with an allow-all rule between users and servers. In
Stage 2 I replaced it with an allow-list per flow and re-ran the same scan from a workstation:
the reachable ports went from everything to a short documented list, and each blocked attempt
is logged.

**7. Why is FTP a finding?**
It sends the user name and password in clear text, so anyone who can observe the traffic reads
them, and those credentials are often reused. In my lab the scanner account's password was
captured on the wire and also worked for a share. The fix was removing FTP in favour of an
encrypted alternative; the detection I kept was an IPS alert on any FTP at all, since none
should exist.

**8. How do you know your backups work?**
Because I restore them on a schedule into an isolated host, from the second copy, and time it
against the recovery time objective. I keep a record of each test: date, system, how long, the
result. The backup server sits in its own network, isn't joined to the domain and pulls the data,
so a compromised domain account can't delete the backups, which is what ransomware does first.

**9. What is Group Policy and what did you use it for?**
It's the mechanism for pushing settings to domain computers and users, linked to organisational
units. I used it for the audit policy, because Windows logs too little by default, for the
hardening baseline, for LAPS, and for turning off legacy name resolution. I deploy the policies
from code so the domain can be rebuilt, and verify with the resulting-set-of-policy report on a
client.

**10. What is LLMNR poisoning, and can you demonstrate it in the cloud?**
When DNS fails to resolve a name, Windows may ask the local network by multicast; an attacker on
that network answers "that's me" and receives an authentication attempt it can crack or relay.
It needs a shared layer-2 network. A cloud virtual network doesn't deliver multicast between
instances, so it can't be shown there; I demonstrated it on my home hypervisor, then disabled
the protocols by policy and repeated the attack to show it fail. Knowing which platform can
teach which attack was part of my lab design.

---

## 4. Stage 2: mid-size company (PROPOSED: use after building)

**1. What is Kerberoasting, how do you detect it, and how do you fix it?**
Any domain user can request a service ticket for any account with a service principal name; the
ticket is encrypted with that account's password-derived key, so it can be cracked offline. I
detect it by ticket requests using the weak encryption type for service accounts, by one client
requesting tickets for many services, and most reliably by a honey account with a service name
that nothing legitimate ever requests. The fix is group managed service accounts, whose long
random passwords can't be cracked, and removing privilege from service accounts.

**2. How did you find the path to Domain Admin, and what did the fix look like?**
I collected the directory's objects and permissions and graphed them: users, groups, sessions,
access rights. The graph showed a path nobody had designed: a helpdesk right to reset passwords
on a group that was nested into an administrative group. The fix wasn't one change but removing
edges: the delegation scoped to the staff unit only, the nesting removed, the service account
replaced. I re-ran the collection and the path was gone; the before-and-after graphs are in the
report.

**3. How did you design your segmentation?**
By function and trust: users, servers, management, a DMZ, guests, unmanaged devices, backups.
Between them the firewall allows only listed flows, each with a reason, in a table that the
rules are generated from or reviewed against. Then I tested it as an attacker: from every
network, try every other and compare with the table. Anything reachable that isn't in the table
is a finding. The trade-off is operational: every new application needs a flow request, which is
the point.

**4. You have five hundred open vulnerabilities. Where do you start?**
Not at the top of the severity list. I combine severity with whether it's being exploited in
the wild, how likely exploitation is, whether the host is reachable from where attackers are,
and how valuable the asset is. An actively exploited flaw on a perimeter host beats a critical
one on an isolated machine. Then each gets an owner and a deadline, and I report time-to-fix
against the deadline rather than raw counts.

**5. Describe your change process.**
Every change is a pull request that states what, why, the risk, the rollback and how to verify.
Automated checks run, someone other than the author approves, and only merged code is applied,
from a saved plan. Afterwards the verify commands are run and recorded. Emergencies act first by
a documented manual step and go through review within a day. The pull request history *is* the
change log an auditor asks for.

**6. Explain the OIDC authorisation code flow.**
The application redirects the browser to the identity provider. The user signs in there, with a
second factor, and the provider redirects back with a one-time code. The application exchanges
that code, server to server, for signed tokens that say who the user is and which groups they
have. The application never sees the password. The risks are in the details: redirect addresses
must be exact, the state value must be checked, and ending an account must also end its
sessions.

**7. What went wrong with your certificate authority?**
A certificate template let the requester choose the subject name and was usable for sign-in, so
an ordinary user could request a certificate as an administrator and authenticate with it. It's
a common misconfiguration because the PKI is installed once and forgotten. I fixed the template,
required approval for sensitive ones, and added an alert on issued certificates whose subject
differs from the requester.

**8. How would you detect DNS tunnelling?**
By what tunnelling can't avoid: many queries to one domain, long and random-looking names,
unusual record types, and volume per client far above normal. That requires having the query
logs in the first place, and forcing clients to use the company's resolvers so they can't go
around them. In my lab the tunnel worked until I blocked direct DNS at the firewall and wrote a
rule on query length and count per domain.

**9. What are patch rings, and why not patch everything at once?**
Updates go first to a small test group, then a pilot, then everyone, with days between. A bad
update then breaks a few machines instead of the company. Domain controllers are patched one at
a time with a replication check between. The exception is a flaw being exploited on an exposed
system: that goes out of cycle, with the same verification afterwards.

**10. How do you handle alert fatigue?**
Every alert a human sees must have a runbook and must have been judged worth a human's time.
Rules that are always closed as false positives get tuned or removed in a scheduled review;
low-severity events are stored for hunting but don't notify. I track the false-positive rate
per rule from the closing states, so tuning time goes where the noise is.

---

## 5. Stage 3: a slice of a large company (PROPOSED: use after building)

**1. Explain the tier model.**
Administrative credentials are split by what they control: identity systems, servers,
workstations. A credential for a higher tier never signs in to a lower one, because any machine
you sign in to can capture your credential. Admins use dedicated workstations for each tier.
The part most implementations miss is that anything able to run code on a domain controller,
such as the hypervisor, the backup system and the patch server, belongs to the top tier too.

**2. What does privileged access management add?**
It replaces standing privileges with brokered, time-limited, recorded sessions. The admin asks
for access with a reason, signs in with a second factor, and gets a short-lived credential for
that session only. It only works if the direct path is closed: in my lab the firewall accepts
administrative ports only from the access broker.

**3. Walk me through an incident from detection to closure.**
Preparation comes first: a plan, contacts, tested backups. Then detection and analysis: confirm,
scope which hosts and accounts, build a timeline. Then containment, eradication and recovery:
isolate without destroying evidence, remove persistence and rotate credentials, rebuild from
known-good code. Finally a blameless postmortem whose actions include new detections. In my
exercise the lesson was order: my first instinct was to rebuild from code, which would have
destroyed the memory and disk evidence, so the plan now says snapshot first.

**4. What is detection as code?**
Detection rules live in version control, carry metadata, have tests with sample events, and are
deployed by a pipeline after review. A change that breaks a test, or that stops a rule matching
its sample, fails the build. It gives rules what software has: history, review and regression
protection. Mine started from a painful case of a rule that could never fire because of how the
keyword worked, which a test would have caught.

**5. What are MTTD and MTTR, and how did you measure them?**
Mean time to detect is from the first malicious action to an alert a human would see; mean time
to respond is from that alert to containment. I measured them by comparing the red role's
timestamped operation log with alert times, per step. I'm careful about what the numbers mean:
in a lab I know the attack is coming, so they show whether an alert fires, not how fast a busy
analyst would react.

**6. Why use dynamic secrets?**
A static database password lives for years and is known to everything that ever used it. With
dynamic secrets, the secret store creates a database account on request with a short lifetime
and removes it afterwards, so a leaked credential expires on its own and every credential maps
to one requester in the audit log. The hard part is the first secret: how a host proves its
identity to the store.

**7. How do you secure a Kubernetes cluster?**
Least-privilege roles so a workload's account can't read every secret; network policies so pods
only reach what they need; admission rules that refuse privileged or root containers; images
pinned and signed; audit logging to the SIEM; and runtime detection for a shell in a container.
My deliberate weakness was a workload account with cluster-admin: from one compromised pod it
was the whole cluster, and the audit log showed it.

**8. What is a risk register and how does it relate to ISO 27001?**
It's the list of identified risks with their likelihood, impact, owner and treatment: reduce,
transfer, avoid or accept. ISO 27001 requires that process; the Statement of Applicability then
says which controls you apply and why. My first entry was real: my WAF's rule set lacked three
fixes that needed a newer engine. It had a reason, a compensating control and a planned end date,
which is what an accepted risk should look like.

**9. Why a read-only domain controller at the branch?**
A branch has weaker physical security. A read-only controller holds no writable directory copy
and caches only the passwords you permit, so stealing it doesn't yield the domain. The mistake
to avoid is allowing privileged accounts to be cached there, which I tested as a deliberate
weakness.

**10. How is a red team operation different from a penetration test, and what goes in the executive summary?**
A penetration test finds as many weaknesses as time allows in a defined scope. A red team
operation pursues one goal the way a real adversary would, quietly, to test whether the
defenders detect and respond. The executive summary is one page with no tool names: what we set
out to test, whether the goal was reached and how long it took to be noticed, the three changes
that would have stopped it earliest, and what worked well.

---

## 6. Questions that cut across stages

**"Tell me about a time something broke."** Use the IPS outage. Cause, how you noticed, the
immediate fix, the permanent rule you adopted.

**"How do you learn a new technology?"** Build by hand, compare with code, rebuild from code:
the lab's own method. Give one example.

**"Cloud or on-premises?"** They teach and expose different things: the cloud has no shared
layer 2 and gives you a control-plane audit trail; on-premises has the layer-2 attacks and
long-lived hosts that need patching. Point to your comparison.

**"What don't you know?"** Have a real answer: for example, large-scale environments, a
commercial SIEM in production, or a real on-call rotation. Then say how you'd close the gap.

**"Why security?"** Your own answer. Not from a document.

---

## 7. Before each interview

- [ ] Re-read the write-up of the stage most relevant to the role.
- [ ] Pick three decisions you can defend in depth, with the alternative you rejected.
- [ ] Pick one failure and one known gap.
- [ ] Know your numbers: hosts, cost per hour, rebuild time, detection counts.
- [ ] Be ready to draw the architecture from memory in two minutes.
- [ ] Prepare two questions for them: how changes are reviewed there, and what their last
      postmortem changed.
