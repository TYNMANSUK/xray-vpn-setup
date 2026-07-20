#!/bin/bash
#
# install.sh — установка и настройка Xray VPN (3x-ui) для Ubuntu VPS
# Репозиторий: https://github.com/TYNMANSUK/xray-vpn-setup
#
# Что делает (по шагам, с возможностью продолжить после обрыва):
#   1. Swap (умный размер под RAM)
#   2. BBR + сетевые оптимизации (sysctl)
#   3. Firewall (ufw)
#   4. fail2ban
#   5. 3x-ui + Xray
#   6. Финал: команда vpn, данные панели
#
# После установки — меню: vpn
# В меню есть автонастройка: скрипт тестирует SNI-цели и создаёт несколько
# готовых связок (VLESS+Reality / Trojan+Reality) с разными отпечатками,
# чтобы в клиенте можно было выбрать рабочую.
#
# Запуск:
#   curl -fsSL https://raw.githubusercontent.com/TYNMANSUK/xray-vpn-setup/main/install.sh | bash
#   или:  bash install.sh
#
# Дополнительно (опционально): CDN-подключение (XHTTP через CDN) — команда `vpn cdn`.
# Модуль CDN основан на проекте obletcdn (Apache License 2.0, (c) Gleb Bakulev):
# встроенные bridge.py и users.py включены с изменениями (адаптированы пути,
# имена сервисов и интеграция). Текст лицензии — obletcdn-main/LICENSE в репозитории.
#
# Важно: НЕ используем set -e — это установщик, отдельные ошибки не должны
# убивать весь процесс. Резюмируемость обеспечивает файл состояния.

set -uo pipefail

# ==================== ЛОКАЛЬ (UTF-8, чтобы русский не рассыпался) ====================
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

# ==================== КОНСТАНТЫ ====================
SCRIPT_VERSION="2.7"
SCRIPT_URL="https://raw.githubusercontent.com/TYNMANSUK/xray-vpn-setup/main/install.sh"
REPO_URL="https://github.com/TYNMANSUK/xray-vpn-setup"
XUI_INSTALLER_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh"

INSTALL_DIR="/opt/xray-vpn"
SCRIPT_DEST="${INSTALL_DIR}/install.sh"
STATE_DIR="/var/lib/xray-vpn"
STATE_FILE="${STATE_DIR}/state"
PANEL_ENV="${STATE_DIR}/panel.env"
LINKS_FILE="${STATE_DIR}/links.txt"

INSTALL_LOG="/var/log/xray-vpn-install.log"
XUI_INSTALL_LOG="/tmp/3xui_install.log"
INFO_FILE="/root/xray-vpn-info.txt"
JAR="/tmp/xui_cookies.txt"

TOTAL_STEPS=6

# ---- CDN-модуль (XHTTP через CDN), опционально ----
CDN_DIR="/opt/xray-vpn-cdn"
CDN_CONFIG="${CDN_DIR}/config.json"
CDN_XRAY_BIN="${CDN_DIR}/xray"
CDN_USERS="${CDN_DIR}/users.py"
CDN_XRAY_PORT=8003                 # локальный порт xray XHTTP (за Nginx)
CDN_XHTTP_PATH="/api-test"
CDN_PADDING_KEY="dc"
CDN_NGINX_SITE="/etc/nginx/sites-available/xray-vpn-cdn.conf"
CDN_NGINX_MAP="/etc/nginx/conf.d/xray-vpn-cdn-method.conf"
CDN_ENV="${STATE_DIR}/cdn.env"

# ==================== ЦВЕТА ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==================== ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ (init для set -u) ====================
MODE="install"       # install | manage
SUBCMD="menu"
SUBARG=""            # доп. позиционный аргумент подкоманды (например имя пользователя CDN)
USE_TMUX="false"     # по умолчанию БЕЗ tmux; включается флагом --tmux

PANEL_PORT=""
PANEL_USER=""
PANEL_PASS=""
WEB_BASE_PATH="/"
PRIVATE_KEY=""
PUBLIC_KEY=""

# ==================== ЛОГ / ВЫВОД (объявлены ДО любого использования) ====================
ensure_dirs() {
  mkdir -p "$INSTALL_DIR" "$STATE_DIR" 2>/dev/null || true
  mkdir -p /var/log 2>/dev/null || true
  touch "$INSTALL_LOG" 2>/dev/null || true
  chmod 644 "$INSTALL_LOG" 2>/dev/null || true
}

log()     { printf '%s\n' "$*"        | tee -a "$INSTALL_LOG" ; }
ok()      { printf '  [OK] %s\n' "$*" | tee -a "$INSTALL_LOG" ; }
warn()    { printf '  [!] %s\n'  "$*" | tee -a "$INSTALL_LOG" ; }
err()     { printf '  [X] %s\n'  "$*" | tee -a "$INSTALL_LOG" ; }
cecho()   { printf '%b\n' "$1"; }

print_header() {
  echo
  echo "================================================================"
  echo "        XRAY VPN — установка и настройка (Ubuntu)  v${SCRIPT_VERSION}"
  echo "================================================================"
  echo
}

# ==================== БАЗОВЫЕ ПРОВЕРКИ ====================
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Нужны права root. Запусти: sudo bash install.sh"
    exit 1
  fi
}

detect_os() {
  if [ ! -f /etc/os-release ]; then
    err "Не удалось определить ОС (нет /etc/os-release)"
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  log "ОС: ${PRETTY_NAME:-неизвестно}"
  if [ "${ID:-}" != "ubuntu" ]; then
    warn "Скрипт рассчитан на Ubuntu. Текущая ОС: ${PRETTY_NAME:-?}"
    if [ -t 0 ]; then
      read -rp "  Продолжить всё равно? (y/N): " a
      case "$a" in y|Y) ;; *) exit 1 ;; esac
    else
      warn "Продолжаю (неинтерактивный режим)."
    fi
  fi
}

system_info() {
  local mem cpu
  mem=$(free -m 2>/dev/null | awk '/Mem:/{print $2}')
  cpu=$(nproc 2>/dev/null || echo "?")
  log "Ресурсы: RAM ${mem:-?} МБ, CPU ${cpu} ядер"
}

server_ip() {
  local ip
  ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null)
  [ -z "$ip" ] && ip=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null)
  [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  printf '%s' "${ip:-127.0.0.1}"
}

# ==================== ФАЙЛ СОСТОЯНИЯ (резюмируемость) ====================
state_get() {
  [ -f "$STATE_FILE" ] || return 0
  grep -E "^$1=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}
state_set() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  touch "$STATE_FILE" 2>/dev/null || true
  { grep -vE "^$1=" "$STATE_FILE" 2>/dev/null || true; echo "$1=$2"; } > "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
}
state_is_ok() { [ "$(state_get "$1")" = "ok" ]; }

# do_step <key> <num> <title> <check_fn> <do_fn> [critical]
# Логика:
#   - если реальная проверка системы проходит -> шаг уже сделан, пропускаем
#   - иначе выполняем; при успехе + подтверждении проверкой -> отмечаем ok
#   - при провале критичного шага -> останавливаемся (резюме при следующем запуске)
do_step() {
  local key="$1" num="$2" title="$3" check_fn="$4" do_fn="$5" critical="${6:-false}"

  log ""
  log "[Шаг ${num}/${TOTAL_STEPS}] ${title}"

  if "$check_fn" 2>/dev/null; then
    state_set "$key" ok
    log "  [ПРОПУСК] уже настроено"
    return 0
  fi

  if state_is_ok "$key"; then
    log "  [ПОВТОР] помечено как готовое, но система это не подтвердила — настраиваю заново"
  fi

  if "$do_fn"; then
    if "$check_fn" 2>/dev/null; then
      state_set "$key" ok
      ok "${title} — готово"
      return 0
    fi
    state_set "$key" partial
    warn "${title}: шаг выполнен, но проверка не подтвердила результат"
    [ "$critical" = "true" ] && halt_resume "$title"
    return 1
  else
    state_set "$key" failed
    err "${title}: шаг не выполнен"
    [ "$critical" = "true" ] && halt_resume "$title"
    return 1
  fi
}

halt_resume() {
  echo
  err "Установка остановлена на шаге: $1"
  log "Это не страшно. Запусти установку ещё раз — она продолжит с этого места:"
  log "   curl -fsSL ${SCRIPT_URL} | bash"
  log "Уже выполненные шаги повторяться не будут."
  exit 1
}

# ==================== ПОДГОТОВКА ПАКЕТОВ ====================
ensure_prereqs() {
  log ""
  log "Подготовка: проверяю необходимые пакеты..."
  local need=""
  command -v curl     >/dev/null 2>&1 || need="$need curl"
  command -v jq       >/dev/null 2>&1 || need="$need jq"
  command -v openssl  >/dev/null 2>&1 || need="$need openssl"
  command -v ufw      >/dev/null 2>&1 || need="$need ufw"
  command -v fail2ban-client >/dev/null 2>&1 || need="$need fail2ban"
  command -v tmux     >/dev/null 2>&1 || need="$need tmux"
  command -v qrencode >/dev/null 2>&1 || need="$need qrencode"
  command -v ss       >/dev/null 2>&1 || need="$need iproute2"
  command -v uuidgen  >/dev/null 2>&1 || need="$need uuid-runtime"

  if [ -n "$need" ]; then
    log "  Устанавливаю:$need"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y  >>"$INSTALL_LOG" 2>&1 || true
    # shellcheck disable=SC2086
    apt-get install -y $need >>"$INSTALL_LOG" 2>&1 || true
    ok "Пакеты обработаны"
  else
    ok "Все пакеты на месте"
  fi
}

# ==================== ШАГ 1: SWAP ====================
check_swap() {
  local s
  s=$(free 2>/dev/null | awk '/Swap:/{print $2}')
  [ -n "$s" ] && [ "$s" -gt 0 ] 2>/dev/null
}
do_swap() {
  local mem_mb size
  mem_mb=$(free -m 2>/dev/null | awk '/Mem:/{print $2}')
  size=2048
  [ "${mem_mb:-0}" -gt 4096 ] 2>/dev/null && size=1024
  log "  Создаю swap ${size} МБ..."
  swapoff /swapfile 2>/dev/null || true
  rm -f /swapfile
  fallocate -l "${size}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$size" status=none 2>>"$INSTALL_LOG"
  chmod 600 /swapfile
  mkswap /swapfile >>"$INSTALL_LOG" 2>&1
  swapon /swapfile || return 1
  grep -q '^/swapfile ' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10 >>"$INSTALL_LOG" 2>&1 || true
  grep -q 'vm.swappiness' /etc/sysctl.conf 2>/dev/null || echo 'vm.swappiness=10' >> /etc/sysctl.conf
  return 0
}

# ==================== ШАГ 2: BBR + СЕТЬ ====================
check_sysctl() {
  [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]
}
do_sysctl() {
  log "  Применяю сетевые оптимизации (BBR + fq)..."
  cat > /etc/sysctl.d/99-xray-vpn.conf << 'EOF'
# xray-vpn — сетевые оптимизации для Xray / Reality
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.somaxconn = 65535
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 8192

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384

net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600

fs.file-max = 1048576
net.ipv4.ip_forward = 1
EOF

  cat > /etc/security/limits.d/99-xray-vpn.conf << 'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

  echo "tcp_bbr" > /etc/modules-load.d/xray-bbr.conf 2>/dev/null || true
  modprobe tcp_bbr 2>/dev/null || true
  sysctl --system >>"$INSTALL_LOG" 2>&1 || true
  return 0
}

# ==================== ШАГ 3: FIREWALL ====================
check_ufw() {
  ufw status 2>/dev/null | grep -q "Status: active"
}
detect_ssh_port() {
  local p
  p=$(grep -oiP '^\s*Port\s+\K[0-9]+' /etc/ssh/sshd_config 2>/dev/null | head -1)
  echo "${p:-22}"
}
do_ufw() {
  local ssh_port
  ssh_port=$(detect_ssh_port)
  log "  Настраиваю ufw (SSH ${ssh_port}, 443)..."
  ufw --force reset            >>"$INSTALL_LOG" 2>&1 || true
  ufw default deny incoming    >>"$INSTALL_LOG" 2>&1 || true
  ufw default allow outgoing   >>"$INSTALL_LOG" 2>&1 || true
  ufw allow "${ssh_port}/tcp"  comment 'SSH'          >>"$INSTALL_LOG" 2>&1 || true
  ufw allow OpenSSH            >>"$INSTALL_LOG" 2>&1 || true
  ufw allow 443/tcp            comment 'Xray Reality' >>"$INSTALL_LOG" 2>&1 || true
  ufw --force enable           >>"$INSTALL_LOG" 2>&1 || true
  return 0
}

# ==================== ШАГ 4: FAIL2BAN ====================
check_fail2ban() {
  systemctl is-active --quiet fail2ban 2>/dev/null
}
do_fail2ban() {
  local ssh_port
  ssh_port=$(detect_ssh_port)
  log "  Настраиваю fail2ban..."
  # backend = systemd — читаем journald (на Ubuntu 22.04/24.04 /var/log/auth.log
  # может отсутствовать), поэтому logpath НЕ указываем.
  cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = ${ssh_port}
backend = systemd
maxretry = 4
bantime = 3600
EOF
  systemctl enable fail2ban  >>"$INSTALL_LOG" 2>&1 || true
  systemctl restart fail2ban >>"$INSTALL_LOG" 2>&1 || true
  sleep 1
  return 0
}

# ==================== ШАГ 5: 3X-UI + XRAY ====================
check_xui() {
  [ -x /usr/local/x-ui/x-ui ]
}
do_xui() {
  log "  Скачиваю официальный установщик 3x-ui (MHSanaei)..."
  rm -f "$XUI_INSTALL_LOG" /tmp/3xui_installer.sh
  curl -fLsS -o /tmp/3xui_installer.sh "$XUI_INSTALLER_URL" 2>>"$INSTALL_LOG"
  if [ ! -s /tmp/3xui_installer.sh ]; then
    err "Не удалось скачать установщик 3x-ui (проверь интернет)"
    return 1
  fi
  log "  Запускаю установщик 3x-ui (1-3 минуты)..."
  export DEBIAN_FRONTEND=noninteractive
  # 'yes n' — отвечаем "нет" на интерактивные вопросы (не меняем порт/логин на этом этапе)
  yes n | bash /tmp/3xui_installer.sh >>"$XUI_INSTALL_LOG" 2>&1
  cat "$XUI_INSTALL_LOG" >> "$INSTALL_LOG" 2>/dev/null || true
  sleep 3
  if [ ! -x /usr/local/x-ui/x-ui ]; then
    err "3x-ui не установился. Подробности: $XUI_INSTALL_LOG"
    return 1
  fi
  systemctl enable x-ui           >>"$INSTALL_LOG" 2>&1 || true
  timeout 30 systemctl restart x-ui >>"$INSTALL_LOG" 2>&1 || true
  sleep 2
  configure_panel
  return 0
}

# ==================== ШАГ 6: ФИНАЛ ====================
check_finalize() {
  [ -x /usr/local/bin/vpn ] && [ -x /usr/local/bin/xray-vpn ]
}
do_finalize() {
  install_management_command
  # добьём данные панели, если их ещё нет
  if [ ! -f "$PANEL_ENV" ] && [ -x /usr/local/x-ui/x-ui ]; then
    get_panel_settings
    save_panel_env
    save_info_file
  fi
  return 0
}

# ==================== ДАННЫЕ ПАНЕЛИ ====================
normalize_basepath() {
  WEB_BASE_PATH=$(printf '%s' "${WEB_BASE_PATH:-}" | sed 's#^/*##; s#/*$##')
  if [ -n "$WEB_BASE_PATH" ]; then
    WEB_BASE_PATH="/${WEB_BASE_PATH}/"
  else
    WEB_BASE_PATH="/"
  fi
}

configure_panel() {
  log "  Читаю настройки панели..."
  local out port base
  out=$(timeout 10 /usr/local/x-ui/x-ui setting -show 2>/dev/null || true)
  port=$(printf '%s\n' "$out" | grep -oiP 'port:\s*\K[0-9]+' | head -1)
  [ -z "$port" ] && port=$(grep -oiP 'port:\s*\K[0-9]+' "$XUI_INSTALL_LOG" 2>/dev/null | tail -1)
  [ -z "$port" ] && port=2053
  PANEL_PORT="$port"
  base=$(printf '%s\n' "$out" | grep -oiP 'webBasePath:\s*\K\S+' | head -1)
  WEB_BASE_PATH="$base"
  normalize_basepath

  # Сбрасываем логин/пароль на известный (нужно для автонастройки)
  reset_panel_password
  save_panel_env
  save_info_file

  ufw allow "${PANEL_PORT}/tcp" comment '3x-ui panel' >>"$INSTALL_LOG" 2>&1 || true
  ok "Панель: порт ${PANEL_PORT}, путь ${WEB_BASE_PATH}"
}

reset_panel_password() {
  local new_user="admin" new_pass attempt=0
  new_pass=$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16)
  [ -z "$new_pass" ] && new_pass="Xray$(date +%s | tail -c 6)"
  PANEL_USER="$new_user"
  PANEL_PASS="$new_pass"

  log "  Устанавливаю известный логин/пароль панели..."
  while [ $attempt -lt 3 ]; do
    attempt=$((attempt + 1))
    if timeout 30 /usr/local/x-ui/x-ui setting --username "$new_user" --password "$new_pass" >>"$INSTALL_LOG" 2>&1; then
      timeout 30 systemctl restart x-ui >>"$INSTALL_LOG" 2>&1 || true
      sleep 2
      ok "Логин/пароль панели заданы"
      return 0
    fi
    sleep 3
  done
  warn "Не удалось задать пароль автоматически. Попробуй пункт меню «Сбросить пароль»."
  return 0
}

save_panel_env() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  cat > "$PANEL_ENV" << EOF
PANEL_PORT="${PANEL_PORT}"
PANEL_USER="${PANEL_USER}"
PANEL_PASS="${PANEL_PASS}"
WEB_BASE_PATH="${WEB_BASE_PATH}"
EOF
  chmod 600 "$PANEL_ENV" 2>/dev/null || true
}

get_panel_settings() {
  if [ -f "$PANEL_ENV" ]; then
    # shellcheck disable=SC1090
    . "$PANEL_ENV"
  fi
  if [ -x /usr/local/x-ui/x-ui ]; then
    local out p b
    out=$(timeout 10 /usr/local/x-ui/x-ui setting -show 2>/dev/null || true)
    p=$(printf '%s\n' "$out" | grep -oiP 'port:\s*\K[0-9]+' | head -1)
    [ -n "$p" ] && PANEL_PORT="$p"
    b=$(printf '%s\n' "$out" | grep -oiP 'webBasePath:\s*\K\S+' | head -1)
    if [ -n "$b" ]; then WEB_BASE_PATH="$b"; normalize_basepath; fi
  fi
  [ -z "${PANEL_PORT:-}" ] && PANEL_PORT="2053"
  [ -z "${WEB_BASE_PATH:-}" ] && WEB_BASE_PATH="/"
  PANEL_USER="${PANEL_USER:-}"
  PANEL_PASS="${PANEL_PASS:-}"
}

save_info_file() {
  local ip
  ip=$(server_ip)
  {
    echo "=== XRAY VPN — данные ($(date '+%Y-%m-%d %H:%M')) ==="
    echo "IP сервера:   ${ip}"
    echo "Порт панели:  ${PANEL_PORT}"
    echo "Логин:        ${PANEL_USER:-admin}"
    echo "Пароль:       ${PANEL_PASS:-<неизвестен>}"
    echo "Адрес панели: http://${ip}:${PANEL_PORT}${WEB_BASE_PATH}"
    echo
    echo "Применено: swap, BBR, ufw, fail2ban."
    if [ -s "$LINKS_FILE" ]; then
      echo
      echo "=== Готовые ссылки (автонастройка) ==="
      cat "$LINKS_FILE"
    fi
  } > "$INFO_FILE"
  chmod 600 "$INFO_FILE" 2>/dev/null || true
}

add_link() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s\n' "$1" >> "$LINKS_FILE"
}

# ==================== КОМАНДА vpn / xray-vpn ====================
download_self() {
  mkdir -p "$INSTALL_DIR" 2>/dev/null || true
  if [ -f "$0" ] && [ "$0" != "bash" ] && [ "$0" != "-" ] && [[ "$0" != /dev/fd/* ]] && [[ "$0" != /proc/* ]]; then
    # запущено из файла — всегда обновляем локальную копию свежей версией
    cp "$0" "$SCRIPT_DEST" 2>/dev/null || true
  else
    # запущено через pipe (curl | bash) — тянем свежую копию с GitHub,
    # чтобы команда vpn всегда указывала на актуальную версию
    curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_DEST" 2>>"$INSTALL_LOG" || true
  fi
  [ -s "$SCRIPT_DEST" ] || curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_DEST" 2>>"$INSTALL_LOG" || true
  chmod +x "$SCRIPT_DEST" 2>/dev/null || true
}

install_management_command() {
  download_self
  cat > /usr/local/bin/xray-vpn << 'WRAP'
#!/bin/bash
exec bash /opt/xray-vpn/install.sh --manage "$@"
WRAP
  chmod +x /usr/local/bin/xray-vpn
  cp /usr/local/bin/xray-vpn /usr/local/bin/vpn 2>/dev/null || true
  chmod +x /usr/local/bin/vpn 2>/dev/null || true
}

# ==================== TMUX (запасной вариант для curl | bash) ====================
# tmux ОПЦИОНАЛЕН (флаг --tmux). Основная защита от обрыва — резюмируемость:
# перезапуск продолжает с незавершённого шага. tmux нужен, только если хочется,
# чтобы установка крутилась дальше без переподключения.
ensure_tmux_for_install() {
  [ -n "${TMUX:-}" ] && return 0                 # уже внутри tmux

  command -v tmux >/dev/null 2>&1 || {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y tmux >/dev/null 2>&1 || true
  }
  command -v tmux >/dev/null 2>&1 || { warn "tmux недоступен — ставлю напрямую"; return 0; }

  download_self
  echo
  echo "==========================================="
  echo "  Запускаю установку в tmux-сессии 'vpn'"
  echo "==========================================="
  echo "  Смотреть прогресс:   tmux attach -t vpn"
  echo "  Лог:                 tail -f ${INSTALL_LOG}"
  echo

  tmux kill-session -t vpn 2>/dev/null || true
  tmux new-session -d -s vpn \
    "export LANG=C.UTF-8 LC_ALL=C.UTF-8; bash '${SCRIPT_DEST}' --install --no-tmux; echo; echo '[Установка завершена. Нажми Enter или закрой окно]'; exec bash"

  touch "$INSTALL_LOG" 2>/dev/null || true

  # При `curl | bash` stdin — пайп, поэтому attach кормим терминалом /dev/tty.
  if { : < /dev/tty; } 2>/dev/null; then
    sleep 1
    exec tmux attach -t vpn < /dev/tty
  fi

  echo "Установка идёт в фоновой tmux-сессии 'vpn'."
  echo "Подключиться:   tmux attach -t vpn"
  echo "Смотреть лог:   tail -f ${INSTALL_LOG}"
  exit 0
}

# ==================== ПОДДЕРЖКА SSH ВО ВРЕМЯ УСТАНОВКИ ====================
ssh_keepalive() {
  sed -i 's/^#*ClientAliveInterval.*/ClientAliveInterval 60/' /etc/ssh/sshd_config 2>/dev/null || true
  sed -i 's/^#*ClientAliveCountMax.*/ClientAliveCountMax 5/'  /etc/ssh/sshd_config 2>/dev/null || true
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
}

# ==================== АВТОНАСТРОЙКА: ТЕСТ SNI ====================
# Реальный тест: доступность цели и время TLS-рукопожатия. Возвращает мс или пусто.
test_sni() {
  local sni="$1" t
  t=$(curl -o /dev/null -sS --tlsv1.3 --max-time 8 \
        -w '%{time_appconnect}' "https://${sni}/" 2>/dev/null) || return 1
  awk -v x="$t" 'BEGIN{ v=x*1000; if (v<=0) exit 1; printf "%d", v }'
}

# ==================== АВТОНАСТРОЙКА: ГЕНЕРАЦИЯ КЛЮЧЕЙ REALITY ====================
xray_bin_path() {
  find /usr/local/x-ui -maxdepth 2 -name 'xray*' -type f -executable 2>/dev/null | head -1
}
generate_reality_keys() {
  local xb keys
  xb=$(xray_bin_path)
  [ -z "$xb" ] && { printf '[keys] xray binary not found\n' >> "$INSTALL_LOG" 2>/dev/null; return 1; }
  keys=$("$xb" x25519 2>/dev/null || true)
  # Формат вывода xray x25519 менялся между версиями:
  #   старый:  "Private key: ..."  / "Public key: ..."
  #   новый:   "PrivateKey: ..."   / "Password: ..."  (Password = публичный ключ)
  PRIVATE_KEY=$(printf '%s\n' "$keys" | grep -i  'private'          | awk '{print $NF}' | head -1)
  PUBLIC_KEY=$( printf '%s\n' "$keys" | grep -iE 'public|password'  | awk '{print $NF}' | head -1)
  if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    printf '[keys] parse failed. x25519 output was:\n%s\n' "$keys" >> "$INSTALL_LOG" 2>/dev/null
    return 1
  fi
  return 0
}

# ==================== АВТОНАСТРОЙКА: ВХОД В ПАНЕЛЬ ====================
xui_login() {
  local port="$1" base="$2" user="$3" pass="$4"
  rm -f "$JAR"
  local base_url="http://127.0.0.1:${port}${base}"
  curl -sk -c "$JAR" -b "$JAR" -o /dev/null "$base_url" 2>/dev/null || true
  local csrf
  csrf=$(curl -sk -b "$JAR" -c "$JAR" "${base_url}csrf-token" 2>/dev/null | jq -r '.obj // empty' 2>/dev/null || true)
  local extra=()
  [ -n "$csrf" ] && extra+=(-H "X-CSRF-Token: $csrf")
  local resp
  resp=$(curl -sk -b "$JAR" -c "$JAR" "${extra[@]}" \
    --data-urlencode "username=${user}" \
    --data-urlencode "password=${pass}" \
    "${base_url}login" 2>/dev/null || true)
  echo "$resp" | grep -q '"success":true'
}

# ==================== АВТОНАСТРОЙКА: РАБОТА С ИНБАУНДАМИ ====================
cleanup_auto_inbounds() {
  local base_url list ids id
  base_url="http://127.0.0.1:${PANEL_PORT}${WEB_BASE_PATH}"
  list=$(curl -sk -b "$JAR" -c "$JAR" "${base_url}panel/api/inbounds/list" 2>/dev/null)
  ids=$(printf '%s' "$list" | jq -r '.obj[]? | select(.remark|test("^XVPN-")) | .id' 2>/dev/null)
  for id in $ids; do
    curl -sk -b "$JAR" -c "$JAR" -X POST "${base_url}panel/api/inbounds/del/${id}" >/dev/null 2>&1 || true
  done
}
delete_inbound_by_port() {
  local port="$1" base_url list id
  base_url="http://127.0.0.1:${PANEL_PORT}${WEB_BASE_PATH}"
  list=$(curl -sk -b "$JAR" -c "$JAR" "${base_url}panel/api/inbounds/list" 2>/dev/null)
  id=$(printf '%s' "$list" | jq -r --argjson p "$port" '.obj[]? | select(.port==$p) | .id' 2>/dev/null | head -1)
  [ -n "$id" ] && curl -sk -b "$JAR" -c "$JAR" -X POST "${base_url}panel/api/inbounds/del/${id}" >/dev/null 2>&1 || true
}
port_in_use() {
  ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
}
wait_for_port() {
  local port="$1" i=0
  while [ "$i" -lt 10 ]; do
    port_in_use "$port" && return 0
    sleep 1; i=$((i + 1))
  done
  return 1
}

# create_inbound <port> <sni> <fp> <proto> <remark>
# Печатает структурированный блок (LINK=... и т.д.) в stdout при успехе.
create_inbound() {
  local port="$1" sni="$2" fp="$3" proto="$4" remark="$5"
  local base_url="http://127.0.0.1:${PANEL_PORT}${WEB_BASE_PATH}"

  generate_reality_keys || return 1

  local uuid short_id protocol settings password
  uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)
  short_id=$(openssl rand -hex 4 2>/dev/null)

  if [ "$proto" = "trojan-reality" ]; then
    protocol="trojan"
    password=$(openssl rand -hex 16 2>/dev/null)
    settings=$(jq -n --arg pass "$password" '{
      clients: [{ password: $pass, email: "auto-trojan", limitIp: 0, totalGB: 0, expiryTime: 0, enable: true, tgId: 0, subId: "", reset: 0 }],
      fallbacks: []
    }')
  else
    protocol="vless"
    settings=$(jq -n --arg uuid "$uuid" --arg email "auto-${port}" --arg sub "$(openssl rand -hex 8)" '{
      clients: [{ id: $uuid, flow: "xtls-rprx-vision", email: $email, limitIp: 0, totalGB: 0, expiryTime: 0, enable: true, tgId: 0, subId: $sub, reset: 0 }],
      decryption: "none",
      fallbacks: []
    }')
  fi

  local stream
  stream=$(jq -n --arg dest "${sni}:443" --arg sni "$sni" --arg priv "$PRIVATE_KEY" \
                 --arg pub "$PUBLIC_KEY" --arg sid "$short_id" --arg fp "$fp" '{
    network: "tcp", security: "reality", externalProxy: [],
    realitySettings: {
      show: false, xver: 0, dest: $dest, serverNames: [$sni], privateKey: $priv,
      minClient: "", maxClient: "", maxTimediff: 0, shortIds: [$sid],
      settings: { publicKey: $pub, fingerprint: $fp, serverName: "", spiderX: "/" }
    },
    tcpSettings: { acceptProxyProtocol: false, header: { type: "none" } }
  }')

  local sniffing='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'
  local allocate='{"strategy":"always","refresh":5,"concurrency":3}'
  local payload
  payload=$(jq -n --argjson port "$port" --arg remark "$remark" \
                  --argjson settings "$settings" --argjson stream "$stream" \
                  --argjson sniffing "$sniffing" --argjson allocate "$allocate" \
                  --arg protocol "$protocol" '{
    up:0, down:0, total:0, remark:$remark, enable:true, expiryTime:0, listen:"",
    port:$port, protocol:$protocol, settings:($settings|tojson),
    streamSettings:($stream|tojson), sniffing:($sniffing|tojson), allocate:($allocate|tojson)
  }')

  local csrf extra=()
  csrf=$(curl -sk -b "$JAR" -c "$JAR" "${base_url}csrf-token" 2>/dev/null | jq -r '.obj // empty' 2>/dev/null || true)
  [ -n "$csrf" ] && extra+=(-H "X-CSRF-Token: $csrf")

  local resp
  resp=$(curl -sk -b "$JAR" -c "$JAR" "${extra[@]}" \
    -H "Content-Type: application/json" \
    --data-raw "$payload" \
    "${base_url}panel/api/inbounds/add" 2>/dev/null || true)

  if ! echo "$resp" | grep -q '"success":true'; then
    printf '[create_inbound] add failed (port=%s proto=%s fp=%s): %s\n' \
      "$port" "$proto" "$fp" "$resp" >> "$INSTALL_LOG" 2>/dev/null
    return 1
  fi

  local ip link client_id_or_pass
  ip=$(server_ip)
  if [ "$protocol" = "trojan" ]; then
    client_id_or_pass="$password"
    link="trojan://${password}@${ip}:${port}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=${fp}&sni=${sni}&sid=${short_id}&spx=%2F#${remark}"
  else
    client_id_or_pass="$uuid"
    link="vless://${uuid}@${ip}:${port}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=${fp}&sni=${sni}&sid=${short_id}&spx=%2F&flow=xtls-rprx-vision#${remark}"
  fi

  # Одинарные кавычки — чтобы eval у вызывающего не сломался на &, ?, # в ссылке
  cat <<EODATA
LINK='${link}'
PORT='${port}'
SNI='${sni}'
FP='${fp}'
PROTO='${proto}'
CLIENT_ID='${client_id_or_pass}'
SHORT_ID='${short_id}'
PUBLIC_KEY='${PUBLIC_KEY}'
EODATA
  return 0
}

# ==================== АВТОНАСТРОЙКА: ПРОВЕРКА СВЯЗКИ ====================
# Поднимает временный xray-клиент к 127.0.0.1:port с точными параметрами и
# пробует реальный запрос через SOCKS. Проверяет рукопожатие Reality + проксирование.
# РКН-блокировки со стороны сервера проверить невозможно (сервер не видит DPI).
verify_bundle() {
  local port="$1" sni="$2" fp="$3" proto="$4" client_id="$5" short_id="$6" pubkey="$7"
  local xb socks=10808
  local cfg="/tmp/xray-vpn-test-${port}.json" tlog="/tmp/xray-vpn-test-${port}.log"
  xb=$(xray_bin_path)
  [ -z "$xb" ] && { warn "xray не найден для проверки"; return 1; }

  local out_proto out_settings
  if [ "$proto" = "trojan-reality" ] || [ "$proto" = "trojan" ]; then
    out_proto="trojan"
    out_settings=$(jq -n --arg pass "$client_id" --argjson port "$port" \
      '{ servers: [{ address:"127.0.0.1", port:$port, password:$pass }] }')
  else
    out_proto="vless"
    out_settings=$(jq -n --arg id "$client_id" --argjson port "$port" \
      '{ vnext: [{ address:"127.0.0.1", port:$port, users:[{ id:$id, encryption:"none", flow:"xtls-rprx-vision" }] }] }')
  fi

  local stream
  stream=$(jq -n --arg sni "$sni" --arg pbk "$pubkey" --arg sid "$short_id" --arg fp "$fp" \
    '{ network:"tcp", security:"reality",
       realitySettings:{ fingerprint:$fp, serverName:$sni, publicKey:$pbk, shortId:$sid, spiderX:"/" } }')

  jq -n --argjson socks "$socks" --argjson out "$out_settings" --argjson stream "$stream" --arg op "$out_proto" '{
    log: { loglevel: "warning" },
    inbounds: [{ port:$socks, listen:"127.0.0.1", protocol:"socks", settings:{ auth:"noauth", udp:true } }],
    outbounds: [{ protocol:$op, settings:$out, streamSettings:$stream }]
  }' > "$cfg" 2>/dev/null || return 1

  pkill -f "xray-vpn-test-${port}" 2>/dev/null || true
  nohup "$xb" run -c "$cfg" > "$tlog" 2>&1 &
  local pid=$!

  # Ждём, пока тест-клиент поднимет локальный SOCKS-порт (до ~8с на слабых VPS)
  local i=0
  while [ "$i" -lt 8 ]; do
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${socks}\$" && break
    sleep 1; i=$((i + 1))
  done

  # Несколько попыток реального запроса через прокси (защита от ложного «не работает»)
  local rc=1 try=0
  while [ "$try" -lt 3 ]; do
    try=$((try + 1))
    if curl -s -x "socks5h://127.0.0.1:${socks}" --max-time 10 -I "https://www.google.com" 2>/dev/null | head -1 | grep -qE "20[0-9]|30[0-9]"; then
      rc=0; break
    fi
    if curl -s -x "socks5h://127.0.0.1:${socks}" --max-time 8 -I "https://1.1.1.1" 2>/dev/null | head -1 | grep -qE "20[0-9]|30[0-9]"; then
      rc=0; break
    fi
    sleep 2
  done

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$cfg" "$tlog"
  return $rc
}

remark_for() {
  # XVPN-<PROTO>-<PORT>-<FP> в верхнем регистре, без недопустимых символов
  printf 'XVPN-%s-%s-%s' "$1" "$2" "$3" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9-' '-'
}

# ==================== АВТОНАСТРОЙКА (главная) ====================
auto_setup() {
  get_panel_settings
  if [ ! -x /usr/local/x-ui/x-ui ]; then
    err "3x-ui не установлен. Сначала выполни установку: curl -fsSL ${SCRIPT_URL} | bash"
    return 1
  fi

  echo
  log "=== АВТОНАСТРОЙКА СВЯЗОК ==="
  log "Что реально проверяется со стороны сервера:"
  log "  • доступность и скорость SNI-цели (TLS 1.3)"
  log "  • рукопожатие Reality и проксирование трафика"
  log "РКН-блокировки с сервера проверить нельзя — поэтому создаём несколько"
  log "готовых связок с разными отпечатками. В клиенте попробуй их по очереди:"
  log "рабочей будет та, что подключается у твоего провайдера."
  echo

  if [ -z "$PANEL_USER" ] || [ -z "$PANEL_PASS" ]; then
    warn "Логин/пароль панели неизвестны."
    read -rp "  Логин панели [admin]: " PANEL_USER; PANEL_USER="${PANEL_USER:-admin}"
    read -rsp "  Пароль панели: " PANEL_PASS; echo
  fi

  if ! xui_login "$PANEL_PORT" "$WEB_BASE_PATH" "$PANEL_USER" "$PANEL_PASS"; then
    err "Не удалось войти в панель. Проверь данные (vpn info) или сбрось пароль (пункт меню)."
    return 1
  fi
  ok "Вход в панель выполнен"

  # 1) Тестируем SNI-цели
  log ""
  log "Тестирую SNI-цели (доступность и задержка):"
  local snis=("www.microsoft.com" "www.apple.com" "www.samsung.com" "dl.google.com" "www.nvidia.com")
  local best_sni="" best_t=100000 sni tms
  printf '  %-22s %s\n' "SNI" "TLS-рукопожатие"
  for sni in "${snis[@]}"; do
    tms=$(test_sni "$sni")
    if [ -n "$tms" ]; then
      printf '  %-22s %s мс\n' "$sni" "$tms"
      if [ "$tms" -lt "$best_t" ]; then best_t="$tms"; best_sni="$sni"; fi
    else
      printf '  %-22s недоступен\n' "$sni"
    fi
  done
  [ -z "$best_sni" ] && best_sni="www.microsoft.com"
  ok "Лучший SNI: ${best_sni} (${best_t} мс)"

  # 2) Чистим прошлые авто-связки и ссылки
  cleanup_auto_inbounds
  : > "$LINKS_FILE"

  # 3) Создаём и проверяем набор связок. Формат: proto|port|fp|описание
  log ""
  log "Создаю и проверяю связки (нерабочие удаляются автоматически):"
  local combos=(
    "vless-reality|443|firefox|Основная (VLESS+Reality, Firefox)"
    "vless-reality|8443|chrome|Запасная (VLESS+Reality, Chrome)"
    "trojan-reality|2083|safari|Альтернатива (Trojan+Reality, Safari)"
  )
  local created=0 entry proto port fp note out
  local LINK PORT SNI FP PROTO CLIENT_ID SHORT_ID
  for entry in "${combos[@]}"; do
    IFS='|' read -r proto port fp note <<< "$entry"

    if [ "$port" = "$PANEL_PORT" ]; then
      warn "Порт ${port} занят панелью — пропускаю (${note})"
      continue
    fi
    if port_in_use "$port"; then
      warn "Порт ${port} уже занят — пропускаю (${note})"
      continue
    fi

    ufw allow "${port}/tcp" comment 'xray reality' >>"$INSTALL_LOG" 2>&1 || true
    log "  Пробую: ${note} | порт ${port} | SNI=${best_sni} ..."

    out=$(create_inbound "$port" "$best_sni" "$fp" "$proto" "$(remark_for "$proto" "$port" "$fp")" 2>/dev/null || true)
    if ! printf '%s' "$out" | grep -q '^LINK='; then
      warn "    Не удалось создать инбаунд (${note})"
      continue
    fi

    # безопасный разбор (значения в одинарных кавычках)
    eval "$(printf '%s\n' "$out" | grep -E "^(LINK|PORT|SNI|FP|PROTO|CLIENT_ID|SHORT_ID|PUBLIC_KEY)=")"

    if ! wait_for_port "$PORT"; then
      warn "    Порт ${PORT} не поднялся — удаляю (${note})"
      delete_inbound_by_port "$port"
      continue
    fi

    if verify_bundle "$PORT" "$SNI" "$FP" "$PROTO" "$CLIENT_ID" "$SHORT_ID" "$PUBLIC_KEY"; then
      ok "    РАБОТАЕТ: ${note}"
      add_link "# ${note} | порт ${PORT} | отпечаток ${FP} | SNI ${SNI}"
      add_link "$LINK"
      add_link ""
      created=$((created + 1))
    else
      warn "    Проверка не прошла — удаляю (${note})"
      delete_inbound_by_port "$port"
    fi
  done

  save_info_file
  echo
  if [ "$created" -gt 0 ]; then
    ok "Готово. Рабочих связок создано: ${created}"
    log "Ссылки сохранены в ${INFO_FILE}"
    log "Совет: начни с Firefox-ссылки. Если у провайдера не идёт — пробуй Chrome/Trojan."
    show_links
  else
    err "Не удалось создать ни одной рабочей связки. Смотри лог: ${INSTALL_LOG}"
    warn "Можно создать инбаунд вручную в панели: http://$(server_ip):${PANEL_PORT}${WEB_BASE_PATH}"
  fi
}

# ==================== CDN-ПОДКЛЮЧЕНИЕ (XHTTP через CDN) ====================
# Второй способ доставки: клиент -> CDN (росс. IP) -> origin (этот VPS) -> интернет.
# Прячет IP сервера за CDN, обходит блокировки по IP, транспорт XHTTP (быстрый).
# Основано на obletcdn (Apache-2.0, (c) Gleb Bakulev), с изменениями.

write_cdn_nginx() {
  # map OPTIONS -> POST (клиент шлёт OPTIONS для Yandex CDN, xray ждёт POST-uplink)
  cat > "$CDN_NGINX_MAP" << 'NGXMAP'
map $request_method $xhttp_proxy_method {
    default  $request_method;
    OPTIONS  POST;
}
NGXMAP

  # сайт origin: HTTP:80, проксирует XHTTP-путь в локальный xray, отдаёт заглушку на /
  cat > "$CDN_NGINX_SITE" << NGXSITE
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    client_max_body_size 0;
    client_header_buffer_size 64k;
    large_client_header_buffers 8 128k;

    location = /cdn-check {
        add_header X-CDN-Origin "ok" always;
        add_header X-Origin-Method \$request_method always;
        return 204;
    }

    location ${CDN_XHTTP_PATH} {
        proxy_pass http://127.0.0.1:${CDN_XRAY_PORT};
        proxy_method \$xhttp_proxy_method;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_pass_request_headers on;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location / {
        default_type text/html;
        return 200 "<!doctype html><title>Welcome</title><h1>Welcome</h1><p>Service is operating normally.</p>";
    }
}
NGXSITE

  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  ln -sfn "$CDN_NGINX_SITE" /etc/nginx/sites-enabled/xray-vpn-cdn.conf
}

write_cdn_users() {
  mkdir -p "$CDN_DIR"
  cat > "$CDN_USERS" << 'PYEOF'
#!/usr/bin/env python3
# Manage per-user Xray routing for the CDN XHTTP module.
# Based on obletcdn users.py (Apache-2.0, (c) Gleb Bakulev), modified (paths/service).
import argparse
import json
import os
import shutil
import subprocess
import sys
import urllib.parse
import uuid
from pathlib import Path

CONFIG_PATH = Path("/opt/xray-vpn-cdn/config.json")
XRAY_BIN = "/opt/xray-vpn-cdn/xray"
SERVICE = "xray-vpn-cdn-xray.service"
HAPP_XHTTP_EXTRA = {
    "mode": "packet-up", "path": "/api-test",
    "uplinkHTTPMethod": "OPTIONS",
    "scMaxEachPostBytes": 1000000, "scMinPostsIntervalMs": 30, "scMaxBufferedPosts": 30,
    "xPaddingObfsMode": True, "xPaddingKey": "dc", "xPaddingHeader": "X-Cache",
    "xPaddingMethod": "tokenish", "xPaddingPlacement": "queryInHeader",
}


def fail(message):
    print(f"Error: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_config():
    try:
        return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"{CONFIG_PATH} not found; configure CDN first (vpn cdn)")
    except json.JSONDecodeError as error:
        fail(f"invalid Xray config: {error}")


def clients(config):
    try:
        return config["inbounds"][0]["settings"]["clients"]
    except (IndexError, KeyError, TypeError):
        fail("unsupported config: no VLESS inbound clients found")


def apply(config):
    candidate = CONFIG_PATH.with_name("config.users-candidate.json")
    candidate.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    checked = subprocess.run([XRAY_BIN, "run", "-test", "-config", str(candidate)], capture_output=True, text=True)
    if checked.returncode:
        candidate.unlink(missing_ok=True)
        fail(f"Xray rejected the configuration:\n{checked.stderr.strip()}")
    shutil.copy2(CONFIG_PATH, str(CONFIG_PATH) + ".bak")
    candidate.replace(CONFIG_PATH)
    subprocess.run(["systemctl", "restart", SERVICE], check=True)


def print_details(name, user_id, host, port, security):
    sni = f"&sni={host}" if security == "tls" else ""
    extra = dict(HAPP_XHTTP_EXTRA)
    extra["host"] = host
    extra_q = "&extra=" + urllib.parse.quote(json.dumps(extra, separators=(",", ":")), safe="")
    link = (f"vless://{user_id}@{host}:{port}?encryption=none&type=xhttp&security={security}{sni}"
            f"&host={host}&path=%2Fapi-test&mode=packet-up{extra_q}#CDN-XHTTP-{name}")
    print(f"Created user `{name}`.")
    print(f"VLESS: {link}")
    print("Happ -> xHTTP -> extra -> Raw JSON:")
    print(json.dumps(HAPP_XHTTP_EXTRA, indent=2))


def add(args):
    config = load_config()
    email = f"user:{args.name}"
    if any(c.get("email") == email for c in clients(config)):
        fail(f"user `{args.name}` already exists")
    try:
        user_id = str(uuid.UUID(args.uuid)) if args.uuid else str(uuid.uuid4())
    except ValueError:
        fail("--uuid must be a UUID")
    if any(c.get("id") == user_id for c in clients(config)):
        fail("this UUID is already in use")
    clients(config).append({"id": user_id, "email": email})
    apply(config)
    print_details(args.name, user_id, args.cdn_host, args.port, args.security)


def list_users(_):
    config = load_config()
    print(f"{'NAME':<24} {'UUID':<36}")
    for c in clients(config):
        email = c.get("email", "")
        if email.startswith("user:"):
            print(f"{email[5:]:<24} {c['id']:<36}")


def remove(args):
    config = load_config()
    email = f"user:{args.name}"
    inbound = config["inbounds"][0]["settings"]
    before = len(inbound["clients"])
    inbound["clients"] = [c for c in inbound["clients"] if c.get("email") != email]
    if len(inbound["clients"]) == before:
        fail(f"user `{args.name}` was not found")
    apply(config)
    print(f"Removed `{args.name}`. Backup: {CONFIG_PATH}.bak")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cdn-host", required=True)
    parser.add_argument("--port", type=int, default=80)
    parser.add_argument("--security", default="none", choices=("none", "tls"))
    commands = parser.add_subparsers(dest="command", required=True)
    add_cmd = commands.add_parser("add")
    add_cmd.add_argument("name")
    add_cmd.add_argument("--uuid")
    add_cmd.set_defaults(func=add)
    list_cmd = commands.add_parser("list")
    list_cmd.set_defaults(func=list_users)
    remove_cmd = commands.add_parser("remove")
    remove_cmd.add_argument("name")
    remove_cmd.set_defaults(func=remove)
    args = parser.parse_args()
    if os.geteuid() != 0:
        fail("run as root")
    if not 1 <= args.port <= 65535:
        fail("--port must be between 1 and 65535")
    args.func(args)


if __name__ == "__main__":
    main()
PYEOF
  chmod 755 "$CDN_USERS"
}

cdn_extra_json() {
  # XHTTP extra — ОДИНАКОВЫЙ на сервере (инбаунд) и в клиентской ссылке, иначе не состыкуется.
  # Значения по образцу рабочего сервиса (xmux + padding + сессии в cookie + uplink GET).
  printf '%s' '{"xmux":{"cMaxLifetimeMs":0,"cMaxReuseTimes":"36-96","maxConcurrency":"8-32","maxConnections":0,"hMaxRequestTimes":"320-640","hMaxReusableSecs":"720-1800"},"seqKey":"part_index","sessionKey":"stream_auth","xPaddingKey":"_t","seqPlacement":"cookie","sessionIDKey":"viewer_session","xPaddingBytes":"96-1040","xPaddingHeader":"X-Media-Token","xPaddingMethod":"tokenish","uplinkChunkSize":0,"sessionPlacement":"cookie","uplinkHTTPMethod":"GET","xPaddingObfsMode":true,"xPaddingPlacement":"queryInHeader","scMaxEachPostBytes":976846,"sessionIDPlacement":"cookie","uplinkDataPlacement":"body","scMinPostsIntervalMs":70}'
}

cdn_pick_port() {
  # порт origin-инбаунда: 443 если свободен, иначе 1443 (443 обычно занят Reality)
  if ! port_in_use 443; then echo 443
  elif ! port_in_use 1443; then echo 1443
  elif ! port_in_use 8443; then echo 8443
  else echo 1443; fi
}

cdn_gen_path() {
  echo "/api/v1/$(openssl rand -hex 4 2>/dev/null || echo bs3657)/sync/"
}

cdn_link() {
  # клиент идёт на CDN (externalProxy): host:443, tls, chrome; xhttp extra зашит в ссылку
  local uuid="$1" host="$2" path="$3"
  local epath extra_enc
  epath=$(printf '%s' "$path" | jq -Rr @uri 2>/dev/null || printf '%s' "$path")
  extra_enc=$(cdn_extra_json | jq -Rr @uri 2>/dev/null || true)
  printf 'vless://%s@%s:443?encryption=none&type=xhttp&security=tls&sni=%s&fp=chrome&alpn=h2%%2Chttp%%2F1.1&path=%s&mode=packet-up&extra=%s#CDN-XHTTP' \
    "$uuid" "$host" "$host" "$epath" "$extra_enc"
}

# создать в 3x-ui инбаунд VLESS + XHTTP(security none) + externalProxy на CDN
create_cdn_inbound() {
  local uuid="$1" port="$2" path="$3" cdn_host="$4"
  local base_url="http://127.0.0.1:${PANEL_PORT}${WEB_BASE_PATH}"
  local subid settings stream sniffing payload csrf resp
  local hdr=()
  subid=$(openssl rand -hex 8 2>/dev/null)

  settings=$(jq -n --arg uuid "$uuid" --arg sub "$subid" '{
    clients:[{ id:$uuid, email:"cdn-default", flow:"", limitIp:0, totalGB:0, expiryTime:0, enable:true, tgId:0, subId:$sub, comment:"", reset:0 }],
    decryption:"none"
  }')
  stream=$(jq -n --arg path "$path" --arg host "$cdn_host" --argjson extra "$(cdn_extra_json)" '{
    network:"xhttp", security:"none",
    xhttpSettings:{ path:$path, host:"", mode:"packet-up", noSSEHeader:false, extra:$extra },
    externalProxy:[{ forceTls:"tls", dest:$host, port:443, remark:"CDN", sni:$host, fingerprint:"chrome", alpn:["h2","http/1.1"] }]
  }')
  sniffing='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'
  payload=$(jq -n --argjson port "$port" --argjson settings "$settings" --argjson stream "$stream" --argjson sniffing "$sniffing" '{
    up:0, down:0, total:0, remark:"XVPN-CDN", enable:true, expiryTime:0, listen:"",
    port:$port, protocol:"vless",
    settings:($settings|tojson), streamSettings:($stream|tojson), sniffing:($sniffing|tojson)
  }')

  csrf=$(curl -sk -b "$JAR" -c "$JAR" "${base_url}csrf-token" 2>/dev/null | jq -r '.obj // empty' 2>/dev/null || true)
  [ -n "$csrf" ] && hdr+=(-H "X-CSRF-Token: $csrf")
  resp=$(curl -sk -b "$JAR" -c "$JAR" "${hdr[@]}" -H "Content-Type: application/json" \
    --data-raw "$payload" "${base_url}panel/api/inbounds/add" 2>/dev/null || true)
  if ! echo "$resp" | grep -q '"success":true'; then
    printf '[create_cdn_inbound] add failed (port=%s): %s\n' "$port" "$resp" >> "$INSTALL_LOG" 2>/dev/null
    return 1
  fi
  return 0
}

cdn_delete_inbound() {
  # удалить инбаунд(ы) с remark == XVPN-CDN (перед пересозданием / при удалении)
  local base_url="http://127.0.0.1:${PANEL_PORT}${WEB_BASE_PATH}" list ids id
  list=$(curl -sk -b "$JAR" -c "$JAR" "${base_url}panel/api/inbounds/list" 2>/dev/null)
  ids=$(printf '%s' "$list" | jq -r '.obj[]? | select(.remark=="XVPN-CDN") | .id' 2>/dev/null)
  for id in $ids; do
    curl -sk -b "$JAR" -c "$JAR" -X POST "${base_url}panel/api/inbounds/del/${id}" >/dev/null 2>&1 || true
  done
}

cdn_installed() {
  [ -f "$CDN_ENV" ]
}

cdn_prepare_xray_bin() {
  mkdir -p "$CDN_DIR"
  local xb; xb=$(xray_bin_path)
  if [ -n "$xb" ] && [ -x "$xb" ]; then
    cp -f "$xb" "$CDN_XRAY_BIN" 2>/dev/null || true
  fi
  if [ ! -x "$CDN_XRAY_BIN" ]; then
    log "  Скачиваю xray-core для CDN..."
    local arch=64
    case "$(dpkg --print-architecture 2>/dev/null)" in
      arm64) arch="arm64-v8a" ;;
    esac
    curl -fsSL --retry 3 -o /tmp/xray-cdn.zip \
      "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip" 2>>"$INSTALL_LOG" || true
    command -v unzip >/dev/null 2>&1 || apt-get install -y unzip >>"$INSTALL_LOG" 2>&1 || true
    unzip -qo /tmp/xray-cdn.zip -d /tmp/xray-cdn 2>>"$INSTALL_LOG" || true
    install -Dm755 /tmp/xray-cdn/xray "$CDN_XRAY_BIN" 2>>"$INSTALL_LOG" || true
    rm -rf /tmp/xray-cdn /tmp/xray-cdn.zip
  fi
  [ -x "$CDN_XRAY_BIN" ]
}

cdn_write_config() {
  local uuid="$1"
  mkdir -p "$CDN_DIR"
  cat > "$CDN_CONFIG" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "tag": "xhttp-in",
    "listen": "127.0.0.1",
    "port": ${CDN_XRAY_PORT},
    "protocol": "vless",
    "settings": {
      "decryption": "none",
      "clients": [{ "id": "${uuid}", "email": "user:default" }]
    },
    "streamSettings": {
      "network": "xhttp",
      "xhttpSettings": {
        "mode": "packet-up",
        "path": "${CDN_XHTTP_PATH}",
        "xPaddingObfsMode": true,
        "xPaddingKey": "${CDN_PADDING_KEY}",
        "xPaddingHeader": "X-Cache",
        "xPaddingMethod": "tokenish",
        "xPaddingPlacement": "queryInHeader"
      }
    }
  }],
  "outbounds": [{ "tag": "direct", "protocol": "freedom" }]
}
EOF
  chmod 600 "$CDN_CONFIG"
}

cdn_systemd() {
  cat > /etc/systemd/system/xray-vpn-cdn-xray.service << EOF
[Unit]
Description=xray-vpn CDN XHTTP backend
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${CDN_XRAY_BIN} run -config ${CDN_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable xray-vpn-cdn-xray.service >>"$INSTALL_LOG" 2>&1 || true
  systemctl restart xray-vpn-cdn-xray.service >>"$INSTALL_LOG" 2>&1 || true
}

cdn_save_env() {
  mkdir -p "$STATE_DIR"
  cat > "$CDN_ENV" << EOF
CDN_HOST="${1}"
CDN_ORIGIN_PORT="${2}"
CDN_PATH="${3}"
CDN_PROVIDER="${4}"
CDN_UUID="${5}"
EOF
  chmod 600 "$CDN_ENV"
}

cdn_provider_guide() {
  local provider="$1" ip="$2" host="$3" port="$4"
  echo
  cecho "${GREEN}=== Настрой CDN (${provider}) — один раз, в панели ===${NC}"
  echo "  Источник (origin):   ${ip}:${port}, ПРОТОКОЛ ИСТОЧНИКА = HTTP (не HTTPS!)"
  echo "  Основной домен:      ${host}  (сертификат Let's Encrypt / Certificate Manager на него)"
  echo "  Разрешённые методы:  GET, HEAD  (метод uplink = GET)"
  echo "  Кэш / сжатие:        отключить"
  case "$provider" in
    "Yandex Cloud CDN")
      echo "  DNS клиента: CNAME ${host} -> <id>.topology.gslb.yccdn.ru (из «Настройки DNS» ресурса)."
      echo "  КЛЮЧЕВОЕ: «Протокол для запросов к источнику» = HTTP, адрес источника = ${ip}:${port}."
      ;;
    *)
      echo "  DNS клиента: CNAME ${host} -> edge-домен провайдера."
      ;;
  esac
  echo "  Затем проверь:  vpn cdn-check"
  warn "Источник должен вести на ${ip}:${port} по HTTP — там слушает xray XHTTP (инбаунд XVPN-CDN)."
}

cdn_setup() {
  check_root
  get_panel_settings
  if [ ! -x /usr/local/x-ui/x-ui ]; then
    err "3x-ui не установлен. Сначала базовая установка: curl -fsSL ${SCRIPT_URL} | bash"
    return 1
  fi
  echo
  log "=== CDN-НОДА (VLESS + XHTTP через CDN) ==="
  log "Создаю в 3x-ui инбаунд с externalProxy на твой CDN. Один сервер, без Nginx."
  log "Клиент -> CDN (HTTPS:443) -> этот сервер (xray XHTTP) -> интернет."
  echo

  echo "  Какой у тебя CDN?"
  echo "    1) Yandex Cloud CDN"
  echo "    2) VK Cloud CDN"
  echo "    3) Gcore"
  echo "    4) Selectel"
  echo "    5) Другой"
  read -rp "  Выбор [1-5]: " pc
  local provider
  case "$pc" in
    1) provider="Yandex Cloud CDN" ;;
    2) provider="VK Cloud CDN" ;;
    3) provider="Gcore" ;;
    4) provider="Selectel" ;;
    *) provider="Custom" ;;
  esac

  local host
  read -rp "  CDN-домен для клиентов (например cdn.mydomain.xyz): " host
  host=$(printf '%s' "$host" | tr -d ' ')
  [ -z "$host" ] && { err "Домен не указан"; return 1; }

  # вход в панель (нужен для создания инбаунда через API)
  if [ -z "$PANEL_USER" ] || [ -z "$PANEL_PASS" ]; then
    warn "Логин/пароль панели неизвестны."
    read -rp "  Логин панели [admin]: " PANEL_USER; PANEL_USER="${PANEL_USER:-admin}"
    read -rsp "  Пароль панели: " PANEL_PASS; echo
  fi
  if ! xui_login "$PANEL_PORT" "$WEB_BASE_PATH" "$PANEL_USER" "$PANEL_PASS"; then
    err "Не удалось войти в панель. Проверь данные (vpn info) или сбрось пароль."
    return 1
  fi
  ok "Вход в панель выполнен"

  # миграция: снести старый Nginx/xray-модуль прежних версий, если остался
  systemctl disable --now xray-vpn-cdn-xray.service xray-vpn-cdn-bridge.service >>"$INSTALL_LOG" 2>&1 || true
  rm -f /etc/systemd/system/xray-vpn-cdn-*.service /etc/nginx/sites-enabled/xray-vpn-cdn.conf "$CDN_NGINX_SITE" "$CDN_NGINX_MAP" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  command -v nginx >/dev/null 2>&1 && { nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1; } || true

  local port uuid path
  port=$(cdn_pick_port)
  if [ -f "$CDN_ENV" ]; then . "$CDN_ENV"; fi
  uuid="${CDN_UUID:-}"; [ -z "$uuid" ] && uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
  path="${CDN_PATH:-$(cdn_gen_path)}"

  cdn_delete_inbound   # убрать прежний XVPN-CDN, чтобы не дублировать
  log "Создаю инбаунд XVPN-CDN: порт ${port}, путь ${path}, externalProxy -> ${host}:443 ..."
  if ! create_cdn_inbound "$uuid" "$port" "$path" "$host"; then
    err "Не удалось создать инбаунд. Лог: grep create_cdn_inbound ${INSTALL_LOG}"
    return 1
  fi
  ok "Инбаунд создан (порт ${port}, XHTTP/none, externalProxy на CDN)"
  ufw allow "${port}/tcp" comment 'CDN origin' >>"$INSTALL_LOG" 2>&1 || true

  local ip link
  ip=$(server_ip)
  link=$(cdn_link "$uuid" "$host" "$path")
  if [ -f "$LINKS_FILE" ]; then
    grep -vE 'CDN-XHTTP|^# CDN ' "$LINKS_FILE" > "${LINKS_FILE}.tmp" 2>/dev/null || true
    mv "${LINKS_FILE}.tmp" "$LINKS_FILE" 2>/dev/null || true
  fi
  add_link "# CDN (${provider}) | клиент ${host}:443 | origin ${ip}:${port} (HTTP) | путь ${path}"
  add_link "$link"
  add_link ""
  cdn_save_env "$host" "$port" "$path" "$provider" "$uuid"
  save_info_file

  cdn_provider_guide "$provider" "$ip" "$host" "$port"

  echo
  cecho "${GREEN}Ссылка для клиента (заработает после настройки CDN):${NC}"
  echo "  $link"
  echo
  ok "Пользователи этой ноды — в панели 3x-ui, инбаунд «XVPN-CDN» (там добавляй/удаляй клиентов)."
}

cdn_check() {
  check_root
  [ -f "$CDN_ENV" ] || { err "CDN ещё не настроен. Запусти: vpn cdn"; return 1; }
  . "$CDN_ENV"
  local ip resolved code
  ip=$(server_ip)
  echo
  cecho "${GREEN}=== Проверка CDN (${CDN_PROVIDER:-?}) ===${NC}"
  echo "  CDN-домен: ${CDN_HOST}"
  echo "  Origin:    ${ip}:${CDN_ORIGIN_PORT} (инбаунд 3x-ui XVPN-CDN, XHTTP)"
  echo "  Путь:      ${CDN_PATH}"
  if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${CDN_ORIGIN_PORT}\$"; then
    ok "порт ${CDN_ORIGIN_PORT} слушается (xray)"
  else
    err "порт ${CDN_ORIGIN_PORT} не слушается — проверь инбаунд XVPN-CDN в панели (vpn info)"
  fi

  resolved=$(getent hosts "$CDN_HOST" 2>/dev/null | awk '{print $1}' | head -1)
  echo "  ${CDN_HOST} резолвится в: ${resolved:-<нет записи>}"
  if [ -n "$resolved" ] && [ "$resolved" = "$ip" ]; then
    warn "домен ведёт ПРЯМО на VPS — это не через CDN. Домен должен вести на edge CDN."
  fi

  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 12 "https://${CDN_HOST}${CDN_PATH}" 2>/dev/null || echo 000)
  case "$code" in
    502|504) warn "через домен: HTTP ${code} — CDN не достучался до origin. Проверь: протокол источника=HTTP, адрес источника=${ip}:${CDN_ORIGIN_PORT}, порт открыт в ufw." ;;
    000)     warn "через домен: нет ответа — DNS/сертификат/CDN ещё не готовы (проверь CNAME и статус ресурса)." ;;
    *)       ok "через домен: HTTP ${code} — CDN достучался до origin. Финальный тест — подключись клиентом по ссылке." ;;
  esac
}

cdn_add() {
  [ -f "$CDN_ENV" ] || { err "CDN не настроен. Запусти: vpn cdn"; return 1; }
  . "$CDN_ENV"
  local ip; ip=$(server_ip)
  log "Пользователи CDN-ноды — в панели 3x-ui, инбаунд «XVPN-CDN»."
  log "Открой: http://${ip}:${PANEL_PORT}${WEB_BASE_PATH} -> инбаунд XVPN-CDN -> добавь клиента."
  log "Ссылка нового клиента сгенерится в панели (уже через CDN, externalProxy)."
}

cdn_list() {
  [ -f "$CDN_ENV" ] || { err "CDN не настроен. Запусти: vpn cdn"; return 1; }
  . "$CDN_ENV"
  show_links
  log "Полный список клиентов CDN-ноды — в панели, инбаунд «XVPN-CDN»."
}

cdn_remove() {
  [ -f "$CDN_ENV" ] || { err "CDN не настроен. Запусти: vpn cdn"; return 1; }
  . "$CDN_ENV"
  log "Удаляй клиентов CDN-ноды в панели 3x-ui (инбаунд «XVPN-CDN»)."
}

cdn_uninstall() {
  log "Удаляю CDN-ноду..."
  get_panel_settings
  if xui_login "$PANEL_PORT" "$WEB_BASE_PATH" "${PANEL_USER:-admin}" "${PANEL_PASS:-}" 2>/dev/null; then
    cdn_delete_inbound
    ok "Инбаунд XVPN-CDN удалён"
  else
    warn "Не вошёл в панель — удали инбаунд XVPN-CDN вручную в 3x-ui."
  fi
  # снести старый Nginx/xray-модуль прежних версий (если остался)
  systemctl disable --now xray-vpn-cdn-xray.service xray-vpn-cdn-bridge.service >>"$INSTALL_LOG" 2>&1 || true
  rm -f /etc/systemd/system/xray-vpn-cdn-*.service /etc/nginx/sites-enabled/xray-vpn-cdn.conf "$CDN_NGINX_SITE" "$CDN_NGINX_MAP"
  systemctl daemon-reload 2>/dev/null || true
  command -v nginx >/dev/null 2>&1 && { nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1; } || true
  if [ -f "$CDN_ENV" ]; then . "$CDN_ENV"; ufw delete allow "${CDN_ORIGIN_PORT:-1443}/tcp" >>"$INSTALL_LOG" 2>&1 || true; fi
  rm -rf "$CDN_DIR"
  rm -f "$CDN_ENV"
}

cdn_menu() {
  while true; do
    echo
    cecho "${YELLOW}=== CDN-ПОДКЛЮЧЕНИЕ (XHTTP через CDN) ===${NC}"
    if cdn_installed; then echo "  Статус: настроен"; else echo "  Статус: не настроен"; fi
    echo "  1) Настроить / переустановить CDN origin"
    echo "  2) Добавить пользователя"
    echo "  3) Список пользователей"
    echo "  4) Удалить пользователя"
    echo "  5) Проверить CDN"
    echo "  6) Удалить CDN-модуль"
    echo "  0) Назад"
    read -rp "  Выбор: " c
    case "$c" in
      1) cdn_setup ;;
      2) cdn_add ;;
      3) cdn_list ;;
      4) cdn_remove ;;
      5) cdn_check ;;
      6) cdn_uninstall && ok "CDN-модуль удалён" ;;
      0) return ;;
      *) warn "Неверный выбор" ;;
    esac
  done
}

# ==================== МЕНЮ / УПРАВЛЕНИЕ ====================
show_links() {
  if [ ! -s "$LINKS_FILE" ]; then
    warn "Ссылок пока нет. Запусти автонастройку (пункт 1)."
    return
  fi
  echo
  cecho "${GREEN}=== Готовые ссылки ===${NC}"
  cat "$LINKS_FILE"
  if command -v qrencode >/dev/null 2>&1; then
    echo
    echo "QR-коды (наведи камеру телефона):"
    grep -E '^(vless|trojan)://' "$LINKS_FILE" 2>/dev/null | while IFS= read -r l; do
      echo
      printf '%s\n' "${l##*#}"
      qrencode -t ANSIUTF8 "$l" 2>/dev/null || true
    done
  fi
}

show_panel_info() {
  get_panel_settings
  local ip
  ip=$(server_ip)
  echo
  cecho "${GREEN}=== ДАННЫЕ ПАНЕЛИ ===${NC}"
  echo "IP:           ${ip}"
  echo "Порт панели:  ${PANEL_PORT}"
  echo "Логин:        ${PANEL_USER:-admin}"
  echo "Пароль:       ${PANEL_PASS:-<неизвестен, сбрось через меню>}"
  echo "Адрес:        http://${ip}:${PANEL_PORT}${WEB_BASE_PATH}"
  echo "Файл данных:  ${INFO_FILE}"
  show_links
}

show_quick_status() {
  get_panel_settings
  echo
  cecho "${GREEN}=== СТАТУС ===${NC}"
  printf '  x-ui:        %s\n' "$(systemctl is-active x-ui 2>/dev/null || echo неизвестно)"
  printf '  fail2ban:    %s\n' "$(systemctl is-active fail2ban 2>/dev/null || echo неизвестно)"
  echo   "  Порт панели: ${PANEL_PORT}"
  echo   "  BBR:         $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  echo   "  Swap:        $(free -h 2>/dev/null | awk '/Swap:/{print $3" из "$2}')"
  echo   "  Инбаунды:"
  ss -tlnH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un | sed 's/^/    порт /' || true
}

restart_services() {
  log "Перезапускаю сервисы..."
  systemctl restart x-ui 2>/dev/null || true
  systemctl restart fail2ban 2>/dev/null || true
  ok "Готово"
  show_quick_status
}

show_logs() {
  echo
  cecho "${GREEN}=== Логи x-ui (последние 40 строк) ===${NC}"
  journalctl -u x-ui -n 40 --no-pager 2>/dev/null || tail -n 40 "$INSTALL_LOG" 2>/dev/null || true
}

speed_test() {
  echo
  cecho "${GREEN}=== СКОРОСТЬ И ПИНГ ===${NC}"
  command -v curl >/dev/null 2>&1 || { err "curl не найден"; return 1; }
  echo "Загрузка 100 МБ (Cloudflare)..."
  local res bps tt
  res=$(curl -o /dev/null -s --max-time 40 -w '%{speed_download} %{time_total}' \
        "https://speed.cloudflare.com/__down?bytes=100000000" 2>/dev/null || true)
  if [ -n "$res" ]; then
    bps="${res%% *}"; tt="${res##* }"
    awk -v b="${bps:-0}" -v t="${tt:-0}" 'BEGIN{ printf "  Скорость: %.2f МБ/с   Время: %.1f c\n", b/1048576, t }'
  else
    echo "  тест не удался"
  fi
  echo
  echo "Пинг:"
  local host avg
  for host in 1.1.1.1 google.com ya.ru; do
    avg=$(ping -c 4 -W 2 "$host" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
    if [ -n "$avg" ]; then printf '  %-16s %s мс\n' "$host" "$avg"; else printf '  %-16s недоступен\n' "$host"; fi
  done
}

menu_reset_password() {
  get_panel_settings
  if [ ! -x /usr/local/x-ui/x-ui ]; then err "3x-ui не установлен"; return 1; fi
  reset_panel_password
  save_panel_env
  save_info_file
  show_panel_info
}

update_script() {
  log "Обновляю скрипт из GitHub..."
  if curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_DEST" 2>>"$INSTALL_LOG"; then
    chmod +x "$SCRIPT_DEST"
    install_management_command
    ok "Обновлено. Перезапусти: vpn"
  else
    err "Не удалось скачать обновление"
  fi
}

uninstall_all() {
  echo
  cecho "${RED}=== УДАЛЕНИЕ XRAY VPN ===${NC}"
  echo "Будут удалены: 3x-ui/Xray, CDN-модуль, swap-файл, оптимизации, команды vpn, данные."
  read -rp "Точно удалить? Введи 'yes' для подтверждения: " a
  [ "$a" = "yes" ] || { echo "Отменено."; return 0; }

  cdn_uninstall
  yes | x-ui uninstall >>"$INSTALL_LOG" 2>&1 || /usr/local/x-ui/x-ui uninstall >>"$INSTALL_LOG" 2>&1 || true
  swapoff /swapfile 2>/dev/null || true
  rm -f /swapfile
  sed -i '/swapfile/d' /etc/fstab 2>/dev/null || true
  rm -f /etc/sysctl.d/99-xray-vpn.conf /etc/security/limits.d/99-xray-vpn.conf /etc/modules-load.d/xray-bbr.conf
  sysctl --system >>"$INSTALL_LOG" 2>&1 || true
  rm -f /usr/local/bin/vpn /usr/local/bin/xray-vpn
  rm -rf "$STATE_DIR" "$INSTALL_DIR"
  rm -f "$INFO_FILE"
  ok "Удаление завершено. fail2ban/ufw оставлены (системные)."
}

post_install_menu() {
  get_panel_settings
  echo
  cecho "${YELLOW}=== МЕНЮ УПРАВЛЕНИЯ XRAY VPN ===${NC}"
  while true; do
    echo
    echo "  1) Автонастройка: протестировать и создать связки"
    echo "  2) Показать данные панели и ссылки"
    echo "  3) Статус"
    echo "  4) Перезапустить сервисы"
    echo "  5) Логи"
    echo "  6) Тест скорости и пинга"
    echo "  7) Сбросить пароль панели"
    echo "  8) Обновить скрипт (GitHub)"
    echo "  9) Удалить всё"
    echo " 10) CDN-подключение (XHTTP через CDN)"
    echo "  0) Выход"
    echo
    read -rp "  Выбор [0-10]: " choice
    case "$choice" in
      1) auto_setup ;;
      2) show_panel_info ;;
      3) show_quick_status ;;
      4) restart_services ;;
      5) show_logs ;;
      6) speed_test ;;
      7) menu_reset_password ;;
      8) update_script ;;
      9) uninstall_all ;;
      10) cdn_menu ;;
      0) echo "Выход."; exit 0 ;;
      *) warn "Неверный выбор" ;;
    esac
  done
}

# ==================== УСТАНОВКА (главный поток) ====================
install_flow() {
  print_header | tee -a "$INSTALL_LOG"
  check_root
  detect_os
  system_info

  log "Настраиваю SSH keepalive (чтобы соединение не отваливалось)..."
  ssh_keepalive

  # Команда vpn — как можно раньше, чтобы работала даже при обрыве установки
  download_self
  install_management_command
  ensure_prereqs

  do_step swap     1 "Swap"                      check_swap     do_swap
  do_step sysctl   2 "BBR + сетевые оптимизации" check_sysctl   do_sysctl
  do_step ufw      3 "Firewall (ufw)"            check_ufw      do_ufw
  do_step fail2ban 4 "fail2ban"                  check_fail2ban do_fail2ban
  do_step xui      5 "3x-ui + Xray"              check_xui      do_xui      true
  do_step finalize 6 "Финал (команда vpn, данные панели)" check_finalize do_finalize

  echo
  if check_xui && check_finalize; then
    echo "===========================================" | tee -a "$INSTALL_LOG"
    echo "  УСТАНОВКА ЗАВЕРШЕНА"                        | tee -a "$INSTALL_LOG"
    echo "===========================================" | tee -a "$INSTALL_LOG"
    echo "  vpn        — меню управления"               | tee -a "$INSTALL_LOG"
    echo "  vpn info   — данные панели и ссылки"        | tee -a "$INSTALL_LOG"
    echo "  vpn setup  — автонастройка связок"          | tee -a "$INSTALL_LOG"
    echo "===========================================" | tee -a "$INSTALL_LOG"
    # Меню открываем только при наличии терминала (интерактивный запуск).
    # При `curl | bash` терминала на stdin нет — просто подсказываем команду vpn.
    if [ -t 0 ]; then
      post_install_menu
    else
      echo
      echo "Дальше набери:  vpn setup   — чтобы создать рабочие связки"
      echo "или просто:     vpn         — открыть меню"
    fi
  else
    halt_resume "финальная проверка"
  fi
}

# ==================== УПРАВЛЕНИЕ (диспетчер) ====================
manage_dispatch() {
  check_root
  case "$1" in
    status)          show_quick_status ;;
    restart)         restart_services ;;
    logs)            show_logs ;;
    speed)           speed_test ;;
    info)            show_panel_info ;;
    setup|add)       auto_setup ;;
    reset-pass|pass) menu_reset_password ;;
    update)          update_script ;;
    uninstall)       uninstall_all ;;
    cdn|cdn-setup)   cdn_setup ;;
    cdn-add)         cdn_add "$SUBARG" ;;
    cdn-list)        cdn_list ;;
    cdn-remove)      cdn_remove "$SUBARG" ;;
    cdn-check)       cdn_check ;;
    cdn-uninstall)   cdn_uninstall && ok "CDN-модуль удалён" ;;
    cdn-menu)        cdn_menu ;;
    menu|*)          post_install_menu ;;
  esac
}

# ==================== РАЗБОР АРГУМЕНТОВ ====================
parse_args() {
  case "$(basename "$0" 2>/dev/null)" in
    vpn|xray-vpn) MODE="manage" ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --manage)  MODE="manage" ;;
      --install) MODE="install" ;;
      --resume)  MODE="install" ;;
      --tmux)    USE_TMUX="true" ;;
      --no-tmux) USE_TMUX="false" ;;
      status|restart|logs|speed|info|setup|add|reset-pass|pass|update|uninstall|menu)
        MODE="manage"; SUBCMD="$1" ;;
      cdn|cdn-setup|cdn-add|cdn-list|cdn-remove|cdn-check|cdn-uninstall|cdn-menu)
        MODE="manage"; SUBCMD="$1" ;;
      "" ) ;;
      * )
        # первый «свободный» аргумент (без дефиса) считаем доп. параметром подкоманды
        # (например имя пользователя для cdn-add / cdn-remove)
        if [ -z "$SUBARG" ] && [ "${1#-}" = "$1" ]; then SUBARG="$1"; fi
        ;;
    esac
    shift
  done
}

# ==================== ТОЧКА ВХОДА ====================
main() {
  ensure_dirs
  parse_args "$@"

  if [ "$MODE" = "manage" ]; then
    manage_dispatch "$SUBCMD"
    exit 0
  fi

  # режим установки
  check_root
  if [ "$USE_TMUX" = "true" ]; then
    ensure_tmux_for_install   # опционально по флагу --tmux, может уйти в tmux
  fi
  install_flow
}

main "$@"
