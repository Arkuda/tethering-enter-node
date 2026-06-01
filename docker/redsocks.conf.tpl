base {
  log_debug = off;
  log_info = on;
  log = "stderr";
  daemon = off;
  redirector = iptables;
}

redsocks {
  local_ip = 127.0.0.1;
  local_port = ${REDSOCKS_PORT};
  ip = ${SSH_SOCKS_HOST};
  port = ${SSH_SOCKS_PORT};
  type = socks5;
}
