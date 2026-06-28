# root.vpn v2 — TCP/443 + maximum masking (design)

> Research synthesis from **30 independent expert agents + OpenAI Codex (gpt‑5.2)**,
> with adversarial verification of the make‑or‑break claims. 2026 threat context:
> RU TSPU (ML + connection‑pattern policing), China GFW (active probing + TLS‑in‑TLS
> + QUIC‑SNI), Iran (protocol whitelisting). Items not solidly verified are tagged
> **NEEDS‑CHECK**.

## TL;DR

**Do not turn AmneziaWG into TCP.** Keep **AmneziaWG 2.0 over UDP/443** as the primary
fast path, and add a **separate** **VLESS + REALITY** listener on **TCP/443** (served by
**Xray‑core**) as the fallback. Two upstream daemons on one host. Client‑side failover via
**two QRs** (AWG + `vless://…reality`). This is the unanimous conclusion of both Codex and
the expert panel.

## Why not "AmneziaWG over TCP"

- **The GFW's fully‑encrypted‑traffic (FET) classifier is TCP‑only.** UDP AmneziaWG
  *dodges it entirely*. Wrapping AWG into fake‑TCP (phantun/udp2raw) would move it **into**
  that classifier's jurisdiction — strictly worse. (verified)
- **Fake‑TCP is not real TLS/web traffic.** phantun/udp2raw produce synthetic TCP with no
  real handshake; detectable by stateful DPI and useless against L7 proxy/whitelist regimes
  (Iran). Keep them only as an `--expert` last resort (phantun v0.8.1 — no TCP‑over‑TCP
  meltdown, but needs TUN + firewall rules; router/root‑client only).

## Recommended architecture

```
PRIMARY   UDP/443  ->  AmneziaWG 2.0 (awg0) + offline QUIC‑Initial I1 mimicry   [keep as‑is]
FALLBACK  TCP/443  ->  Xray‑core: VLESS + REALITY + xtls‑rprx‑vision            [new]
DECOY     TCP/80   ->  optional boring static site (ACME/health only)           [optional]
CORE      two co‑located daemons (amneziawg‑go + xray); no L4 conflict (UDP vs TCP on 443)
FAILOVER  client‑side, UDP‑first -> TCP/443 on UDP loss/block (two profiles)
```

### Why VLESS+REALITY for the TCP/443 leg (and not the others)

| Candidate | Verdict | Why |
|---|---|---|
| **VLESS + REALITY + Vision** | ✅ **recommend** | Relays the genuine ClientHello to a real third‑party `dest` and returns *that site's real cert* on any probe → strongest active‑probe resistance. No owned domain/cert. Universal client + QR support (fixes today's Amnezia‑only lock‑in). |
| ShadowTLS v3 | ❌ avoid | **Dead.** Detected by Aparecium via NewSessionTicket length mismatch; abandonware (last release 2023). |
| Cloak | ⚠️ weaker | *Forges* the ServerHello (not a real upstream) → weaker probe resistance than REALITY. |
| Trojan / Trojan‑Go | ❌ avoid | Local‑webserver fallback now fingerprinted (TrojanProbe, 2025); grouped with obsolete protocols. |
| gRPC transport | ⚠️ phasing out | Deprecated in Xray (→ XHTTP); bare HTTP/2 removed in v25. Use only for CDN. |
| CDN WS/XHTTP front | ⚠️ powerful but separate | Only thing that beats the **AS/IP‑reputation cut**, but Xray‑only clients, needs a domain, ToS‑gray. Reserve for MAX / Iran. |

### Why two daemons, not one unified sing‑box

**sing‑box has no AmneziaWG inbound** (upstream rejected it, #4045 not‑planned). Unifying
AWG + REALITY in one config requires an **unsigned community fork** (sing‑box‑lx /
amnezia‑box) with no mobile release binaries. Two **upstream, signed, independently‑pinned**
daemons (amneziawg‑go + Xray‑core) beat one unsigned fork on supply‑chain + longevity.
Revisit only if a stable AWG *server* mode lands upstream (**NEEDS‑CHECK**).

## Mandatory version pin

- **Xray‑core ≥ v25.6.8** (the NewSessionTicket post‑handshake mimicry fix that saved
  REALITY from the Aparecium scanner). Prefer **v26.x** (2026). Pin it exactly like
  `UPSTREAM_VERSION`, and keep client/server Xray versions matched.

## The honest ceiling (do not oversell)

- **TLS‑in‑TLS is not solved.** Vision raises the USENIX'24 detector's required FPR ~11×
  but standalone still tested at **~51% TPR**. It raises cost, not invisibility.
- **Russia, Nov 2025+:** TSPU connection‑pattern policing **freezes VLESS+REALITY+Vision on
  :443 after ~16 KB / ~25 packets**, independent of SNI/fingerprint. The working fixes are
  **drop the Vision flow + add mux**, **XHTTP(+XMUX)**, **move off :443**, or **SS‑2022** —
  *not* changing the uTLS fingerprint. → For RU, prefer **XHTTP+mux** or non‑443.
- **IP/ASN reputation dominates.** A clean protocol on a burned VPS subnet still dies. CDN
  fronting is the only listed technique that launders this (censor sees the CDN edge IP).

## Tiered options

| Tier | Stack | Effort | Stealth | Best for |
|---|---|---|---|---|
| **GOOD** (default) | AWG/UDP + VLESS‑REALITY‑**Vision** TCP/443, two QRs | Medium | High (China‑leaning) | Default ship; throughput‑sensitive; low users/server |
| **BETTER** | GOOD, but TCP leg = **REALITY over XHTTP (+XMUX)**; low per‑server fan‑out; ASN hygiene | Med‑High | High → state‑grade in CN | Russia‑exposed (survives the Nov‑2025 Vision‑kill) |
| **MAX** | BETTER + **VLESS Encryption** (ML‑KEM‑768 hybrid PFS + padding/jitter, Xray PR #5067) + **DAITA/Maybenot flow‑shaping on the AWG leg** + **residential/clean‑ASN egress** + **CDN‑fronted XHTTP for Iran/AS‑cut** | High | Max available self‑host | Iran whitelisting; hostile ASNs; high‑value users |

## Threat mapping (what survives where)

- **China (GFW):** REALITY+Vision strong (probe‑resistant; UDP AWG dodges FET). Residual:
  TLS‑in‑TLS ML on the TCP leg → mux/XHTTP helps.
- **Russia (TSPU):** Vision‑on‑:443 now actively frozen → use **XHTTP+mux / off‑443 / SS‑2022**;
  ASN reputation is decisive.
- **Iran:** protocol whitelisting defeats any raw VPS → needs **CDN‑fronting / domestic chain /
  clean in‑country IP**.

## Client matrix

| Platform | AWG (UDP) | VLESS+REALITY (TCP) | XHTTP | Failover |
|---|---|---|---|---|
| Amnezia app | ✅ (QR) | ✅ | ❌ | manual (import 2nd profile) |
| v2rayN (Win) | — | ✅ | ✅ | manual / urltest |
| sing‑box / NekoBox (Android/Linux) | client forks only | ✅ | ❌ (SagerNet declined) | `urltest` selector |
| Hiddify | — | ✅ | ✅ | subscription urltest |

True in‑app AWG↔VLESS auto‑failover does **not** exist in mainstream clients today. Default
UX = **two QRs**. Advanced = sing‑box subscription with `urltest` over the TCP profiles
(desktop‑first; AWG‑in‑sub needs a patched fork).

## What NOT to do

- Don't make fake‑TCP the default. Don't claim the QUIC‑I1 turns AWG into a real QUIC session
  (a stateful classifier sees the flow isn't real QUIC after the decoy).
- Don't reuse shared SNIs or copied REALITY templates; per‑deploy keys/UUIDs/shortIds/`dest`.
- Don't pick a bad REALITY `dest` (non‑:443, overused Apple/CDN targets, TLS‑version mismatch,
  implausible‑for‑your‑ASN). Auto‑validate and add `rotate-reality`.
- Don't stack WS/gRPC/TLS/CDN/VLESS unless a specific client needs it (worsens TLS‑in‑TLS +
  traffic‑shape fingerprints). Don't set client `insecure=true`. Don't expose unauth
  subscription/admin on the same IP.

## Implementation roadmap (extend the `awg2` overlay)

1. **`defaults.conf`:** `TCP_ENABLED=1`, `TCP_CORE=xray`, `TCP_PORT=443`,
   `TCP_TRANSPORT=vision|xhttp`, `REALITY_DEST`, `REALITY_SERVERNAME`,
   `REALITY_FLOW=xtls-rprx-vision`, `XRAY_VERSION` (pinned ≥ v25.6.8).
2. **Xray installer:** download pinned Xray‑core, verify checksum, locked‑down system user,
   write `/etc/rootvpn/xray.json`, systemd unit, `xray -test` gate.
3. **Keys:** per‑deploy REALITY keypair (`xray x25519`); per‑client UUID + `shortId`.
   Auto‑validate `dest` (only :443, reachable, TLS1.3, not blocklisted/overused).
4. **Extend `awg2 add/remove/list/regen`:** create BOTH an AWG client and a VLESS‑REALITY
   client; emit **two QRs** + `vless://` link + per‑client artifacts.
5. **`awg2 rotate-reality` / `rotate-reality-target`; `status`** for TCP/443, UUID/shortId
   inventory, dest reachability.
6. **Optional `--profile xhttp`** (RU‑hardened) and **CDN‑fronted XHTTP** (needs a domain).
   **`--expert awg-faketcp`** (phantun) as documented last resort.
7. **README:** client matrix + blunt threat table.

## Sources

Primary 2026 sources consulted include: XTLS/Xray‑core (REALITY, Vision, XHTTP, VLESS
Encryption PR #5067, NewSessionTicket fix v25.6.8), SagerNet/sing‑box docs (urltest,
ShadowTLS, no‑AWG‑inbound #4045/#3550), GFW.report (USENIX'23 FET, active probing),
net4people/bbs (#528 TLS‑in‑TLS, XHTTP guides, RU Nov‑2025 TSPU threads), apernet/hysteria,
dndx/phantun, wangyu‑/udp2raw, cbeuw/Cloak, amnezia‑vpn docs, and the TLS‑in‑TLS detection
literature (USENIX'24). Full per‑expert citations are in the workflow transcript.
