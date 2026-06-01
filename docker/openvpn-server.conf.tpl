port ${OPENVPN_PORT}
proto ${OPENVPN_PROTO}
dev tun0
user nobody
group nogroup
persist-key
persist-tun
keepalive 10 120
topology subnet
server ${OPENVPN_NETWORK} ${OPENVPN_NETMASK}
ifconfig-pool-persist /data/openvpn/ipp.txt
push "redirect-gateway def1 bypass-dhcp"
${OPENVPN_DNS_PUSHES}

ca /data/openvpn/pki/ca.crt
cert /data/openvpn/pki/issued/server.crt
key /data/openvpn/pki/private/server.key
dh none
ecdh-curve prime256v1
tls-crypt /data/openvpn/pki/ta.key
crl-verify /data/openvpn/pki/crl.pem
auth SHA256
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
verb 3
