#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-vars.sh"

REQUIRED_PKGS=(
  curl
  tar
  gzip
  ca-certificates
  iptables
)

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  local line_no=$1
  echo "[ERROR] Script failed at line ${line_no}, exit code ${exit_code}" >&2
  exit "${exit_code}"
}
trap 'on_error $LINENO' ERR

bool_true() {
  case "${1,,}" in
    true|1|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

unit_exists() {
  systemctl list-unit-files --no-legend --no-pager 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

package_available() {
  local pkg="$1"
  zypper -n info "${pkg}" >/dev/null 2>&1
}

backup_file_once() {
  local f="$1"
  if [[ -f "$f" && ! -f "${f}.bak" ]]; then
    cp -a "$f" "${f}.bak"
    log "Backup created: ${f}.bak"
  fi
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Please run this script as root."
}

require_slemicro() {
  command_exists transactional-update || die "transactional-update not found. This script is intended for SLE Micro."
}

set_timezone_if_needed() {
  if command_exists timedatectl; then
    local current_tz=""
    current_tz="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
    if [[ "${current_tz}" != "${TIMEZONE}" ]]; then
      log "Setting timezone to ${TIMEZONE}"
      timedatectl set-timezone "${TIMEZONE}" || warn "Failed to set timezone"
    else
      log "Timezone already set to ${TIMEZONE}"
    fi
  else
    warn "timedatectl not found, skipping timezone setup"
  fi
}

set_hostname_if_needed() {
  if [[ -z "${NODE_HOSTNAME}" ]]; then
    warn "NODE_HOSTNAME not provided. Please ensure hostname is unique before joining RKE2."
    return 0
  fi

  local current_hostname=""
  current_hostname="$(hostnamectl --static 2>/dev/null || hostname)"

  if [[ "${current_hostname}" != "${NODE_HOSTNAME}" ]]; then
    log "Setting hostname to ${NODE_HOSTNAME}"
    hostnamectl set-hostname "${NODE_HOSTNAME}"
  else
    log "Hostname already set to ${NODE_HOSTNAME}"
  fi
}

ensure_hosts_baseline() {
  log "Ensuring /etc/hosts baseline entries"
  backup_file_once /etc/hosts

  grep -qE '^127\.0\.0\.1[[:space:]]+localhost([[:space:]]|$)' /etc/hosts || echo "127.0.0.1 localhost" >> /etc/hosts
  grep -qE '^::1[[:space:]]+localhost([[:space:]]|$)' /etc/hosts || echo "::1 localhost" >> /etc/hosts

  if [[ -n "${NODE_IP}" && -n "${NODE_HOSTNAME}" ]]; then
    if grep -qE "^[[:space:]]*${NODE_IP}[[:space:]]+${NODE_HOSTNAME}([[:space:]]|$)" /etc/hosts; then
      log "/etc/hosts already contains ${NODE_IP} ${NODE_HOSTNAME}"
    else
      echo "${NODE_IP} ${NODE_HOSTNAME}" >> /etc/hosts
      log "Added ${NODE_IP} ${NODE_HOSTNAME} to /etc/hosts"
    fi
  fi
}

configure_networkmanager_for_rke2() {
  log "Configuring NetworkManager to ignore RKE2/CNI interfaces"
  mkdir -p /etc/NetworkManager/conf.d

  cat > /etc/NetworkManager/conf.d/rke2-canal.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:flannel*;interface-name:cali*;interface-name:tunl*;interface-name:vxlan.calico;interface-name:vxlan-v6.calico;interface-name:wireguard.cali;interface-name:wg-v6.cali
EOF

  chmod 0644 /etc/NetworkManager/conf.d/rke2-canal.conf

  if systemctl is-active --quiet NetworkManager; then
    systemctl reload NetworkManager || warn "Failed to reload NetworkManager"
    log "NetworkManager reloaded"
  else
    warn "NetworkManager is not active. Please verify host networking service."
  fi
}

disable_nm_cloud_setup() {
  for unit in nm-cloud-setup.service nm-cloud-setup.timer; do
    if unit_exists "${unit}"; then
      log "Disabling ${unit}"
      systemctl disable --now "${unit}" || warn "Failed to disable ${unit}"
    else
      log "${unit} not found, skipping"
    fi
  done
}

disable_firewalld_if_present() {
  if unit_exists firewalld.service; then
    log "Disabling firewalld"
    systemctl disable --now firewalld || warn "Failed to disable firewalld"
  else
    log "firewalld.service not found, skipping"
  fi
}

write_sysctl_config() {
  log "Writing sysctl config for forwarding"
  cat > /etc/sysctl.d/90-rke2.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1
EOF
  chmod 0644 /etc/sysctl.d/90-rke2.conf

  if command_exists sysctl; then
    sysctl --system >/dev/null 2>&1 || warn "sysctl reload returned non-zero, changes should still apply after reboot"
  else
    warn "sysctl not found, skipping live apply"
  fi
}

write_profile_for_rke2_tools() {
  log "Preparing PATH/KUBECONFIG profile for future RKE2 tools"
  cat > /etc/profile.d/rke2-path.sh <<'EOF'
export PATH=$PATH:/var/lib/rancher/rke2/bin:/opt/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
alias k=kubectl
EOF
  chmod 0644 /etc/profile.d/rke2-path.sh
}

build_package_list() {
  PKG_LIST=("${REQUIRED_PKGS[@]}")
  OPTIONAL_APPARMOR_CHOSEN=""

  if bool_true "${INSTALL_OPTIONAL_APPARMOR_TOOLS}" && ! command_exists apparmor_parser; then
    for candidate in apparmor-parser apparmor; do
      if package_available "${candidate}"; then
        OPTIONAL_APPARMOR_CHOSEN="${candidate}"
        PKG_LIST+=("${candidate}")
        break
      fi
    done

    if [[ -z "${OPTIONAL_APPARMOR_CHOSEN}" ]]; then
      warn "No optional AppArmor userspace package found in current repos, continuing without it"
    fi
  fi
}

install_packages() {
  build_package_list
  log "Installing packages via transactional-update: ${PKG_LIST[*]}"
  transactional-update -n pkg install "${PKG_LIST[@]}"
}

setup_post_reboot_registration() {
  if ! bool_true "${AUTO_CONTINUE_AFTER_REBOOT}"; then
    log "AUTO_CONTINUE_AFTER_REBOOT=false, skip post-reboot continuation"
    return 0
  fi

  if ! bool_true "${RUN_RANCHER_REGISTRATION_COMMAND}"; then
    log "RUN_RANCHER_REGISTRATION_COMMAND=false, skip post-reboot registration"
    return 0
  fi

  if [[ -z "${RANCHER_REGISTRATION_COMMAND// }" ]]; then
    warn "RANCHER_REGISTRATION_COMMAND is empty, skip post-reboot registration"
    return 0
  fi

  local cmd_b64
  cmd_b64="$(printf '%s' "${RANCHER_REGISTRATION_COMMAND}" | base64 -w0)"

  log "Creating one-shot post-reboot registration hook"

  cat > /usr/local/sbin/rke2-post-reboot-register.sh <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

sleep ${POST_REBOOT_DELAY_SECONDS}

echo "[INFO] Running Rancher registration command after reboot..."
CMD_B64='${cmd_b64}'
printf '%s' "\${CMD_B64}" | base64 -d | bash

echo "[INFO] Registration command completed successfully, cleaning up one-shot service..."
systemctl disable --now rke2-post-reboot-register.service || true
rm -f /etc/systemd/system/rke2-post-reboot-register.service
rm -f /usr/local/sbin/rke2-post-reboot-register.sh
systemctl daemon-reload || true
EOF

  chmod 0755 /usr/local/sbin/rke2-post-reboot-register.sh

  cat > /etc/systemd/system/rke2-post-reboot-register.service <<'EOF'
[Unit]
Description=Run Rancher registration command once after reboot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rke2-post-reboot-register.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable rke2-post-reboot-register.service
  log "One-shot post-reboot registration service enabled"
}

show_summary() {
  echo
  echo "============================================================"
  echo "SLE Micro 6.2 RKE2 node pre-init finished"
  echo "============================================================"
  echo "Hostname       : ${NODE_HOSTNAME:-<unchanged>}"
  echo "Node IP        : ${NODE_IP:-<not set>}"
  echo "Timezone       : ${TIMEZONE}"
  echo "Reboot needed  : YES (transactional-update was used)"
  echo
  echo "Key files:"
  echo "  - /etc/NetworkManager/conf.d/rke2-canal.conf"
  echo "  - /etc/sysctl.d/90-rke2.conf"
  echo "  - /etc/profile.d/rke2-path.sh"
  echo
  if bool_true "${AUTO_CONTINUE_AFTER_REBOOT}" && bool_true "${RUN_RANCHER_REGISTRATION_COMMAND}"; then
    echo "Post-reboot:"
    echo "  - rke2-post-reboot-register.service is enabled"
    echo "  - It will run once after reboot"
    echo
  fi
  echo "Next:"
  echo "  1. Reboot this node"
  echo "  2. After reboot, verify:"
  echo "     cat /etc/NetworkManager/conf.d/rke2-canal.conf"
  echo "     systemctl is-enabled firewalld || true"
  echo "     which iptables"
  echo "  3. If you did NOT enable post-reboot registration, then manually run the Rancher UI generated registration command"
  echo "============================================================"
  echo
}

maybe_reboot() {
  if bool_true "${DO_REBOOT}"; then
    log "DO_REBOOT=true, rebooting now..."
    reboot
  else
    warn "Please reboot manually before installing/joining RKE2."
  fi
}

main() {
  require_root
  require_slemicro

  log "Starting SLE Micro 6.2 pre-init for RKE2 node"

  set_timezone_if_needed
  set_hostname_if_needed
  ensure_hosts_baseline
  configure_networkmanager_for_rke2
  disable_nm_cloud_setup
  disable_firewalld_if_present
  write_sysctl_config
  write_profile_for_rke2_tools
  setup_post_reboot_registration
  install_packages
  show_summary
  maybe_reboot
}

main "$@"
