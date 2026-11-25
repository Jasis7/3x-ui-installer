# 3x-ui installer

Ставит на чистый сервер свежую 3x-ui (последний релиз), сразу создаёт до 9 протоколов, сайты-заглушки на поддоменах и Cloudflare CDN.

## Запуск — всё сразу (рекомендуется)

Нужен домен, добавленный в Cloudflare, и токен API (права: Zone Read, DNS Edit, Zone Settings Edit).

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Jasis7/3x-ui-installer/main/install.sh) -b example.com -t CF_TOKEN
```

Скрипт сам создаст поддомены:

| Поддомен | Облако CF | Что на нём |
|---|---|---|
| `photo.example.com` | серое (DNS only) | прямые TLS-протоколы, REALITY маскируется под этот сайт, сайт-заглушка |
| `static.example.com` | оранжевое (proxy) | VLESS через Cloudflare CDN, та же заглушка |

Свои имена поддоменов: `-D cloud.example.com -c img.example.com`.

Другие варианты:

```bash
install.sh                                 # без домена: 7 протоколов, REALITY под www.microsoft.com
install.sh -D vpn.example.com              # свой домен без Cloudflare (A-запись создать вручную)
install.sh -o "1 3 5"                      # только выбранные протоколы
install.sh -r www.samsung.com              # другой REALITY-сайт
install.sh -v v3.11.0                      # конкретная версия панели
install.sh -d                              # отладка: показывает ответы панели
```

## Протоколы

| № | Протокол | Порт | Нужен домен |
|---|----------|------|---|
| 1 | VLESS Reality Vision | 443/tcp | — |
| 2 | VLESS XHTTP Reality | 8443/tcp | — |
| 3 | Hysteria2 | 443/udp | — (с доменом — настоящий сертификат) |
| 4 | TUIC v5 | 8443/udp | — (с доменом — настоящий сертификат) |
| 5 | AmneziaWG | 51820/udp | — |
| 6 | Shadowsocks-2022 | 9443 | — |
| 7 | MTProto (Telegram) | 2443 | — |
| 8 | VLESS TLS Vision | 2096/tcp | да |
| 9 | Trojan TLS | 2087/tcp | да |
| CDN | VLESS WS / HTTPUpgrade / XHTTP через Cloudflare | 2053 | да + CF |

## Заглушки

- `https://photo.example.com` открывает обычный сайт («облачное хранилище фото»). Тот же сайт видит любой, кто стучится на 443 без ключа REALITY или на 2096/2087 не по протоколу.
- `https://static.example.com:2053` показывает ту же заглушку через Cloudflare.
- Сертификаты Let's Encrypt продлеваются автоматически.

Итог (адрес панели, логин, пароль, ссылки) сохраняется в `/root/3x-ui-result.txt`.

## Заметки

- Конфиг AmneziaWG берётся в панели (клиент → QR/скачать), приложение AmneziaVPN.
- TUIC и AmneziaWG могут не попасть в общий список ссылок — берите их из панели.
- `cdn.sh` можно запускать отдельно на сервере, где 3x-ui уже стоит.
