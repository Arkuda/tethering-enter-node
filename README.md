# tethering-enter-node

Docker-конфигурация поднимает Linux-контейнер, который при старте:

1. открывает SSH dynamic forwarding (`SOCKS5`) до удалённого exit-сервера по указанным логину и ключу;
2. запускает OpenVPN-сервер;
3. запускает Hysteria 2-сервер;
4. перенаправляет TCP-трафик OpenVPN-клиентов в SSH SOCKS-туннель через `redsocks` и `iptables`;
5. настраивает Hysteria 2 на исходящий SOCKS5-прокси, созданный SSH-туннелем.

> Важно: обычный SSH `-D` SOCKS-туннель проксирует TCP. UDP-трафик OpenVPN-клиентов в этой сборке явно отклоняется. Hysteria 2 принимает клиентов по UDP/QUIC, но его forwarding через SSH SOCKS в этой конфигурации ограничен TCP (`HYSTERIA_DISABLE_UDP=true`). Если нужен полноценный UDP-forwarding через exit-сервер, используйте WireGuard/TUN на exit-сервере или отдельный UDP-capable прокси вместо чистого SSH `-D`.

## Быстрый старт

1. Положите приватный SSH-ключ для подключения к exit-серверу:

   ```bash
   mkdir -p secrets
   cp ~/.ssh/id_ed25519 secrets/ssh_private_key
   chmod 600 secrets/ssh_private_key
   ```

2. Отредактируйте `docker-compose.yml`:

   ```yaml
   environment:
     SSH_TUNNEL_HOST: "exit.example.com"
     SSH_TUNNEL_PORT: "22"
     SSH_TUNNEL_USER: "proxyuser"
     HYSTERIA_AUTH_PASSWORD: "change-me"
   ```

3. Соберите и запустите контейнер:

   ```bash
   docker compose up -d --build
   ```

Контейнеру нужны `NET_ADMIN` и `/dev/net/tun`, потому что OpenVPN создаёт TUN-интерфейс, а entrypoint настраивает `iptables`.

## Переменные окружения

| Переменная | Значение по умолчанию | Описание |
| --- | --- | --- |
| `SSH_TUNNEL_HOST` | — | Хост exit-сервера. Обязательная переменная. |
| `SSH_TUNNEL_PORT` | `22` | SSH-порт exit-сервера. |
| `SSH_TUNNEL_USER` | — | Логин для SSH на exit-сервере. Обязательная переменная. |
| `SSH_KEY_PATH` | `/run/secrets/ssh_private_key` | Путь к приватному ключу внутри контейнера. |
| `SSH_PRIVATE_KEY` | — | Альтернатива mount-файлу: приватный ключ текстом. |
| `SSH_PRIVATE_KEY_B64` | — | Альтернатива mount-файлу: приватный ключ в base64. |
| `SSH_SOCKS_HOST` | `127.0.0.1` | Адрес локального SOCKS5, который создаёт `ssh -D`. |
| `SSH_SOCKS_PORT` | `1080` | Порт локального SOCKS5. |
| `SSH_STRICT_HOST_KEY_CHECKING` | `accept-new` | Политика проверки host key для SSH. |
| `OPENVPN_PORT` | `1194` | Порт OpenVPN. |
| `OPENVPN_PROTO` | `udp` | Протокол OpenVPN (`udp` или `tcp`). |
| `OPENVPN_NETWORK` | `10.8.0.0` | VPN-сеть OpenVPN. |
| `OPENVPN_NETMASK` | `255.255.255.0` | Маска VPN-сети OpenVPN. |
| `OPENVPN_DNS` | `1.1.1.1 8.8.8.8` | DNS-серверы, отправляемые клиентам OpenVPN. |
| `HYSTERIA_LISTEN` | `:443` | Адрес/порт прослушивания Hysteria 2. |
| `HYSTERIA_AUTH_PASSWORD` | `change-me` | Пароль Hysteria 2. Обязательно смените. |
| `HYSTERIA_DISABLE_UDP` | `true` | Отключает UDP-forwarding в Hysteria, потому что SSH `-D` не проксирует UDP. |
| `HYSTERIA_TLS_CERT` | `/data/hysteria/server.crt` | TLS-сертификат Hysteria при self-signed режиме. |
| `HYSTERIA_TLS_KEY` | `/data/hysteria/server.key` | TLS-ключ Hysteria при self-signed режиме. |
| `HYSTERIA_ACME_EMAIL` | — | Если задан, Hysteria использует ACME. |
| `HYSTERIA_ACME_DOMAIN` | — | Домен для ACME. Обязателен вместе с `HYSTERIA_ACME_EMAIL`. |
| `ENABLE_IPTABLES` | `1` | Включает автоматическую настройку редиректа OpenVPN TCP-трафика. |

## OpenVPN PKI и клиентские сертификаты

При первом старте контейнер автоматически создаёт CA, серверный сертификат, `tls-crypt` ключ и CRL в `/data/openvpn/pki`.

Чтобы выпустить клиентский сертификат, выполните внутри запущенного контейнера:

```bash
docker exec -it tethering-enter-node bash
cd /tmp
cp -a /usr/share/easy-rsa ./easy-rsa
cd easy-rsa
EASYRSA_PKI=/data/openvpn/pki EASYRSA_REQ_CN=client1 ./easyrsa --batch build-client-full client1 nopass
```

Затем соберите клиентский `.ovpn`, используя:

- `/data/openvpn/pki/ca.crt`
- `/data/openvpn/pki/issued/client1.crt`
- `/data/openvpn/pki/private/client1.key`
- `/data/openvpn/pki/ta.key`

Минимальный клиентский шаблон:

```ovpn
client
dev tun
proto udp
remote YOUR_PUBLIC_SERVER_IP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA256
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
verb 3
key-direction 1

<ca>
# вставьте ca.crt
</ca>
<cert>
# вставьте client1.crt
</cert>
<key>
# вставьте client1.key
</key>
<tls-crypt>
# вставьте ta.key
</tls-crypt>
```

## Hysteria 2

По умолчанию контейнер генерирует self-signed сертификат для Hysteria 2. Клиенту нужно разрешить insecure TLS или доверить сертификату.

Пример клиента Hysteria 2:

```yaml
server: YOUR_PUBLIC_SERVER_IP:443
auth: change-me
tls:
  insecure: true
socks5:
  listen: 127.0.0.1:1080
```

Для ACME/TLS от Let's Encrypt задайте:

```yaml
environment:
  HYSTERIA_ACME_EMAIL: "admin@example.com"
  HYSTERIA_ACME_DOMAIN: "vpn.example.com"
```

и направьте DNS `vpn.example.com` на этот сервер.

## Как устроена маршрутизация

- `ssh -N -D 127.0.0.1:1080 user@exit` создаёт локальный SOCKS5-прокси до exit-сервера.
- `redsocks` слушает `127.0.0.1:12345` и отправляет TCP в этот SOCKS5.
- `iptables` перенаправляет TCP из интерфейса OpenVPN `tun0` в `redsocks`.
- Конфиг Hysteria 2 содержит outbound `socks5` на `127.0.0.1:1080`.

## Проверка

```bash
docker compose logs -f
```

В логах должны появиться сообщения о старте SSH SOCKS tunnel, OpenVPN server и Hysteria 2 server.
