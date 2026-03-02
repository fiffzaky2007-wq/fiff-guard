#!/usr/bin/env bash
set -euo pipefail

# ============================
#  FIFF SECURE - VPS HARDENER
#  DEVELOPER @fifonemsg
# ============================

# ---- Colors
RED="\033[0;31m"
BRED="\033[1;31m"
WHITE="\033[1;37m"
DIM="\033[2m"
GRAY="\033[0;37m"
RESET="\033[0m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
CYAN="\033[0;36m"

APP="fiff-secure"
LOG="/var/log/${APP}.log"

# ---- UI helpers
now() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo -e "[$(now)] $*" | tee -a "$LOG" >/dev/null; }
ok()  { echo -e "${GREEN}✓${RESET} $*"; log "OK: $*"; }
warn(){ echo -e "${YELLOW}!${RESET} $*"; log "WARN: $*"; }
err() { echo -e "${RED}✗${RESET} $*"; log "ERR: $*"; }

spinner() {
  # spinner "message" command...
  local msg="$1"; shift
  local pid
  local spin='-\|/'
  local i=0
  echo -ne "${BRED}⟲${RESET} ${WHITE}${msg}${RESET} "
  ( "$@" ) >>"$LOG" 2>&1 & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) %4 ))
    echo -ne "\b${spin:$i:1}"
    sleep 0.12
  done
  wait "$pid" || return 1
  echo -ne "\b${GREEN}done${RESET}\n"
}

pause() { echo; read -r -p "Tekan ENTER untuk kembali..." _ || true; }

clear_screen() { clear 2>/dev/null || true; }

banner() {
  clear_screen
  echo -e "${BRED}"
  echo "███████╗██╗███████╗███████╗    ███████╗███████╗ ██████╗██╗   ██╗██████╗ ███████╗"
  echo "██╔════╝██║██╔════╝██╔════╝    ██╔════╝██╔════╝██╔════╝██║   ██║██╔══██╗██╔════╝"
  echo "█████╗  ██║█████╗  █████╗      ███████╗█████╗  ██║     ██║   ██║██████╔╝█████╗  "
  echo "██╔══╝  ██║██╔══╝  ██╔══╝      ╚════██║██╔══╝  ██║     ██║   ██║██╔══██╗██╔══╝  "
  echo "██║     ██║██║     ██║         ███████║███████╗╚██████╗╚██████╔╝██║  ██║███████╗"
  echo "╚═╝     ╚═╝╚═╝     ╚═╝         ╚══════╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝"
  echo -e "${RESET}"
  echo -e "${BRED}DEVELOPER @fifonemsg${RESET}  ${DIM}(${APP})${RESET}"
  echo -e "${DIM}Hardening VPS aman + menu keren. Semua aksi tercatat di: ${LOG}${RESET}"
  echo
}

need_root() {
  if [[ ${EUID:-999} -ne 0 ]]; then
    err "Harus dijalankan sebagai root."
    echo "Pakai: sudo bash ${APP}.sh"
    exit 1
  fi
}

has_apt() { command -v apt >/dev/null 2>&1; }
has_systemctl() { command -v systemctl >/dev/null 2>&1; }
has_ufw() { command -v ufw >/dev/null 2>&1; }

os_name() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "${PRETTY_NAME:-Linux}"
  else
    echo "Linux"
  fi
}

# ----------------------------
# Safety: avoid SSH lockout
# ----------------------------

ssh_port() {
  # get effective ssh port (first Port line), fallback 22
  local p
  p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
  echo "${p:-22}"
}

user_exists() { id "$1" >/dev/null 2>&1; }

user_has_key() {
  local u="$1"
  local home
  home="$(getent passwd "$u" | cut -d: -f6)"
  [[ -n "$home" && -f "$home/.ssh/authorized_keys" ]] || return 1
  [[ $(wc -c <"$home/.ssh/authorized_keys" 2>/dev/null || echo 0) -gt 30 ]]
}

safe_to_harden_ssh() {
  # require: at least one non-root sudo user with authorized_keys
  local u
  for u in $(getent group sudo | awk -F: '{print $4}' | tr ',' ' '); do
    [[ -n "$u" ]] || continue
    if user_exists "$u" && user_has_key "$u"; then
      return 0
    fi
  done
  return 1
}

# ----------------------------
# Core actions
# ----------------------------

action_sys_update() {
  banner
  echo -e "${WHITE}[SYSTEM] Update OS packages${RESET}"
  echo
  if ! has_apt; then err "APT tidak ditemukan. Script ini fokus Ubuntu/Debian."; pause; return; fi
  spinner "apt update" apt update -y
  spinner "apt upgrade" apt upgrade -y
  ok "Update selesai."
  warn "Kalau ada tulisan 'System restart required', reboot nanti setelah semua setup."
  pause
}

action_install_base_tools() {
  banner
  echo -e "${WHITE}[SYSTEM] Install tools dasar (curl, nano, ufw, fail2ban, auditd)${RESET}"
  echo
  if ! has_apt; then err "APT tidak ditemukan."; pause; return; fi
  spinner "Install base packages" apt install -y curl ca-certificates nano ufw fail2ban auditd needrestart
  ok "Base tools terinstall."
  pause
}

action_enable_ssh() {
  banner
  echo -e "${WHITE}[/sshaktif] Install + aktifkan OpenSSH Server${RESET}"
  echo
  if ! has_apt; then err "APT tidak ditemukan."; pause; return; fi
  spinner "Install openssh-server" apt install -y openssh-server
  if has_systemctl; then
    spinner "Enable & restart ssh" bash -lc "systemctl enable ssh >/dev/null 2>&1 || true; systemctl restart ssh || systemctl restart sshd"
  fi

  local p; p="$(ssh_port)"
  ok "SSH aktif. Port: ${p}"
  if has_ufw; then
    spinner "UFW allow ${p}/tcp" ufw allow "${p}/tcp"
    ok "UFW rule ditambahkan untuk SSH."
  else
    warn "UFW belum ada / belum dipakai. (Skip firewall rule)"
  fi
  pause
}

action_create_admin_user() {
  banner
  echo -e "${WHITE}[USER] Buat user admin baru + sudo${RESET}"
  echo -e "${DIM}Disarankan jangan pakai root terus.${RESET}"
  echo
  read -r -p "Nama user baru (contoh: fiff): " uname
  uname="${uname:-}"
  if [[ -z "$uname" ]]; then err "Nama user kosong."; pause; return; fi
  if user_exists "$uname"; then warn "User '$uname' sudah ada. Lanjut set sudo."; else
    spinner "adduser ${uname}" adduser "$uname"
  fi
  spinner "Tambah ke group sudo" usermod -aG sudo "$uname"
  ok "User '$uname' siap jadi admin (sudo)."
  echo -e "${DIM}Next: pasang SSH key ke user ini biar aman.${RESET}"
  pause
}

action_install_ssh_key_to_user() {
  banner
  echo -e "${WHITE}[USER] Pasang SSH public key ke user (authorized_keys)${RESET}"
  echo
  read -r -p "Nama user target (contoh: fiff): " uname
  uname="${uname:-}"
  if ! user_exists "$uname"; then err "User '$uname' tidak ada."; pause; return; fi

  echo
  echo -e "${YELLOW}Paste SSH PUBLIC KEY kamu (1 baris) lalu ENTER.${RESET}"
  echo -e "${DIM}Contoh: ssh-ed25519 AAAA.... comment${RESET}"
  read -r pubkey
  if [[ -z "${pubkey}" || "${pubkey}" != ssh-* ]]; then
    err "Public key tidak valid (harus diawali ssh-ed25519 / ssh-rsa / dst)."
    pause; return
  fi

  local home; home="$(getent passwd "$uname" | cut -d: -f6)"
  spinner "Buat folder .ssh" bash -lc "mkdir -p '$home/.ssh' && chmod 700 '$home/.ssh' && touch '$home/.ssh/authorized_keys' && chmod 600 '$home/.ssh/authorized_keys' && chown -R '$uname:$uname' '$home/.ssh'"
  spinner "Append key" bash -lc "echo '$pubkey' >> '$home/.ssh/authorized_keys'"
  ok "Key dipasang ke $uname."
  echo -e "${DIM}Tes dari HP: ssh ${uname}@IP (harusnya tanpa password kalau key dipakai).${RESET}"
  pause
}

action_firewall_ufw_basic() {
  banner
  echo -e "${WHITE}[FIREWALL] Setup UFW basic (aman)${RESET}"
  echo -e "${DIM}Default deny incoming, allow outgoing. Buka SSH/HTTP/HTTPS.${RESET}"
  echo
  if ! has_apt; then err "APT tidak ditemukan."; pause; return; fi
  spinner "Install ufw" apt install -y ufw

  local p; p="$(ssh_port)"
  spinner "ufw default deny incoming" ufw default deny incoming
  spinner "ufw default allow outgoing" ufw default allow outgoing
  spinner "ufw allow SSH ${p}/tcp" ufw allow "${p}/tcp"
  spinner "ufw allow 80/tcp" ufw allow 80/tcp
  spinner "ufw allow 443/tcp" ufw allow 443/tcp
  spinner "Enable UFW" ufw --force enable
  ok "UFW aktif."
  ufw status || true
  pause
}

action_fail2ban_enable() {
  banner
  echo -e "${WHITE}[SECURITY] Enable Fail2ban (anti brute force)${RESET}"
  echo
  if ! has_apt; then err "APT tidak ditemukan."; pause; return; fi
  spinner "Install fail2ban" apt install -y fail2ban
  if has_systemctl; then
    spinner "Enable & restart fail2ban" bash -lc "systemctl enable --now fail2ban; systemctl restart fail2ban"
  fi
  ok "Fail2ban aktif."
  pause
}

action_auto_updates() {
  banner
  echo -e "${WHITE}[SECURITY] Aktifkan Unattended-Upgrades (auto security update)${RESET}"
  echo
  if ! has_apt; then err "APT tidak ditemukan."; pause; return; fi
  spinner "Install unattended-upgrades" apt install -y unattended-upgrades
  spinner "Enable unattended-upgrades" dpkg-reconfigure -f noninteractive unattended-upgrades
  ok "Auto security updates aktif."
  pause
}

detect_webroot() {
  if [[ -d /var/www/html ]]; then echo "/var/www/html"
  elif [[ -d /var/www ]]; then echo "/var/www"
  else echo ""
  fi
}

action_antideface_basic() {
  banner
  echo -e "${WHITE}[WEB] Anti-deface basic (permission + optional immutable)${RESET}"
  echo
  local webroot; webroot="$(detect_webroot)"
  if [[ -z "$webroot" ]]; then
    warn "Webroot tidak ketemu (/var/www atau /var/www/html)."
    read -r -p "Masukkan path webroot manual (contoh /var/www/site): " webroot
    [[ -d "$webroot" ]] || { err "Folder tidak ada."; pause; return; }
  fi

  ok "Webroot: $webroot"
  echo

  spinner "Set owner root:www-data (best effort)" bash -lc "chown -R root:www-data '$webroot' 2>/dev/null || true"
  spinner "Set folder 755" bash -lc "find '$webroot' -type d -exec chmod 755 {} \; 2>/dev/null || true"
  spinner "Set file 644" bash -lc "find '$webroot' -type f -exec chmod 644 {} \; 2>/dev/null || true"
  ok "Permission dasar diterapkan."

  echo
  echo -e "${YELLOW}Mode ketat (opsional): chattr +i (immutable).${RESET}"
  echo -e "${DIM}PERINGATAN: bisa lama kalau file banyak. Untuk unlock: chattr -R -i PATH${RESET}"
  read -r -p "Aktifkan immutable lock? (y/N): " ans
  ans="${ans:-N}"
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    if command -v chattr >/dev/null 2>&1; then
      spinner "chattr -R +i $webroot" bash -lc "chattr -R +i '$webroot' || true"
      ok "Immutable lock diaktifkan."
    else
      warn "chattr tidak tersedia. Skip."
    fi
  else
    ok "Skip immutable lock."
  fi

  pause
}

action_ssh_hardening_safe() {
  banner
  echo -e "${WHITE}[SSH] Hardening SSH (SAFE MODE)${RESET}"
  echo -e "${DIM}Aman: hanya jalan jika ada sudo user NON-root yang sudah punya SSH key.${RESET}"
  echo

  if ! safe_to_harden_ssh; then
    err "Belum aman untuk hardening."
    echo -e "${YELLOW}Syarat:${RESET}"
    echo "1) Buat user admin (menu User)"
    echo "2) Pasang SSH public key ke user itu"
    echo "3) Tes bisa login tanpa password"
    echo
    warn "Kalau dipaksa sekarang, bisa ke-lock."
    pause
    return
  fi

  local p; p="$(ssh_port)"
  ok "Safety check lolos. SSH port: $p"
  echo

  spinner "Backup sshd_config" bash -lc "cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)"
  spinner "Set PubkeyAuthentication yes" bash -lc "sed -i 's/^#\\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config || true"
  spinner "Disable PasswordAuthentication" bash -lc "sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config || true"
  spinner "Disable root login" bash -lc "sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config || true"
  spinner "Set MaxAuthTries 3" bash -lc "grep -q '^MaxAuthTries' /etc/ssh/sshd_config && sed -i 's/^MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config || echo 'MaxAuthTries 3' >> /etc/ssh/sshd_config"
  spinner "Set LoginGraceTime 20" bash -lc "grep -q '^LoginGraceTime' /etc/ssh/sshd_config && sed -i 's/^LoginGraceTime.*/LoginGraceTime 20/' /etc/ssh/sshd_config || echo 'LoginGraceTime 20' >> /etc/ssh/sshd_config"

  # validate config before restart
  if sshd -t >/dev/null 2>&1; then
    spinner "Restart ssh" bash -lc "systemctl restart ssh || systemctl restart sshd"
    ok "Hardening SSH selesai."
    echo -e "${DIM}Sekarang login harus pakai SSH key (password mati) dan root login dimatikan.${RESET}"
  else
    err "sshd_config invalid. Tidak restart. Cek: /etc/ssh/sshd_config"
  fi

  pause
}

action_pterodactyl_notes() {
  banner
  echo -e "${WHITE}[PTERODACTYL] Quick hardening checklist (aman)${RESET}"
  echo
  echo -e "${DIM}Ini bukan 'anti hack 100%'. Ini checklist aman yang sering dilupakan.${RESET}"
  echo
  echo -e "${WHITE}1) Jangan expose Docker socket${RESET}"
  echo -e "   - Pastikan /var/run/docker.sock tidak bisa diakses user biasa."
  echo -e "   - Jangan kasih user panel akses ke group 'docker' kecuali perlu."
  echo
  echo -e "${WHITE}2) Firewall ports Wings/Panel sesuai kebutuhan${RESET}"
  echo -e "   - Panel (biasanya 80/443) saja untuk publik."
  echo -e "   - Wings port (biasanya 8080/2022 tergantung config) batasi hanya dari panel/IP tertentu kalau bisa."
  echo
  echo -e "${WHITE}3) Update rutin + fail2ban${RESET}"
  echo -e "   - Pastikan auto updates aktif."
  echo -e "   - Fail2ban jalan."
  echo
  echo -e "${WHITE}4) Permission folder data${RESET}"
  echo -e "   - Pastikan permission folder /var/lib/pterodactyl sesuai docs."
  echo
  echo -e "${YELLOW}Mau aku tambah menu 'UFW preset untuk Pterodactyl' (panel+wings) sesuai port kamu?${RESET}"
  pause
}

action_status() {
  banner
  echo -e "${WHITE}[STATUS] Cek status layanan & keamanan${RESET}"
  echo
  echo -e "${CYAN}OS:${RESET} $(os_name)"
  echo -e "${CYAN}SSH Port:${RESET} $(ssh_port)"
  echo

  echo -e "${WHITE}SSH service:${RESET}"
  systemctl status ssh --no-pager 2>/dev/null | head -n 12 || true
  echo

  if has_ufw; then
    echo -e "${WHITE}UFW:${RESET}"
    ufw status || true
    echo
  else
    echo -e "${DIM}UFW: tidak terpasang${RESET}"
  fi

  echo -e "${WHITE}Fail2ban:${RESET}"
  systemctl status fail2ban --no-pager 2>/dev/null | head -n 10 || true
  echo

  echo -e "${WHITE}Auditd:${RESET}"
  systemctl status auditd --no-pager 2>/dev/null | head -n 10 || true
  echo

  echo -e "${DIM}Log tools: ${LOG}${RESET}"
  pause
}

action_reboot_prompt() {
  banner
  echo -e "${WHITE}[SYSTEM] Reboot VPS${RESET}"
  echo -e "${YELLOW}Reboot dibutuhkan setelah kernel update atau perubahan penting.${RESET}"
  echo
  read -r -p "Yakin reboot sekarang? (y/N): " ans
  ans="${ans:-N}"
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    ok "Rebooting..."
    reboot
  else
    ok "Batal."
    pause
  fi
}

# ----------------------------
# Menu
# ----------------------------

menu() {
  while true; do
    banner
    echo -e "${BRED}MENU KEAMANAN VPS${RESET}"
    echo -e "${DIM}Ketik nomor lalu ENTER.${RESET}"
    echo
    echo -e "${WHITE}[ 1 ]${RESET} System Update (apt update/upgrade)"
    echo -e "${WHITE}[ 2 ]${RESET} Install Base Tools (curl/nano/ufw/fail2ban/auditd)"
    echo -e "${WHITE}[ 3 ]${RESET} /sshaktif  (install + aktifkan SSH server)"
    echo -e "${WHITE}[ 4 ]${RESET} Buat User Admin + sudo"
    echo -e "${WHITE}[ 5 ]${RESET} Pasang SSH Key ke User"
    echo -e "${WHITE}[ 6 ]${RESET} Firewall UFW Basic (SSH/80/443)"
    echo -e "${WHITE}[ 7 ]${RESET} Enable Fail2ban"
    echo -e "${WHITE}[ 8 ]${RESET} Enable Auto Security Updates"
    echo -e "${WHITE}[ 9 ]${RESET} /antideface (permission + optional immutable)"
    echo -e "${WHITE}[10 ]${RESET} Hardening SSH (SAFE MODE: key wajib)"
    echo -e "${WHITE}[11 ]${RESET} Pterodactyl Hardening Notes (aman)"
    echo -e "${WHITE}[12 ]${RESET} Status Check"
    echo -e "${WHITE}[13 ]${RESET} Reboot"
    echo
    echo -e "${GRAY}[ q ] Quit${RESET}"
    echo
    read -r -p "> " choice || true

    case "${choice}" in
      1) action_sys_update ;;
      2) action_install_base_tools ;;
      3) action_enable_ssh ;;
      4) action_create_admin_user ;;
      5) action_install_ssh_key_to_user ;;
      6) action_firewall_ufw_basic ;;
      7) action_fail2ban_enable ;;
      8) action_auto_updates ;;
      9) action_antideface_basic ;;
      10) action_ssh_hardening_safe ;;
      11) action_pterodactyl_notes ;;
      12) action_status ;;
      13) action_reboot_prompt ;;
      q|Q) echo -e "${DIM}Bye.${RESET}"; exit 0 ;;
      *) warn "Pilihan tidak valid."; sleep 0.8 ;;
    esac
  done
}

# Entry
need_root
touch "$LOG" 2>/dev/null || true
menu
