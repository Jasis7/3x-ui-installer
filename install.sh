#!/usr/bin/env bash
# =====================================================================
#  3x-ui installer · github.com/Jasis7/3x-ui-installer
#  Чистый сервер → свежая 3x-ui (последний релиз) + 7 протоколов одной командой.
#
#  Протоколы (каждый — отдельный инбаунд с тестовым клиентом):
#   1. VLESS + REALITY + Vision (TCP)        443/tcp
#   2. VLESS + XHTTP + REALITY               8443/tcp
#   3. Hysteria2                             443/udp
#   4. TUIC v5 (нативный сервер 3x-ui ≥3.9)  8443/udp
#   5. AmneziaWG (обфусцированный WireGuard) 51820/udp
#   6. Shadowsocks 2022                      9443/tcp+udp
#   7. MTProto (FakeTLS, для Telegram)       2443/tcp
#  Со своим доменом (флаг -D) дополнительно:
#   8. VLESS + TLS + Vision (сертификат LE)  2096/tcp
#   9. Trojan + TLS                          2087/tcp
#   + сайт-заглушка на домене (https://домен открывает обычный сайт),
#     REALITY маскируется под этот сайт («steal from yourself»),
#     Hysteria2/TUIC получают настоящий сертификат (без allowInsecure)
#   + по желанию CDN через Cloudflare (WS / HTTPUpgrade / XHTTP) — флаг -c
#
#  Запуск (root, Ubuntu 22.04+/Debian 12, чистый сервер):
#    bash install.sh
#    bash install.sh -b example.com -t CF_TOKEN          # ВСЁ СРАЗУ: домен в Cloudflare →
#        photo.example.com  — прямой TLS + REALITY под свой сайт + сайт-заглушка
#        static.example.com — Cloudflare CDN + та же заглушка
#        (имена можно поменять: -D свой.поддомен -c свой.поддомен)
#    bash install.sh -D vpn.example.com                  # свой домен (A-запись → IP сервера)
#    bash install.sh -D vpn.example.com -t CF_TOKEN      # домен в Cloudflare: запись создаст сам
#    bash install.sh -c cdn.example.com -t CF_TOKEN      # + Cloudflare CDN
#    bash install.sh -r www.microsoft.com                # свой REALITY-target
#    bash install.sh -o "1 2 3 5"                        # только выбранные протоколы
#    bash install.sh -v v3.11.0                          # конкретная версия панели
# =====================================================================
set -euo pipefail

REALITY_SNI="www.microsoft.com"; R_SET=0; ONLY=""; VERSION=""; CDN_DOMAIN=""; CF_TOKEN=""; DOMAIN=""; BASE=""; DEBUG=0
while getopts "r:o:v:c:t:D:b:d" o; do case $o in
  r) REALITY_SNI=$OPTARG; R_SET=1;; o) ONLY=$OPTARG;; v) VERSION=$OPTARG;;
  c) CDN_DOMAIN=$OPTARG;; t) CF_TOKEN=$OPTARG;; D) DOMAIN=$OPTARG;; b) BASE=$OPTARG;; d) DEBUG=1;;
  *) sed -n '2,34p' "$0"; exit 1;; esac; done

ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31m✖ %s\033[0m\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
rnd()  { tr -dc 'a-z0-9' </dev/urandom | head -c "$1"; }
want() { [[ " $ONLY " == *" $1 "* ]]; }

[[ $EUID -eq 0 ]] || die "Запустите от root"
if [[ -n $BASE ]]; then
  [[ -n $CF_TOKEN ]] || die "Для -b нужен токен Cloudflare: -t"
  BASE=${BASE#*://}; BASE=${BASE%%/*}
  DOMAIN=${DOMAIN:-photo.$BASE}; CDN_DOMAIN=${CDN_DOMAIN:-static.$BASE}
fi
[[ -n $CDN_DOMAIN && -z $CF_TOKEN ]] && die "Для -c нужен токен Cloudflare: -t"
[[ -n $DOMAIN && $DOMAIN == "$CDN_DOMAIN" ]] && die "-D и -c должны быть разными поддоменами (например vpn.… и cdn.…)"
if [[ -z $ONLY ]]; then ONLY="1 2 3 4 5 6 7"; [[ -n $DOMAIN ]] && ONLY+=" 8 9"; fi
REALITY_TARGET="$REALITY_SNI:443"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# ---------------------------------------------------------------- система
step "Система"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq curl jq openssl ca-certificates tar socat ufw >/dev/null
IP=$(curl -4 -s --max-time 8 https://api.ipify.org || curl -4 -s --max-time 8 ifconfig.me || true)
[[ $IP =~ ^[0-9.]+$ ]] || die "Не удалось узнать внешний IPv4 сервера"
ok "IP сервера: $IP"
if ! sysctl -n net.ipv4.tcp_congestion_control | grep -q bbr; then
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-bbr.conf
  sysctl -q --system >/dev/null 2>&1 || true
fi
ok "BBR: $(sysctl -n net.ipv4.tcp_congestion_control)"
for p in 80 443 8443 9443 2443 2096 2087; do ss -tlnH "( sport = :$p )" | grep -q . && die "Порт $p/tcp занят — скрипт рассчитан на чистый сервер"; done

# ---------------------------------------------------------------- панель
step "3x-ui ${VERSION:-(последний релиз)}"
if [[ -x /usr/local/x-ui/x-ui ]]; then
  die "3x-ui уже установлена. Этот скрипт — для чистого сервера (для существующей панели есть cdn.sh)"
fi
# Официальный установщик в неинтерактивном режиме: случайные логин/пароль/порт/путь,
# панель по HTTPS с сертификатом Let's Encrypt на IP (нужен открытый 80 порт).
curl -fsSL https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o /tmp/xui-install.sh
ufw allow 80/tcp >/dev/null 2>&1 || true
if ! XUI_NONINTERACTIVE=1 XUI_SSL_MODE=ip XUI_SERVER_IP="$IP" bash /tmp/xui-install.sh ${VERSION:+"$VERSION"} </dev/null >/tmp/xui-install.log 2>&1 \
   || [[ ! -f /etc/x-ui/install-result.env ]]; then
  if [[ -x /usr/local/x-ui/x-ui ]]; then
    warn "Сертификат на IP не выпустился (закрыт 80 порт у хостинга?) — панель останется на HTTP"
  else
    tail -30 /tmp/xui-install.log; die "Официальный установщик завершился с ошибкой (лог: /tmp/xui-install.log)"
  fi
fi
[[ -f /etc/x-ui/install-result.env ]] || die "Нет /etc/x-ui/install-result.env — установка не завершилась"
# shellcheck disable=SC1091
. /etc/x-ui/install-result.env
ok "Панель $( /usr/local/x-ui/x-ui -v ) установлена"

# API: локально, по Bearer-токену из install-result.env
WBP="${XUI_WEB_BASE_PATH#/}"; WBP="${WBP%/}"
API_BASE="https://127.0.0.1:${XUI_PANEL_PORT}/${WBP}"
curl -sk -o /dev/null --max-time 5 "$API_BASE/" || API_BASE="http://127.0.0.1:${XUI_PANEL_PORT}/${WBP}"
api() { # METHOD PATH [JSON]
  local a=(-sk --max-time 30 -X "$1" "$API_BASE$2" -H "Authorization: Bearer $XUI_API_TOKEN")
  [[ -n ${3:-} ]] && a+=(-H "Content-Type: application/json" --data "$3")
  curl "${a[@]}" || true; }
for _ in $(seq 20); do [[ $(api GET /panel/api/server/getNewUUID | jq -r .success 2>/dev/null) == true ]] && break; sleep 2; done
[[ $(api GET /panel/api/server/getNewUUID | jq -r .success 2>/dev/null) == true ]] || die "API панели не отвечает ($API_BASE)"
ok "API панели доступно"

# ---------------------------------------------------------------- свой домен: сертификат + сайт-заглушка
CERT_FILE=""; KEY_FILE=""; INSECURE=true
cf() { curl -sS -X "$1" "https://api.cloudflare.com/client/v4$2" -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" ${3:+--data "$3"}; }
if [[ -n $DOMAIN ]]; then
  step "Домен $DOMAIN"
  if [[ -n $CF_TOKEN ]]; then
    ZONE="$DOMAIN"; ZID=""
    while [[ $ZONE == *.* ]]; do
      ZID=$(cf GET "/zones?name=$ZONE" | jq -r '.result[0].id // empty' || true); [[ -n $ZID ]] && break; ZONE=${ZONE#*.}
    done
    [[ -n $ZID ]] || die "Зона для $DOMAIN не найдена в Cloudflare (у токена нет доступа к зоне?)"
    BODY=$(jq -nc --arg n "$DOMAIN" --arg ip "$IP" '{type:"A",name:$n,content:$ip,ttl:60,proxied:false}')
    REC=$(cf GET "/zones/$ZID/dns_records?type=A&name=$DOMAIN" | jq -r '.result[0].id // empty' || true)
    if [[ -n $REC ]]; then R=$(cf PUT "/zones/$ZID/dns_records/$REC" "$BODY" || true); else R=$(cf POST "/zones/$ZID/dns_records" "$BODY" || true); fi
    [[ $(jq -r .success <<<"$R" 2>/dev/null) == true ]] || die "Не удалось создать A-запись: $(jq -c .errors <<<"$R")"
    ok "A-запись $DOMAIN → $IP (серое облако, без проксирования)"
  else
    RES=$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}' || true)
    [[ $RES == "$IP" ]] || die "$DOMAIN указывает на '${RES:-ничего}', а нужно $IP. Создайте A-запись (в Cloudflare — серое облако) или передайте -t CF_TOKEN"
    ok "$DOMAIN → $IP"
  fi
  [[ -d ~/.acme.sh ]] || curl -fsSL https://get.acme.sh | sh -s email="admin@$DOMAIN" >/dev/null
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null
  if [[ -n $CF_TOKEN ]]; then
    export CF_Token="$CF_TOKEN" CF_Zone_ID="$ZID"
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256 >/dev/null 2>&1 || true
  else
    ~/.acme.sh/acme.sh --issue --standalone -d "$DOMAIN" --keylength ec-256 >/dev/null 2>&1 || true
  fi
  DCERT=/etc/x-ui/domain-cert; mkdir -p "$DCERT"
  ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file "$DCERT/fullchain.pem" --key-file "$DCERT/privkey.pem" \
    --reloadcmd "systemctl reload nginx 2>/dev/null; x-ui restart >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  [[ -s $DCERT/fullchain.pem ]] || die "Сертификат для $DOMAIN не выпущен (без -t нужен открытый 80 порт у хостинга)"
  chmod 600 "$DCERT/privkey.pem"
  CERT_FILE=$DCERT/fullchain.pem; KEY_FILE=$DCERT/privkey.pem; INSECURE=false
  ok "Сертификат Let's Encrypt выпущен, продлевается автоматически"

  apt-get install -y -qq nginx >/dev/null
  rm -f /etc/nginx/sites-enabled/default
  mkdir -p /var/www/decoy
  NAME=$(awk -F. '{print (NF>2)?$(NF-1):$1}' <<<"$DOMAIN"); NAME=${NAME^}
  cat > /var/www/decoy/index.html <<HTML
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$NAME — облачное хранилище фотографий</title>
<style>*{box-sizing:border-box}body{margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;color:#1d2433;background:#f6f7fb}
header{display:flex;justify-content:space-between;align-items:center;max-width:1040px;margin:auto;padding:22px 24px}
.logo{font-weight:800;font-size:22px;color:#3b5bfd}nav a{margin-left:22px;color:#4a5368;text-decoration:none;font-size:15px}
.hero{max-width:1040px;margin:40px auto;padding:0 24px;display:grid;grid-template-columns:1.1fr .9fr;gap:40px;align-items:center}
h1{font-size:44px;line-height:1.1;margin:0 0 18px}p{color:#5b6478;font-size:18px;line-height:1.6}
.btn{display:inline-block;margin-top:14px;background:#3b5bfd;color:#fff;padding:14px 26px;border-radius:12px;text-decoration:none;font-weight:600}
.card{background:#fff;border-radius:20px;box-shadow:0 20px 50px rgba(30,40,90,.12);padding:22px}
.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}.grid div{aspect-ratio:1;border-radius:12px;background:linear-gradient(135deg,#c9d4ff,#ffd9e8)}
.grid div:nth-child(3n){background:linear-gradient(135deg,#d2f5e3,#c9e3ff)}.grid div:nth-child(4n){background:linear-gradient(135deg,#ffe8c4,#ffc9c9)}
.f{max-width:1040px;margin:60px auto;padding:0 24px;display:grid;grid-template-columns:repeat(3,1fr);gap:24px}
.f div{background:#fff;border-radius:16px;padding:22px}.f h3{margin:0 0 8px}footer{text-align:center;color:#99a0b0;font-size:14px;padding:40px}
@media(max-width:800px){.hero,.f{grid-template-columns:1fr}h1{font-size:34px}}</style></head><body>
<header><div class="logo">$NAME</div><nav><a href="#">Возможности</a><a href="#">Тарифы</a><a href="#">Войти</a></nav></header>
<section class="hero"><div><h1>Все ваши фото — в одном месте</h1><p>Автоматическая загрузка с телефона, умные альбомы и семейный доступ. Ваши снимки хранятся в зашифрованном виде.</p><a class="btn" href="#">Попробовать бесплатно</a></div>
<div class="card"><div class="grid"><div></div><div></div><div></div><div></div><div></div><div></div><div></div><div></div><div></div></div></div></section>
<section class="f"><div><h3>Автозагрузка</h3><p>Фото и видео сохраняются сразу после съёмки.</p></div><div><h3>Альбомы</h3><p>Сортировка по датам, местам и людям.</p></div><div><h3>Семья</h3><p>Общие альбомы для близких.</p></div></section>
<footer>© $(date +%Y) $NAME</footer></body></html>
HTML
  cat > /etc/nginx/conf.d/decoy.conf <<NGX
# сайт-заглушка для $DOMAIN (создано 3x-ui-installer)
# цель REALITY («steal from yourself»): 443/tcp → Xray → сюда
server {
  listen 127.0.0.1:8001 ssl http2 default_server; server_name $DOMAIN;
  ssl_certificate $CERT_FILE; ssl_certificate_key $KEY_FILE;
  ssl_protocols TLSv1.2 TLSv1.3; ssl_session_cache shared:decoy:10m;
  add_header Strict-Transport-Security "max-age=31536000" always;
  root /var/www/decoy; index index.html; location / { try_files \$uri /index.html; }
}
# fallback для VLESS-TLS / Trojan (уже расшифрованный трафик)
server { listen 127.0.0.1:8002 default_server; server_name _; root /var/www/decoy; index index.html; location / { try_files \$uri /index.html; } }
NGX
  nginx -t >/dev/null 2>&1 || { nginx -t; die "Ошибка в конфиге nginx (/etc/nginx/conf.d/decoy.conf)"; }
  systemctl enable --now nginx >/dev/null 2>&1; systemctl reload nginx
  ok "Сайт-заглушка: https://$DOMAIN"
  if [[ $R_SET == 0 ]]; then REALITY_SNI=$DOMAIN; REALITY_TARGET=127.0.0.1:8001; ok "REALITY маскируется под свой сайт ($DOMAIN)"; fi
fi

# ---------------------------------------------------------------- сертификат для QUIC (Hysteria2, TUIC)
CERT_DIR=/etc/x-ui/quic-cert
if [[ -z $CERT_FILE ]] && { want 3 || want 4; }; then
  mkdir -p "$CERT_DIR"
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
    -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" -subj "/CN=$REALITY_SNI" \
    -addext "subjectAltName=DNS:$REALITY_SNI,IP:$IP" >/dev/null 2>&1
  chmod 600 "$CERT_DIR/key.pem"
  CERT_FILE=$CERT_DIR/cert.pem; KEY_FILE=$CERT_DIR/key.pem
  ok "Самоподписанный сертификат для Hysteria2/TUIC (в клиенте включить «allowInsecure»)"
fi
TLS_SNI=${DOMAIN:-$REALITY_SNI}

# ---------------------------------------------------------------- общие куски
SUB=$(rnd 16)
client() { jq -nc --arg e "$1" --arg s "$SUB" '{email:$e,limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$s,comment:"installer",reset:0}'; }
SNIFF='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'
CREATED=(); FAILED=()
add() { # name protocol port settings stream
  local body r
  body=$(jq -nc --arg remark "$1" --arg proto "$2" --argjson port "$3" --argjson s "$4" --argjson st "$5" --argjson sn "$SNIFF" \
    '{remark:$remark,enable:true,listen:"",port:$port,protocol:$proto,expiryTime:0,total:0,up:0,down:0,
      settings:$s,streamSettings:$st,sniffing:$sn}')
  r=$(api POST /panel/api/inbounds/add "$body")
  [[ $DEBUG == 1 ]] && { echo "--- $1 request:"; echo "$body"; echo "--- response:"; echo "$r"; }
  if [[ $(jq -r .success <<<"$r" 2>/dev/null) == true ]]; then ok "$1 — порт $3 (id $(jq -r .obj.id <<<"$r"))"; CREATED+=("$1")
  else warn "$1 не создан: $(jq -r '.msg // .' <<<"$r" | head -c 300)"; FAILED+=("$1"); fi; }

reality_stream() { # network extraJSON
  local kp; kp=$(api GET /panel/api/server/getNewX25519Cert)
  local priv pub; priv=$(jq -r .obj.privateKey <<<"$kp"); pub=$(jq -r .obj.publicKey <<<"$kp")
  [[ -n $priv && $priv != null ]] || { echo "ERR"; return; }
  jq -nc --arg net "$1" --argjson extra "$2" --arg sni "$REALITY_SNI" --arg tgt "$REALITY_TARGET" --arg priv "$priv" --arg pub "$pub" --arg sid "$(openssl rand -hex 8)" \
    '{network:$net,security:"reality",
      realitySettings:{show:false,xver:0,target:$tgt,serverNames:[$sni],privateKey:$priv,shortIds:[$sid],
        settings:{publicKey:$pub,fingerprint:"chrome",serverName:"",spiderX:"/"}}} + $extra'; }

# ---------------------------------------------------------------- инбаунды
step "Инбаунды"

if want 1; then
  ST=$(reality_stream tcp '{"tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}')
  S=$(jq -nc --arg id "$(cat /proc/sys/kernel/random/uuid)" --argjson c "$(client vision-$SUB)" \
    '{clients:[$c+{id:$id,flow:"xtls-rprx-vision"}],decryption:"none",encryption:"none",fallbacks:[]}')
  [[ $ST == ERR ]] && warn "REALITY-ключи не получены" || add "VLESS-Reality-Vision" vless 443 "$S" "$ST"
fi

if want 2; then
  ST=$(reality_stream xhttp "$(jq -nc --arg p "/$(rnd 10)" '{xhttpSettings:{path:$p,host:"",mode:"auto",headers:{}}}')")
  S=$(jq -nc --arg id "$(cat /proc/sys/kernel/random/uuid)" --argjson c "$(client xhttp-$SUB)" \
    '{clients:[$c+{id:$id,flow:""}],decryption:"none",encryption:"none",fallbacks:[]}')
  [[ $ST == ERR ]] && warn "REALITY-ключи не получены" || add "VLESS-XHTTP-Reality" vless 8443 "$S" "$ST"
fi

if want 3; then
  S=$(jq -nc --arg a "$(rnd 16)" --argjson c "$(client hy2-$SUB)" '{version:2,clients:[$c+{auth:$a}]}')
  ST=$(jq -nc --arg cf "$CERT_FILE" --arg kf "$KEY_FILE" --arg sni "$TLS_SNI" --argjson ins "$INSECURE" \
    '{network:"hysteria",security:"tls",
      tlsSettings:{serverName:$sni,alpn:["h3"],certificates:[{certificateFile:$cf,keyFile:$kf,ocspStapling:0,oneTimeLoading:false,usage:"encipherment",buildChain:false}],
        settings:{fingerprint:"",allowInsecure:$ins}},
      hysteriaSettings:{version:2,auth:"",udpIdleTimeout:60}}')
  add "Hysteria2" hysteria 443 "$S" "$ST"
fi

if want 4; then
  U=$(cat /proc/sys/kernel/random/uuid)
  S=$(jq -nc --arg u "$U" --arg pw "$(rnd 16)" --argjson c "$(client tuic-$SUB)" --arg cf "$CERT_FILE" --arg kf "$KEY_FILE" --arg sni "$TLS_SNI" \
    '{server:{certificate:$cf,private_key:$kf,congestion_control:"bbr",alpn:["h3"],udp_relay_mode:"native",zero_rtt_handshake:false,
       log_level:"warn",max_idle_time:15,authentication_timeout:3,max_udp_relay_packet_size:1500,sni:$sni},
      clients:[$c+{uuid:$u,id:$u,password:$pw}]}')
  add "TUIC-v5" tuic 8443 "$S" '{}'
fi

if want 5; then
  # Блок server не передаём: панель сама сгенерирует ключи и случайные параметры обфускации
  S=$(jq -nc --argjson c "$(client awg-$SUB)" '{clients:[$c]}')
  add "AmneziaWG" amneziawg 51820 "$S" '{}'
fi

if want 6; then
  S=$(jq -nc --arg sp "$(openssl rand -base64 32)" --arg cp "$(openssl rand -base64 32)" --argjson c "$(client ss-$SUB)" \
    '{method:"2022-blake3-aes-256-gcm",password:$sp,network:"tcp,udp",ivCheck:false,clients:[$c+{method:"",password:$cp}]}')
  add "Shadowsocks-2022" shadowsocks 9443 "$S" '{"network":"tcp","security":"none","tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}'
fi

if want 7; then
  S=$(jq -nc --argjson c "$(client mtproto-$SUB)" '{fakeTlsDomain:"www.cloudflare.com",clients:[$c]}')
  add "MTProto" mtproto 2443 "$S" '{}'
fi

tls_stream() { # ALPN-список JSON
  jq -nc --arg cf "$CERT_FILE" --arg kf "$KEY_FILE" --arg sni "$DOMAIN" --argjson alpn "$1" \
    '{network:"tcp",security:"tls",tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}},
      tlsSettings:{serverName:$sni,minVersion:"1.2",maxVersion:"1.3",cipherSuites:"",rejectUnknownSni:false,alpn:$alpn,
        certificates:[{certificateFile:$cf,keyFile:$kf,ocspStapling:0,oneTimeLoading:false,usage:"encipherment",buildChain:false}],
        settings:{fingerprint:"chrome",allowInsecure:false}}}'; }
FALLBACK='[{"name":"","alpn":"","path":"","dest":"8002","xver":0}]'

if want 8 || want 9; then [[ -n $DOMAIN ]] || warn "Протоколы 8 и 9 требуют свой домен (-D) — пропущены"; fi
if want 8 && [[ -n $DOMAIN ]]; then
  S=$(jq -nc --arg id "$(cat /proc/sys/kernel/random/uuid)" --argjson c "$(client tls-$SUB)" --argjson fb "$FALLBACK" \
    '{clients:[$c+{id:$id,flow:"xtls-rprx-vision"}],decryption:"none",encryption:"none",fallbacks:$fb}')
  add "VLESS-TLS-Vision" vless 2096 "$S" "$(tls_stream '["http/1.1"]')"
fi

if want 9 && [[ -n $DOMAIN ]]; then
  S=$(jq -nc --arg pw "$(rnd 20)" --argjson c "$(client trojan-$SUB)" --argjson fb "$FALLBACK" \
    '{clients:[$c+{password:$pw,flow:""}],fallbacks:$fb}')
  add "Trojan-TLS" trojan 2087 "$S" "$(tls_stream '["http/1.1"]')"
fi

# ---------------------------------------------------------------- фаервол
step "Фаервол (ufw)"
SSH_PORTS=$(ss -tlnpH 2>/dev/null | awk '/sshd/{n=split($4,a,":"); print a[n]}' | sort -u)
for p in ${SSH_PORTS:-22}; do ufw allow "$p/tcp" >/dev/null; done
ufw allow "${XUI_PANEL_PORT}/tcp" >/dev/null
for r in 80/tcp 443/tcp 443/udp 8443/tcp 8443/udp 51820/udp 9443/tcp 9443/udp 2443/tcp 2096/tcp 2087/tcp; do ufw allow "$r" >/dev/null; done
ufw --force enable >/dev/null
ok "Открыты: SSH ${SSH_PORTS:-22}, панель ${XUI_PANEL_PORT}, 80, 443, 8443, 51820/udp, 9443, 2443, 2096, 2087"

# ---------------------------------------------------------------- CDN (по желанию)
if [[ -n $CDN_DOMAIN ]]; then
  step "Cloudflare CDN"
  [[ -f $SCRIPT_DIR/cdn.sh ]] || curl -fsSL https://raw.githubusercontent.com/Jasis7/3x-ui-installer/main/cdn.sh -o "$SCRIPT_DIR/cdn.sh"
  bash "$SCRIPT_DIR/cdn.sh" -d "$CDN_DOMAIN" -t "$CF_TOKEN" -u "$XUI_USERNAME" -w "$XUI_PASSWORD" -l "$API_BASE/" -p 2053 \
    || warn "CDN не настроился — смотрите вывод выше, остальные протоколы работают"
fi

# ---------------------------------------------------------------- итог
OUT=/root/3x-ui-result.txt
LINKS=$(api GET /panel/api/inbounds/allLinks | jq -r '.obj // empty | if type=="array" then .[] else . end' 2>/dev/null || true)
{
  echo "ПАНЕЛЬ: ${XUI_ACCESS_URL}"
  [[ -n $DOMAIN ]] && echo "Сайт-заглушка: https://$DOMAIN"
  echo "Логин:  ${XUI_USERNAME}"
  echo "Пароль: ${XUI_PASSWORD}"
  echo
  echo "Подписка клиента (все протоколы): смотрите в панели → Клиенты → subId $SUB"
  echo
  echo "Ссылки:"
  echo "${LINKS:-(не удалось получить — откройте панель)}"
} > "$OUT"; chmod 600 "$OUT"

printf '\n\033[1m================ ГОТОВО ================\033[0m\n'
cat "$OUT"
echo
echo "Создано: ${#CREATED[@]} — ${CREATED[*]:-}"
[[ ${#FAILED[@]} -gt 0 ]] && echo "НЕ создано: ${FAILED[*]}  (повторите с -d, чтобы увидеть ответ панели)"
cat <<EOF

• Всё сохранено в $OUT (только для root).
$( [[ $INSECURE == true ]] && echo "• Hysteria2 и TUIC используют самоподписанный сертификат: в клиенте включите allowInsecure / «Пропустить проверку»." || echo "• Hysteria2, TUIC, VLESS-TLS и Trojan работают на сертификате Let's Encrypt для $DOMAIN." )
• AmneziaWG: конфиг клиента скачивается в панели (Инбаунды → AmneziaWG → клиент → QR/скачать), клиент — приложение AmneziaVPN.
• TUIC и AmneziaWG в ссылки выше могут не попасть — берите их из панели.
EOF
