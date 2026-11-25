#!/usr/bin/env bash
# =====================================================================
#  3x-cdn.sh — инбаунды VLESS за Cloudflare CDN для уже установленной 3x-ui
#  github.com/Jasis7/3x-ui-installer · cdn.sh (вызывается из install.sh -c, можно и отдельно)
#
#  Что делает:
#   1. Cloudflare (через API): A-запись с оранжевым облаком, WebSockets ON,
#      проверка режима SSL (Full strict) — то, на чём обычно всё и ломается.
#   2. Сертификат Let's Encrypt через DNS-01 (acme.sh + токен Cloudflare).
#   3. nginx на CDN-порту: TLS + маршрутизация путей в Xray, на корне сайт-заглушка.
#   4. Три инбаунда VLESS через API панели (слушают только 127.0.0.1):
#      WebSocket · HTTPUpgrade · XHTTP (packet-up).
#   5. Самопроверка через Cloudflare и готовые ссылки для клиентов.
#
#  Не трогает: существующие инбаунды (Reality на 443 и т.д.), клиентов, бота.
#
#  Запуск (от root, Ubuntu 22.04+/Debian 12):
#    bash cdn.sh -d cdn.kpamir.xyz -t CF_TOKEN [-p 2053] [-u admin -w пароль -l http://127.0.0.1:ПОРТ/ПУТЬ/]
#
#  Токен Cloudflare (My Profile → API Tokens → Create Custom Token), права:
#    Zone → Zone → Read;  Zone → DNS → Edit;  Zone → Zone Settings → Edit
#    Zone Resources: Include → Specific zone → kpamir.xyz
#
#  Порт: Cloudflare проксирует HTTPS только на 443, 2053, 2083, 2087, 2096, 8443.
#  Если 443 занят Reality — скрипт сам возьмёт 2053 (или укажите -p).
# =====================================================================
set -euo pipefail

DOMAIN=""; CF_TOKEN=""; PORT=""; P_USER=""; P_PASS=""; P_URL=""; EMAIL=""
while getopts "d:t:p:u:w:l:e:" o; do case $o in
  d) DOMAIN=$OPTARG;; t) CF_TOKEN=$OPTARG;; p) PORT=$OPTARG;;
  u) P_USER=$OPTARG;; w) P_PASS=$OPTARG;; l) P_URL=$OPTARG;; e) EMAIL=$OPTARG;;
  *) sed -n '2,30p' "$0"; exit 1;; esac; done

ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31m✖ %s\033[0m\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
rnd()  { tr -dc 'a-z0-9' </dev/urandom | head -c "$1"; }

[[ $EUID -eq 0 ]] || die "Запустите от root"
[[ -n $DOMAIN && -n $CF_TOKEN ]] || die "Нужны -d домен и -t токен Cloudflare (см. шапку скрипта)"
[[ -x /usr/local/x-ui/x-ui ]] || die "3x-ui не найдена. Сначала поставьте панель:  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)"
EMAIL=${EMAIL:-"admin@${DOMAIN#*.}"}
ZONE_NAME=$(awk -F. '{print $(NF-1)"."$NF}' <<<"$DOMAIN")

# ---------------------------------------------------------------- пакеты
step "Пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq nginx curl jq socat openssl >/dev/null
ok "nginx, curl, jq"

# ---------------------------------------------------------------- повторный запуск
CONF=/etc/nginx/conf.d/cdn-$DOMAIN.conf
[[ -f $CONF ]] && die "Для $DOMAIN уже настроено (ссылки: /root/3x-cdn-$DOMAIN.txt). Чтобы поставить заново: удалите $CONF и CDN-инбаунды в панели"

# ---------------------------------------------------------------- порт
step "Порт CDN"
CF_PORTS="443 2053 2083 2087 2096 8443"
busy() { ss -tlnH "( sport = :$1 )" | grep -q .; }
if [[ -z $PORT ]]; then
  for p in 443 2053 2083 2087 2096 8443; do busy "$p" || { PORT=$p; break; }; done
fi
[[ -n $PORT ]] || die "Все порты Cloudflare заняты"
grep -qw "$PORT" <<<"$CF_PORTS" || die "Порт $PORT Cloudflare не проксирует. Допустимы: $CF_PORTS"
busy "$PORT" && die "Порт $PORT занят другой программой: $(ss -tlnpH "( sport = :$PORT )" | head -1)"
ok "CDN будет на порту $PORT"

# ---------------------------------------------------------------- Cloudflare
step "Cloudflare"
cf() { curl -sS -X "$1" "https://api.cloudflare.com/client/v4$2" -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" ${3:+--data "$3"}; }
[[ $(cf GET /user/tokens/verify | jq -r .success) == true ]] || die "Токен Cloudflare не принят — проверьте, что скопировали его целиком"
ZID=$(cf GET "/zones?name=$ZONE_NAME" | jq -r '.result[0].id // empty')
[[ -n $ZID ]] || die "Зона $ZONE_NAME не найдена: у токена нет права Zone → Read на эту зону"
ok "Токен работает, зона $ZONE_NAME"

IP=$(curl -4 -s https://api.ipify.org || curl -4 -s ifconfig.me || true)
[[ $IP =~ ^[0-9.]+$ ]] || die "Не удалось узнать IP сервера"
REC=$(cf GET "/zones/$ZID/dns_records?type=A&name=$DOMAIN" | jq -r '.result[0].id // empty')
BODY=$(jq -nc --arg n "$DOMAIN" --arg ip "$IP" '{type:"A",name:$n,content:$ip,proxied:true,ttl:1}')
if [[ -n $REC ]]; then R=$(cf PUT "/zones/$ZID/dns_records/$REC" "$BODY"); else R=$(cf POST "/zones/$ZID/dns_records" "$BODY"); fi
[[ $(jq -r .success <<<"$R") == true ]] || die "DNS-запись не создана: $(jq -c .errors <<<"$R") — нужно право DNS → Edit"
ok "$DOMAIN → $IP, оранжевое облако (проксируется)"

R=$(cf PATCH "/zones/$ZID/settings/websockets" '{"value":"on"}')
[[ $(jq -r .success <<<"$R") == true ]] && ok "WebSockets включены" || warn "WebSockets не включились через API — включите вручную: Network → WebSockets"

SSL=$(cf GET "/zones/$ZID/settings/ssl" | jq -r '.result.value // "?"')
if [[ $SSL == strict || $SSL == full ]]; then ok "SSL/TLS: $SSL"
else
  warn "SSL/TLS зоны сейчас «$SSL». Для CDN нужен Full (strict)."
  warn "Это настройка ВСЕЙ зоны $ZONE_NAME: поддомены с оранжевым облаком без сертификата на сервере перестанут открываться."
  read -rp "  Переключить зону на Full (strict)? [y/N] " a
  if [[ $a == [yY]* ]]; then
    [[ $(cf PATCH "/zones/$ZID/settings/ssl" '{"value":"strict"}' | jq -r .success) == true ]] && ok "SSL/TLS → Full (strict)" || die "Не удалось сменить SSL — нужно право Zone Settings → Edit"
  else die "Без Full/Full (strict) CDN не заработает. Переключите в Cloudflare: SSL/TLS → Overview и запустите скрипт снова"; fi
fi

# ---------------------------------------------------------------- сертификат
step "Сертификат Let's Encrypt (DNS-01)"
CERT_DIR=/etc/ssl/cdn-$DOMAIN
if [[ -s $CERT_DIR/fullchain.pem ]] && openssl x509 -checkend 2592000 -noout -in "$CERT_DIR/fullchain.pem" >/dev/null; then
  ok "Действующий сертификат уже есть"
else
  [[ -d ~/.acme.sh ]] || curl -fsSL https://get.acme.sh | sh -s email="$EMAIL" >/dev/null
  export CF_Token="$CF_TOKEN" CF_Zone_ID="$ZID"
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null
  ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256 >/dev/null 2>&1 || \
  ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256 --force >/dev/null 2>&1 || true
  mkdir -p "$CERT_DIR"
  ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file "$CERT_DIR/fullchain.pem" --key-file "$CERT_DIR/privkey.pem" \
    --reloadcmd "systemctl reload nginx || true" >/dev/null
  [[ -s $CERT_DIR/fullchain.pem ]] || die "Сертификат не выпущен. Частая причина: у токена нет DNS → Edit"
  ok "Сертификат выпущен, продлевается автоматически"
fi

# ---------------------------------------------------------------- панель
step "Панель 3x-ui"
if [[ -z $P_URL ]]; then
  INFO=$(/usr/local/x-ui/x-ui setting -show true 2>/dev/null || true)
  PP=$(grep -oiE 'port: *[0-9]+' <<<"$INFO" | grep -oE "[0-9]+" | head -1 || true)
  PB=$(grep -oiE 'webBasePath: *[^ ]+' <<<"$INFO" | awk "{print \$2}" | head -1 || true)
  PB=${PB:-/}; [[ $PB == /* ]] || PB="/$PB"; [[ $PB == */ ]] || PB="$PB/"
  P_URL="http://127.0.0.1:${PP:-2053}${PB}"
fi
# если панель на https — ходим к ней по https без проверки сертификата (локально)
curl -s -o /dev/null --max-time 5 "$P_URL" || P_URL=${P_URL/http:/https:}
[[ -n $P_USER ]] || read -rp "  Логин панели: " P_USER
[[ -n $P_PASS ]] || { read -rsp "  Пароль панели: " P_PASS; echo; }
JAR=$(mktemp); trap 'rm -f "$JAR"' EXIT
L=$(curl -sk -c "$JAR" --data-urlencode "username=$P_USER" --data-urlencode "password=$P_PASS" "${P_URL}login")
[[ $(jq -r .success <<<"$L" 2>/dev/null) == true ]] || die "Вход в панель не удался ($P_URL). Укажите адрес вручную: -l http://127.0.0.1:ПОРТ/ПУТЬ/"
ok "Вход в панель: $P_URL"

UUID=$(cat /proc/sys/kernel/random/uuid); SUBID=$(rnd 16)
BASE=$((RANDOM % 5000 + 20000))
P_WS="/$(rnd 10)"; P_HU="/$(rnd 10)"; P_XH="/$(rnd 10)"
SNIFF='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'
settings() { jq -nc --arg id "$UUID" --arg e "$1" --arg s "$SUBID" '{clients:[{id:$id,flow:"",email:$e,limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:"",subId:$s,comment:"",reset:0}],decryption:"none",fallbacks:[]}'; }
add() { # remark port settings stream
  local r; r=$(curl -sk -b "$JAR" "${P_URL}panel/api/inbounds/add" \
    --data-urlencode "remark=$1" --data-urlencode "enable=true" --data-urlencode "listen=127.0.0.1" \
    --data-urlencode "port=$2" --data-urlencode "protocol=vless" --data-urlencode "expiryTime=0" \
    --data-urlencode "up=0" --data-urlencode "down=0" --data-urlencode "total=0" \
    --data-urlencode "settings=$3" --data-urlencode "streamSettings=$4" --data-urlencode "sniffing=$SNIFF")
  if [[ $(jq -r .success <<<"$r" 2>/dev/null) == true ]]; then ok "$1 (id $(jq -r '.obj.id' <<<"$r"))"; IDS+=("$(jq -r '.obj.id' <<<"$r")")
  else warn "$1 не создан: $(jq -r '.msg // .' <<<"$r")"; fi; }
IDS=()
step "Инбаунды (слушают только 127.0.0.1)"
add "CDN-WS"    $BASE       "$(settings cdn-ws-$SUBID)" "$(jq -nc --arg p "$P_WS" --arg h "$DOMAIN" '{network:"ws",security:"none",wsSettings:{path:$p,host:$h,headers:{}}}')"
add "CDN-HU"    $((BASE+1)) "$(settings cdn-hu-$SUBID)" "$(jq -nc --arg p "$P_HU" --arg h "$DOMAIN" '{network:"httpupgrade",security:"none",httpupgradeSettings:{path:$p,host:$h,headers:{}}}')"
add "CDN-XHTTP" $((BASE+2)) "$(settings cdn-xh-$SUBID)" "$(jq -nc --arg p "$P_XH" --arg h "$DOMAIN" '{network:"xhttp",security:"none",xhttpSettings:{path:$p,host:$h,headers:{},mode:"packet-up"}}')"
[[ ${#IDS[@]} -gt 0 ]] || die "Ни один инбаунд не создан"

# ---------------------------------------------------------------- nginx
step "nginx на порту $PORT"
mkdir -p /var/www/cdn-cover
# если install.sh уже сделал сайт-заглушку — используем её же
[[ -s /var/www/cdn-cover/index.html || ! -s /var/www/decoy/index.html ]] || cp /var/www/decoy/index.html /var/www/cdn-cover/
[[ -s /var/www/cdn-cover/index.html ]] || cat > /var/www/cdn-cover/index.html <<'HTML'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Welcome</title><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{font-family:system-ui,sans-serif;max-width:640px;margin:15vh auto;padding:0 20px;color:#333}</style></head><body><h1>Under construction</h1><p>This site is being updated. Please check back later.</p></body></html>
HTML
grep -rqs 'map $http_upgrade $connection_upgrade' /etc/nginx/ || MAPLINE='map $http_upgrade $connection_upgrade { default upgrade; "" close; }'
cat > "$CONF" <<EOF
# 3x-cdn.sh — $DOMAIN:$PORT → Xray (127.0.0.1)
${MAPLINE:-}
server {
    listen $PORT ssl;
    http2 on;
    server_name $DOMAIN;
    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    root /var/www/cdn-cover; index index.html;
    # Cloudflare передаёт настоящий IP клиента
    real_ip_header CF-Connecting-IP;

    location $P_WS {            # WebSocket
        proxy_pass http://127.0.0.1:$BASE;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_read_timeout 1h; proxy_send_timeout 1h;
    }
    location $P_HU {            # HTTPUpgrade
        proxy_pass http://127.0.0.1:$((BASE+1));
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_read_timeout 1h; proxy_send_timeout 1h;
    }
    location $P_XH {            # XHTTP
        proxy_pass http://127.0.0.1:$((BASE+2));
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_buffering off; proxy_request_buffering off;
        client_max_body_size 0;
        proxy_read_timeout 1h; proxy_send_timeout 1h;
    }
    location / { try_files \$uri \$uri/ =404; }
}
EOF
nginx -t >/dev/null 2>&1 || { nginx -t; die "Ошибка в конфиге nginx (файл $CONF)"; }
systemctl enable --now nginx >/dev/null 2>&1; systemctl reload nginx
command -v ufw >/dev/null && ufw status | grep -q active && ufw allow "$PORT/tcp" >/dev/null && ok "ufw: открыт $PORT/tcp"
ok "nginx слушает $PORT"

# ---------------------------------------------------------------- самопроверка
step "Проверка через Cloudflare (ждём DNS до 60 с)"
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN:$PORT$1" || echo 000; }
for i in $(seq 12); do [[ $(code /) == 200 ]] && break; sleep 5; done
C=$(code /)
case $C in
  200) ok "Сайт-заглушка открывается через Cloudflare" ;;
  526|525) die "Cloudflare $C: проблема с сертификатом на сервере (SSL Full strict не видит валидный сертификат)" ;;
  521|522|523) die "Cloudflare $C: не может достучаться до сервера на порту $PORT — проверьте фаервол хостинга" ;;
  000) warn "Нет ответа от $DOMAIN — DNS ещё обновляется, проверьте через пару минут" ;;
  *) warn "Корень сайта отвечает $C" ;;
esac
chk() { local c; c=$(code "$2"); case $c in 400|404|405) ok "$1: путь доходит до Xray ($c — так и должно быть без клиента)";; 502|504) warn "$1: Cloudflare доходит, но Xray не отвечает ($c) — инбаунд выключен?";; *) warn "$1: ответ $c";; esac; }
chk "WebSocket"   "$P_WS"
chk "HTTPUpgrade" "$P_HU"
chk "XHTTP"       "$P_XH"

# ---------------------------------------------------------------- ссылки
enc() { jq -rn --arg v "$1" '$v|@uri'; }
COMMON="encryption=none&security=tls&sni=$DOMAIN&fp=chrome&host=$DOMAIN"
L_WS="vless://$UUID@$DOMAIN:$PORT?$COMMON&alpn=http%2F1.1&type=ws&path=$(enc "$P_WS")#CDN-WS"
L_HU="vless://$UUID@$DOMAIN:$PORT?$COMMON&alpn=http%2F1.1&type=httpupgrade&path=$(enc "$P_HU")#CDN-HTTPUpgrade"
L_XH="vless://$UUID@$DOMAIN:$PORT?$COMMON&alpn=h2&type=xhttp&mode=packet-up&path=$(enc "$P_XH")#CDN-XHTTP"
OUT=/root/3x-cdn-$DOMAIN.txt
{ echo "domain=$DOMAIN port=$PORT inbound_ids=${IDS[*]}"; echo; echo "$L_WS"; echo "$L_HU"; echo "$L_XH"; } > "$OUT"; chmod 600 "$OUT"

printf '\n\033[1m================ ГОТОВО ================\033[0m\n'
cat "$OUT"
cat <<EOF

• Ссылки и ID инбаундов сохранены в $OUT
• Чтобы бот выдавал CDN-ключи клиентам, добавьте ID инбаундов (${IDS[*]})
  в XUI_INBOUND_IDS в .env бота и перезапустите его.
• Если через мобильный интернет не подключается, а через Wi-Fi работает —
  оператор режет Cloudflare или порт $PORT. Попробуйте запустить с другим -p (2083/8443).
EOF
