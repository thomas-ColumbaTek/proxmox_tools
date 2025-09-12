#!/usr/bin/env bash
#
# proxmox-quorum-one.sh
# Force quorum to 1 in /etc/pve/corosync.conf (expected_votes=1, two_node=1)
# Now with preflight checks for root + pmxcfs (/etc/pve) writeability.
#
# WARNING: Disables split-brain protection. Use only if you do NOT want HA.
set -euo pipefail

CONF="/etc/pve/corosync.conf"
BACKUP_DIR="/root"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="${BACKUP_DIR}/corosync.conf.${TS}.bak"

usage() {
  cat <<EOF
Usage: $0 [--apply | --dry-run | --restore <backupfile>]

Options:
  --apply        Patch /etc/pve/corosync.conf and restart corosync
  --dry-run      Show what would be changed, without writing
  --restore F    Restore a previous backup and restart corosync

Notes:
  - Must be run as root.
  - /etc/pve must be mounted by pmxcfs and writable (rw). This script checks that first
    and provides guidance if it isn't.

EOF
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Please run as root (sudo or root shell)." >&2
    exit 1
  fi
}

check_pmxcfs_writable() {
  echo ">> Checking pmxcfs (/etc/pve) mount & write access..."
  # Is /etc/pve mounted as fuse.pve-cluster?
  if ! mount | grep -qE '/etc/pve .* type fuse\.pve-cluster '; then
    echo "ERROR: /etc/pve is not mounted via pmxcfs (fuse.pve-cluster)." >&2
    echo "Hints:" >&2
    echo "  - Ensure Proxmox cluster filesystem is running:  systemctl status pve-cluster" >&2
    echo "  - Start/Restart it:                           systemctl restart pve-cluster" >&2
    echo "  - If this is a single-node lab, verify corosync isn't blocking pmxcfs." >&2
    exit 1
  fi

  # Is it mounted read-write?
  if ! mount | grep -E '/etc/pve .* type fuse\.pve-cluster ' | grep -q '(rw,'; then
    echo "ERROR: /etc/pve is mounted read-only." >&2
    echo "Hints:" >&2
    echo "  - Check cluster health:        pvecm status" >&2
    echo "  - Try to restart services:     systemctl restart pve-cluster corosync" >&2
    echo "  - Ensure this node has quorum or intentionally bypass quorum only if you know what you're doing." >&2
    exit 1
  fi

  # Can we actually write?
  local testfile="/etc/pve/.write_test_${TS}"
  if ! (touch "$testfile" && rm -f "$testfile"); then
    echo "ERROR: Write test to /etc/pve failed (pmxcfs not writable)." >&2
    echo "Hints:" >&2
    echo "  - Check that pmxcfs is healthy and RW: mount | grep /etc/pve" >&2
    echo "  - Service health:               systemctl status pve-cluster" >&2
    echo "  - Try:                          systemctl restart pve-cluster corosync" >&2
    echo "  - If single-node lab: ensure corosync isn't forcing RO state." >&2
    exit 1
  fi

  echo ">> /etc/pve is writable (pmxcfs RW) ✓"
}

check_conf_present_writable() {
  if [[ ! -f "$CONF" ]]; then
    echo "ERROR: ${CONF} not found. Is this node part of a Proxmox cluster?" >&2
    exit 1
  fi
  if [[ ! -w "$CONF" ]]; then
    echo "ERROR: No write permissions on ${CONF} (even though /etc/pve is RW)." >&2
    exit 1
  fi
}

make_backup() {
  cp -a "$CONF" "$BACKUP"
  echo "Backup created: $BACKUP"
}

render_patched_config() {
  awk '
    BEGIN { inq=0 }
    /^[[:space:]]*quorum[[:space:]]*\{/ { inq=1; next }
    inq && /\}/ { inq=0; next }
    inq { next }
    { print }
    END {
      print ""
      print "quorum {"
      print "    provider: corosync_votequorum"
      print "    expected_votes: 1"
      print "    two_node: 1"
      print "    wait_for_all: 0"
      print "    auto_tie_breaker: 0"
      print "    last_man_standing: 1"
      print "    last_man_standing_window: 0"
      print "}"
    }
  ' "$CONF"
}

already_patched() {
  grep -qE '^[[:space:]]*expected_votes:[[:space:]]*1' "$CONF" && \
  grep -qE '^[[:space:]]*two_node:[[:space:]]*1' "$CONF"
}

restart_corosync() {
  echo "Restarting corosync..."
  systemctl restart corosync
  sleep 2
  echo "Cluster status:"
  pvecm status || true
}

do_apply() {
  need_root
  check_pmxcfs_writable
  check_conf_present_writable

  if already_patched; then
    echo "Quorum settings already present (expected_votes=1, two_node=1)."
  else
    make_backup
    tmpf="$(mktemp)"
    render_patched_config > "$tmpf"

    if [[ ! -s "$tmpf" ]] || ! grep -q 'quorum {' "$tmpf"; then
      echo "Internal error: generated config looks invalid." >&2
      rm -f "$tmpf"
      exit 1
    fi

    # Atomic-ish replace
    cp "$tmpf" "$CONF"
    rm -f "$tmpf"
    echo "Patched ${CONF}."
  fi

  # Also apply at runtime (best-effort)
  if command -v pvecm >/dev/null 2>&1; then
    pvecm expected 1 || true
  fi

  restart_corosync
  echo "Done. ⚠️ Quorum enforcement is now effectively disabled."
}

do_dryrun() {
  # Dry-run can run without root; show config + preview only
  if [[ -f "$CONF" ]]; then
    echo "----- CURRENT CONFIG (${CONF}) -----"
    cat "$CONF"
  else
    echo "NOTE: ${CONF} not found. This node may not be in a cluster."
  fi
  echo
  echo "----- PATCHED CONFIG (PREVIEW) -----"
  if [[ -f "$CONF" ]]; then
    render_patched_config
  else
    cat <<'YAML'
quorum {
    provider: corosync_votequorum
    expected_votes: 1
    two_node: 1
    wait_for_all: 0
    auto_tie_breaker: 0
    last_man_standing: 1
    last_man_standing_window: 0
}
YAML
  fi
}

do_restore() {
  need_root
  check_pmxcfs_writable
  local src="${1:-}"
  if [[ -z "$src" || ! -f "$src" ]]; then
    echo "ERROR: Backup file not found: $src" >&2
    exit 1
  fi
  cp -a "$src" "$CONF"
  echo "Restored: $src -> $CONF"
  restart_corosync
}

main() {
  case "${1:-}" in
    --apply)   do_apply ;;
    --dry-run) do_dryrun ;;
    --restore) shift; do_restore "${1:-}" ;;
    *)         usage; exit 1 ;;
  esac
}
main "$@"
