# 3x-ui installer

Ставит 3x-ui (последнюю версию) на чистый сервер и сразу создаёт 7 инбаундов + по желанию Cloudflare CDN.

## Запуск

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Jasis7/3x-ui-installer/main/install.sh)
```

С CDN через Cloudflare:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Jasis7/3x-ui-installer/main/install.sh) -c cdn.example.com -t CF_API_TOKEN
```

Флаги: `-r` SNI для Reality (по умолчанию www.microsoft.com), `-o "1 3 5"` — только выбранные протоколы, `-v v3.11.0` — конкретная версия панели, `-d` — отладка.

## Протоколы

| № | Протокол | Порт |
|---|----------|------|
| 1 | VLESS Reality Vision | 443/tcp |
| 2 | VLESS XHTTP Reality | 8443/tcp |
| 3 | Hysteria2 | 443/udp |
| 4 | TUIC v5 | 8443/udp |
| 5 | AmneziaWG | 51820/udp |
| 6 | Shadowsocks-2022 | 9443 |
| 7 | MTProto (Telegram) | 2443 |
| CDN | VLESS WS / HTTPUpgrade / XHTTP через Cloudflare | 2053 |

Итог (адрес панели, логин, пароль, ссылки) — в `/root/3x-ui-result.txt`.

## Заметки

- Hysteria2/TUIC работают на самоподписанном сертификате → в клиенте включить «allowInsecure».
- Конфиг AmneziaWG берётся из панели (клиенты инбаунда) → импорт в AmneziaVPN.
- `cdn.sh` можно запускать отдельно на сервере, где 3x-ui уже стоит.
- Скрипт на сервере ещё не обкатан: если какой-то инбаунд не создался — запустить с `-d` и прислать вывод.
