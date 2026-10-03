#!/usr/bin/env bash
#
# setup-nextcloud-aio-stack.sh
#
# Автоматическая установка на чистый Linux-сервер (Debian/Ubuntu):
#   1. Docker Engine + Docker Compose plugin
#   2. Nginx Proxy Manager (реверс-прокси) — домен и SSL настраиваются
#      автоматически через его REST API
#   3. Nextcloud AIO (All-in-One) за этим реверс-прокси
#
# ВАЖНО (прочитайте перед запуском):
#   Nextcloud AIO принципиально не даёт полностью безголовую установку —
#   разработчики сознательно сделали так, что пароль к панели AIO и
#   логин/пароль первого администратора Nextcloud создаются ТОЛЬКО через
#   веб-интерфейс мастер-контейнера (это подтверждено официальной
#   документацией: https://github.com/nextcloud/all-in-one). Ни один
#   скрипт не может обойти этот шаг — таких переменных окружения /
#   API-эндпоинтов Nextcloud AIO не предоставляет.
#
#   Поэтому скрипт делает МАКСИМУМ, что можно автоматизировать:
#     - ставит Docker и Compose
#     - поднимает Nginx Proxy Manager, меняет пароль администратора,
#       создаёт proxy host и заказывает Let's Encrypt сертификат для
#       вашего домена — полностью через API, без единого клика в UI
#     - поднимает мастер-контейнер Nextcloud AIO, правильно подключает
#       его к сети реверс-прокси (APACHE_PORT/APACHE_ADDITIONAL_NETWORK
#       по официальной схеме), ждёт поднятия контейнеров и сама
#       прописывает trusted_proxies внутри Nextcloud
#   А на 2-3 неизбежных ручных шага (задать пароль панели AIO, ввести
#   домен, скопировать сгенерированный логин/пароль администратора
#   Nextcloud) скрипт вас проведёт интерактивно и остановится ровно
#   там, где нужно нажать кнопку в браузере.
#
# Использование:
#   sudo bash setup-nextcloud-aio-stack.sh
#
# Скрипт идемпотентен: его можно перезапускать, уже поднятые шаги он
# будет пропускать.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Константы / пути
# ---------------------------------------------------------------------------
STACK_DIR="/opt/nextcloud-stack"
NPM_DIR="${STACK_DIR}/npm"
NPM_COMPOSE_FILE="${NPM_DIR}/docker-compose.yml"
NETWORK_NAME="reverse-proxy-net"
NETWORK_SUBNET="172.30.0.0/24"
NPM_CONTAINER_NAME="npm"
AIO_MASTER_CONTAINER="nextcloud-aio-mastercontainer"
AIO_APACHE_CONTAINER="nextcloud-aio-apache"
AIO_NEXTCLOUD_CONTAINER="nextcloud-aio-nextcloud"
APACHE_PORT="11000"
STATE_FILE="${STACK_DIR}/.install-state"
LOG_FILE="/var/log/nextcloud-aio-stack-install.log"

NPM_IMAGE="${NPM_IMAGE:-jc21/nginx-proxy-manager:latest}"
AIO_IMAGE="${AIO_IMAGE:-ghcr.io/nextcloud-releases/all-in-one:latest}"

# WireGuard VPN (wg-easy)
WG_CONTAINER_NAME="wg-easy"
WG_IMAGE="${WG_IMAGE:-ghcr.io/wg-easy/wg-easy:15}"
WG_NETWORK_NAME="wg-net"
WG_IPV4_CIDR="10.8.0.0/24"
WG_IPV6_CIDR="fd00:0:0:0::/64"

# RustDesk (свой сервер удалённого доступа)
RD_DATA_DIR="${STACK_DIR}/rustdesk/data"
RD_IMAGE="${RD_IMAGE:-rustdesk/rustdesk-server:latest}"

# ---------------------------------------------------------------------------
# Вывод / логирование
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_blue=$'\033[36m'

log()   { printf '%s[*]%s %s\n' "$c_blue"  "$c_reset" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$c_green" "$c_reset" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$c_yellow" "$c_reset" "$*"; }
err()   { printf '%s[x]%s %s\n' "$c_red"   "$c_reset" "$*" >&2; }
step()  { printf '\n%s==> %s%s\n' "$c_bold" "$*" "$c_reset"; }
pause() { read -r -p "$(printf '%s      Нажмите Enter, чтобы продолжить...%s ' "$c_yellow" "$c_reset")" _; }

trap 'err "Скрипт прерван на строке $LINENO. Подробности в лог-файле: $LOG_FILE"' ERR

# Скрипт интерактивный (использует read/pause). Если его запустили одной
# командой вида "curl ... | sudo bash" — его собственный stdin занят потоком
# самого скрипта, а не терминалом, и все вопросы ниже останутся без ответа.
# Переключаем stdin на реальный терминал, если он есть, чтобы такой запуск
# тоже работал.
if [[ -r /dev/tty ]] && ! [[ -t 0 ]]; then
  exec < /dev/tty
fi

# ---------------------------------------------------------------------------
# Предварительные проверки
# ---------------------------------------------------------------------------
step "Проверка окружения"

if [[ $EUID -ne 0 ]]; then
  err "Запускайте скрипт от root (sudo bash $0)"
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  err "Скрипт поддерживает только Debian/Ubuntu (нужен apt-get). Обнаружен другой дистрибутив."
  exit 1
fi

mkdir -p "$STACK_DIR"
touch "$STATE_FILE"
state_has() { grep -qxF "$1" "$STATE_FILE" 2>/dev/null; }
state_set() { state_has "$1" || echo "$1" >> "$STATE_FILE"; }

ok "Базовые проверки пройдены"

# ---------------------------------------------------------------------------
# Установка базовых утилит
# ---------------------------------------------------------------------------
step "Установка вспомогательных пакетов (curl, jq, dnsutils, ca-certificates...)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl jq dnsutils ca-certificates gnupg lsb-release openssl >/dev/null
ok "Пакеты установлены"

# ---------------------------------------------------------------------------
# Интерактивный сбор параметров
# ---------------------------------------------------------------------------
step "Параметры установки"

read -r -p "Домен для Nextcloud (например, cloud.example.com): " NC_DOMAIN
while [[ -z "$NC_DOMAIN" ]]; do
  read -r -p "Домен обязателен. Введите домен для Nextcloud: " NC_DOMAIN
done

read -r -p "E-mail для Let's Encrypt и учётной записи админа Nginx Proxy Manager: " ADMIN_EMAIL
while [[ -z "$ADMIN_EMAIL" ]]; do
  read -r -p "E-mail обязателен: " ADMIN_EMAIL
done

while true; do
  read -r -s -p "Пароль администратора Nginx Proxy Manager (мин. 8 символов): " NPM_ADMIN_PASSWORD
  echo
  read -r -s -p "Повторите пароль: " NPM_ADMIN_PASSWORD_CONFIRM
  echo
  if [[ "$NPM_ADMIN_PASSWORD" != "$NPM_ADMIN_PASSWORD_CONFIRM" ]]; then
    warn "Пароли не совпадают, попробуйте ещё раз"
  elif [[ ${#NPM_ADMIN_PASSWORD} -lt 8 ]]; then
    warn "Слишком короткий пароль, нужно минимум 8 символов"
  else
    break
  fi
done

log "По умолчанию (как и в стандартной установке Nextcloud AIO) панель на порту 8080"
log "доступна снаружи напрямую по IP сервера и защищена паролем, который вы зададите"
log "при первом входе — отдельный SSH-туннель для этого не нужен."
read -r -p "Ограничить панель AIO (порт 8080) только localhost вместо доступа извне? [y/N]: " AIO_RESTRICT
AIO_RESTRICT="${AIO_RESTRICT,,}"
if [[ "$AIO_RESTRICT" == "y" || "$AIO_RESTRICT" == "yes" ]]; then
  AIO_BIND="127.0.0.1"
  log "Панель AIO будет доступна только с самого сервера. Доступ снаружи — через SSH-туннель:"
  log "  ssh -L 8080:localhost:8080 <ваш_пользователь>@<ip_сервера>"
  log "  затем откройте в браузере: https://localhost:8080"
else
  AIO_BIND="0.0.0.0"
  log "Панель AIO будет доступна на https://<IP_сервера>:8080 — стандартная схема AIO (логин через пароль панели)."
fi

step "Дополнительные сервисы"

read -r -p "Установить WireGuard VPN для безопасного удалённого доступа (через wg-easy)? [Y/n]: " INSTALL_WG
INSTALL_WG="${INSTALL_WG,,}"
if [[ "$INSTALL_WG" == "n" || "$INSTALL_WG" == "no" ]]; then INSTALL_WG="no"; else INSTALL_WG="yes"; fi

if [[ "$INSTALL_WG" == "yes" ]]; then
  read -r -p "Домен/поддомен для веб-панели WireGuard (например vpn.${NC_DOMAIN#*.}): " WG_DOMAIN
  while [[ -z "$WG_DOMAIN" ]]; do
    read -r -p "Домен обязателен для веб-панели WireGuard: " WG_DOMAIN
  done
  read -r -p "Имя администратора VPN-панели [admin]: " WG_ADMIN_USER
  WG_ADMIN_USER="${WG_ADMIN_USER:-admin}"
  while true; do
    read -r -s -p "Пароль администратора VPN-панели (мин. 8 символов): " WG_ADMIN_PASSWORD
    echo
    read -r -s -p "Повторите пароль: " WG_ADMIN_PASSWORD_CONFIRM
    echo
    if [[ "$WG_ADMIN_PASSWORD" != "$WG_ADMIN_PASSWORD_CONFIRM" ]]; then
      warn "Пароли не совпадают, попробуйте ещё раз"
    elif [[ ${#WG_ADMIN_PASSWORD} -lt 8 ]]; then
      warn "Слишком короткий пароль, нужно минимум 8 символов"
    else
      break
    fi
  done
fi

read -r -p "Установить RustDesk-сервер — свой удалённый доступ вместо TeamViewer/AnyDesk (hbbs+hbbr)? [Y/n]: " INSTALL_RD
INSTALL_RD="${INSTALL_RD,,}"
if [[ "$INSTALL_RD" == "n" || "$INSTALL_RD" == "no" ]]; then INSTALL_RD="no"; else INSTALL_RD="yes"; fi

RD_VPN_ONLY="no"
if [[ "$INSTALL_RD" == "yes" && "$INSTALL_WG" == "yes" ]]; then
  log "RustDesk шифрует соединение собственным ключом и обычно держат его порты открытыми в интернет — это штатный режим его работы (так советует сам RustDesk, иначе хуже работает проброс соединения через NAT)."
  read -r -p "Всё же ограничить порты RustDesk только VPN-подсетью (${WG_IPV4_CIDR}) через firewall? [y/N]: " RD_VPN_ONLY_IN
  RD_VPN_ONLY_IN="${RD_VPN_ONLY_IN,,}"
  if [[ "$RD_VPN_ONLY_IN" == "y" || "$RD_VPN_ONLY_IN" == "yes" ]]; then RD_VPN_ONLY="yes"; fi
fi

read -r -p "Установить Fail2ban для защиты SSH от перебора паролей? [Y/n]: " INSTALL_F2B
INSTALL_F2B="${INSTALL_F2B,,}"
if [[ "$INSTALL_F2B" == "n" || "$INSTALL_F2B" == "no" ]]; then INSTALL_F2B="no"; else INSTALL_F2B="yes"; fi

step "Проверка DNS для $NC_DOMAIN"
SERVER_IP="$(curl -fsS4 --max-time 5 https://ifconfig.me 2>/dev/null || curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
DOMAIN_IP="$(dig +short A "$NC_DOMAIN" | tail -n1 || true)"
if [[ -n "$SERVER_IP" && -n "$DOMAIN_IP" ]]; then
  if [[ "$SERVER_IP" == "$DOMAIN_IP" ]]; then
    ok "A-запись $NC_DOMAIN -> $DOMAIN_IP совпадает с IP сервера ($SERVER_IP)"
  else
    warn "A-запись $NC_DOMAIN указывает на $DOMAIN_IP, а IP этого сервера — $SERVER_IP."
    warn "Let's Encrypt не сможет выпустить сертификат, пока DNS не будет исправлен."
    read -r -p "Продолжить всё равно? [y/N]: " CONT
    [[ "${CONT,,}" == "y" ]] || exit 1
  fi
else
  warn "Не удалось автоматически проверить DNS (нет внешней сети?). Продолжаю без проверки."
fi

echo
log "Итоговые параметры:"
log "  Домен Nextcloud:        $NC_DOMAIN"
log "  E-mail (LE / NPM):      $ADMIN_EMAIL"
log "  Панель AIO слушает на:  ${AIO_BIND}:8080"
log "  WireGuard VPN:          $([[ "$INSTALL_WG" == "yes" ]] && echo "да -> https://${WG_DOMAIN}" || echo "нет")"
log "  RustDesk-сервер:        $([[ "$INSTALL_RD" == "yes" ]] && echo "да$([[ "$RD_VPN_ONLY" == "yes" ]] && echo " (только через VPN)")" || echo "нет")"
log "  Fail2ban (SSH):         $([[ "$INSTALL_F2B" == "yes" ]] && echo "да" || echo "нет")"
pause

# ---------------------------------------------------------------------------
# Установка Docker
# ---------------------------------------------------------------------------
step "Установка Docker"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ok "Docker и Docker Compose уже установлены ($(docker --version))"
else
  log "Устанавливаю Docker через официальный скрипт get.docker.com..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
  systemctl enable --now docker
  ok "Docker установлен: $(docker --version)"
fi

if ! docker compose version >/dev/null 2>&1; then
  err "Docker Compose plugin не найден после установки Docker. Установите вручную: apt-get install docker-compose-plugin"
  exit 1
fi

# ---------------------------------------------------------------------------
# Сеть Docker для реверс-прокси
# ---------------------------------------------------------------------------
step "Создание общей docker-сети ${NETWORK_NAME}"
if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  ok "Сеть $NETWORK_NAME уже существует"
else
  docker network create --subnet "$NETWORK_SUBNET" "$NETWORK_NAME" >/dev/null
  ok "Сеть $NETWORK_NAME создана (подсеть $NETWORK_SUBNET)"
fi

# ---------------------------------------------------------------------------
# Развёртывание Nginx Proxy Manager
# ---------------------------------------------------------------------------
step "Развёртывание Nginx Proxy Manager"
mkdir -p "$NPM_DIR"

cat > "$NPM_COMPOSE_FILE" <<EOF
services:
  npm:
    image: ${NPM_IMAGE}
    container_name: ${NPM_CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "81:81"
    environment:
      # Поддерживается новыми версиями NPM для автоматической настройки
      # первого администратора. Старыми версиями игнорируется — тогда
      # скрипт сам произведёт смену пароля через API (см. ниже).
      INITIAL_ADMIN_EMAIL: "${ADMIN_EMAIL}"
      INITIAL_ADMIN_PASSWORD: "${NPM_ADMIN_PASSWORD}"
    volumes:
      - npm_data:/data
      - npm_letsencrypt:/etc/letsencrypt
    networks:
      - ${NETWORK_NAME}

networks:
  ${NETWORK_NAME}:
    external: true

volumes:
  npm_data:
  npm_letsencrypt:
EOF

(cd "$NPM_DIR" && docker compose up -d)
ok "Nginx Proxy Manager запущен"

step "Ожидание готовности API Nginx Proxy Manager"
NPM_API="http://127.0.0.1:81/api"
for i in $(seq 1 60); do
  if curl -fsS --max-time 3 "${NPM_API}/" >/dev/null 2>&1; then
    ok "API Nginx Proxy Manager отвечает"
    break
  fi
  sleep 2
  if [[ $i -eq 60 ]]; then
    err "API Nginx Proxy Manager не поднялся за отведённое время. Проверьте: docker logs ${NPM_CONTAINER_NAME}"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Авторизация в NPM API + при необходимости смена дефолтного пароля
# ---------------------------------------------------------------------------
step "Настройка администратора Nginx Proxy Manager через API"

npm_login() {
  # $1 identity, $2 secret -> печатает token в stdout, либо пусто при неудаче
  curl -fsS --max-time 10 -X POST "${NPM_API}/tokens" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg identity "$1" --arg secret "$2" '{identity:$identity, secret:$secret}')" \
    2>/dev/null | jq -r '.token // empty'
}

NPM_TOKEN="$(npm_login "$ADMIN_EMAIL" "$NPM_ADMIN_PASSWORD" || true)"

if [[ -n "$NPM_TOKEN" ]]; then
  ok "Вход выполнен под учётной записью $ADMIN_EMAIL (INITIAL_ADMIN_* сработал)"
else
  log "Пробую войти под стандартными первоначальными данными NPM (admin@example.com / changeme)..."
  DEFAULT_TOKEN="$(npm_login "admin@example.com" "changeme" || true)"
  if [[ -n "$DEFAULT_TOKEN" ]]; then
    log "Меняю почту и пароль администратора на указанные вами..."
    USER_ID="$(curl -fsS --max-time 10 "${NPM_API}/users/me" -H "Authorization: Bearer ${DEFAULT_TOKEN}" | jq -r '.id')"
    curl -fsS --max-time 10 -X PUT "${NPM_API}/users/${USER_ID}" \
      -H "Authorization: Bearer ${DEFAULT_TOKEN}" -H 'Content-Type: application/json' \
      -d "$(jq -n --arg email "$ADMIN_EMAIL" --arg name "Admin" --arg nickname "Admin" \
            '{email:$email, name:$name, nickname:$nickname}')" >/dev/null
    curl -fsS --max-time 10 -X PUT "${NPM_API}/users/${USER_ID}/auth" \
      -H "Authorization: Bearer ${DEFAULT_TOKEN}" -H 'Content-Type: application/json' \
      -d "$(jq -n --arg cur "changeme" --arg new "$NPM_ADMIN_PASSWORD" \
            '{type:"password", current:$cur, secret:$new}')" >/dev/null
    NPM_TOKEN="$(npm_login "$ADMIN_EMAIL" "$NPM_ADMIN_PASSWORD" || true)"
    if [[ -n "$NPM_TOKEN" ]]; then
      ok "Учётная запись администратора NPM обновлена и подтверждена"
    fi
  fi
fi

if [[ -z "${NPM_TOKEN:-}" ]]; then
  warn "Не удалось автоматически авторизоваться в API Nginx Proxy Manager."
  warn "Откройте http://<IP_сервера>:81 вручную, войдите (admin@example.com / changeme, если это первый запуск)"
  warn "и задайте почту/пароль. Дальнейшие шаги (proxy host, сертификат) тогда тоже придётся сделать в UI:"
  warn "  Domain Names: ${NC_DOMAIN}; Forward Hostname: ${AIO_APACHE_CONTAINER}; Forward Port: ${APACHE_PORT}; Scheme: http"
  warn "  SSL: заказать Let's Encrypt, включить Force SSL, HTTP/2, HSTS."
  NPM_AUTOMATED="no"
else
  NPM_AUTOMATED="yes"
fi

# ---------------------------------------------------------------------------
# Универсальная функция: proxy host + Let's Encrypt сертификат через NPM API
# ---------------------------------------------------------------------------
# Аргументы: domain forward_host forward_port advanced_config state_prefix
# Результат кладёт id хоста в ${STACK_DIR}/.npm_proxy_host_id_<state_prefix>
npm_create_proxy_with_ssl() {
  local domain="$1" fhost="$2" fport="$3" advanced="$4" prefix="$5"
  local payload resp hostid cert_resp cert_id

  if state_has "${prefix}_proxy_host_created"; then
    ok "[$domain] proxy host уже был создан ранее, пропускаю"
    return 0
  fi

  step "Создание proxy host для ${domain}"
  payload="$(jq -n \
    --arg domain "$domain" --arg host "$fhost" --argjson port "$fport" --arg advanced "$advanced" \
    '{domain_names: [$domain], forward_scheme: "http", forward_host: $host, forward_port: $port,
      block_exploits: true, allow_websocket_upgrade: true, caching_enabled: false,
      advanced_config: $advanced, enabled: true}')"

  resp="$(curl -fsS --max-time 15 -X POST "${NPM_API}/nginx/proxy-hosts" \
    -H "Authorization: Bearer ${NPM_TOKEN}" -H 'Content-Type: application/json' \
    -d "$payload" || true)"
  hostid="$(echo "$resp" | jq -r '.id // empty')"

  if [[ -z "$hostid" ]]; then
    warn "Не удалось создать proxy host для $domain через API (ответ: $(echo "$resp" | head -c 300))"
    warn "Создайте его вручную в UI: домен $domain -> forward host $fhost, порт $fport, схема http."
    return 1
  fi

  ok "Proxy host создан (id=$hostid) -> $fhost:$fport"
  state_set "${prefix}_proxy_host_created"
  echo "$hostid" > "${STACK_DIR}/.npm_proxy_host_id_${prefix}"

  step "Заказ сертификата Let's Encrypt для ${domain}"
  cert_resp="$(curl -fsS --max-time 90 -X POST "${NPM_API}/nginx/certificates" \
    -H "Authorization: Bearer ${NPM_TOKEN}" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg domain "$domain" --arg email "$ADMIN_EMAIL" \
          '{provider:"letsencrypt", domain_names:[$domain],
            meta:{dns_challenge:false, letsencrypt_email:$email, letsencrypt_agree:true}}')" || true)"
  cert_id="$(echo "$cert_resp" | jq -r '.id // empty')"

  if [[ -z "$cert_id" ]]; then
    log "Повторная попытка с упрощённым телом запроса..."
    cert_resp="$(curl -fsS --max-time 90 -X POST "${NPM_API}/nginx/certificates" \
      -H "Authorization: Bearer ${NPM_TOKEN}" -H 'Content-Type: application/json' \
      -d "$(jq -n --arg domain "$domain" '{provider:"letsencrypt", domain_names:[$domain], meta:{dns_challenge:false}}')" || true)"
    cert_id="$(echo "$cert_resp" | jq -r '.id // empty')"
  fi

  if [[ -n "$cert_id" ]]; then
    ok "Сертификат Let's Encrypt выпущен (id=$cert_id)"
    curl -fsS --max-time 15 -X PUT "${NPM_API}/nginx/proxy-hosts/${hostid}" \
      -H "Authorization: Bearer ${NPM_TOKEN}" -H 'Content-Type: application/json' \
      -d "$(jq -n --argjson cert "$cert_id" \
            '{certificate_id:$cert, ssl_forced:true, http2_support:true, hsts_enabled:true, hsts_subdomains:false}')" >/dev/null
    ok "SSL включён для proxy host (Force SSL, HTTP/2, HSTS)"
    state_set "${prefix}_cert_attached"
  else
    warn "Не удалось автоматически заказать сертификат для $domain (ответ API: $(echo "$cert_resp" | head -c 300))"
    warn "Наиболее частая причина — DNS для $domain ещё не указывает на этот сервер, либо порт 80 закрыт файрволом."
    warn "Закажите сертификат вручную в UI Nginx Proxy Manager (http://<IP>:81), когда DNS будет готов."
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Proxy host + Let's Encrypt сертификат для Nextcloud
# ---------------------------------------------------------------------------
if [[ "$NPM_AUTOMATED" == "yes" ]]; then
  NC_ADVANCED_CONFIG='client_max_body_size 0;
proxy_read_timeout 3610s;
proxy_send_timeout 3610s;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;'
  npm_create_proxy_with_ssl "$NC_DOMAIN" "$AIO_APACHE_CONTAINER" "$APACHE_PORT" "$NC_ADVANCED_CONFIG" "nc" || true
fi

# ---------------------------------------------------------------------------
# Развёртывание Nextcloud AIO
# ---------------------------------------------------------------------------
step "Развёртывание Nextcloud AIO (мастер-контейнер)"

if docker inspect "$AIO_MASTER_CONTAINER" >/dev/null 2>&1; then
  ok "Мастер-контейнер Nextcloud AIO уже существует, пропускаю создание"
else
  docker volume create nextcloud_aio_mastercontainer >/dev/null

  docker run -d \
    --init \
    --sig-proxy=false \
    --name "$AIO_MASTER_CONTAINER" \
    --restart unless-stopped \
    --publish "${AIO_BIND}:8080:8080" \
    --env APACHE_PORT="$APACHE_PORT" \
    --env APACHE_IP_BINDING="127.0.0.1" \
    --env APACHE_ADDITIONAL_NETWORK="$NETWORK_NAME" \
    --env SKIP_DOMAIN_VALIDATION="false" \
    --volume nextcloud_aio_mastercontainer:/mnt/docker-aio-config \
    --volume /var/run/docker.sock:/var/run/docker.sock:ro \
    "$AIO_IMAGE" >/dev/null

  ok "Мастер-контейнер Nextcloud AIO запущен"
fi

log "Жду появления ссылки для первого входа в панель AIO в логах контейнера..."
AIO_LOGIN_URL=""
for i in $(seq 1 30); do
  AIO_LOGIN_URL="$(docker logs "$AIO_MASTER_CONTAINER" 2>&1 | grep -oE 'https?://[^[:space:]]*token=[^[:space:]"]*' | tail -n1 || true)"
  [[ -n "$AIO_LOGIN_URL" ]] && break
  sleep 2
done

echo
echo "======================================================================"
echo " ШАГ 1 ИЗ 2 — нужно сделать руками в браузере (это НЕЛЬЗЯ автоматизировать:"
echo " так задумано разработчиками Nextcloud AIO ради безопасности)"
echo "======================================================================"
if [[ -n "$AIO_LOGIN_URL" ]]; then
  echo "Откройте ссылку для первого входа в панель AIO (она войдёт в систему без пароля один раз):"
  echo
  echo "  $AIO_LOGIN_URL"
  echo
  if [[ "$AIO_BIND" == "127.0.0.1" ]]; then
    warn "Если открываете с другого компьютера — сначала пробросьте порт:"
    warn "  ssh -L 8080:localhost:8080 <пользователь>@<IP_сервера>"
    warn "и замените в ссылке хост на localhost."
  fi
else
  warn "Не нашёл готовую ссылку в логах. Откройте панель AIO напрямую:"
  echo "  https://<IP_сервера_или_localhost>:8080"
fi
echo
echo "В открывшейся панели сделайте по порядку:"
echo "  1) Задайте пароль ДЛЯ САМОЙ ПАНЕЛИ AIO (это и есть 'ключ от панели админа' — придумайте его сейчас, он нигде не генерируется автоматически)"
echo "  2) В поле домена введите:  ${NC_DOMAIN}"
echo "  3) Нажмите 'Validate domain'. Если увидите ошибку — это нормально, контейнер Apache ещё не запущен."
echo "  4) Нажмите 'Save and start containers' — начнётся скачивание образов и запуск Apache/Nextcloud."
echo "     Дальше можно не ждать в браузере — вернитесь в этот терминал, скрипт сам дождётся готовности."
pause

step "Ожидание запуска контейнеров Nextcloud (Apache и сам Nextcloud)"
log "Это может занять несколько минут — идёт скачивание образов и первичная инициализация."
APACHE_UP="no"
NC_UP="no"
for i in $(seq 1 180); do
  if [[ "$APACHE_UP" == "no" ]] && docker inspect "$AIO_APACHE_CONTAINER" >/dev/null 2>&1; then
    APACHE_UP="yes"
    ok "Контейнер $AIO_APACHE_CONTAINER обнаружен"
  fi
  if [[ "$NC_UP" == "no" ]] && docker inspect "$AIO_NEXTCLOUD_CONTAINER" >/dev/null 2>&1; then
    NC_UP="yes"
    ok "Контейнер $AIO_NEXTCLOUD_CONTAINER обнаружен"
  fi
  [[ "$APACHE_UP" == "yes" && "$NC_UP" == "yes" ]] && break
  sleep 5
  printf '.'
done
echo

if [[ "$APACHE_UP" != "yes" ]]; then
  warn "Контейнер Apache так и не появился за отведённое время."
  warn "Проверьте прогресс в панели AIO (https://<IP>:8080) и, при необходимости, перезапустите скрипт — он идемпотентен."
fi

# Прописываем доверенный прокси внутри Nextcloud, как только контейнер готов
if [[ "$NC_UP" == "yes" ]] && ! state_has "trusted_proxies_set"; then
  step "Настройка trusted_proxies внутри Nextcloud"
  for i in $(seq 1 30); do
    if docker exec --user www-data "$AIO_NEXTCLOUD_CONTAINER" php occ status >/dev/null 2>&1; then
      docker exec --user www-data "$AIO_NEXTCLOUD_CONTAINER" \
        php occ config:system:set trusted_proxies 0 --value="$NETWORK_SUBNET" >/dev/null 2>&1 \
        && ok "trusted_proxies выставлен в $NETWORK_SUBNET" \
        && state_set "trusted_proxies_set" \
        && break
    fi
    sleep 5
  done
  state_has "trusted_proxies_set" || warn "Не успел выставить trusted_proxies автоматически — сделайте вручную позже:"
  warn "  docker exec --user www-data $AIO_NEXTCLOUD_CONTAINER php occ config:system:set trusted_proxies 0 --value=\"$NETWORK_SUBNET\""
fi

# Повторно убеждаемся, что proxy host в NPM смотрит на apache-контейнер
if [[ "$NPM_AUTOMATED" == "yes" && "$APACHE_UP" == "yes" && -f "${STACK_DIR}/.npm_proxy_host_id_nc" ]]; then
  PROXY_HOST_ID="$(cat "${STACK_DIR}/.npm_proxy_host_id_nc")"
  NPM_TOKEN="$(npm_login "$ADMIN_EMAIL" "$NPM_ADMIN_PASSWORD" || true)"
  if [[ -n "$NPM_TOKEN" ]]; then
    curl -fsS --max-time 15 -X PUT "${NPM_API}/nginx/proxy-hosts/${PROXY_HOST_ID}" \
      -H "Authorization: Bearer ${NPM_TOKEN}" -H 'Content-Type: application/json' \
      -d "$(jq -n --arg host "$AIO_APACHE_CONTAINER" --argjson port "$APACHE_PORT" \
            '{forward_scheme:"http", forward_host:$host, forward_port:$port}')" >/dev/null 2>&1 || true
  fi
fi

if [[ "$APACHE_UP" != "yes" || "$NC_UP" != "yes" ]]; then
  echo
  echo "======================================================================"
  echo " Контейнеры ещё не готовы — при необходимости завершите шаги в панели AIO"
  echo " (https://<IP_сервера>:8080), затем нажмите Enter, чтобы продолжить."
  echo "======================================================================"
  pause
fi

echo
echo "======================================================================"
echo " ШАГ 2 ИЗ 2 — логин и пароль первого администратора Nextcloud"
echo "======================================================================"
echo "Как только контейнеры поднимутся, панель AIO САМА сгенерирует и покажет"
echo "одноразово логин (обычно 'admin') и длинный случайный пароль — это и"
echo "есть 'ключи от первого аккаунта админа'. Nextcloud AIO не даёт задать"
echo "их заранее через скрипт или переменные окружения — только показывает"
echo "один раз в этом экране. Скопируйте их сразу, затем откройте:"
echo
echo "  https://${NC_DOMAIN}"
echo
echo "и войдите под этими данными."
echo "======================================================================"
echo

# ---------------------------------------------------------------------------
# WireGuard VPN (wg-easy)
# ---------------------------------------------------------------------------
if [[ "$INSTALL_WG" == "yes" ]]; then
  step "Развёртывание WireGuard VPN (wg-easy)"

  if ! docker network inspect "$WG_NETWORK_NAME" >/dev/null 2>&1; then
    docker network create --subnet "$WG_IPV4_CIDR" "$WG_NETWORK_NAME" >/dev/null
    ok "Сеть $WG_NETWORK_NAME создана (подсеть $WG_IPV4_CIDR)"
  fi

  if docker inspect "$WG_CONTAINER_NAME" >/dev/null 2>&1; then
    ok "Контейнер $WG_CONTAINER_NAME уже существует, пропускаю создание"
  else
    WG_PUBLIC_IP="${SERVER_IP:-}"
    if [[ -z "$WG_PUBLIC_IP" ]]; then
      WG_PUBLIC_IP="$(curl -fsS4 --max-time 5 https://ifconfig.me 2>/dev/null || curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    fi
    if [[ -z "$WG_PUBLIC_IP" ]]; then
      warn "Не удалось определить публичный IP сервера — в качестве адреса подключения клиентов будет указан $NC_DOMAIN."
      WG_PUBLIC_IP="$NC_DOMAIN"
    fi

    docker run -d \
      --name "$WG_CONTAINER_NAME" \
      --restart unless-stopped \
      --cap-add NET_ADMIN --cap-add SYS_MODULE \
      --sysctl net.ipv4.conf.all.src_valid_mark=1 \
      --sysctl net.ipv4.ip_forward=1 \
      --publish 51820:51820/udp \
      --publish 51821:51821/tcp \
      --network "$WG_NETWORK_NAME" \
      --env INIT_ENABLED=true \
      --env INIT_USERNAME="$WG_ADMIN_USER" \
      --env INIT_PASSWORD="$WG_ADMIN_PASSWORD" \
      --env INIT_HOST="$WG_PUBLIC_IP" \
      --env INIT_PORT=51820 \
      --env INIT_IPV4_CIDR="$WG_IPV4_CIDR" \
      --env INIT_IPV6_CIDR="$WG_IPV6_CIDR" \
      --volume wg_easy_data:/etc/wireguard \
      "$WG_IMAGE" >/dev/null

    ok "WireGuard (wg-easy) запущен, клиентам раздаётся подсеть $WG_IPV4_CIDR"
  fi

  # Подключаем wg-easy и к сети реверс-прокси, чтобы NPM мог проксировать его веб-панель по имени контейнера
  docker network connect "$NETWORK_NAME" "$WG_CONTAINER_NAME" >/dev/null 2>&1 || true

  log "Жду готовности веб-панели WireGuard..."
  for i in $(seq 1 30); do
    curl -fsS --max-time 3 "http://127.0.0.1:51821/" >/dev/null 2>&1 && break
    sleep 2
  done

  if [[ "$NPM_AUTOMATED" == "yes" ]]; then
    npm_create_proxy_with_ssl "$WG_DOMAIN" "$WG_CONTAINER_NAME" "51821" "" "wg" || true
  else
    warn "Настройте proxy host для $WG_DOMAIN -> $WG_CONTAINER_NAME:51821 (http) вручную в UI NPM."
  fi
fi

# ---------------------------------------------------------------------------
# RustDesk-сервер (hbbs + hbbr)
# ---------------------------------------------------------------------------
if [[ "$INSTALL_RD" == "yes" ]]; then
  step "Развёртывание RustDesk-сервера (hbbs + hbbr)"
  mkdir -p "$RD_DATA_DIR"

  if docker inspect hbbs >/dev/null 2>&1; then
    ok "Контейнеры RustDesk уже существуют, пропускаю создание"
  else
    # network_mode: host — официальная рекомендация RustDesk, иначе хуже работает
    # проброс соединения через NAT (см. документацию rustdesk-server-oss).
    docker run -d --name hbbr --restart unless-stopped --network host \
      -v "${RD_DATA_DIR}:/root" "$RD_IMAGE" hbbr >/dev/null
    docker run -d --name hbbs --restart unless-stopped --network host \
      -v "${RD_DATA_DIR}:/root" "$RD_IMAGE" hbbs >/dev/null
    ok "RustDesk-сервер запущен (hbbs+hbbr, порты 21115-21119 TCP и 21116 UDP)"
  fi

  log "Жду генерации ключа сервера..."
  RD_PUBKEY=""
  for i in $(seq 1 30); do
    if [[ -f "${RD_DATA_DIR}/id_ed25519.pub" ]]; then
      RD_PUBKEY="$(cat "${RD_DATA_DIR}/id_ed25519.pub")"
      break
    fi
    sleep 2
  done

  if [[ "$RD_VPN_ONLY" == "yes" ]]; then
    step "Ограничение доступа к RustDesk только из VPN-подсети ${WG_IPV4_CIDR}"
    apt-get install -y -qq iptables-persistent >/dev/null 2>&1 || true
    # Порядок важен: ACCEPT из VPN-подсети должен оказаться ВЫШЕ общего DROP.
    iptables -C INPUT -p tcp --dport 21115:21119 -j DROP 2>/dev/null \
      || iptables -I INPUT -p tcp --dport 21115:21119 -j DROP
    iptables -C INPUT -p udp --dport 21116 -j DROP 2>/dev/null \
      || iptables -I INPUT -p udp --dport 21116 -j DROP
    iptables -C INPUT -p tcp --dport 21115:21119 -s "$WG_IPV4_CIDR" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p tcp --dport 21115:21119 -s "$WG_IPV4_CIDR" -j ACCEPT
    iptables -C INPUT -p udp --dport 21116 -s "$WG_IPV4_CIDR" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p udp --dport 21116 -s "$WG_IPV4_CIDR" -j ACCEPT
    netfilter-persistent save >/dev/null 2>&1 || true
    ok "Порты RustDesk теперь принимают подключения только из подсети VPN ($WG_IPV4_CIDR)"
    warn "Подключиться к RustDesk теперь можно только после подключения к WireGuard VPN."
  fi
fi

# ---------------------------------------------------------------------------
# Fail2ban
# ---------------------------------------------------------------------------
if [[ "$INSTALL_F2B" == "yes" ]]; then
  step "Установка и настройка Fail2ban (защита SSH)"
  apt-get install -y -qq fail2ban >/dev/null
  cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled  = true
backend  = systemd
EOF
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
  ok "Fail2ban установлен и защищает SSH (5 неверных попыток за 10 минут -> бан на 1 час)"
  warn "Веб-панели (NPM/AIO/WireGuard) Fail2ban НЕ защищает: их логи внутри Docker-контейнеров, а блокировка"
  warn "Docker-портов требует отдельной настройки цепочки DOCKER-USER. Основная защита для них — длинные"
  warn "пароли (уже заданы) и, при желании, перевод этих панелей на доступ только через VPN."
fi

echo
ok "Установка инфраструктуры завершена."
log "Логи установки сохранены в $LOG_FILE"
log "Docker-compose Nginx Proxy Manager: $NPM_COMPOSE_FILE"
log "Панель Nginx Proxy Manager: http://<IP_сервера>:81  (логин: $ADMIN_EMAIL)"
if [[ "$INSTALL_WG" == "yes" ]]; then
  log "WireGuard VPN панель: https://${WG_DOMAIN}  (логин: $WG_ADMIN_USER)"
fi
if [[ "$INSTALL_RD" == "yes" ]]; then
  log "RustDesk-сервер: ID-адрес сервера = IP этого сервера; публичный ключ для клиентов:"
  log "  ${RD_PUBKEY:-<не успел сгенерироваться, проверьте ${RD_DATA_DIR}/id_ed25519.pub>}"
fi
if [[ "$INSTALL_F2B" == "yes" ]]; then
  log "Fail2ban активен для SSH (проверить: fail2ban-client status sshd)"
fi
