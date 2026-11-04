# Findings report

Format for each scenario: attack → detection (or miss) → custom rule/fix → re-test.

## Outside (internet)
TODO

## Inside (stolen VPN cert)
TODO

## Malicious email
TODO

## Access control
TODO

## Juice Shop ground truth (decisions 67 to 76)

Target: `vuln.<domain>` (Juice Shop on the vuln host), attacked from the attacker certificate (10.8.0.x) through `attacks/` (decision 75). Filled in during 2.15 and 2.16.

**Result** is one of: blocked (the layer stopped it), detected (logged or alerted, not stopped), missed (no layer saw it), FP (a benign request was blocked). A bypass is confirmed by Juice Shop's scoreboard (challenge solved). **Mode · PL** is the vuln server's ModSecurity engine mode and paranoia level for that run. Every row follows attack → detection (or miss) → custom rule/fix → re-test.

### Matrix (decision 71)

Same corpus each run: GoTestWAF, the scripted challenges, and the benign capture.

| Mode | PL | Attacks blocked % | Bypassed % | Benign blocked (FP) % | Notes |
|---|---|---|---|---|---|
| DetectionOnly | 1 |  |  |  | "would block" from the anomaly score |
| DetectionOnly | 2 |  |  |  |  |
| DetectionOnly | 3 |  |  |  |  |
| DetectionOnly | 4 |  |  |  |  |
| On | 1 |  |  |  |  |
| On | 2 |  |  |  |  |
| On | 3 |  |  |  |  |
| On | 4 |  |  |  |  |

### SQL injection

Expected: 942xxx; JSON-encoding gap 4RI-250413 in CRS 4.25.0 (decision 63).

| # | Attack (tool / challenge / payload) | Mode · PL | nftables | Suricata | ModSecurity (rule IDs) | Wazuh (rule ID) | Flow logs | Result | Custom rule / fix | Re-test |
|---|---|---|---|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |  |  |  |  |

### XSS

Expected: 941xxx; DOM XSS through the URL fragment never reaches a server (expected miss).

| # | Attack (tool / challenge / payload) | Mode · PL | nftables | Suricata | ModSecurity (rule IDs) | Wazuh (rule ID) | Flow logs | Result | Custom rule / fix | Re-test |
|---|---|---|---|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |  |  |  |  |

### IDOR / BOLA

Expected: valid requests, so no WAF signal; Wazuh frequency rule on the access log.

| # | Attack (tool / challenge / payload) | Mode · PL | nftables | Suricata | ModSecurity (rule IDs) | Wazuh (rule ID) | Flow logs | Result | Custom rule / fix | Re-test |
|---|---|---|---|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |  |  |  |  |

### JWT tampering

Expected: no CRS rule; custom ModSecurity rule and Suricata rule on the decrypted path.

| # | Attack (tool / challenge / payload) | Mode · PL | nftables | Suricata | ModSecurity (rule IDs) | Wazuh (rule ID) | Flow logs | Result | Custom rule / fix | Re-test |
|---|---|---|---|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |  |  |  |  |

### Brute force

Expected: Nginx `limit_req`; Wazuh frequency on 401s; Suricata flow threshold; rate caps (decision 75).

| # | Attack (tool / challenge / payload) | Mode · PL | nftables | Suricata | ModSecurity (rule IDs) | Wazuh (rule ID) | Flow logs | Result | Custom rule / fix | Re-test |
|---|---|---|---|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |  |  |  |  |

### SSRF

Expected: 934xxx; container and vuln-subnet egress drops; flow log REJECTs.

| # | Attack (tool / challenge / payload) | Mode · PL | nftables | Suricata | ModSecurity (rule IDs) | Wazuh (rule ID) | Flow logs | Result | Custom rule / fix | Re-test |
|---|---|---|---|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |  |  |  |  |

### File upload

Expected: 922xxx and upload rules; Juice Shop's client-side checks.

| # | Attack (tool / challenge / payload) | Mode · PL | nftables | Suricata | ModSecurity (rule IDs) | Wazuh (rule ID) | Flow logs | Result | Custom rule / fix | Re-test |
|---|---|---|---|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |  |  |  |  |

### Path traversal

Expected: 930xxx; `%2500` null-byte bypass on `/ftp`.

| # | Attack (tool / challenge / payload) | Mode · PL | nftables | Suricata | ModSecurity (rule IDs) | Wazuh (rule ID) | Flow logs | Result | Custom rule / fix | Re-test |
|---|---|---|---|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |  |  |  |  |

### Outside window (2.1, 2.16)

Source Marko's /32 only, Juice Shop only, through the 8443 listener (decision 72).

| # | Attack (tool / challenge / payload) | Mode · PL | nftables | Suricata | ModSecurity (rule IDs) | Wazuh (rule ID) | Flow logs | Result | Custom rule / fix | Re-test |
|---|---|---|---|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |  |  |  |  |
