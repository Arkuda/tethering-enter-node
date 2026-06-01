FROM debian:12-slim

ARG HYSTERIA_INSTALLER_URL="https://get.hy2.sh/"

ENV DEBIAN_FRONTEND=noninteractive \
    SSH_SOCKS_HOST=127.0.0.1 \
    SSH_SOCKS_PORT=1080 \
    REDSOCKS_PORT=12345 \
    OPENVPN_PORT=1194 \
    OPENVPN_PROTO=udp \
    OPENVPN_NETWORK=10.8.0.0 \
    OPENVPN_NETMASK=255.255.255.0 \
    OPENVPN_DNS="1.1.1.1 8.8.8.8" \
    HYSTERIA_LISTEN=:443 \
    HYSTERIA_AUTH_PASSWORD=change-me \
    HYSTERIA_DISABLE_UDP=true \
    HYSTERIA_ACME_EMAIL= \
    HYSTERIA_TLS_CERT=/data/hysteria/server.crt \
    HYSTERIA_TLS_KEY=/data/hysteria/server.key \
    SSH_KEY_PATH=/run/secrets/ssh_private_key \
    SSH_STRICT_HOST_KEY_CHECKING=accept-new \
    SSH_ALIVE_INTERVAL=30 \
    SSH_ALIVE_COUNT_MAX=3 \
    SSH_EXTRA_OPTS= \
    ENABLE_IPTABLES=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        easy-rsa \
        gettext-base \
        iproute2 \
        iptables \
        openssh-client \
        openvpn \
        openssl \
        procps \
        redsocks \
    && curl -fsSL "$HYSTERIA_INSTALLER_URL" | bash \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY docker/entrypoint.sh /usr/local/bin/tethering-entrypoint
COPY docker/redsocks.conf.tpl /etc/redsocks.conf.tpl
COPY docker/openvpn-server.conf.tpl /etc/openvpn/server.conf.tpl
COPY docker/hysteria-server.yaml.tpl /etc/hysteria/server.yaml.tpl

RUN chmod +x /usr/local/bin/tethering-entrypoint

VOLUME ["/data"]

EXPOSE 1194/udp 443/udp

ENTRYPOINT ["/usr/local/bin/tethering-entrypoint"]
