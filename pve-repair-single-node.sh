#!/usr/bin/env bash
#
# pve-repair-single-node.sh
#
# Repair a Proxmox VE cluster stuck without quorum by converting it to a clean
# **single-node** configuration (expected_votes=1) so /etc/pve becomes writable again.
#
# What it does:
#   1) Stops corosync & pve-cluster
#   2) Starts pmxcfs in LOCAL mode to regain write access to /etc/pve
#   3) Writes a minimal, valid single-node /etc/pve/corosync.conf
#   4) Restarts services in normal mode and prints health checks
#
# ⚠️ Use on ONE NODE only. This will make the cluster effectively single-node.
#    You can add nodes later using `pvecm add` on the new nodes.
#
# License: MIT

set -euo pipefail

log()   { printf "\033[1;34m>> %s\033[0m\n" "$*"; }
warn()  { printf "\033[1;33m!! %s\033[0m\n" "$*"; }
error() { printf "\033[1;31mERROR: %s\033[0m\n" "$*" >&2; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    error "Run as root (sudo or root shell)."
    exit 1
  fi
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

detect_values() {
  CLUSTER_NAME="ProxmoxCluster"
  NODE_NAME="$(hostname -s)"
  # Prefer RFC1918 IPv4 as ring0_addr
  RING0_ADDR="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | head -n1 || true)"
  [[ -z "${RING0_ADDR}" ]] && RING0_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -z "${RING0_ADDR}" ]] && RING0_ADDR="127.0.0.1"

  NODE_ID="1"

  if [[ -f /etc/pve/corosync.conf ]]; then
    # Reuse existing values if present
    local cn nid old_r0 old_name
    cn="$(grep -E '^\s*cluster_name\s*:' /etc/pve/corosync.conf | awk -F: '{print $2}' | xargs || true)"
    nid="$(grep -E '^\s*nodeid\s*:'       /etc/pve/corosync.conf | head -n1 | awk -F: '{print $2}' | xargs || true)"
    old_r0="$(grep -E '^\s*ring0_addr\s*:' /etc/pve/corosync.conf | head -n1 | awk -F: '{print $2}' | xargs || true)"
    old_name="$(grep -E '^\s*name\s*:'     /etc/pve/corosync.conf | head -n1 | awk -F: '{print $2}' | xargs || true)"

    [[ -n "${cn}"      ]] && CLUSTER_NAME="${cn}"
    [[ -n "${nid}"     ]] && NODE_ID="${nid}"
    [[ -n "${old_r0}"  ]] && RING0_ADDR="${old_r0}"
    [[ -n "${old_name}" ]] && NODE_NAME="${old_name}"
  fi

  log "Using values:"
  echo "  cluster_name: ${CLUSTER_NAME}"
  echo "  node name:    ${NODE_NAME}"
  echo "  nodeid:       ${NODE_ID}"
  echo "  ring0_addr:   ${RING0_ADDR}"
}

stop_services() {
  log "Stopping corosync & pve-cluster..."
  systemctl stop corosync pve-cluster || true
}

start_pmxcfs_local() {
  log "Starting pmxcfs in LOCAL mode (daemonized)..."
  # pmxcfs by default daemonizes (foreground only with -f). -l = local mode.
  pmxcfs -l || true

  # Wait for /etc/pve to be writable
  for i in {1..30}; do
    if touch /etc/pve/.pmxcfs_write_test 2>/dev/null; then
      rm -f /etc/pve/.pmxcfs_write_test
      log "/etc/pve is writable ✓"
      return 0
    fi
    sleep 0.5
  done

  error "/etc/pve did not become writable in local mode."
  echo "  - Check: systemctl status pve-cluster"
  echo "  - Logs : journalctl -u pve-cluster -u corosync -b"
  exit 1
}

backup_conf() {
  if [[ -f /etc/pve/corosync.conf ]]; then
    BK="/root/corosync.conf.$(date +%Y%m%d-%H%M%S).bak"
    cp -a /etc/pve/corosync.conf "$BK"
    log "Backup created: $BK"
  fi
}

write_single_node_conf() {
  log "Writing single-node /etc/pve/corosync.conf ..."
  cat >/etc/pve/corosync.conf <<EOF
totem {
    version: 2
    cluster_name: ${CLUSTER_NAME}
    transport: knet
    crypto_cipher: aes256
    crypto_hash: sha256
    ip_version: ipv4-6
    interface {
        linknumber: 0
        knet_link_priority: 1
    }
}

nodelist {
    node {
        name: ${NODE_NAME}
        nodeid: ${NODE_ID}
        quorum_votes: 1
        ring0_addr: ${RING0_ADDR}
    }
}

quorum {
    provider: corosync_votequorum
    expected_votes: 1
    two_node: 1
    wait_for_all: 0
    auto_tie_breaker: 0
    last_man_standing: 1
    last_man_standing_window: 0
}

logging {
    to_syslog: yes
}
EOF

  # Syntax check corosync config if available
  if cmd_exists corosync; then
    if ! corosync -t >/dev/null 2>&1; then
      error "corosync -t reported a syntax error; output follows:"
      corosync -t || true
      exit 1
    fi
  else
    warn "corosync command not found; skipping syntax check."
  fi
}

restart_normal() {
  log "Restarting services in NORMAL mode..."
  # Ensure local pmxcfs is not lingering
  pkill -x pmxcfs || true
  sleep 1
  systemctl start pve-cluster corosync
}

verify() {
  log "Verifying state..."
  findmnt /etc/pve || true
  echo
  pvecm status || true
  echo
  if cmd_exists corosync-quorumtool; then
    log "corosync-quorumtool:"
    corosync-quorumtool -s || true
  fi
  echo
  warn "You are now running a SINGLE-NODE cluster (expected_votes=1). Add nodes later with 'pvecm add'."
}

main() {
  need_root
  detect_values
  stop_services
  start_pmxcfs_local
  backup_conf
  write_single_node_conf
  restart_normal
  verify
  log "Done."
}

main
