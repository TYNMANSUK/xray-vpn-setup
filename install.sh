#!/bin/bash
#
# xray-vpn-install.sh
# Автоматическая установка и настройка Xray VPN для Ubuntu VPS

# Форсируем UTF-8, чтобы в tmux и на любом терминале был читаемый русский текст
export LANG=C.UTF-8 2>/dev/null || export LANG=en_US.UTF-8 2>/dev/null || true
export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=en_US.UTF-8 2>/dev/null || true
#
# Делает:
# - Умный swap, BBR + лучшие оптимизации
# - fail2ban + ufw
# - Установка 3x-ui + Xray
# - После установки: меню с АВТОМАТИЧЕСКОЙ НАСТРОЙКОЙ
#
# Автоматическая настройка учитывает блокировки РКН:
#   - Пробует VLESS+Reality и Trojan+Reality
#   - Разные fingerprint (Firefox/Edge/Safari в приоритете, Chrome блокируют)
#   - Разные порты + SNI
#   - Реально проверяет связки
#
# Запуск:
#   curl -fsSL https://raw.githubusercontent.com/TYNMANSUK/xray-vpn-setup/main/install.sh | bash
# или
#   bash install.sh
#

# НЕ используем set -e, потому что это инсталлятор: ошибки отдельных
# команд (ufw, systemctl, x-ui setting) не должны убивать всё.
set -uo pipefail

# Глобальный URL скрипта — используем везде вместо магических ...
SCRIPT_URL="https://raw.githubusercontent.com/TYNMANSUK/xray-vpn-setup/main/install.sh"

# When run via `curl | bash` there are no arguments.
# This prevents "unbound variable" error from set -u.
if [ $# -eq 0 ]; then
  set -- ""
fi

# Ensure log file exists early
mkdir -p /var/log 2>/dev/null || true
touch /var/log/xray-vpn-install.log 2>/dev/null || true
chmod 644 /var/log/xray-vpn-install.log 2>/dev/null || true

# ==================== РАННЯЯ ПРОВЕРКА СУЩЕСТВУЮЩЕЙ СЕССИИ ====================
# Если tmux сессия 'vpn' уже есть, и мы не внутри неё - покажем статус.
if [ -z "${TMUX:-}" ]; then
  if tmux has-session -t vpn 2>/dev/null; then
    echo ""
    echo "==========================================="
    echo "  $(t "Установка Xray VPN уже запущена в tmux" "Xray VPN install is already running in tmux")"
    echo "==========================================="
    echo ""
    echo "$(t "Посмотреть прогресс:" "View progress:")"
    echo "   tmux attach -t vpn"
    echo "   tail -f /var/log/xray-vpn-install.log"
    echo ""
    echo "$(t "Перезапустить полностью:" "Restart fully:")"
    echo "   tmux kill-session -t vpn && curl -fsSL ${SCRIPT_URL} | bash"
    echo ""
    echo "$(t "После завершения установки используй команду: vpn" "After install use: vpn")"
    echo ""
    exit 0
  fi
fi

# ==================== РАННЕЕ ОПРЕДЕЛЕНИЕ РЕЖИМА ЗАПУСКА ====================
# Нужно, чтобы не пытаться запускать tmux при `curl | bash` (нет терминала)
RUN_VIA_PIPE=false
if [[ "$0" == "bash" || "$0" == /dev/fd/* || "$0" == "-" || ! -t 0 || ! -t 1 ]]; then
  RUN_VIA_PIPE=true
fi

# Ранний swap для слабых VPS (2GB) — делаем ДО всего тяжёлого, даже до tmux
if ! swapon --show | grep -q '/swapfile'; then
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if [ "$mem_kb" -gt 0 ] && [ "$mem_kb" -lt 2500000 ]; then
    echo "  [ранний swap] Мало RAM — создаём 2G..."
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab 2>/dev/null || true
    sysctl -w vm.swappiness=10 >/dev/null 2>&1
    echo "  [ранний swap] готов"
  fi
fi

# ==================== EARLY TMUX HANDLER ====================
# Чтобы не было "not a terminal" и чтобы SSH не падал от тяжёлой работы:
# - Ставим tmux
# - Если piped (curl | bash) — запускаем ВСЮ установку в detached tmux и выходим
# - Если интерактив — уходим в tmux
if [ -z "${TMUX:-}" ]; then
  if ! command -v tmux >/dev/null 2>&1; then
    echo "Ставим tmux..."
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y tmux >/dev/null 2>&1 || true
  fi

  # piped режим (curl | bash) — запускаем всё в detached tmux и сразу выходим
  if [ "$RUN_VIA_PIPE" = true ] || [ ! -t 0 ] || [ ! -t 1 ]; then
    echo ""
    echo "==========================================="
    echo "  $(t "Xray VPN — подготовка к установке" "Xray VPN — install preparation")"
    echo "==========================================="
    echo ""

    s="/tmp/xray-install.sh"
    echo "$(t "Скачиваю свежую версию установщика..." "Downloading latest installer...")"
    if ! curl -fsSL "$SCRIPT_URL" -o "$s"; then
      echo "[$(t "ОШИБКА" "ERROR")] $(t "Не удалось скачать установщик. Проверь интернет." "Failed to download installer. Check internet.")"
      echo "   curl -fsSL ${SCRIPT_URL}"
      exit 1
    fi
    chmod +x "$s"

    # Убиваем старую сессию, если она осталась с прошлого неудачного запуска
    tmux kill-session -t vpn 2>/dev/null || true

    tmux new-session -d -s vpn
    tmux send-keys -t vpn "export LANG=C.UTF-8 LC_ALL=C.UTF-8; XRAY_VPN_IN_TMUX=1 bash $s ${@}" C-m

    touch /var/log/xray-vpn-install.log 2>/dev/null || true

    echo "$(t "Установка запущена в фоновой сессии tmux 'vpn'." "Install started in background tmux session 'vpn'.")"
    echo ""
    echo "$(t "Что делать:" "What to do:")"
    echo "   1. $(t "НЕ закрывайте это окно сразу — подождите 2-3 минуты." "DO NOT close this window immediately — wait 2-3 minutes.")"
    echo "   2. $(t "Чтобы смотреть прогресс в реальном времени:" "To watch live progress:")"
    echo "         tmux attach -t vpn"
    echo "   3. $(t "Чтобы проверить лог:" "To check the log:")"
    echo "         tail -f /var/log/xray-vpn-install.log"
    echo "   4. $(t "После завершения используй команду:" "After completion use command:")"
    echo "         vpn"
    echo ""
    echo "$(t "Если прервали случайно (Ctrl+Z / отвал SSH) — ничего страшного:" "If interrupted (Ctrl+Z / SSH drop) — no problem:")"
    echo "   tmux attach -t vpn   $(t "продолжит установку." "will continue install.")"
    echo ""
    echo "$(t "Чтобы перезапустить полностью:" "To restart fully:")"
    echo "   tmux kill-session -t vpn && curl -fsSL ${SCRIPT_URL} | bash"
    echo ""
    echo "$(t "Запущено. Можете подключиться:" "Started. You can attach:") tmux attach -t vpn"
    exit 0
  fi

  # интерактив — уходим в tmux
  if command -v tmux >/dev/null 2>&1; then
    echo "$(t "Переходим в tmux 'vpn' для стабильности..." "Switching to tmux 'vpn' for stability...")"
    tmux kill-session -t vpn 2>/dev/null || true
    tmux new-session -d -s vpn
    tmux send-keys -t vpn "export LANG=C.UTF-8 LC_ALL=C.UTF-8; bash $0 ${@}" C-m
    exec tmux attach -t vpn
  fi
fi

# ==================== РЕЖИМ УПРАВЛЕНИЯ ====================
# Поддержка: vpn, xray-vpn, vpn status, vpn restart, vpn speed, vpn logs и т.д.
MANAGEMENT_MODE=0
SUBCOMMAND=""
SCRIPT_BASENAME=$(basename "$0")

if [[ "$SCRIPT_BASENAME" == "xray-vpn" || "$SCRIPT_BASENAME" == "vpn" ]]; then
  MANAGEMENT_MODE=1
  SUBCOMMAND="${1:-menu}"
elif [ $# -gt 0 ] && [[ "$1" == "--menu" || "$1" == "menu" ]]; then
  MANAGEMENT_MODE=1
  SUBCOMMAND="menu"
elif [ $# -gt 0 ] && [[ "$1" =~ ^(status|restart|speed|logs|info|diag)$ ]]; then
  MANAGEMENT_MODE=1
  SUBCOMMAND="$1"
fi

# (tmux handling is all at the very top for reliable curl | bash + no attach required)

# ==================== ЛОКАЛИЗАЦИЯ ====================
# Определяем, поддерживает ли терминал русский.
# По умолчанию используем английский — он отображается в любом терминале.
# Русский включается только если LANG/LC_ALL явно ru_RU.UTF-8.
USE_RU="no"
if [[ "${LANG:-}" == *ru_RU* || "${LC_ALL:-}" == *ru_RU* ]]; then
  USE_RU="yes"
fi

# Функция перевода
t() {
  local ru="$1"
  local en="$2"
  if [[ "$USE_RU" == "yes" ]]; then
    echo "$ru"
  else
    echo "$en"
  fi
}

# ==================== ЦВЕТА ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==================== ПЕРЕМЕННЫЕ ====================
INSTALL_LOG="/var/log/xray-vpn-install.log"
XUI_INSTALL_LOG="/tmp/3xui_install.log"
JAR="/tmp/xui_cookies.txt"
INFO_FILE="/root/xray-vpn-info.txt"

PANEL_PORT=""
PANEL_USER=""
PANEL_PASS=""
WEB_BASE_PATH="/"

# ==================== ВСПОМОГАТЕЛЬНЫЕ (простой вывод, всё в лог) ====================
log()    { echo "$1" | tee -a "$INSTALL_LOG"; }
success(){ echo "[готово] $1" | tee -a "$INSTALL_LOG"; }
warn()   { echo "[внимание] $1" | tee -a "$INSTALL_LOG"; }
error()  { echo "[ошибка] $1" | tee -a "$INSTALL_LOG"; }

print_header() {
  echo
  echo "================================================================"
  echo "  $(t "XRAY VPN — автоматическая установка (Ubuntu)" "XRAY VPN — automatic install (Ubuntu)")"
  echo "================================================================"
  echo
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "Запусти скрипт от root: sudo bash install.sh"
    exit 1
  fi
}

detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    error "Не удалось определить ОС"
    exit 1
  fi
  . /etc/os-release
  if [[ "$ID" != "ubuntu" ]]; then
    warn "Скрипт протестирован на Ubuntu. Текущая ОС: $PRETTY_NAME"
    read -p "Продолжить? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
  fi
  log "ОС: $PRETTY_NAME"
}

# (tmux auto logic moved to early block above for curl | bash compatibility)

# Лёгкая защита после suspend (даём системе прогреться)
if [ "$(cat /proc/uptime | awk '{print int($1)}')" -lt 300 ]; then
  echo "[INFO] VM недавно проснулась — ждём 15 сек..." | tee -a /var/log/xray-vpn-install.log 2>/dev/null || true
  sleep 15
fi

system_info() {
  local mem=$(free -m | awk '/Mem:/ {print $2}')
  local cpu=$(nproc)
  log "Система: RAM ${mem}MB | CPU ${cpu} ядер"
}

# ==================== УМНЫЙ SWAP ====================
setup_swap() {
  local mem_mb=$(free -m | awk '/Mem:/ {print $2}')
  local swap_size=2048
  if [[ $mem_mb -le 1024 ]]; then swap_size=2048
  elif [[ $mem_mb -le 4096 ]]; then swap_size=2048
  else swap_size=1024; fi

  if swapon --show | grep -q '/swapfile'; then
    return
  fi

  log "Создаём swap ${swap_size}MB..."

  swapoff /swapfile 2>/dev/null || true
  rm -f /swapfile
  fallocate -l "${swap_size}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$swap_size status=none
  chmod 600 /swapfile
  mkswap /swapfile >> "$INSTALL_LOG" 2>&1
  swapon /swapfile

  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10 >> "$INSTALL_LOG" 2>&1
  grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf

  success "Swap готов (${swap_size}MB)"
}

# ==================== 3. ЛУЧШИЕ ОПТИМИЗАЦИИ (BBR + сеть) ====================
apply_tuning() {
  log "Применяем сетевые оптимизации (BBR)..."

  cat > /etc/sysctl.d/99-xray-vpn.conf << 'EOF'
# xray-vpn — лучшие настройки для Xray / Reality
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

  sysctl --system >> "$INSTALL_LOG" 2>&1

  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    success "BBR + fq успешно включены"
  else
    warn "BBR может не поддерживаться ядром (проверь позже)"
  fi
}

# ==================== 4. FIREWALL ====================
setup_firewall() {
  log "Настройка firewall (ufw)..."

  ufw --force reset >> "$INSTALL_LOG" 2>&1 || true
  ufw default deny incoming >> "$INSTALL_LOG" 2>&1
  ufw default allow outgoing >> "$INSTALL_LOG" 2>&1

  ufw allow 22/tcp comment 'SSH' >> "$INSTALL_LOG" 2>&1
  ufw allow 443/tcp comment 'Xray Reality' >> "$INSTALL_LOG" 2>&1

  # Панель откроем позже, когда узнаем порт

  ufw --force enable >> "$INSTALL_LOG" 2>&1
  success "UFW включён (22 + 443 открыты)"
}

# ==================== РАННЕЕ СОЗДАНИЕ КОМАНДЫ VPN ====================
# Делаем команду vpn доступной ПЕРЕД тяжёлой установкой.
# Если установка ещё идёт — заглушка скажет подождать.
install_early_management_command() {
  local install_dir="/opt/xray-vpn"
  local script_dest="$install_dir/install.sh"
  local cmd_path="/usr/local/bin/xray-vpn"
  local alt_cmd="/usr/local/bin/vpn"

  mkdir -p "$install_dir" 2>/dev/null || true

  # Скачиваем свежую версию скрипта, чтобы команда всегда работала
  curl -fsSL "$SCRIPT_URL" -o "$script_dest" 2>/dev/null || true

  chmod +x "$script_dest" 2>/dev/null || true

  cat > "$cmd_path" << EOF
#!/bin/bash
# xray-vpn / vpn — управление Xray VPN
if [[ -f "$script_dest" ]]; then
  bash "$script_dest" "\$@"
else
  echo "Скрипт не найден. Переустановите: curl -fsSL ${SCRIPT_URL} | bash"
  exit 1
fi
EOF

  chmod +x "$cmd_path"
  ln -sf "$cmd_path" "$alt_cmd" 2>/dev/null || true
}

# ==================== 5. FAIL2BAN ====================
setup_fail2ban() {
  log "Настройка fail2ban..."

  systemctl enable --now fail2ban >> "$INSTALL_LOG" 2>&1 || true

  cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/auth.log
maxretry = 4
bantime = 3600
EOF

  systemctl restart fail2ban >> "$INSTALL_LOG" 2>&1 || true
  sleep 1

  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    success "fail2ban запущен и настроен"
  else
    warn "fail2ban установлен, но не запустился (проверь вручную)"
  fi
}

# ==================== 6. УСТАНОВКА 3X-UI + XRAY ====================
install_3x_ui() {
  log "Установка 3x-ui (Xray + панель)..."

  # Идемпотентность: если уже установлено — обновим настройки и выйдем
  if [ -x /usr/local/x-ui/x-ui ]; then
    log "3x-ui уже установлен — обновляем данные панели..."
    get_panel_settings
    if [[ -n "$PANEL_PORT" ]]; then
      ufw allow "${PANEL_PORT}/tcp" comment '3x-ui Panel' >> "$INSTALL_LOG" 2>&1 || true
    fi
    timeout 30 systemctl restart x-ui >> "$INSTALL_LOG" 2>&1 || true
    success "3x-ui уже готов"
    return
  fi

  rm -f "$XUI_INSTALL_LOG"

  echo "  Скачиваем официальный установщик 3x-ui..." | tee -a "$INSTALL_LOG"
  curl -L --progress-bar \
       -o /tmp/3xui_installer.sh \
       https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh 2>&1 | tee -a "$INSTALL_LOG"

  if [[ ! -s /tmp/3xui_installer.sh ]]; then
    error "Не удалось скачать установщик 3x-ui"
    exit 1
  fi

  echo "  Запускаем установщик 3x-ui (может занять 1-3 минуты)..." | tee -a "$INSTALL_LOG"
  export DEBIAN_FRONTEND=noninteractive

  # Полный вывод официального установщика (прогресс реальный)
  yes n | bash /tmp/3xui_installer.sh 2>&1 | tee -a "$XUI_INSTALL_LOG" | tee -a "$INSTALL_LOG"

  sleep 3

  if [[ -x /usr/local/x-ui/x-ui ]]; then
    success "3x-ui + Xray установлены"
  else
    error "3x-ui не установился. Смотри лог: $XUI_INSTALL_LOG"
    exit 1
  fi

  # Извлекаем данные панели
  PANEL_PORT=$(grep -oP 'port:\s*\K[0-9]+' "$XUI_INSTALL_LOG" | tail -1 || true)
  PANEL_USER=$(grep -oP '(?i)username:?\s*\K\S+' "$XUI_INSTALL_LOG" | tail -1 || true)
  PANEL_PASS=$(grep -oP '(?i)password:?\s*\K\S+' "$XUI_INSTALL_LOG" | tail -1 || true)

  if [[ -z "$PANEL_PORT" ]]; then
    PANEL_PORT=$(/usr/local/x-ui/x-ui setting -show 2>/dev/null | grep -oP 'port:\s*\K[0-9]+' | head -1 || echo "2053")
  fi

  if [[ -n "$PANEL_PORT" ]]; then
    ufw allow "${PANEL_PORT}/tcp" comment '3x-ui Panel' >> "$INSTALL_LOG" 2>&1 || true
  fi

  timeout 30 systemctl restart x-ui >> "$INSTALL_LOG" 2>&1 || true

  success "Xray + 3x-ui готовы"
}

# ==================== УСТАНОВКА КОМАНДЫ ДЛЯ МЕНЮ ====================
install_management_command() {
  log "Устанавливаем удобные команды управления (vpn / xray-vpn)..."

  local install_dir="/opt/xray-vpn"
  local script_dest="$install_dir/install.sh"
  local cmd_path="/usr/local/bin/xray-vpn"
  local alt_cmd="/usr/local/bin/vpn"

  mkdir -p "$install_dir"

  # Копируем текущий скрипт в постоянное место (работает даже при curl | bash)
  if [[ -f "$0" && "$0" != "/dev/fd/"* && "$0" != "-" ]]; then
    cp "$0" "$script_dest" 2>/dev/null || true
  fi

  # Если не скопировался (curl | bash), скачиваем свежую версию
  if [[ ! -f "$script_dest" ]]; then
    curl -fsSL https://raw.githubusercontent.com/TYNMANSUK/xray-vpn-setup/main/install.sh -o "$script_dest" 2>/dev/null || true
  fi

  chmod +x "$script_dest" 2>/dev/null || true

  # Создаём удобную команду
  cat > "$cmd_path" << EOF
#!/bin/bash
# xray-vpn / vpn — управление Xray VPN
if [[ -f "$script_dest" ]]; then
  bash "$script_dest" "\$@"
else
  echo "Скрипт не найден. Переустановите: curl -fsSL https://raw.githubusercontent.com/TYNMANSUK/xray-vpn-setup/main/install.sh | bash"
  exit 1
fi
EOF

  chmod +x "$cmd_path"
  ln -sf "$cmd_path" "$alt_cmd" 2>/dev/null || true

  success "Команда установлена. Теперь можно использовать: vpn  или  xray-vpn"
}

# ==================== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ УПРАВЛЕНИЯ ====================

show_quick_status() {
  echo "=== Статус Xray VPN ==="
  echo
  echo -n "x-ui:     "; systemctl is-active x-ui
  echo -n "xray:     "; systemctl is-active xray 2>/dev/null || echo "inactive (не найден отдельный сервис)"
  echo -n "fail2ban: "; systemctl is-active fail2ban
  echo
  echo "Порт панели: ${PANEL_PORT}"
  echo "Информация:  $INFO_FILE"
  echo
  echo "BBR активен: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  echo "Swap:        $(free -h | awk '/Swap:/ {print $2 " total, " $3 " used"}')"
}

restart_services() {
  log "Перезапускаем сервисы..."
  systemctl restart x-ui 2>/dev/null || true
  systemctl restart xray 2>/dev/null || true
  systemctl restart fail2ban 2>/dev/null || true
  success "Сервисы перезапущены"
  show_quick_status
}

show_logs() {
  echo "=== Последние логи ==="
  echo
  echo "--- x-ui ---"
  journalctl -u x-ui -n 30 --no-pager 2>/dev/null || tail -30 /var/log/xray-vpn-install.log
  echo
  echo "--- Системные (xray) ---"
  journalctl -u xray -n 20 --no-pager 2>/dev/null || true
}

speed_test() {
  echo
  log "=== Проверка скорости и пинга ==="
  echo

  if ! command -v curl >/dev/null 2>&1; then
    error "curl не найден"
    return 1
  fi

  echo "→ Загрузка 100MB (Cloudflare):"
  curl -L -o /dev/null -# --max-time 35 \
    -w "   Скорость: %{speed_download} байт/сек (~%.1f MB/s)\n   Время: %{time_total}s\n" \
    https://speed.cloudflare.com/__down?bytes=100000000 2>/dev/null || echo "   Тест не удался"

  echo
  echo "→ Пинг (задержка):"
  printf "   %-20s %s\n" "Хост" "Средний пинг"
  for host in 1.1.1.1 google.com ya.ru cloudflare.com; do
    avg=$(ping -c 4 -W 2 "$host" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
    if [[ -n "$avg" ]]; then
      printf "   %-20s %s ms\n" "$host" "$avg"
    else
      printf "   %-20s недоступен\n" "$host"
    fi
  done

  echo
  log "Тест скорости завершён"
}

# ==================== ПОЛУЧЕНИЕ ДАННЫХ ПАНЕЛИ ====================
get_panel_settings() {
  local out
  out=$(timeout 10 /usr/local/x-ui/x-ui setting -show 2>/dev/null || true)

  PANEL_PORT=$(echo "$out" | grep -oP 'port:\s*\K[0-9]+' | head -1 || echo "${PANEL_PORT:-2053}")
  WEB_BASE_PATH=$(echo "$out" | grep -oP 'webBasePath:\s*\K\S+' | head -1 || echo "/")
  WEB_BASE_PATH=$(echo "$WEB_BASE_PATH" | sed 's#^/*##;s#/*$##')
  [[ -n "$WEB_BASE_PATH" ]] && WEB_BASE_PATH="/${WEB_BASE_PATH}/" || WEB_BASE_PATH="/"

  log "Панель: порт=${PANEL_PORT}, basepath=${WEB_BASE_PATH}"
}

# Сброс пароля на известный (чтобы автонастройка работала стабильно)
reset_panel_password() {
  local new_user="admin"
  local new_pass

  new_pass=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 14)

  log "$(t "Сброс пароля панели (с таймаутом 15 сек)..." "Resetting panel password (15 sec timeout)...")"

  # Пробуем через x-ui setting (если поддерживается). Иногда x-ui setting зависает — ставим таймаут.
  if timeout 15 /usr/local/x-ui/x-ui setting --help 2>&1 | grep -qi "username"; then
    if timeout 15 /usr/local/x-ui/x-ui setting --username "$new_user" --password "$new_pass" >> "$INSTALL_LOG" 2>&1; then
      PANEL_USER="$new_user"
      PANEL_PASS="$new_pass"
      # Экспортируем, чтобы точно были доступны везде
      export PANEL_USER PANEL_PASS
      success "$(t "Пароль панели сброшен на новый (для автонастройки)" "Panel password reset to new one (for auto setup)")"
    else
      warn "$(t "Не удалось сбросить пароль через x-ui setting (таймаут или ошибка)." "Failed to reset password via x-ui setting (timeout or error).")"
      warn "$(t "Зайди в панель вручную и поменяй пароль." "Log into panel manually and change password.")"
    fi
  else
    warn "$(t "x-ui setting не поддерживает смену пароля (или не отвечает)." "x-ui setting does not support password change (or not responding).")"
  fi
}

save_info_file() {
  # Убедимся, что логин/пароль не пустые перед сохранением
  [[ -z "$PANEL_USER" ]] && PANEL_USER="admin"
  [[ -z "$PANEL_PASS" ]] && PANEL_PASS="admin"

  mkdir -p "$(dirname "$INFO_FILE")"
  {
    echo "=== XRAY VPN SETUP ($(date)) ==="
    echo "IP: $(curl -s4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
    echo "Panel port: ${PANEL_PORT}"
    echo "Username: ${PANEL_USER}"
    echo "Password: ${PANEL_PASS}"
    echo ""
    echo "Panel URL: http://$(hostname -I | awk '{print $1}'):${PANEL_PORT}${WEB_BASE_PATH}"
    echo ""
    echo "Swap and tuning applied"
    echo "fail2ban active"
    echo "BBR active (if supported)"
  } > "$INFO_FILE"
  chmod 600 "$INFO_FILE"
  log "$(t "Данные сохранены в" "Data saved to") $INFO_FILE"
}

show_panel_info() {
  # Подстраховка: если переменные пустые — попробуем прочитать из info-файла
  if [[ -z "$PANEL_USER" || -z "$PANEL_PASS" ]] && [[ -f "$INFO_FILE" ]]; then
    PANEL_USER=$(grep -iE '^login|логин' "$INFO_FILE" | head -1 | awk -F': ' '{print $2}')
    PANEL_PASS=$(grep -iE '^password|пароль' "$INFO_FILE" | head -1 | awk -F': ' '{print $2}')
  fi

  # Если всё ещё пустые — попробуем стандартные admin/admin
  if [[ -z "$PANEL_USER" ]]; then
    PANEL_USER="admin"
  fi
  if [[ -z "$PANEL_PASS" ]]; then
    PANEL_PASS="$(t "неизвестен (попробуйте admin / установленный пароль)" "unknown (try admin / your set password)")"
  fi

  echo
  echo -e "${GREEN}=== $(t "ДАННЫЕ ДЛЯ ВХОДА В ПАНЕЛЬ" "PANEL LOGIN INFO") ===${NC}"
  local ip
  ip=$(curl -s4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  echo "IP: $ip"
  echo "$(t "Порт панели" "Panel port"): ${PANEL_PORT}"
  echo "$(t "Логин" "Username"): ${PANEL_USER}"
  echo "$(t "Пароль" "Password"): ${PANEL_PASS}"
  echo
  echo "$(t "Ссылка" "URL"): http://${ip}:${PANEL_PORT}${WEB_BASE_PATH}"
  echo
  echo "$(t "Файл с информацией" "Info file"): $INFO_FILE"
  echo
}

# ==================== АВТОНАСТРОЙКА ИНБАУНДОВ (ГЛАВНАЯ ФИШКА) ====================

generate_reality_keys() {
  local xray_bin
  xray_bin=$(find /usr/local/x-ui -name 'xray*' -type f -executable 2>/dev/null | head -1)

  if [[ -z "$xray_bin" ]]; then
    error "Не найден бинарник xray для генерации ключей"
    return 1
  fi

  local keys
  keys=$("$xray_bin" x25519 2>/dev/null || true)

  PRIVATE_KEY=$(echo "$keys" | grep -i 'Private' | awk '{print $2}' | head -1)
  PUBLIC_KEY=$(echo "$keys" | grep -i 'Public' | awk '{print $2}' | head -1)

  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    error "Не удалось сгенерировать Reality ключи"
    return 1
  fi
}

xui_login() {
  local port=$1
  local base=$2
  local user=$3
  local pass=$4

  rm -f "$JAR"

  local base_url="http://127.0.0.1:${port}${base}"
  curl -sk -c "$JAR" -b "$JAR" -o /dev/null "$base_url" 2>/dev/null || true

  # CSRF
  local csrf
  csrf=$(curl -sk -b "$JAR" -c "$JAR" "${base_url}csrf-token" 2>/dev/null | jq -r '.obj // empty' 2>/dev/null || true)

  local extra_args=()
  [[ -n "$csrf" ]] && extra_args+=(-H "X-CSRF-Token: $csrf")

  local login_url="${base_url}login"
  local resp
  resp=$(curl -sk -b "$JAR" -c "$JAR" "${extra_args[@]}" \
    --data-urlencode "username=${user}" \
    --data-urlencode "password=${pass}" \
    "$login_url" 2>/dev/null || true)

  if echo "$resp" | grep -q '"success":true'; then
    return 0
  fi
  return 1
}

create_inbound() {
  local port=$1
  local sni=$2
  local fp=$3
  local proto=$4
  local remark=$5

  local base_url="http://127.0.0.1:${PANEL_PORT}${WEB_BASE_PATH}"

  generate_reality_keys || return 1

  local uuid
  uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "$(date +%s | md5sum | cut -c1-8)-$(date +%s | md5sum | cut -c1-4)-4$(date +%s | md5sum | cut -c1-3)-$(date +%s | md5sum | cut -c1-4)-$(date +%s | md5sum | cut -c1-12)")

  local short_id
  short_id=$(openssl rand -hex 4 2>/dev/null || echo "$(date +%s | md5sum | cut -c1-8)")

  local protocol="vless"
  local settings
  local stream
  local client_link_proto="vless"

  if [[ "$proto" == "trojan-reality" ]]; then
    protocol="trojan"
    local password=$(openssl rand -hex 16 2>/dev/null || date +%s | md5sum | cut -c1-16)

    settings=$(jq -n \
      --arg pass "$password" \
      '{
        clients: [{
          password: $pass,
          email: "auto-trojan",
          limitIp: 0,
          totalGB: 0,
          expiryTime: 0,
          enable: true,
          tgId: "",
          subId: "",
          reset: 0
        }],
        fallbacks: []
      }')

    client_link_proto="trojan"
  else
    # VLESS Reality
    settings=$(jq -n \
      --arg uuid "$uuid" \
      --arg email "auto-${port}" \
      --arg sub "$(openssl rand -hex 8)" \
      '{
        clients: [{
          id: $uuid,
          flow: "xtls-rprx-vision",
          email: $email,
          limitIp: 0,
          totalGB: 0,
          expiryTime: 0,
          enable: true,
          tgId: "",
          subId: $sub,
          reset: 0
        }],
        decryption: "none",
        fallbacks: []
      }')
  fi

  stream=$(jq -n \
    --arg dest "${sni}:443" \
    --arg sni "$sni" \
    --arg priv "$PRIVATE_KEY" \
    --arg pub "$PUBLIC_KEY" \
    --arg sid "$short_id" \
    --arg fp "$fp" \
    '{
      network: "tcp",
      security: "reality",
      externalProxy: [],
      realitySettings: {
        show: false,
        xver: 0,
        dest: $dest,
        serverNames: [$sni],
        privateKey: $priv,
        minClient: "",
        maxClient: "",
        maxTimediff: 0,
        shortIds: [$sid],
        settings: {
          publicKey: $pub,
          fingerprint: $fp,
          serverName: "",
          spiderX: "/"
        }
      },
      tcpSettings: { acceptProxyProtocol: false, header: { type: "none" } }
    }')

  local sniffing='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
  local allocate='{"strategy":"always","refresh":5,"concurrency":3}'

  local payload
  payload=$(jq -n \
    --argjson port "$port" \
    --arg remark "$remark" \
    --argjson settings "$settings" \
    --argjson stream "$stream" \
    --argjson sniffing "$sniffing" \
    --argjson allocate "$allocate" \
    --arg protocol "$protocol" \
    '{
      up: 0, down: 0, total: 0,
      remark: $remark,
      enable: true,
      expiryTime: 0,
      listen: "",
      port: $port,
      protocol: $protocol,
      settings: $settings,
      streamSettings: $stream,
      sniffing: $sniffing,
      allocate: $allocate
    }')

  local csrf
  csrf=$(curl -sk -b "$JAR" -c "$JAR" "${base_url}csrf-token" 2>/dev/null | jq -r '.obj // empty' 2>/dev/null || true)
  local extra_args=()
  [[ -n "$csrf" ]] && extra_args+=(-H "X-CSRF-Token: $csrf")

  local resp
  resp=$(curl -sk -b "$JAR" -c "$JAR" "${extra_args[@]}" \
    -H "Content-Type: application/json" \
    --data-raw "$payload" \
    "${base_url}panel/api/inbounds/add" 2>/dev/null || true)

  if echo "$resp" | grep -q '"success":true'; then
    local ip
    ip=$(curl -s4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

    local link
    local client_id_or_pass

    if [[ "$protocol" == "trojan" ]]; then
      client_id_or_pass=$(echo "$settings" | jq -r '.clients[0].password')
      link="trojan://${client_id_or_pass}@${ip}:${port}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=${fp}&sni=${sni}&sid=${short_id}&spx=%2F#${remark}"
    else
      client_id_or_pass="$uuid"
      link="vless://${uuid}@${ip}:${port}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=${fp}&sni=${sni}&sid=${short_id}&spx=%2F&flow=xtls-rprx-vision#${remark}"
    fi

    # Output structured data for verification (caller can parse)
    cat <<EODATA
LINK=$link
PORT=$port
SNI=$sni
FP=$fp
PROTO=$protocol
CLIENT_ID=$client_id_or_pass
SHORT_ID=$short_id
PUBLIC_KEY=$PUBLIC_KEY
EODATA
    return 0
  else
    return 1
  fi
}

# ==================== ПРОВЕРКА СВЯЗКИ (реальная верификация) ====================
# Проверяет, сможет ли клиент подключиться к этому инбаунду.
# Это лучший способ понять "будет ли работать у пользователя в РФ",
# хотя 100% симуляция РКН с сервера невозможна.
verify_bundle() {
  local port=$1
  local sni=$2
  local fp=$3
  local proto=$4
  local client_id=$5
  local short_id=$6
  local pubkey=$7

  local test_socks_port=10808
  local test_config="/tmp/xray-vpn-test-client-${port}.json"
  local test_log="/tmp/xray-vpn-test-${port}.log"
  local xray_bin
  xray_bin=$(find /usr/local/x-ui -name 'xray*' -type f -executable 2>/dev/null | head -1)

  if [[ -z "$xray_bin" ]]; then
    warn "Не найден xray для теста связки"
    return 1
  fi

  # Строим минимальный клиентский конфиг
  local outbound_protocol outbound_settings

  if [[ "$proto" == "trojan-reality" || "$proto" == "trojan" ]]; then
    outbound_protocol="trojan"
    outbound_settings=$(jq -n \
      --arg pass "$client_id" \
      '{
        servers: [{
          address: "127.0.0.1",
          port: '"$port"',
          password: $pass
        }]
      }')
  else
    outbound_protocol="vless"
    outbound_settings=$(jq -n \
      --arg id "$client_id" \
      '{
        vnext: [{
          address: "127.0.0.1",
          port: '"$port"',
          users: [{
            id: $id,
            encryption: "none",
            flow: "xtls-rprx-vision"
          }]
        }]
      }')
  fi

  local stream_settings
  stream_settings=$(jq -n \
    --arg sni "$sni" \
    --arg pbk "$pubkey" \
    --arg sid "$short_id" \
    --arg fp "$fp" \
    '{
      network: "tcp",
      security: "reality",
      realitySettings: {
        fingerprint: $fp,
        serverName: $sni,
        publicKey: $pbk,
        shortId: $sid,
        spiderX: "/"
      }
    }')

  # Полный тестовый клиентский конфиг
  jq -n \
    --argjson socks_port "$test_socks_port" \
    --argjson outbound_settings "$outbound_settings" \
    --argjson stream "$stream_settings" \
    --arg out_proto "$outbound_protocol" \
    '{
      log: { loglevel: "warning" },
      inbounds: [{
        port: $socks_port,
        listen: "127.0.0.1",
        protocol: "socks",
        settings: { auth: "noauth", udp: true }
      }],
      outbounds: [{
        protocol: $out_proto,
        settings: $outbound_settings,
        streamSettings: $stream
      }]
    }' > "$test_config" 2>/dev/null || return 1

  # Запускаем тестовый xray
  pkill -f "xray-vpn-test-client-${port}" 2>/dev/null || true
  nohup "$xray_bin" run -c "$test_config" > "$test_log" 2>&1 &
  local xray_pid=$!
  sleep 2.5   # даём время на запуск

  # Пробуем реальный запрос через прокси
  local test_result=1
  if curl -s -x "socks5h://127.0.0.1:${test_socks_port}" \
       --max-time 10 \
       -I "https://www.google.com" 2>/dev/null | head -1 | grep -q "200\|301\|302"; then
    test_result=0
  else
    # Фоллбэк на cloudflare или 1.1.1.1
    if curl -s -x "socks5h://127.0.0.1:${test_socks_port}" \
         --max-time 8 \
         -I "https://1.1.1.1" 2>/dev/null | head -1 | grep -q "200\|301"; then
      test_result=0
    fi
  fi

  # Чистим
  kill $xray_pid 2>/dev/null || true
  wait $xray_pid 2>/dev/null || true
  rm -f "$test_config"

  if [[ $test_result -eq 0 ]]; then
    log "Тест связки прошёл успешно (handshake + проксирование работает)"
    return 0
  else
    log "Тест связки не прошёл (не удалось установить соединение через этот инбаунд)"
    return 1
  fi
}

auto_setup() {
  echo
  log "=== АВТОНАСТРОЙКА ИНБАУНДОВ ==="
  log "Скрипт ищет самые рабочие связки и реально их проверяет:"
  log "  • VLESS + Reality и Trojan + Reality"
  log "  • Разные fingerprint (Chrome сейчас блокируют РКН)"
  log "  • Разные порты и SNI"
  log ""
  log "Как проверяется 'будет ли работать у пользователя в РФ':"
  log "  1. Создаём инбаунд на сервере"
  log "  2. Запускаем временный Xray-клиент с точными параметрами этой связки"
  log "  3. Пробуем реальный запрос (через SOCKS) на google.com / 1.1.1.1"
  log "  4. Если запрос прошёл — связка ВЕРИФИЦИРОВАНА"
  log "  5. Это не 100% гарантия от РКН, но сильно лучше чем просто 'порт слушается'"
  log "  Рекомендация: в клиенте используй тот же fingerprint, что выбрал скрипт"

  get_panel_settings

  if [[ -z "$PANEL_USER" || -z "$PANEL_PASS" ]]; then
    warn "Не удалось автоматически получить логин/пароль панели."
    read -p "Введи логин панели (обычно admin): " PANEL_USER
    read -p "Введи пароль панели: " PANEL_PASS
  fi

  if ! xui_login "$PANEL_PORT" "$WEB_BASE_PATH" "$PANEL_USER" "$PANEL_PASS"; then
    error "Не удалось войти в панель автоматически."
    echo "Войди в панель вручную и создай инбаунды:"
    show_panel_info
    return
  fi

  success "Успешный вход в панель"

  local ports=(443 8443 2053 2083 2096 80)
  local snis=("www.microsoft.com" "www.apple.com" "one.one.one.one" "chat.openai.com")
  # Важно: Chrome сейчас блокируют РКН. Пробуем разные fingerprint'ы в первую очередь
  local fingerprints=("firefox" "edge" "safari" "random" "chrome")
  local protocols=("vless-reality" "trojan-reality")   # разные связки, не только Reality
  local created=0

  echo
  log "Пробуем разные СВЯЗКИ (протокол + порт + fingerprint + SNI)..."
  log "Учитываем блокировки РКН (Chrome fingerprint под ударом)"

  for protocol in "${protocols[@]}"; do
    for port in "${ports[@]}"; do
      if ss -tlnp | grep -q ":${port} "; then
        continue
      fi

      for sni in "${snis[@]}"; do
        for fp in "${fingerprints[@]}"; do
          local remark="${protocol^^}-${port}"
          log "Пробуем ${protocol} | порт ${port} | fp=${fp} | ${sni} ..."

          # Capture structured output from create
          local create_output
          create_output=$(create_inbound "$port" "$sni" "$fp" "$protocol" "$remark" 2>/dev/null || true)

          if echo "$create_output" | grep -q "^LINK="; then
            # Parse structured data
            eval "$(echo "$create_output" | grep -E '^(LINK|PORT|SNI|FP|PROTO|CLIENT_ID|SHORT_ID|PUBLIC_KEY)=' )"

            if ss -tlnp | grep -q ":${PORT} "; then
              # === REAL VERIFICATION ===
              if verify_bundle "$PORT" "$SNI" "$FP" "$PROTO" "$CLIENT_ID" "$SHORT_ID" "$PUBLIC_KEY"; then
                success "✅ ВЕРИФИЦИРОВАНО: ${PROTO} порт ${PORT} fp=${FP} SNI=${SNI}"
                echo -e "${GREEN}${LINK}${NC}"
                echo "$LINK" >> "$INFO_FILE"
                ((created++))
                if [[ $created -ge 2 ]]; then
                  break 4
                fi
              else
                warn "Создано, но тест соединения НЕ прошёл — пропускаем эту связку"
              fi
            fi
          fi
          sleep 1
        done
      done
    done
  done

  echo
  if [[ $created -gt 0 ]]; then
    success "Автоматическая настройка завершена. Создано рабочих инбаундов: $created"
    echo "Готовые ссылки сохранены в $INFO_FILE"
  else
    warn "Не удалось автоматически создать ни одного инбаунда."
    echo "Зайди в панель вручную и создай инбаунды."
  fi
}

# ==================== МЕНЮ ПОСЛЕ УСТАНОВКИ ====================
post_install_menu() {
  get_panel_settings

  # Если это не первый запуск меню — не перезаписываем info файл агрессивно
  if [[ $MANAGEMENT_MODE -eq 0 ]]; then
    save_info_file
    echo
    success "$(t "Установка завершена!" "Installation complete!")"
    echo
  fi

  echo -e "${YELLOW}$(t "Меню управления Xray VPN" "Xray VPN management menu")${NC}"
  echo

  while true; do
    echo "1) $(t "Автоматическая настройка / добавить связки (с проверкой)" "Auto setup / add bundles (with verification)")"
    echo "2) $(t "Показать данные панели и ссылки" "Show panel credentials and links")"
    echo "3) $(t "Показать статус" "Show status")"
    echo "4) $(t "Перезапустить сервисы" "Restart services")"
    echo "5) $(t "Посмотреть логи" "View logs")"
    echo "6) $(t "Проверить скорость и пинг" "Speed test and ping")"
    echo "7) $(t "Выйти" "Exit")"
    echo
    read -p "$(t "Выбери вариант [1-7]: " "Choose option [1-7]: ")" choice

    case "$choice" in
      1)
        auto_setup
        ;;
      2)
        show_panel_info
        ;;
      3)
        show_quick_status
        ;;
      4)
        restart_services
        ;;
      5)
        show_logs
        ;;
      6)
        speed_test
        ;;
      7)
        echo
        success "$(t "Выход" "Exit")"
        exit 0
        ;;
      *)
        warn "$(t "Неверный выбор" "Invalid choice")"
        ;;
    esac
    echo
  done
}

# ==================== ГЛАВНАЯ ЛОГИКА ====================
main() {
  if [[ $MANAGEMENT_MODE -eq 1 ]]; then
    get_panel_settings

    case "$SUBCOMMAND" in
      status)
        show_quick_status
        exit 0
        ;;
      restart)
        restart_services
        exit 0
        ;;
      speed)
        speed_test
        exit 0
        ;;
      logs)
        show_logs
        exit 0
        ;;
      info)
        show_panel_info
        exit 0
        ;;
      menu|*)
        post_install_menu
        exit 0
        ;;
    esac
  fi

  : > "$INSTALL_LOG"

  print_header | tee -a "$INSTALL_LOG"
  check_root
  detect_os
  system_info

  # Защита SSH от отвала во время тяжёлой установки
  echo "Настраиваем SSH keepalive для стабильности соединения..." | tee -a "$INSTALL_LOG"
  sed -i 's/^#*ClientAliveInterval.*/ClientAliveInterval 60/' /etc/ssh/sshd_config 2>/dev/null || true
  sed -i 's/^#*ClientAliveCountMax.*/ClientAliveCountMax 3/' /etc/ssh/sshd_config 2>/dev/null || true
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

  log "Начинаем полную установку и настройку..."
  echo "   (Если SSH отвалится — зайди на сервер и набери: tmux attach -t vpn)" | tee -a "$INSTALL_LOG"
  echo | tee -a "$INSTALL_LOG"

  # Создаём команду vpn как можно раньше, чтобы пользователь не увидел "command not found",
  # если прервёт установку на середине.
  install_early_management_command

  # ==================== ЧИСТЫЕ ПОШАГОВЫЕ ПРОВЕРКИ ====================
  # Стиль: Проверка -> настраиваем (если нужно) -> sleep -> настроил
  # Всё идёт по очереди. Задержки между шагами для стабильности на слабых VPS.

  # Шаг 1: Swap
  echo "[1/6] Проверка swap..." | tee -a "$INSTALL_LOG"
  if swapon --show | grep -q '/swapfile'; then
    echo "  [ПРОПУСК] Swap уже настроен." | tee -a "$INSTALL_LOG"
  else
    echo "  настраиваем swap..." | tee -a "$INSTALL_LOG"
    setup_swap
    echo "  [ГОТОВО] swap настроен" | tee -a "$INSTALL_LOG"
  fi

  # Шаг 2: BBR + сеть
  echo "[2/6] Проверка BBR..." | tee -a "$INSTALL_LOG"
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    echo "  [ПРОПУСК] BBR уже включён." | tee -a "$INSTALL_LOG"
  else
    echo "  настраиваем BBR + оптимизации..." | tee -a "$INSTALL_LOG"
    apply_tuning
    echo "  [ГОТОВО] BBR настроен" | tee -a "$INSTALL_LOG"
  fi

  # Шаг 3: Firewall
  echo "[3/6] Проверка firewall (ufw)..." | tee -a "$INSTALL_LOG"
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    echo "  [ПРОПУСК] Firewall уже активен." | tee -a "$INSTALL_LOG"
  else
    echo "  настраиваем firewall (ufw)..." | tee -a "$INSTALL_LOG"
    setup_firewall
    echo "  [ГОТОВО] firewall настроен" | tee -a "$INSTALL_LOG"
  fi

  # Шаг 4: fail2ban
  echo "[4/6] Проверка fail2ban..." | tee -a "$INSTALL_LOG"
  if systemctl is-active fail2ban 2>/dev/null | grep -q active; then
    echo "  [ПРОПУСК] fail2ban уже запущен." | tee -a "$INSTALL_LOG"
  else
    echo "  настраиваем fail2ban..." | tee -a "$INSTALL_LOG"
    setup_fail2ban
    echo "  [ГОТОВО] fail2ban настроен" | tee -a "$INSTALL_LOG"
  fi

  # Шаг 5: 3x-ui / Xray
  echo "[5/6] Проверка 3x-ui..." | tee -a "$INSTALL_LOG"
  if [ -x /usr/local/x-ui/x-ui ]; then
    echo "  [ПРОПУСК] 3x-ui уже установлен. Обновляем данные панели..." | tee -a "$INSTALL_LOG"
    install_3x_ui
  else
    echo "  настраиваем 3x-ui (Xray + панель)..." | tee -a "$INSTALL_LOG"
    install_3x_ui
    echo "  [ГОТОВО] 3x-ui установлен" | tee -a "$INSTALL_LOG"
  fi

  # Шаг 6: Удобные команды + финал
  echo "[6/6] Финальная настройка..." | tee -a "$INSTALL_LOG"
  reset_panel_password
  install_management_command
  echo "  [ГОТОВО] финальная настройка завершена" | tee -a "$INSTALL_LOG"

  success "$(t "Установка завершена. Все проверки пройдены." "Installation complete. All checks passed.")"

  echo "" | tee -a "$INSTALL_LOG"
  echo "===========================================" | tee -a "$INSTALL_LOG"
  echo "  $(t "УСТАНОВКА ЗАВЕРШЕНА" "INSTALLATION COMPLETE")" | tee -a "$INSTALL_LOG"
  echo "===========================================" | tee -a "$INSTALL_LOG"
  echo "  $(t "Введите vpn  — для меню управления" "Type vpn  for management menu")" | tee -a "$INSTALL_LOG"
  echo "  $(t "Введите vpn info  — чтобы увидеть данные панели" "Type vpn info  to show panel credentials")" | tee -a "$INSTALL_LOG"
  echo "===========================================" | tee -a "$INSTALL_LOG"
  echo "" | tee -a "$INSTALL_LOG"

  post_install_menu
}

main "$@" 
