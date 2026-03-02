#!/usr/bin/env bash
set -e

APP="fiff-guard"
CONF="/etc/${APP}.conf"

log() { echo -e "[+] $1"; }

if [[ $EUID -ne 0 ]]; then
  echo "Jalankan sebagai root: sudo bash fiff-guard.sh"
  exit 1
fi

install_packages() {
  log "Update & install package..."
  apt update -y
  apt install -y ufw fail2ban unattended-upgrades auditd libpam-google-authenticator curl
}

setup_firewall() {
  log "Setup firewall..."
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
}

harden_ssh() {
  log "Hardening SSH..."
  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

  sed -i 's/#PermitRootLogin yes/PermitRootLogin no/g' /etc/ssh/sshd_config
  sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
  sed -i 's/PermitRootLogin yes/PermitRootLogin no/g' /etc/ssh/sshd_config
  sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config

  echo "MaxAuthTries 3" >> /etc/ssh/sshd_config
  echo "LoginGraceTime 20" >> /etc/ssh/sshd_config

  systemctl restart ssh
}

setup_fail2ban() {
  log "Setup fail2ban..."
  systemctl enable fail2ban
  systemctl restart fail2ban
}

setup_auto_updates() {
  log "Enable security auto updates..."
  dpkg-reconfigure -f noninteractive unattended-upgrades
}

setup_audit() {
  log "Enable auditd..."
  systemctl enable auditd
  systemctl restart auditd
}

lock_webroot() {
  if [ -d "/var/www" ]; then
    log "Locking webroot (anti deface basic)..."
    chattr -R +i /var/www || true
  fi
}

status_info() {
  echo "===== STATUS ====="
  ufw status
  systemctl status fail2ban --no-pager | head -n 5
  systemctl status ssh --no-pager | head -n 5
}

case "$1" in
  install)
    install_packages
    setup_firewall
    harden_ssh
    setup_fail2ban
    setup_auto_updates
    setup_audit
    lock_webroot
    log "Install selesai ✅"
    ;;
  status)
    status_info
    ;;
  *)
    echo "Gunakan:"
    echo "sudo bash fiff-guard.sh install"
    echo "sudo bash fiff-guard.sh status"
    ;;
esac
