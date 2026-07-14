#!/bin/bash
#
# xray-vpn-install.sh
# Автоматическая установка и настройка Xray VPN для Ubuntu VPS
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
#   curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash
# или
#   bash install.sh
#

set -euo pipefail

# ==================== ЦВЕТА ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ==================== ПЕРЕМЕННЫЕ ====================
INSTALL_LOG="/var/log/xray-vpn-install.log"
XUI_INSTALL_LOG="/tmp/3xui_install.log"
JAR="/tmp/xui_cookies.txt"
INFO_FILE="/root/xray-vpn-info.txt"

PANEL_PORT=""
PANEL_USER=""
PANEL_PASS=""
WEB_BASE_PATH="/"

# ==================== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ====================
log()    { echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$INSTALL_LOG"; }
success(){ echo -e "${GREEN}[УСПЕХ]${NC} $1" | tee -a "$INSTALL_LOG"; }
warn()   { echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1" | tee -a "$INSTALL_LOG"; }
error()  { echo -e "${RED}[ОШИБКА]${NC} $1" | tee -a "$INSTALL_LOG"; }

print_header() {
  clear
  echo -e "${CYAN}"
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║           АВТОМАТИЧЕСКАЯ НАСТРОЙКА XRAY VPN                ║"
  echo "║                  (Ubuntu • RU VPN • лучшие настройки)      ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
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

system_info() {
  local mem=$(free -m | awk '/Mem:/ {print $2}')
  local cpu=$(nproc)
  local disk=$(df -h / | awk 'NR==2 {print $4}')
  echo
  log "RAM: ${mem}MB | CPU: ${cpu} ядер | Свободно на диске: ${disk}"
}

# ==================== 1. ОБНОВЛЕНИЕ СИСТЕМЫ ====================
update_system() {
  log "Обновление системы и установка базовых пакетов..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >> "$INSTALL_LOG" 2>&1
  apt-get upgrade -y >> "$INSTALL_LOG" 2>&1
  apt-get install -y curl wget jq unzip ca-certificates ufw fail2ban sqlite3 net-tools >> "$INSTALL_LOG" 2>&1
  success "Система обновлена"
}

# ==================== 2. УМНЫЙ SWAP ====================
setup_swap() {
  log "Настройка swap (умный подбор)..."

  local mem_mb=$(free -m | awk '/Mem:/ {print $2}')
  local swap_size=1024

  if [[ $mem_mb -le 1024 ]]; then
    swap_size=2048
  elif [[ $mem_mb -le 2048 ]]; then
    swap_size=2048
  elif [[ $mem_mb -le 4096 ]]; then
    swap_size=2048
  else
    swap_size=1024
  fi

  if swapon --show | grep -q '/swapfile'; then
    log "Swap уже существует. Пропускаем создание."
    return
  fi

  log "Создаём swapfile размером ${swap_size}MB (на основе ${mem_mb}MB RAM)..."

  swapoff /swapfile 2>/dev/null || true
  rm -f /swapfile

  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${swap_size}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$swap_size status=none
  else
    dd if=/dev/zero of=/swapfile bs=1M count=$swap_size status=none
  fi

  chmod 600 /swapfile
  mkswap /swapfile >> "$INSTALL_LOG" 2>&1
  swapon /swapfile

  if ! grep -q '^/swapfile ' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  sysctl -w vm.swappiness=10 >> "$INSTALL_LOG" 2>&1
  if ! grep -q 'vm.swappiness' /etc/sysctl.conf; then
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
  fi

  success "Swap создан: ${swap_size}MB, swappiness=10"
  free -h | grep -E 'Mem|Swap' | tee -a "$INSTALL_LOG"
}

# ==================== 3. ЛУЧШИЕ ОПТИМИЗАЦИИ (BBR + сеть) ====================
apply_tuning() {
  log "Применяем лучшие сетевые оптимизации (BBR, буферы, Reality-friendly)..."

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
  log "Настройка ufw (firewall)..."

  ufw --force reset >> "$INSTALL_LOG" 2>&1 || true
  ufw default deny incoming >> "$INSTALL_LOG" 2>&1
  ufw default allow outgoing >> "$INSTALL_LOG" 2>&1

  ufw allow 22/tcp comment 'SSH' >> "$INSTALL_LOG" 2>&1
  ufw allow 443/tcp comment 'Xray Reality' >> "$INSTALL_LOG" 2>&1

  # Панель откроем позже, когда узнаем порт

  ufw --force enable >> "$INSTALL_LOG" 2>&1
  success "UFW включён (22 + 443 открыты)"
}

# ==================== 5. FAIL2BAN ====================
setup_fail2ban() {
  log "Установка и настройка fail2ban..."

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

  systemctl restart fail2ban >> "$INSTALL_LOG" 2>&1
  sleep 1

  if systemctl is-active --quiet fail2ban; then
    success "fail2ban запущен и настроен"
  else
    warn "fail2ban установлен, но не запустился (проверь вручную)"
  fi
}

# ==================== 6. УСТАНОВКА 3X-UI + XRAY ====================
install_3x_ui() {
  log "Установка 3x-ui (Xray + панель)..."

  rm -f "$XUI_INSTALL_LOG"

  curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh -o /tmp/3xui_installer.sh 2>>"$INSTALL_LOG"

  if [[ ! -s /tmp/3xui_installer.sh ]]; then
    error "Не удалось скачать установщик 3x-ui"
    exit 1
  fi

  log "Запуск установщика 3x-ui (неинтерактивно)..."
  export DEBIAN_FRONTEND=noninteractive

  # Запускаем с yes n чтобы отвечать "нет" на вопросы
  yes n | bash /tmp/3xui_installer.sh 2>&1 | tee "$XUI_INSTALL_LOG" || true

  sleep 3

  if [[ -x /usr/local/x-ui/x-ui ]]; then
    success "3x-ui установлен"
  else
    error "3x-ui не установился. Посмотри лог: $XUI_INSTALL_LOG"
    exit 1
  fi

  # Пытаемся вытащить данные из лога установщика
  PANEL_PORT=$(grep -oP 'port:\s*\K[0-9]+' "$XUI_INSTALL_LOG" | tail -1 || true)
  PANEL_USER=$(grep -oP '(?i)username:?\s*\K\S+' "$XUI_INSTALL_LOG" | tail -1 || true)
  PANEL_PASS=$(grep -oP '(?i)password:?\s*\K\S+' "$XUI_INSTALL_LOG" | tail -1 || true)

  # Если не нашли — пробуем через x-ui setting
  if [[ -z "$PANEL_PORT" ]]; then
    PANEL_PORT=$(/usr/local/x-ui/x-ui setting -show 2>/dev/null | grep -oP 'port:\s*\K[0-9]+' | head -1 || echo "2053")
  fi

  # Открываем порт панели
  if [[ -n "$PANEL_PORT" ]]; then
    ufw allow "${PANEL_PORT}/tcp" comment '3x-ui Panel' >> "$INSTALL_LOG" 2>&1 || true
  fi

  # Перезапускаем
  systemctl restart x-ui 2>/dev/null || true

  success "Xray + 3x-ui готовы"
}

# ==================== ПОЛУЧЕНИЕ ДАННЫХ ПАНЕЛИ ====================
get_panel_settings() {
  local out
  out=$(/usr/local/x-ui/x-ui setting -show 2>/dev/null || true)

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

  # Пробуем через x-ui setting (если поддерживается)
  if /usr/local/x-ui/x-ui setting --help 2>&1 | grep -qi "username"; then
    /usr/local/x-ui/x-ui setting --username "$new_user" --password "$new_pass" 2>/dev/null || true
    PANEL_USER="$new_user"
    PANEL_PASS="$new_pass"
    success "Пароль панели сброшен на новый (для автонастройки)"
  fi
}

save_info_file() {
  mkdir -p "$(dirname "$INFO_FILE")"
  {
    echo "=== АВТОМАТИЧЕСКАЯ НАСТРОЙКА XRAY VPN ($(date)) ==="
    echo "IP: $(curl -s4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
    echo "Панель порт: ${PANEL_PORT}"
    echo "Логин: ${PANEL_USER}"
    echo "Пароль: ${PANEL_PASS}"
    echo ""
    echo "Вход в панель: http://$(hostname -I | awk '{print $1}'):${PANEL_PORT}${WEB_BASE_PATH}"
    echo ""
    echo "Swap и оптимизации применены"
    echo "fail2ban активен"
    echo "BBR активен (если поддерживается)"
  } > "$INFO_FILE"
  chmod 600 "$INFO_FILE"
  log "Данные сохранены в $INFO_FILE"
}

show_panel_info() {
  echo
  echo -e "${GREEN}=== ДАННЫЕ ДЛЯ ВХОДА В ПАНЕЛЬ ===${NC}"
  local ip
  ip=$(curl -s4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  echo "IP: $ip"
  echo "Порт панели: ${PANEL_PORT}"
  echo "Логин: ${PANEL_USER}"
  echo "Пароль: ${PANEL_PASS}"
  echo
  echo "Ссылка: http://${ip}:${PANEL_PORT}${WEB_BASE_PATH}"
  echo
  echo "Файл с информацией: $INFO_FILE"
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

  local header=""
  [[ -n "$csrf" ]] && header="-H \"X-CSRF-Token: $csrf\""

  local login_url="${base_url}login"
  local resp
  resp=$(curl -sk -b "$JAR" -c "$JAR" $header \
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
  local header=""
  [[ -n "$csrf" ]] && header="-H \"X-CSRF-Token: $csrf\""

  local resp
  resp=$(curl -sk -b "$JAR" -c "$JAR" $header \
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
    error "Не удалось войти в панель. Проверь данные вручную."
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
  save_info_file

  echo
  success "Установка завершена!"
  echo
  echo -e "${YELLOW}Что хочешь сделать дальше?${NC}"
  echo

  while true; do
    echo "1) Автоматическая настройка (рекомендуется) — разные связки + проверка"
    echo "2) Показать данные для входа в панель"
    echo "3) Выйти"
    echo
    read -p "Выбери вариант [1-3]: " choice

    case "$choice" in
      1)
        auto_setup
        ;;
      2)
        show_panel_info
        ;;
      3)
        echo
        success "Готово! Информация сохранена в $INFO_FILE"
        echo "Можешь теперь зайти в панель и добавить клиентов."
        exit 0
        ;;
      *)
        warn "Неверный выбор"
        ;;
    esac
    echo
  done
}

# ==================== ГЛАВНАЯ ЛОГИКА ====================
main() {
  print_header
  check_root
  detect_os
  system_info

  : > "$INSTALL_LOG"

  log "Начинаем полную установку и настройку..."

  update_system
  setup_swap
  apply_tuning
  setup_firewall
  setup_fail2ban
  install_3x_ui

  # Пытаемся сделать пароль удобным для автонастройки
  reset_panel_password

  post_install_menu
}

main "$@" 
