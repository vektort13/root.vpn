# amneziawg-hardened (`awg2`)

One command on a fresh VPS → a road-warrior **AmneziaWG 2.0** server already
tuned for **serious DPI** (Russia TSPU / Iran / China). No flags to remember:
the hardened profile is baked in.

It is a thin **overlay** on [`bivlked/amneziawg-installer`](https://github.com/bivlked/amneziawg-installer)
(MIT) — that mature, daily-maintained installer does the heavy lifting (DKMS
build, per-deploy-randomized `Jc/Jmin/Jmax/S1–S4/H1–H4`, client/QR generation,
RU carrier presets). `awg2` pins it to a known version, drives it with hardened
flags, and adds the one thing it punts to a browser tool: a **real, offline,
per-deploy-unique QUIC-Initial `I1` carrying your own SNI**.

## What "hardened" bakes in

| Knob | Default | Why |
|---|---|---|
| Tunnel | **full** (`--route-all`) | nothing leaks around the tunnel |
| Port | **UDP/443** | blends with QUIC / HTTP-3 |
| `I1` mimicry | **real QUIC Initial + your SNI** | passes DPI that *classifies* QUIC **and** DPI that *decrypts the Initial + reads SNI* (e.g. GFW) |
| `Jc/Jmin/Jmax/S1–S4/H1–H4` | randomized **per deploy** (upstream) | no universal signature; non-overlapping `H` ranges ≤ INT32_MAX |

The QUIC `I1` is generated locally by [`lib/quic_i1.py`](lib/quic_i1.py) — a
fresh, valid QUIC v1 Initial (RFC 9000/9001) every run. It does **not** reuse
the shared `mini_quic_generator` / `SNI=7-zip.org` blob everyone copies, which
would defeat AmneziaWG 2.0's whole point (per-deployment uniqueness).

## Quickstart

```bash
git clone https://github.com/vektort13/amneziawg-hardened
cd amneziawg-hardened

# Set the one knob: a low-profile SNI for the QUIC mimicry (see defaults.conf).
#   editor defaults.conf   ->   AWG_SNI="www.gov.uk"

sudo ./awg2
```

That installs AmneziaWG 2.0, applies the hardened profile, creates a first
client `phone`, and prints its QR. Import it with the **Amnezia client
≥ 4.8.12.9** (only that client speaks AWG 2.0 today).

If `AWG_SNI` is left empty, it still works — it falls back to *shape-only* QUIC
mimicry (looks like QUIC, no embedded SNI). For serious DPI, set a real SNI.

## Managing it

```bash
sudo awg2 add laptop                 # new client + QR
sudo awg2 add guest --expires=7d     # self-expiring client
sudo awg2 remove laptop
sudo awg2 list -v
sudo awg2 status                      # interface + obfuscation summary
sudo awg2 rotate-sni new.example.com  # new SNI, re-apply, regen all clients
sudo awg2 rotate-i1                    # fresh QUIC Initial (same SNI)
sudo awg2 uninstall
```

After `rotate-sni` / `rotate-i1`, **re-distribute** the updated client configs
from `/root/awg/` — `I1` must be byte-identical on server and every client.

## Supported OS

Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13 (x86_64 / ARM) — per upstream.

## Honest limits (read before relying on it)

- **UDP-only.** AmneziaWG mimics QUIC/DNS/SIP but has no TCP transport. Where a
  network blocks *all* UDP, or allows only TCP-443-to-a-CDN, it **cannot
  connect**. Keep an **OpenVPN+Cloak** or **VLESS+REALITY** (TCP/443) fallback
  on the same VPS for those networks.
- **IP/ASN reputation dominates.** On known-VPS ranges (e.g. Hetzner AS24940
  from RU) the handshake can complete and then data dies — that is an AS-level
  cut, not a parameter problem. Use a clean / residential-reputation exit; the
  QUIC-SNI `I1` sometimes restores such links but is not guaranteed.
- **SNI rot.** The safe SNI is a moving target. If a route degrades, `rotate-sni`.
- **Client lock-in.** Only the Amnezia app speaks AWG 2.0 as of mid-2026
  (Throne/Hiddify/sing-box do not yet).
- **Trust.** `awg2` runs a pinned upstream script as root. Read it
  (`less /root/awg-hardened/install_amneziawg_en.sh`), and optionally pin
  `UPSTREAM_SHA256` in `defaults.conf`.

## Files

```
awg2              hardened entrypoint (install + management proxy + rotation)
defaults.conf     baked defaults you edit once (AWG_SNI is the main one)
lib/quic_i1.py    offline QUIC v1 Initial + SNI generator (run --selftest to verify)
NOTICE / LICENSE  MIT; attribution to bivlked/amneziawg-installer & amnezia-vpn
```

Verify the QUIC generator yourself:

```bash
python3 lib/quic_i1.py --selftest          # builds, decrypts, checks SNI round-trip
python3 lib/quic_i1.py --sni www.gov.uk    # prints the I1 = <b 0x...> token
```

For legitimate privacy / censorship-circumvention use. You are responsible for
complying with the laws that apply to you.
