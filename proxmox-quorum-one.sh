#!/usr/bin/env bash
#
# proxmox-quorum-one.sh
# Force quorum to 1 in /etc/pve/corosync.conf (expected_votes=1, two_node=1)
# WARNING: Disables split-brain protection. Use only if you do not want HA.
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

NOTE: Root privileges required. Script is idempotent (safe to run multiple times).
EOF
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root." >&2
    exit 1
  fi
}

check_files() {
  if [[ ! -f "$CONF" ]]; then
    echo "File ${CONF} not found. Is this node in a cluster?" >&2
    exit 1
  fi
  if [[ ! -w "$CONF" ]]; then
    echo "No write permissions for ${CONF}." >&2
    exit 1
  fi
}

make_backup() {
  cp -a "$CONF" "$BACKUP"
  echo "Backup created: $BACKUP"
}

# Remove any existing quorum block and append our own
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
  check_files
  if already_patched; then
    echo "Quorum settings already applied (expected_votes=1, two_node=1)."
  else
    make_backup
    tmpf="$(mktemp)"
    render_patched_config > "$tmpf"
    if [[ ! -s "$tmpf" ]] || ! grep -q 'quorum {' "$tmpf"; then
      echo "Internal error: generated config looks invalid." >&2
      rm -f "$tmpf"
      exit 1
    fi
    cp "$tmpf" "$CONF"
    rm -f "$tmpf"
    echo "corosync.conf patched."
  fi

  # Apply runtime expected_votes too
  if command -v pvecm >/dev/null 2>&1; then
    pvecm expected 1 || true
  fi

  restart_corosync
  echo "Done. ⚠️ Quorum safety is now disabled."
}

do_dryrun() {
  check_files
  echo "----- CURRENT CONFIG (${CONF}) -----"
  cat "$CONF"
  echo
  echo "----- PATCHED CONFIG (PREVIEW) -----"
  render_patched_config
}

do_restore() {
  need_root
  local src="$1"
  if [[ -z "$src" || ! -f "$src" ]]; then
    echo "Backup file not found: $src" >&2
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
