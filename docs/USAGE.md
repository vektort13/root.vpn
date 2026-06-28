# root.vpn — Client Usage Guide (how to launch the configs)

**🌐 English · [Русский](USAGE.ru.md)**

root.vpn gives each user **two profiles**:

1. **AmneziaWG (UDP/443)** — the fast default. Use this first.
2. **VLESS + REALITY (TCP/443)** — the fallback for networks that block UDP or
   do deep TLS inspection. Use this when #1 won't connect.

> **The failover model is manual today:** try the AmneziaWG profile; if it can't
> connect (UDP blocked / throttled), switch to the VLESS profile. A single‑app
> auto‑failover option (Clash.Meta/Mihomo) is described at the end.

---

## Where the configs are (on the server)

After `sudo awg2 add <name>`, the server prints the paths. Copy them to your
device (e.g. `scp`), or just scan the QR shown in the terminal output.

| Profile | Files (`<name>` = client name) |
|---|---|
| AmneziaWG | `/root/awg/<name>.vpnuri` (vpn:// link) · `/root/awg/<name>.vpnuri.png` (QR) · `/root/awg/<name>.conf` (WireGuard‑style) · `/root/awg/<name>.png` (.conf QR) |
| VLESS+REALITY | `/etc/rootvpn/xray/clients/<name>/vless.txt` (the `vless://…` link) |

Pull everything for one client to your PC:

```bash
scp -r root@SERVER:/root/awg/<name>.* .
scp root@SERVER:/etc/rootvpn/xray/clients/<name>/vless.txt .
```

---

## Recommended app + steps per platform

### 🪟 Windows
- **AmneziaWG profile** → **AmneziaVPN** (amnezia.org/downloads). Open → `+` →
  *Import configuration* → paste the `vpn://…` (from `<name>.vpnuri`) or load the
  `.conf` → Connect.
- **VLESS profile** → **v2rayN** (github.com/2dust/v2rayN, bundles Xray). Copy the
  `vless://…` link → in v2rayN: *Servers → Import from clipboard* → select it →
  *Set as active* → enable *System proxy* (or *Tun mode*).

### 🍎 macOS
- **AmneziaWG** → **AmneziaVPN** (App Store / amnezia.org). Import the `vpn://`.
- **VLESS** → **Hiddify** (App Store) or **Streisand**/**FoXray** (no account).
  *Add profile → from clipboard* (the `vless://` link) → Connect.

### 🤖 Android
- **AmneziaWG** → **AmneziaWG** app (Play Store, `org.amnezia.awg`) — scan
  `<name>.png` (the .conf QR); or **AmneziaVPN** — import the `vpn://` link.
- **VLESS** → **Hiddify** (Play Store) or **v2rayNG** (GitHub APK). Tap `+` →
  *Import from clipboard / Scan QR* → the `vless://` link → connect.

### 📱 iOS
- **AmneziaWG** → **AmneziaVPN** (App Store). Import the `vpn://` link.
- **VLESS** → **FoXray** (free, full REALITY/Vision) or **Streisand** (free) or
  **Shadowrocket** (paid). Add from clipboard → the `vless://` link → connect.

### 🐧 Linux
- **AmneziaWG** → headless: `awg-quick up ./<name>.conf` (needs `amneziawg-tools`),
  or the **AmneziaVPN** GUI.
- **VLESS** → **Hiddify** (AppImage) / **NekoRay** / `xray run -c client.json` /
  **mihomo**. Import the `vless://` link.

---

## 🔑 Pick the right QR/link

| You scanned/imported… | …into | Result |
|---|---|---|
| `vpn://` (`.vpnuri` / `.vpnuri.png`) | **AmneziaVPN** app | ✅ AmneziaWG |
| `.conf` / its `.png` | **AmneziaWG** app or `awg-quick` | ✅ AmneziaWG |
| `vless://` | v2rayN / Hiddify / NekoBox / FoXray / sing‑box / mihomo | ✅ TCP fallback |

The AmneziaVPN app needs the **`vpn://`** form (it does *not* import a raw `.conf`
QR). The standalone **AmneziaWG** app reads the **`.conf`** QR.

---

## 🩺 Troubleshooting (fastest fixes first)

| Symptom | Likely cause | Fix |
|---|---|---|
| AmneziaWG won't connect on mobile data / some Wi‑Fi | UDP blocked on that network | Switch to the **VLESS** profile (TCP/443) |
| VLESS connects then drops after a few seconds in Russia | TSPU pattern‑block of Vision on :443 | Server: `TCP_TRANSPORT="xhttp"` then `sudo awg2` (re‑export links) |
| Handshake completes, then no traffic (any protocol) | server IP/ASN is cut at the network edge | Move to a clean‑reputation VPS / different region |
| "Wrong" or empty page, can't connect | stale config after a key/SNI rotation | Re‑import the latest link (after `awg2 rotate-*`) |
| Connects but sites fail to resolve | DNS / clock skew | Check device time is correct; the tunnel pushes 1.1.1.1 |
| Imported `vpn://` into the wrong app | app mismatch | Use AmneziaVPN for `vpn://`, an Xray client for `vless://` |

---

## 🧪 Verify it's actually tunnelling (no leaks)

After connecting, on the device open **https://ifconfig.co** (or whatsmyip) — it
must show the **server's IP**, not your real one. Then check
**https://ipleak.net** / **browserleaks.com/dns**: the DNS resolver and IP should
be the server's, with **no IPv6** and no local DNS showing.

---

## ⭐ Optional: one app + automatic failover (advanced)

To avoid juggling two profiles, a **Clash.Meta / Mihomo** client can hold *both*
the AmneziaWG and the VLESS endpoint in one subscription and auto‑select the
working one:

- **Windows / macOS / Linux:** **Clash Verge Rev**
- **Android:** **FlClash** (or ClashMetaForAndroid)
- **iOS:** no fully‑verified single‑app AWG+VLESS option yet — keep the two‑app setup.

This needs a small **subscription** to be generated server‑side (a Mihomo YAML
with an `amnezia-wg` proxy + a `vless`/REALITY proxy joined by a `fallback`
group). It is on the roadmap (`awg2 sub`) — see [DESIGN‑v2](DESIGN-v2-tcp-masking.md).
Until then, use the per‑platform apps above.
