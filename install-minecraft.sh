#!/usr/bin/env bash
# install-minecraft.sh — install the official Minecraft launcher .deb on modern
# Ubuntu (24.04+, tested on 26.04 "resolute") where the vendor package fails to
# install due to stale dependency metadata.
#
# Two problems it fixes:
#
#   1. Java. The .deb declares `Depends: default-jre`, but a fresh system has no
#      JRE, so the install aborts. This installs default-jre FIRST.
#
#   2. Renamed dependencies. The .deb was built against an older Ubuntu and
#      names packages that have since been renamed. Some renames carry a
#      compatibility `Provides:` (e.g. the 64-bit time_t "t64" transition:
#      libcurl4 -> libcurl4t64) and resolve automatically. Others do NOT — most
#      notably `libgdk-pixbuf2.0-0` -> `libgdk-pixbuf-2.0-0` — so apt refuses to
#      install even though the library is present and newer.
#
#      Rather than hardcode a fixed list, this script SIMULATES the install,
#      reads back whichever dependencies apt reports as "not installable", finds
#      the current package that satisfies each (known map + rename heuristics),
#      rewrites them in a repacked copy of the .deb, and installs that. Unknown
#      unsatisfiable deps are reported instead of silently ignored.
#
# Usage:
#   chmod +x install-minecraft.sh
#   ./install-minecraft.sh [path/to/Minecraft.deb]
# If no path is given it looks for ~/Downloads/Minecraft.deb.
#
# Get the .deb from https://www.minecraft.net/download (Debian/Ubuntu edition).
#
# License: MIT. No affiliation with Mojang or Microsoft.

set -euo pipefail

log()  { echo -e "\n\033[1;36m=== $* ===\033[0m"; }
ok()   { echo -e "\033[1;32mOK  $*\033[0m"; }
warn() { echo -e "\033[1;33m!   $*\033[0m"; }
die()  { echo -e "\033[1;31mERR $*\033[0m" >&2; exit 1; }

# Known old->new renames to try first. Heuristics below catch the rest, but an
# explicit entry is faster and unambiguous.
declare -A KNOWN_RENAMES=(
    [libgdk-pixbuf2.0-0]=libgdk-pixbuf-2.0-0
)

# --- preflight ----------------------------------------------------------
[[ $EUID -eq 0 ]] && die "Do not run as root. Run as your normal user; sudo is invoked when needed."
command -v apt-get >/dev/null 2>&1 || die "This script is for Debian/Ubuntu (apt-get not found)."
command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb not found (expected on Debian/Ubuntu)."

DEB="${1:-$HOME/Downloads/Minecraft.deb}"
[[ -f "$DEB" ]] || die "Minecraft .deb not found at: $DEB
    Download it from https://www.minecraft.net/download and pass its path, e.g.
    ./install-minecraft.sh ~/Downloads/Minecraft.deb"
DEB="$(readlink -f "$DEB")"

# Sanity-check that this really is the Minecraft launcher package, so pointing
# the script at the wrong .deb fails clearly instead of installing something else.
PKG_NAME="$(dpkg-deb -f "$DEB" Package 2>/dev/null || true)"
if [[ "$PKG_NAME" != "minecraft-launcher" ]]; then
    die "That .deb is '${PKG_NAME:-unknown}', not the Minecraft launcher.
    Download the Debian/Ubuntu edition from https://www.minecraft.net/download
    and pass its path, e.g.  ./install-minecraft.sh ~/Downloads/Minecraft.deb"
fi

# Escape a package name for use inside a POSIX ERE / sed pattern (dots, plus).
ere_escape() { sed -E 's/[.[\*+?(){}|^$]/\\&/g' <<<"$1"; }

# Is a package name installed OR installable from configured repos?
installable() {
    local p="$1" pol
    pol="$(apt-cache policy "$p" 2>/dev/null)" || return 1
    [[ -z "$pol" ]] && return 1
    grep -q 'Candidate:' <<<"$pol" && ! grep -q 'Candidate: (none)' <<<"$pol"
}

# Given an old dependency name apt can't satisfy, return a current name that
# satisfies it, or empty. Tries the known map, then common rename shapes:
#   - append the 64-bit time_t suffix:            libfoo2   -> libfoo2t64
#   - insert a dash before a version group:       libfoo2.0-0 -> libfoo-2.0-0
#   - both of the above combined
find_replacement() {
    local dep="$1" cand dash
    if [[ -n "${KNOWN_RENAMES[$dep]:-}" ]] && installable "${KNOWN_RENAMES[$dep]}"; then
        echo "${KNOWN_RENAMES[$dep]}"; return 0
    fi
    dash="$(sed -E 's/([a-z])([0-9]+\.[0-9])/\1-\2/' <<<"$dep")"
    for cand in "${dep}t64" "$dash" "${dash}t64"; do
        [[ "$cand" == "$dep" ]] && continue
        if installable "$cand"; then echo "$cand"; return 0; fi
    done
    return 1
}

# List deps apt reports as "not installable" for a given .deb (simulated).
# `|| true`: under pipefail an empty grep (no bad deps — the success case) or
# apt's nonzero exit on an unsatisfiable set would otherwise abort via set -e.
unsatisfiable_deps() {
    apt-get install -s "$1" 2>&1 \
        | grep -iE 'Depends:.*not installable' \
        | sed -E 's/.*Depends:[[:space:]]*([^ ]+).*/\1/' \
        | sort -u \
        || true
}

# --- keep sudo warm -----------------------------------------------------
sudo -v
( while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null ) &
KEEPALIVE_PID=$!
WORK=""
cleanup() {
    kill "$KEEPALIVE_PID" 2>/dev/null || true
    [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
}
trap cleanup EXIT

# --- 1/4 Java -----------------------------------------------------------
log "1/4 Java runtime (default-jre)"
if command -v java >/dev/null 2>&1; then
    ok "Java already present: $(java -version 2>&1 | head -1)"
else
    sudo apt-get update
    sudo apt-get install -y default-jre
    ok "Installed: $(java -version 2>&1 | head -1)"
fi

# --- 2/4 Detect stale dependency names ----------------------------------
log "2/4 Checking dependencies"
mapfile -t BAD < <(unsatisfiable_deps "$DEB")

INSTALL_DEB="$DEB"
if [[ ${#BAD[@]} -eq 0 ]]; then
    ok "all dependencies satisfiable — no repack needed"
else
    declare -A MAP=()
    UNRESOLVED=()
    for dep in "${BAD[@]}"; do
        if repl="$(find_replacement "$dep")"; then
            MAP[$dep]="$repl"
            ok "will rewrite  $dep  ->  $repl"
        else
            UNRESOLVED+=("$dep")
            warn "no current package found for stale dependency: $dep"
        fi
    done

    if [[ ${#UNRESOLVED[@]} -gt 0 ]]; then
        die "Could not resolve: ${UNRESOLVED[*]}
    These may be genuinely missing — try:  sudo apt-get install ${UNRESOLVED[*]}
    then re-run this script. If they don't exist under any name, please open an
    issue with your Ubuntu version (cat /etc/os-release) and this output."
    fi

    # --- 3/4 Repack with corrected names --------------------------------
    log "3/4 Repacking .deb with corrected dependency names"
    WORK="$(mktemp -d)"
    EXTRACT="$WORK/pkg"
    dpkg-deb -R "$DEB" "$EXTRACT"
    for dep in "${!MAP[@]}"; do
        pat="$(ere_escape "$dep")"
        sed -i -E "s/\\b${pat}\\b/${MAP[$dep]}/g" "$EXTRACT/DEBIAN/control"
    done
    INSTALL_DEB="$WORK/$(basename "${DEB%.deb}")-fixed.deb"
    dpkg-deb -b "$EXTRACT" "$INSTALL_DEB" >/dev/null 2>&1
    ok "built patched package"
fi

# --- Safety net: confirm nothing is still unmet before touching the system ---
log "Confirming dependencies resolve"
REMAIN="$(unsatisfiable_deps "$INSTALL_DEB")"
if [[ -n "$REMAIN" ]]; then
    die "Dependencies still unmet after patching: $(echo "$REMAIN" | tr '\n' ' ')
    This is unexpected — nothing was installed. Please open an issue with your
    Ubuntu version (cat /etc/os-release) and the output above."
fi
ok "all dependencies resolve — safe to install"

# --- 4/4 Install --------------------------------------------------------
log "4/4 Installing launcher"
sudo apt-get install -y "$INSTALL_DEB"

log "Verify"
if command -v minecraft-launcher >/dev/null 2>&1; then
    ok "minecraft-launcher: $(command -v minecraft-launcher)"
    ok "Java: $(java -version 2>&1 | head -1)"
    echo -e "\nDone. Launch it from your app menu or run:  minecraft-launcher"
else
    warn "Install reported success but 'minecraft-launcher' isn't on PATH."
    warn "Check with:  dpkg -L minecraft-launcher | grep bin"
fi
