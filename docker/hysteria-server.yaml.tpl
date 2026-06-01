listen: ${HYSTERIA_LISTEN}

auth:
  type: password
  password: "${HYSTERIA_AUTH_PASSWORD}"

disableUDP: ${HYSTERIA_DISABLE_UDP}

${HYSTERIA_TLS_BLOCK}

outbounds:
  - name: ssh-tunnel
    type: socks5
    socks5:
      addr: ${SSH_SOCKS_HOST}:${SSH_SOCKS_PORT}
