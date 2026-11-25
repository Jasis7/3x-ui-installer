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
#   + по желанию CDN через Cloudflare (WS / HTTPUpgrade / XHTTP) — флаг -c
#
#  Запуск (root, Ubuntu 22.04+/Debian 12, чистый сервер):
#    bash install.sh
#    bash install.sh -c cdn.example.com -t CF_TOKEN      # + Cloudflare CDN
#    bash install.sh -r www.microsoft.com                # свой REALITY-target
#    bash install.sh -o "1 2 3 5"                        # только выбранные протоколы
#    bash install.sh -v v3.11.0                          # конкретная версия панели
# =====================================================================
set -euo pipefail

REALITY_SNI="www.microsoft.com"; ONLY="1 2 3 4 5 6 7"; VERSION=""; CDN_DOMAIN=""; CF_TOKEN=""; DEBUG=0
while getopts "r:o:v:c:t:d" o; do case $o in
  r) REALITY_SNI=$OPTARG;; o) ONLY=$OPTARG;; v) VERSION=$OPTARG;;
  c) CDN_DOMAIN=$OPTARG;; t) CF_TOKEN=$OPTARG;; d) DEBUG=1;;
  *) sed -n '2,22p' "$0"; exit 1;; esac; done

ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31m✖ %s\033[0m\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
rnd()  { tr -dc 'a-z0-9' </dev/urandom | head -c "$1"; }
want() { [[ " $ONLY " == *" $1 "* ]]; }

[[ $EUID -eq 0 ]] || die "Запустите от root"
[[ -n $CDN_DOMAIN && -z $CF_TOKEN ]] && die "Для -c нужен токен Cloudflare: -t"
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
for p in 443 8443 9443 2443; do ss -tlnH "( sport = :$p )" | grep -q . && die "Порт $p/tcp занят — скрипт рассчитан на чистый сервер"; done

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
for i in $(seq 20); do [[ $(api GET /panel/api/server/getNewUUID | jq -r .success 2>/dev/null) == true ]] && break; sleep 2; done
[[ $(api GET /panel/api/server/getNewUUID | jq -r .success 2>/dev/null) == true ]] || die "API панели не отвечает ($API_BASE)"
ok "API панели доступно"

# ---------------------------------------------------------------- сертификат для QUIC (Hysteria2, TUIC)
CERT_DIR=/etc/x-ui/quic-cert
if want 3 || want 4; then
  mkdir -p "$CERT_DIR"
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
    -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" -subj "/CN=$REALITY_SNI" \
    -addext "subjectAltName=DNS:$REALITY_SNI,IP:$IP" >/dev/null 2>&1
  chmod 600 "$CERT_DIR/key.pem"
  ok "Самоподписанный сертификат для Hysteria2/TUIC (в клиенте включить «allowInsecure»)"
fi

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
  jq -nc --arg net "$1" --argjson extra "$2" --arg sni "$REALITY_SNI" --arg priv "$priv" --arg pub "$pub" --arg sid "$(openssl rand -hex 8)" \
    '{network:$net,security:"reality",
      realitySettings:{show:false,xver:0,target:($sni+":443"),serverNames:[$sni],privateKey:$priv,shortIds:[$sid],
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
  ST=$(jq -nc --arg cf "$CERT_DIR/cert.pem" --arg kf "$CERT_DIR/key.pem" \
    '{network:"hysteria",security:"tls",
      tlsSettings:{serverName:"",alpn:["h3"],certificates:[{certificateFile:$cf,keyFile:$kf,ocspStapling:0,oneTimeLoading:false,usage:"encipherment",buildChain:false}],
        settings:{fingerprint:"",allowInsecure:true}},
      hysteriaSettings:{version:2,auth:"",udpIdleTimeout:60}}')
  add "Hysteria2" hysteria 443 "$S" "$ST"
fi

if want 4; then
  U=$(cat /proc/sys/kernel/random/uuid)
  S=$(jq -nc --arg u "$U" --arg pw "$(rnd 16)" --argjson c "$(client tuic-$SUB)" --arg cf "$CERT_DIR/cert.pem" --arg kf "$CERT_DIR/key.pem" --arg sni "$REALITY_SNI" \
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

# ---------------------------------------------------------------- фаервол
step "Фаервол (ufw)"
SSH_PORTS=$(ss -tlnpH 2>/dev/null | awk '/sshd/{n=split($4,a,":"); print a[n]}' | sort -u)
for p in ${SSH_PORTS:-22}; do ufw allow "$p/tcp" >/dev/null; done
ufw allow "${XUI_PANEL_PORT}/tcp" >/dev/null
for r in 443/tcp 443/udp 8443/tcp 8443/udp 51820/udp 9443/tcp 9443/udp 2443/tcp; do ufw allow "$r" >/dev/null; done
ufw --force enable >/dev/null
ok "Открыты: SSH ${SSH_PORTS:-22}, панель ${XUI_PANEL_PORT}, 443, 8443, 51820/udp, 9443, 2443"

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
• Hysteria2 и TUIC используют самоподписанный сертификат: в клиенте включите allowInsecure / «Пропустить проверку».
• AmneziaWG: конфиг клиента скачивается в панели (Инбаунды → AmneziaWG → клиент → QR/скачать), клиент — приложение AmneziaVPN.
• TUIC и AmneziaWG в ссылки выше могут не попасть — берите их из панели.
EOF
