#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
xray_config.py - build the Xray-core server config and per-client vless:// links
for root.vpn's TCP/443 leg (VLESS + REALITY, Vision or XHTTP), plus an optional
CDN-fronted XHTTP+TLS inbound.

Single source of truth so the JSON field names stay correct (verified against
XTLS/Xray-core docs + Xray-examples, 2026):
  - REALITY:  streamSettings.security="reality", realitySettings{dest,serverNames,
              privateKey,shortIds}; server-only fields never leak into the link.
  - Vision:   network="tcp", client flow="xtls-rprx-vision".
  - XHTTP:    network="xhttp", xhttpSettings{host,path,mode}, flow MUST be "".
  - CDN mode: REALITY cannot live behind a CDN (edge terminates TLS) -> use
              security="tls" + a real ACME cert + XHTTP mode "stream-one".

Inputs:
  params file : KEY=VALUE lines (see defaults below)
  clients file: TSV "name<TAB>uuid<TAB>shortid" per line

Usage:
  xray_config.py build-config  --params P --clients C            > config.json
  xray_config.py client-uri    --params P --clients C --name N [--cdn]
"""

import argparse
import json
import os
import sys
from urllib.parse import quote


def load_params(path):
    p = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            p[k.strip()] = v.strip().strip('"').strip("'")
    return p


def load_clients(path):
    cs = []
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if len(parts) >= 3 and parts[1]:
                    cs.append({"name": parts[0], "uuid": parts[1], "sid": parts[2]})
    return cs


def _reality_inbound(p, clients):
    transport = p.get("TRANSPORT", "vision")
    flow = "xtls-rprx-vision" if transport == "vision" else ""
    clients_json = [{"id": c["uuid"], "flow": flow} for c in clients]
    short_ids = [""] + [c["sid"] for c in clients if c["sid"]]
    reality = {
        "show": False,
        "dest": p["DEST"],                 # server-only; "target" is the newer alias
        "xver": 0,
        "serverNames": [p["SNI"]],
        "privateKey": p["REALITY_PRIV"],
        "shortIds": short_ids,
    }
    ss = {
        "network": "tcp" if transport == "vision" else "xhttp",
        "security": "reality",
        "realitySettings": reality,
    }
    if transport == "xhttp":
        ss["xhttpSettings"] = {
            "host": p.get("XHTTP_HOST", ""),
            "path": p.get("XHTTP_PATH", "/"),
            "mode": p.get("XHTTP_MODE", "auto"),
        }
    return {
        "listen": "0.0.0.0",
        "port": int(p.get("PORT", "443")),
        "protocol": "vless",
        "settings": {"clients": clients_json, "decryption": p.get("VLESS_DECRYPTION", "none")},
        "streamSettings": ss,
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"], "routeOnly": True},
        "tag": "reality-in",
    }


def _cdn_inbound(p, clients):
    # XHTTP + REAL TLS cert, fronted by a CDN (Cloudflare orange-cloud, Full-strict).
    clients_json = [{"id": c["uuid"], "flow": ""} for c in clients]
    ss = {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
            "serverName": p["CDN_DOMAIN"],
            "alpn": ["h2", "http/1.1"],
            "certificates": [{"certificateFile": p["CDN_CERT"], "keyFile": p["CDN_KEY"]}],
        },
        "xhttpSettings": {
            "host": p["CDN_DOMAIN"],
            "path": p.get("CDN_PATH", "/"),
            "mode": "stream-one",
        },
    }
    return {
        "listen": "0.0.0.0",
        "port": int(p.get("CDN_PORT", "8443")),
        "protocol": "vless",
        "settings": {"clients": clients_json, "decryption": p.get("VLESS_DECRYPTION", "none")},
        "streamSettings": ss,
        "tag": "cdn-in",
    }


def build_config(p, clients):
    inbounds = [_reality_inbound(p, clients)]
    if p.get("CDN_DOMAIN") and p.get("CDN_CERT") and p.get("CDN_KEY"):
        inbounds.append(_cdn_inbound(p, clients))
    return {
        # No access log: never record client source IP / sniffed SNI to journald.
        "log": {"access": "none", "error": "", "loglevel": "warning", "dnsLog": False},
        "inbounds": inbounds,
        "outbounds": [
            {"protocol": "freedom", "tag": "direct"},
            {"protocol": "blackhole", "tag": "block"},
        ],
        "routing": {
            "domainStrategy": "AsIs",
            "rules": [
                {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
                {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
            ],
        },
    }


def client_uri(p, c, cdn=False):
    uuid = c["uuid"]
    fp = p.get("FP", "chrome")
    name = c["name"]
    if cdn:
        host = p["CDN_DOMAIN"]
        port = p.get("CDN_PUBLIC_PORT", "443")  # the Cloudflare-facing port
        path = quote(p.get("CDN_PATH", "/"), safe="")
        q = (f"type=xhttp&security=tls&encryption=none&sni={host}&host={host}"
             f"&fp={fp}&path={path}&mode=stream-one")
        return f"vless://{uuid}@{host}:{port}?{q}#{quote(name)}-cdn"

    ip = p.get("SERVER_IP", "SERVER_IP")
    port = p.get("PORT", "443")
    pbk = p["REALITY_PUB"]
    sni = p["SNI"]
    sid = c["sid"]
    enc = p.get("VLESS_ENCRYPTION_CLIENT", "none") or "none"
    transport = p.get("TRANSPORT", "vision")
    if transport == "vision":
        q = (f"type=tcp&security=reality&encryption={quote(enc, safe='')}&flow=xtls-rprx-vision"
             f"&pbk={pbk}&sid={sid}&sni={sni}&fp={fp}&spx=%2F")
        return f"vless://{uuid}@{ip}:{port}?{q}#{quote(name)}-vision"
    path = quote(p.get("XHTTP_PATH", "/"), safe="")
    q = (f"type=xhttp&security=reality&encryption={quote(enc, safe='')}"
         f"&pbk={pbk}&sid={sid}&sni={sni}&fp={fp}&spx=%2F&path={path}&mode={p.get('XHTTP_MODE', 'auto')}")
    return f"vless://{uuid}@{ip}:{port}?{q}#{quote(name)}-xhttp"


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build-config")
    b.add_argument("--params", required=True)
    b.add_argument("--clients", required=True)
    u = sub.add_parser("client-uri")
    u.add_argument("--params", required=True)
    u.add_argument("--clients", required=True)
    u.add_argument("--name", required=True)
    u.add_argument("--cdn", action="store_true")
    args = ap.parse_args()

    p = load_params(args.params)
    clients = load_clients(args.clients)

    if args.cmd == "build-config":
        json.dump(build_config(p, clients), sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0
    if args.cmd == "client-uri":
        match = [c for c in clients if c["name"] == args.name]
        if not match:
            sys.stderr.write("client not found: %s\n" % args.name)
            return 1
        sys.stdout.write(client_uri(p, match[0], cdn=args.cdn) + "\n")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
