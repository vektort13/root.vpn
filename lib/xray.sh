# SPDX-License-Identifier: MIT
# lib/xray.sh - the TCP/443 leg for root.vpn: VLESS + REALITY (Vision or XHTTP)
# via Xray-core, co-located with AmneziaWG (UDP/443). Sourced by ./awg2.
#
# Relies on awg2 helpers: log/ok/warn/die, need_root, SCRIPT_DIR, AWG_WORKDIR,
# and the TCP_* / REALITY_* / XRAY_* / CDN_* / VLESS_* config variables.
#
# Verified design facts (2026): REALITY needs Xray-core >= v25.6.8 (NewSessionTicket
# fix); XHTTP requires empty flow; REALITY cannot sit behind a CDN (edge terminates
# TLS) so CDN mode = XHTTP+real-TLS; AWG-UDP/443 and Xray-TCP/443 coexist (no L4
# clash). DAITA/flow-shaping is NOT available for self-hosted AmneziaWG - not offered.

XRAY_BIN="/usr/local/bin/xray"
XRAY_CFG="/usr/local/etc/xray/config.json"
XRAY_DIR="/etc/rootvpn/xray"
XRAY_PARAMS="$XRAY_DIR/params"
XRAY_CLIENTS="$XRAY_DIR/clients.tsv"
XRAY_CLIENTDIR="$XRAY_DIR/clients"
XRAY_FLOOR="25.6.8"   # minimum Xray-core version (Aparecium/NewSessionTicket fix)

# Curated REALITY decoy targets: foreign, TLS1.3+HTTP2, non-redirecting, not the
# overused Apple/CDN set. One is picked at random per deploy (uniqueness); the
# operator should still set REALITY_DEST to something plausible for the exit region.
XRAY_DESTS_DEFAULT="www.microsoft.com www.amazon.com www.lovelive-anime.jp dl.google.com www.nvidia.com"

xbin() { if command -v xray >/dev/null 2>&1; then echo xray; else echo "$XRAY_BIN"; fi; }
have_xray() { command -v xray >/dev/null 2>&1 || [ -x "$XRAY_BIN" ]; }
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V 2>/dev/null | head -1)" = "$2" ]; }

locate_xray_lib() {
    local c
    for c in "$SCRIPT_DIR/lib/xray_config.py" "$AWG_WORKDIR/lib/xray_config.py"; do
        [ -f "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

# Update (or append) a KEY=VALUE line in the params file, value-safe via ENVIRON.
xray_set_param() {
    local k="$1" v="$2"
    V="$v" awk -F= -v k="$k" 'BEGIN{val=ENVIRON["V"]; d=0}
        $1==k{print k"="val; d=1; next} {print}
        END{if(!d) print k"="val}' "$XRAY_PARAMS" > "$XRAY_PARAMS.tmp" \
        && mv "$XRAY_PARAMS.tmp" "$XRAY_PARAMS"
    chmod 600 "$XRAY_PARAMS" 2>/dev/null || true   # holds REALITY private key
    return 0
}

xray_rand_sid()  { openssl rand -hex 8 2>/dev/null || { head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n'; }; }
xray_rand_path() { printf '/%s-xh' "$(openssl rand -hex 6 2>/dev/null || { head -c6 /dev/urandom | od -An -tx1 | tr -d ' \n'; })"; }

detect_pub_ip() {
    local ip
    ip="$(curl -fsS4 https://api.ipify.org 2>/dev/null || true)"
    [ -n "$ip" ] || ip="$(curl -fsS https://ifconfig.me 2>/dev/null || true)"
    [ -n "$ip" ] || ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    printf '%s' "$ip"
}

# Generate a REALITY X25519 keypair -> prints "PRIV<TAB>PUB" (handles label drift).
xray_gen_keys() {
    local out priv pub
    out="$("$(xbin)" x25519 2>/dev/null)" || return 1
    priv="$(printf '%s\n' "$out" | awk -F': *' 'tolower($0) ~ /private/{print $2; exit}')"
    pub="$(printf '%s\n' "$out" | awk -F': *' 'tolower($0) ~ /password|public/ && tolower($0) !~ /private/{print $2; exit}')"
    [ -n "$priv" ] && [ -n "$pub" ] || return 1
    printf '%s\t%s\n' "$priv" "$pub"
}

dest_ok() {  # host:port reachable with TLS 1.3
    local hp="$1" host="${1%%:*}"
    echo | timeout 8 openssl s_client -connect "$hp" -servername "$host" -tls1_3 >/dev/null 2>&1
}

pick_dest() {
    local want="${REALITY_DEST:-}" d shuffled
    if [ -n "$want" ]; then
        case "$want" in *:*) : ;; *) want="$want:443" ;; esac
        dest_ok "$want" || warn "REALITY dest '$want' did not verify TLS1.3 — using it anyway"
        printf '%s' "$want"; return 0
    fi
    shuffled="$(printf '%s\n' $XRAY_DESTS_DEFAULT | shuf 2>/dev/null || printf '%s\n' $XRAY_DESTS_DEFAULT)"
    for d in $shuffled; do
        if dest_ok "$d:443"; then printf '%s' "$d:443"; return 0; fi
    done
    printf '%s' "www.microsoft.com:443"
}

install_xray() {
    local ver=""
    # awk NR==1 (not `| head -1`): head closes the pipe early -> SIGPIPE -> pipefail
    # -> nonzero -> set -E ERR trap would abort. awk consumes all input safely.
    if have_xray; then ver="$({ "$(xbin)" version 2>/dev/null || true; } | awk 'NR==1{print $2}')"; fi
    if [ -z "$ver" ] || ! version_ge "$ver" "$XRAY_FLOOR"; then
        command -v unzip >/dev/null 2>&1 || apt-get install -y unzip >/dev/null 2>&1 || true
        log "installing Xray-core ${XRAY_VERSION} (need >= v$XRAY_FLOOR)"
        local xlog; xlog="$(mktemp)"
        if ! TERM=dumb bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version "$XRAY_VERSION" >"$xlog" 2>&1; then
            echo "---- xray installer output (tail) ----"; tail -20 "$xlog"; rm -f "$xlog"
            die "Xray-core install failed"
        fi
        rm -f "$xlog"
    else
        log "Xray-core present ($ver >= v$XRAY_FLOOR)"
    fi
    # Hardening drop-in. NOTE: never set MemoryDenyWriteExecute (Go needs W^X off).
    mkdir -p /etc/systemd/system/xray.service.d
    cat > /etc/systemd/system/xray.service.d/10-rootvpn-hardening.conf <<'EOF'
[Service]
NoNewPrivileges=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
SystemCallArchitectures=native
ReadWritePaths=/var/log/xray
EOF
    systemctl daemon-reload 2>/dev/null || true
}

xray_init_params() {
    mkdir -p "$XRAY_DIR" "$XRAY_CLIENTDIR"; chmod 700 "$XRAY_DIR"
    touch "$XRAY_CLIENTS"
    if [ -f "$XRAY_PARAMS" ]; then
        # Re-run: keys/shortIds stay stable, but honor operator-tunable knobs
        # changed in defaults.conf/env (transport, fingerprint, and the decoy).
        xray_set_param TRANSPORT "${TCP_TRANSPORT:-vision}"
        xray_set_param FP "${XRAY_FP:-chrome}"
        if [ -n "${REALITY_DEST:-}" ]; then
            local d="$REALITY_DEST"; case "$d" in *:*) : ;; *) d="$d:443" ;; esac
            xray_set_param DEST "$d"
            xray_set_param SNI "${REALITY_SERVERNAME:-${d%%:*}}"
        fi
        return 0
    fi
    local kp priv pub dest sni ip
    kp="$(xray_gen_keys)" || die "xray x25519 failed"
    IFS=$'\t' read -r priv pub <<<"$kp"
    dest="$(pick_dest)"; sni="${REALITY_SERVERNAME:-${dest%%:*}}"
    ip="$(detect_pub_ip)"; [ -n "$ip" ] || warn "could not auto-detect public IP; set SERVER_IP in $XRAY_PARAMS"
    ( umask 077; cat > "$XRAY_PARAMS" <<EOF
PORT=${TCP_PORT:-443}
TRANSPORT=${TCP_TRANSPORT:-vision}
DEST=$dest
SNI=$sni
REALITY_PRIV=$priv
REALITY_PUB=$pub
FP=${XRAY_FP:-chrome}
SERVER_IP=$ip
XHTTP_PATH=$(xray_rand_path)
XHTTP_MODE=auto
VLESS_DECRYPTION=${VLESS_DECRYPTION:-none}
VLESS_ENCRYPTION_CLIENT=${VLESS_ENCRYPTION_CLIENT:-none}
CDN_DOMAIN=${CDN_DOMAIN:-}
CDN_CERT=${CDN_CERT:-}
CDN_KEY=${CDN_KEY:-}
CDN_PATH=${CDN_PATH:-/}
CDN_PORT=${CDN_PORT:-8443}
CDN_PUBLIC_PORT=${CDN_PUBLIC_PORT:-443}
EOF
    )
    log "REALITY params initialised (transport=${TCP_TRANSPORT:-vision} dest=$dest)"
}

xray_rebuild() {
    local lib; lib="$(locate_xray_lib)" || die "lib/xray_config.py not found"
    # Xray infers config format from the file EXTENSION, so the temp must end in .json.
    local tmp="${XRAY_CFG%.json}.rootvpn-tmp.json"
    python3 "$lib" build-config --params "$XRAY_PARAMS" --clients "$XRAY_CLIENTS" > "$tmp" \
        || die "xray config generation failed"
    if "$(xbin)" run -test -c "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$XRAY_CFG"
        chmod 600 "$XRAY_CFG"   # embeds REALITY private key + client UUIDs/shortIds
        # The service runs as a non-root user (e.g. nobody); make the 600 file
        # readable by exactly that user, not world.
        local svcuser; svcuser="$(systemctl show -p User --value xray 2>/dev/null || true)"
        if [ -n "$svcuser" ] && [ "$svcuser" != "root" ]; then chown "$svcuser" "$XRAY_CFG" 2>/dev/null || true; fi
    else
        "$(xbin)" run -test -c "$tmp" 2>&1 | tail -15 || true
        rm -f "$tmp"
        die "generated xray config failed 'xray run -test' (not applied)"
    fi
    systemctl enable xray >/dev/null 2>&1 || true
    systemctl restart xray 2>/dev/null || true
    sleep 1
    if ! systemctl is-active --quiet xray; then
        journalctl -u xray -n 15 --no-pager 2>/dev/null | tail -15 || true
        die "xray failed to start after applying config (see journal above)"
    fi
}

xray_open_fw() {
    local port="${TCP_PORT:-443}"
    command -v ufw >/dev/null 2>&1 && ufw allow "$port/tcp" >/dev/null 2>&1 || true
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
}

xray_setup() {
    need_root
    log "setting up TCP/443 leg — Xray VLESS+REALITY (transport=${TCP_TRANSPORT:-vision})"
    local need=""
    for t in curl qrencode openssl unzip; do command -v "$t" >/dev/null 2>&1 || need="$need $t"; done
    if [ -n "$need" ]; then
        log "installing deps:$need"
        apt-get update -y >/dev/null 2>&1 || true   # upstream clears apt lists; refresh before install
        apt-get install -y $need >/dev/null 2>&1 || warn "apt install may have failed for:$need"
    fi
    install_xray
    xray_init_params
    xray_open_fw
    # NB: keep this an if/fi, not `A && warn` — as the function's last statement a
    # false test would return non-zero and trip awg2's ERR trap.
    if [ -z "${REALITY_DEST:-}" ]; then
        warn "REALITY_DEST not set — picked a default decoy; set your own in defaults.conf + 'awg2 rotate-reality-target <host>' for per-deploy uniqueness."
    fi
}

# add a VLESS client (idempotent); rebuild config
xray_add_client() {
    local name="${1:-}"; [ -n "$name" ] || return 0
    local uuid sid
    mkdir -p "$XRAY_DIR"; touch "$XRAY_CLIENTS"
    if ! awk -F'\t' -v n="$name" '$1==n{f=1} END{exit !f}' "$XRAY_CLIENTS"; then
        uuid="$("$(xbin)" uuid 2>/dev/null)" || die "xray uuid failed"
        sid="$(xray_rand_sid)"
        printf '%s\t%s\t%s\n' "$name" "$uuid" "$sid" >> "$XRAY_CLIENTS"
    fi
    xray_rebuild   # always rebuild so config.json reflects clients.tsv (incl. re-runs)
}

xray_remove_client() {
    local name="$1"
    [ -f "$XRAY_CLIENTS" ] || return 0
    awk -F'\t' -v n="$name" '$1!=n' "$XRAY_CLIENTS" > "$XRAY_CLIENTS.tmp" && mv "$XRAY_CLIENTS.tmp" "$XRAY_CLIENTS"
    rm -rf "${XRAY_CLIENTDIR:?}/$name"
    xray_rebuild
}

xray_print_client() {
    local name="$1" lib uri curi
    lib="$(locate_xray_lib)" || return 0
    uri="$(python3 "$lib" client-uri --params "$XRAY_PARAMS" --clients "$XRAY_CLIENTS" --name "$name" 2>/dev/null)" \
        || { warn "could not build vless:// URI for $name"; return 0; }
    mkdir -p "$XRAY_CLIENTDIR/$name"
    printf '%s\n' "$uri" > "$XRAY_CLIENTDIR/$name/vless.txt"
    echo
    log "client '$name' — TCP/443 VLESS+REALITY (import into v2rayN / NekoBox / Hiddify):"
    command -v qrencode >/dev/null 2>&1 && qrencode -t ansiutf8 "$uri" || true
    echo "  $uri"
    if grep -Eq '^CDN_DOMAIN=.+' "$XRAY_PARAMS" 2>/dev/null; then
        curi="$(python3 "$lib" client-uri --params "$XRAY_PARAMS" --clients "$XRAY_CLIENTS" --name "$name" --cdn 2>/dev/null || true)"
        [ -n "$curi" ] && { printf '%s\n' "$curi" > "$XRAY_CLIENTDIR/$name/vless-cdn.txt"; echo "  (CDN) $curi"; }
    fi
}

xray_reexport_all() {
    [ -f "$XRAY_CLIENTS" ] || return 0
    local n
    while IFS=$'\t' read -r n _; do [ -n "$n" ] && xray_print_client "$n"; done < "$XRAY_CLIENTS"
}

cmd_rotate_reality() {
    need_root
    [ -f "$XRAY_PARAMS" ] || die "TCP leg not installed (run: sudo awg2)"
    local kp priv pub
    kp="$(xray_gen_keys)" || die "xray x25519 failed"
    IFS=$'\t' read -r priv pub <<<"$kp"
    xray_set_param REALITY_PRIV "$priv"
    xray_set_param REALITY_PUB  "$pub"
    log "REALITY keypair rotated; rebuilding + re-exporting client links"
    xray_rebuild
    xray_reexport_all
    ok "rotate-reality done — re-distribute the new client links from $XRAY_CLIENTDIR/"
}

cmd_rotate_reality_target() {
    need_root
    local d="${1:-}"; [ -n "$d" ] || die "usage: awg2 rotate-reality-target <host[:443]>"
    [ -f "$XRAY_PARAMS" ] || die "TCP leg not installed (run: sudo awg2)"
    case "$d" in *:*) : ;; *) d="$d:443" ;; esac
    dest_ok "$d" || warn "dest '$d' did not verify TLS1.3 — using it anyway"
    xray_set_param DEST "$d"
    xray_set_param SNI  "${d%%:*}"
    xray_rebuild
    xray_reexport_all
    ok "REALITY target set to $d — re-distribute the new client links"
}

xray_status() {
    have_xray || { echo "xray: not installed"; return 0; }
    # awk NR==1 not `| head -1`: with set -E, SIGPIPE in a command substitution
    # pipeline trips the ERR trap.
    echo "xray: $("$(xbin)" version 2>/dev/null | awk 'NR==1')"
    echo "xray service: $(systemctl is-active xray 2>/dev/null || echo unknown)"
    if ss -ltn 2>/dev/null | grep -q ":${TCP_PORT:-443} "; then echo "listening: TCP/${TCP_PORT:-443} yes"; else echo "listening: TCP/${TCP_PORT:-443} NO"; fi
    if [ -f "$XRAY_PARAMS" ]; then grep -E '^(TRANSPORT|DEST|SNI|PORT|CDN_DOMAIN)=' "$XRAY_PARAMS" | sed 's/^/  /' || true; fi
    if [ -f "$XRAY_CLIENTS" ]; then echo "  tcp clients: $(grep -c . "$XRAY_CLIENTS" 2>/dev/null || echo 0)"; fi
    return 0
}
