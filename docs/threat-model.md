# Threat model

TODO: assets, trust boundaries, attacker positions (see ARCHITECTURE.md §11). The full first draft is task 0.7 (Marko).

## Juice Shop target (decisions 67 to 76)

Added 2026-11-04, ahead of 0.7, because the target changes the trust boundaries.

**Assets it must not reach:** Mailbridge's OAuth tokens and token encryption key, the two DB passwords and the database (app, db, `/mailbridge/*`), the Mailbridge image (`mailbridge` ECR repository), Wazuh's data (siem), the VPN PKI (`/vpn/*`), and the admin's Mailbridge session in the browser.

**Trust boundaries:**
- The Juice Shop container is **untrusted by design**: assume RCE inside it. Boundary 1 is the container (capabilities dropped, non-root, `DOCKER-USER` drops new connections, unroutable DNS, IMDS hop limit 1).
- The juiceshop host is **assumed compromisable** after an escape. Boundary 2 is the vuln subnet: its own route table, `sg-juiceshop`, the vuln NACL and nftables on fw-ips, which allow only proxy → 3000, TCP 443 and UDP 123 out (logged), and the Wazuh agent to siem. Its role can pull only the `juice-shop` image.
- proxy is **shared** (decision 70): Juice Shop's attacks reach the same Nginx and ModSecurity as mail. A proxy compromise exposes mail plaintext. Accepted.
- The browser: `juiceshop.<domain>` and `mail.<domain>` are the same site. Boundary 3 is a separate browser profile (decision 76).

**Attacker positions:**
- Inside, with the attacker certificate (user pool): reaches only proxy:443, so Juice Shop and Mailbridge by name.
- Outside, during a window: Marko's /32 only, Juice Shop only, through the 8443 listener (decision 72).
- From the compromised container or host: tries the db, app, IMDS, SSM parameters, ECR and the internet; each attempt should fail at a named layer and be logged.

**Residual risks accepted:** the host's TCP 443 egress for SSM and ECR (a possible C2 channel after an escape, logged); the shared proxy; CRS 4.25.0's missing fixes, live for XML on the Juice Shop server (decisions 63, 71).
