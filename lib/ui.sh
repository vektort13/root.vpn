# SPDX-License-Identifier: MIT
# lib/ui.sh - terminal UI helpers for awg2: colors, sections, box "cards",
# progress and a secret redactor. Degrades to plain ASCII when stdout is not a
# TTY (curl|bash, paramiko, | tee), when NO_COLOR is set, when TERM=dumb, or
# when AWG_ASCII=1 / --ascii. Sourced by awg2 (which calls ui_init early).
#
# Style note: cards use a LEFT border only (no right edge), so wide glyphs
# (Cyrillic/CJK) never break alignment across the 4 UI languages.

UI_TTY=0; UI_COLOR=0; UI_BOX=0; UI_WIDTH=74
QUIET="${QUIET:-0}"; VERBOSE="${VERBOSE:-0}"; AWG_ASCII="${AWG_ASCII:-0}"
B=""; DIM=""; RED=""; GRN=""; YEL=""; CYN=""; R=""
G_OK="*"; G_WARN="!"; G_ERR="x"; G_DOT="-"; BX_TL="+"; BX_BL="+"; BX_H="-"; BX_V="|"

ui_init() {
    [ -t 1 ] && [ "${TERM:-}" != "dumb" ] && UI_TTY=1
    if [ "$UI_TTY" = 1 ] && [ -z "${NO_COLOR:-}" ] && [ "$AWG_ASCII" != 1 ]; then
        UI_COLOR=1
        B=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
        YEL=$'\033[33m'; CYN=$'\033[36m'; R=$'\033[0m'
    fi
    if [ "$UI_TTY" = 1 ] && [ "$AWG_ASCII" != 1 ]; then
        UI_BOX=1
        G_OK="✓"; G_WARN="!"; G_ERR="✗"; G_DOT="•"
        BX_TL="┌"; BX_BL="└"; BX_H="─"; BX_V="│"
    fi
    # terminal width (TTY only); clamp to a sane range
    if [ "$UI_TTY" = 1 ]; then
        local cols; cols="$( (tput cols) 2>/dev/null || echo "${COLUMNS:-80}" )"
        case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
        [ "$cols" -lt 50 ] && cols=50; [ "$cols" -gt 100 ] && cols=100
        UI_WIDTH=$((cols - 2))
    fi
    return 0
}

# --- log lines (stderr for warn/die so they survive stdout redirection) ------
log()  { [ "$QUIET" = 1 ] && return 0; printf '%s[awg2]%s %s\n' "$CYN" "$R" "$*"; return 0; }
vlog() { [ "$VERBOSE" = 1 ] && printf '%s[awg2]%s %s\n' "$DIM" "$R" "$*"; return 0; }
ok()   { [ "$QUIET" = 1 ] && return 0; printf '%s[ %s ]%s %s\n' "$GRN" "$G_OK" "$R" "$*"; return 0; }
warn() { printf '%s[ %s ]%s %s\n' "$YEL" "$G_WARN" "$R" "$*" >&2; return 0; }
die()  { printf '%s[ %s ]%s %s\n' "$RED" "$G_ERR" "$R" "$*" >&2; exit 1; }

_rep() { local s="$1" n="$2" out=""; while [ "$n" -gt 0 ]; do out="$out$s"; n=$((n-1)); done; printf '%s' "$out"; }

section() { [ "$QUIET" = 1 ] && return 0; printf '\n%s%s%s\n' "$B" "$*" "$R"; return 0; }
rule()    { [ "$QUIET" = 1 ] && return 0; printf '%s%s%s\n' "$DIM" "$(_rep "$BX_H" "$UI_WIDTH")" "$R"; return 0; }
step()    { log "${DIM}[$1/$2]${R} $3"; return 0; }   # step N/total message

# card "Title" "line" "line" ...  (left-bordered; safe for wide glyphs)
card() {
    [ "$QUIET" = 1 ] && return 0
    local title="$1"; shift
    if [ "$UI_BOX" = 1 ]; then
        printf '%s%s%s %s%s%s %s%s\n' "$DIM" "$BX_TL" "$BX_H" "$R$B" "$title" "$R" "$DIM$(_rep "$BX_H" 6)" "$R"
        local l; for l in "$@"; do printf '%s%s%s %s\n' "$DIM" "$BX_V" "$R" "$l"; done
        printf '%s%s%s%s\n' "$DIM" "$BX_BL" "$(_rep "$BX_H" "$UI_WIDTH")" "$R"
    else
        printf '\n== %s ==\n' "$title"
        local l; for l in "$@"; do printf '  %s\n' "$l"; done
    fi
    return 0
}

# Pass-through on a real terminal; strip ANSI colour codes when output is not a
# TTY (so upstream tools' colour escapes don't litter logs / redirected output).
plainfilter() {
    if [ "${UI_TTY:-0}" = 1 ]; then cat; else sed -E 's/\x1b\[[0-9;]*m//g'; fi
}

# Strip secrets from text piped through this (for safe error/journal dumps).
redact_secrets() {
    sed -E \
      -e 's/(([Pp]rivate[Kk]ey|[Pp]reshared[Kk]ey)[ "=:]*)[A-Za-z0-9+/_=-]{20,}/\1<redacted>/g' \
      -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<uuid>/g' \
      -e 's/(pbk=)[A-Za-z0-9_-]{20,}/\1<redacted>/g' \
      -e 's/(<b 0x[0-9a-f]{16})[0-9a-f]+/\1…>/g' \
      -e 's/(0x[0-9a-f]{20})[0-9a-f]+/\1…/g'
}
