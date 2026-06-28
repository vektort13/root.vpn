#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# root.vpn bootstrap — download (NO git required) and run the hardened installer.
#
#   curl -fsSL https://raw.githubusercontent.com/antidetect/root.vpn/main/install.sh | sudo bash
#
# Optional config via environment, e.g.:
#   curl -fsSL .../install.sh | sudo REALITY_DEST=dl.google.com AWG_SNI=www.cloudflare.com bash
#
# On a fresh image the underlying installer reboots once or twice to load a new
# kernel — just re-run the SAME command after each reboot; it resumes safely.

set -euo pipefail

REPO="${ROOTVPN_REPO:-antidetect/root.vpn}"
REF="${ROOTVPN_REF:-main}"
DIR="${ROOTVPN_DIR:-/opt/root.vpn}"
ENVF="/etc/root.vpn/install.env"   # survives reboots AND the re-extract below

[ "$(id -u)" -eq 0 ] || { echo "root.vpn: must run as root — pipe into 'sudo bash'"; exit 1; }

# Config knobs we persist + pass through to awg2.
CFG_VARS="RVLANG AWG_SNI AWG_PORT AWG_TUNNEL AWG_MIMICRY AWG_PRESET AWG_SUBNET AWG_FIRST_CLIENT \
TCP_ENABLED TCP_PORT TCP_TRANSPORT REALITY_DEST REALITY_SERVERNAME XRAY_VERSION XRAY_FP \
CDN_DOMAIN CDN_CERT CDN_KEY CDN_PATH CDN_PORT CDN_PUBLIC_PORT VLESS_DECRYPTION VLESS_ENCRYPTION_CLIENT"

# Restore config saved on a previous run, but only for vars NOT provided THIS run —
# so re-running the bare command after a reboot keeps your original options, while a
# new explicit value still wins.
if [ -f "$ENVF" ]; then
    while IFS='=' read -r k v; do
        case "$k" in ''|\#*) continue ;; esac
        [ -z "${!k+x}" ] && export "$k=$v" || true
    done < "$ENVF"
fi

need() { command -v "$1" >/dev/null 2>&1; }
if ! need curl || ! need tar; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y curl tar ca-certificates >/dev/null 2>&1 || true
fi
need curl || { echo "root.vpn: curl is required"; exit 1; }
need tar  || { echo "root.vpn: tar is required";  exit 1; }

echo "root.vpn: downloading ${REPO}@${REF} (no git needed) ..."
mkdir -p "$DIR"
curl -fsSL "https://github.com/${REPO}/archive/refs/heads/${REF}.tar.gz" \
    | tar -xz -C "$DIR" --strip-components=1
cd "$DIR"

# Persist the effective config so a bare re-run after a reboot resumes identically.
mkdir -p "$(dirname "$ENVF")"
: > "$ENVF.tmp"
for v in $CFG_VARS; do
    [ -n "${!v+x}" ] && printf '%s=%s\n' "$v" "${!v}" >> "$ENVF.tmp"
done
mv "$ENVF.tmp" "$ENVF"; chmod 600 "$ENVF"

# Carry config into defaults.conf too (sourced last by awg2 -> appended values win).
# This makes the curl one-liner configurable without an editor.
for v in $CFG_VARS; do
    [ -n "${!v+x}" ] && printf '%s=%q\n' "$v" "${!v}" >> defaults.conf
done

chmod +x awg2
echo "root.vpn: starting installer — if the server reboots, re-run the same command to resume."
exec ./awg2 "$@"
