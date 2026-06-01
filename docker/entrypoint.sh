#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    log "ERROR: required environment variable $name is not set"
    exit 1
  fi
}

render_template() {
  local src="$1"
  local dst="$2"
  envsubst < "$src" > "$dst"
}

wait_for_port() {
  local host="$1"
  local port="$2"
  local name="$3"
  for _ in $(seq 1 30); do
    if timeout 1 bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1; then
      log "$name is listening on ${host}:${port}"
      return 0
    fi
    sleep 1
  done
  log "ERROR: $name did not start listening on ${host}:${port}"
  return 1
}

write_ssh_key_from_env() {
  if [[ -n "${SSH_PRIVATE_KEY_B64:-}" ]]; then
    mkdir -p /run/secrets
    printf '%s' "$SSH_PRIVATE_KEY_B64" | base64 -d > /run/secrets/ssh_private_key
    chmod 600 /run/secrets/ssh_private_key
    export SSH_KEY_PATH=/run/secrets/ssh_private_key
  elif [[ -n "${SSH_PRIVATE_KEY:-}" ]]; then
    mkdir -p /run/secrets
    printf '%s\n' "$SSH_PRIVATE_KEY" > /run/secrets/ssh_private_key
    chmod 600 /run/secrets/ssh_private_key
    export SSH_KEY_PATH=/run/secrets/ssh_private_key
  fi
}

generate_openvpn_pki() {
  if [[ -f /data/openvpn/pki/issued/server.crt && -f /data/openvpn/pki/private/server.key ]]; then
    log "OpenVPN PKI already exists"
    return
  fi

  log "Generating OpenVPN PKI in /data/openvpn/pki"
  mkdir -p /data/openvpn
  rm -rf /data/openvpn/easy-rsa
  cp -a /usr/share/easy-rsa /data/openvpn/easy-rsa
  pushd /data/openvpn/easy-rsa >/dev/null
  ./easyrsa --batch init-pki
  EASYRSA_REQ_CN="${OPENVPN_CA_CN:-tethering-enter-node-ca}" ./easyrsa --batch build-ca nopass
  EASYRSA_REQ_CN="server" ./easyrsa --batch build-server-full server nopass
  ./easyrsa --batch gen-crl
  openvpn --genkey secret pki/ta.key
  popd >/dev/null
  rm -rf /data/openvpn/pki
  mv /data/openvpn/easy-rsa/pki /data/openvpn/pki
  rm -rf /data/openvpn/easy-rsa
}

generate_hysteria_self_signed_cert() {
  if [[ -n "${HYSTERIA_ACME_EMAIL:-}" || -f "$HYSTERIA_TLS_CERT" && -f "$HYSTERIA_TLS_KEY" ]]; then
    return
  fi

  log "Generating self-signed Hysteria TLS certificate"
  mkdir -p "$(dirname "$HYSTERIA_TLS_CERT")" "$(dirname "$HYSTERIA_TLS_KEY")"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$HYSTERIA_TLS_KEY" \
    -out "$HYSTERIA_TLS_CERT" \
    -subj "/CN=${HYSTERIA_TLS_CN:-tethering-enter-node}" \
    -addext "subjectAltName=DNS:${HYSTERIA_TLS_CN:-tethering-enter-node}"
}

build_dns_pushes() {
  local pushes=""
  for dns in ${OPENVPN_DNS:-}; do
    pushes+="push \"dhcp-option DNS ${dns}\""$'\n'
  done
  export OPENVPN_DNS_PUSHES="$pushes"
}

build_hysteria_tls_block() {
  if [[ -n "${HYSTERIA_ACME_EMAIL:-}" ]]; then
    require_env HYSTERIA_ACME_DOMAIN
    export HYSTERIA_TLS_BLOCK="acme:
  domains:
    - ${HYSTERIA_ACME_DOMAIN}
  email: ${HYSTERIA_ACME_EMAIL}"
  else
    export HYSTERIA_TLS_BLOCK="tls:
  cert: ${HYSTERIA_TLS_CERT}
  key: ${HYSTERIA_TLS_KEY}"
  fi
}

configure_iptables() {
  if [[ "${ENABLE_IPTABLES}" != "1" ]]; then
    log "iptables configuration is disabled"
    return
  fi

  log "Configuring TCP redirection from OpenVPN clients to redsocks"
  iptables -t nat -N REDSOCKS 2>/dev/null || true
  iptables -t nat -F REDSOCKS

  # Do not proxy local/private/link-local destinations through the SSH exit.
  iptables -t nat -A REDSOCKS -d 0.0.0.0/8 -j RETURN
  iptables -t nat -A REDSOCKS -d 10.0.0.0/8 -j RETURN
  iptables -t nat -A REDSOCKS -d 100.64.0.0/10 -j RETURN
  iptables -t nat -A REDSOCKS -d 127.0.0.0/8 -j RETURN
  iptables -t nat -A REDSOCKS -d 169.254.0.0/16 -j RETURN
  iptables -t nat -A REDSOCKS -d 172.16.0.0/12 -j RETURN
  iptables -t nat -A REDSOCKS -d 192.168.0.0/16 -j RETURN
  iptables -t nat -A REDSOCKS -d 224.0.0.0/4 -j RETURN
  iptables -t nat -A REDSOCKS -d 240.0.0.0/4 -j RETURN
  iptables -t nat -A REDSOCKS -p tcp -j REDIRECT --to-ports "${REDSOCKS_PORT}"

  iptables -t nat -D PREROUTING -i tun0 -p tcp -j REDSOCKS 2>/dev/null || true
  iptables -t nat -A PREROUTING -i tun0 -p tcp -j REDSOCKS

  # Plain SSH dynamic forwarding does not carry UDP. Reject UDP from OpenVPN clients explicitly.
  iptables -D FORWARD -i tun0 -p udp -j REJECT 2>/dev/null || true
  iptables -A FORWARD -i tun0 -p udp -j REJECT
}

start_ssh_tunnel() {
  require_env SSH_TUNNEL_USER
  require_env SSH_TUNNEL_HOST
  if [[ ! -f "$SSH_KEY_PATH" ]]; then
    log "ERROR: SSH key file not found at $SSH_KEY_PATH. Mount it or set SSH_PRIVATE_KEY/SSH_PRIVATE_KEY_B64."
    exit 1
  fi
  chmod 600 "$SSH_KEY_PATH"
  mkdir -p /root/.ssh

  local target="${SSH_TUNNEL_USER}@${SSH_TUNNEL_HOST}"
  local port="${SSH_TUNNEL_PORT:-22}"
  log "Starting SSH SOCKS tunnel to ${target}:${port} on ${SSH_SOCKS_HOST}:${SSH_SOCKS_PORT}"
  ssh -N \
    -D "${SSH_SOCKS_HOST}:${SSH_SOCKS_PORT}" \
    -i "$SSH_KEY_PATH" \
    -p "$port" \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval="$SSH_ALIVE_INTERVAL" \
    -o ServerAliveCountMax="$SSH_ALIVE_COUNT_MAX" \
    -o StrictHostKeyChecking="$SSH_STRICT_HOST_KEY_CHECKING" \
    ${SSH_EXTRA_OPTS} \
    "$target" &
  PIDS+=("$!")
  wait_for_port "$SSH_SOCKS_HOST" "$SSH_SOCKS_PORT" "SSH SOCKS tunnel"
}

start_processes() {
  log "Rendering configs"
  mkdir -p /data/redsocks /data/openvpn /data/hysteria
  render_template /etc/redsocks.conf.tpl /data/redsocks/redsocks.conf
  render_template /etc/openvpn/server.conf.tpl /data/openvpn/server.conf
  render_template /etc/hysteria/server.yaml.tpl /data/hysteria/server.yaml

  log "Starting redsocks"
  redsocks -c /data/redsocks/redsocks.conf &
  PIDS+=("$!")

  log "Starting OpenVPN server"
  openvpn --config /data/openvpn/server.conf &
  PIDS+=("$!")

  log "Starting Hysteria 2 server"
  hysteria server -c /data/hysteria/server.yaml &
  PIDS+=("$!")
}

shutdown() {
  log "Shutting down"
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait || true
}

main() {
  PIDS=()
  trap shutdown SIGINT SIGTERM EXIT

  write_ssh_key_from_env
  build_dns_pushes
  generate_openvpn_pki
  generate_hysteria_self_signed_cert
  build_hysteria_tls_block
  start_ssh_tunnel
  configure_iptables
  start_processes

  log "All services started"
  wait -n "${PIDS[@]}"
  log "A child process exited; stopping container"
  exit 1
}

main "$@"
