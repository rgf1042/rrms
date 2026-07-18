#!/usr/bin/env bash
set -euo pipefail

# Deploy a local Wi-Fi access point for tablets/phones on Debian 13.
# Run as root on the target host.

WIFI_IFACE="${WIFI_IFACE:-wlan0}"
UPSTREAM_IFACE="${UPSTREAM_IFACE:-}"
WIRELESS_SSID="${WIRELESS_SSID:-RRMS-JMRI}"
WIRELESS_PASSWORD="${WIRELESS_PASSWORD:-}"
WIRELESS_PASSWORD_TEXT_FILE="${WIRELESS_PASSWORD_TEXT_FILE:-/root/rrms-wireless.password.txt}"
WIRELESS_SUBNET="${WIRELESS_SUBNET:-10.42.0.0/24}"
WIRELESS_COUNTRY="${WIRELESS_COUNTRY:-US}"
WIRELESS_CHANNEL="${WIRELESS_CHANNEL:-6}"
WIRELESS_HW_MODE="${WIRELESS_HW_MODE:-g}"
DHCP_LEASE_TIME="${DHCP_LEASE_TIME:-12h}"
DNS_UPSTREAM="${DNS_UPSTREAM:-1.1.1.1,8.8.8.8}"
ENABLE_NAT="${ENABLE_NAT:-1}"
HOSTAPD_CONFIG="/etc/hostapd/hostapd.conf"

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

if [[ "${#WIRELESS_SSID}" -lt 1 || "${#WIRELESS_SSID}" -gt 32 ]]; then
  echo "WIRELESS_SSID must be 1-32 characters." >&2
  exit 1
fi

if [[ -n "${WIRELESS_PASSWORD}" && ( "${#WIRELESS_PASSWORD}" -lt 8 || "${#WIRELESS_PASSWORD}" -gt 63 ) ]]; then
  echo "WIRELESS_PASSWORD must be 8-63 characters for WPA2-PSK." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "==> Installing packages"
apt-get update
apt-get install -y \
  dnsmasq \
  hostapd \
  nftables \
  openssl \
  python3 \
  rfkill

if ! ip link show "${WIFI_IFACE}" >/dev/null 2>&1; then
  echo "Wireless interface ${WIFI_IFACE} was not found." >&2
  echo "Set WIFI_IFACE to the AP-capable wireless interface name." >&2
  exit 1
fi

if [[ -z "${UPSTREAM_IFACE}" ]]; then
  UPSTREAM_IFACE="$(ip route show default 0.0.0.0/0 | awk '{print $5; exit}')"
fi

if [[ "${ENABLE_NAT}" == "1" && -z "${UPSTREAM_IFACE}" ]]; then
  echo "Could not detect the upstream interface for NAT." >&2
  echo "Set UPSTREAM_IFACE, or set ENABLE_NAT=0 for isolated Wi-Fi only." >&2
  exit 1
fi

subnet_info="$(
  WIRELESS_SUBNET="${WIRELESS_SUBNET}" python3 - <<'PY'
import ipaddress
import os
import sys

try:
    network = ipaddress.ip_network(os.environ["WIRELESS_SUBNET"], strict=False)
except ValueError as exc:
    print(f"Invalid WIRELESS_SUBNET: {exc}", file=sys.stderr)
    sys.exit(1)

if network.version != 4:
    print("WIRELESS_SUBNET must be an IPv4 CIDR, for example 10.42.0.0/24.", file=sys.stderr)
    sys.exit(1)

if network.num_addresses < 6:
    print("WIRELESS_SUBNET must provide at least 4 usable host addresses.", file=sys.stderr)
    sys.exit(1)

gateway = network.network_address + 1
dhcp_start = network.network_address + 2
dhcp_end = network.broadcast_address - 1
print(f"GATEWAY_IP={gateway}")
print(f"PREFIX_LEN={network.prefixlen}")
print(f"NETWORK_CIDR={network.with_prefixlen}")
print(f"DHCP_START={dhcp_start}")
print(f"DHCP_END={dhcp_end}")
PY
)"
eval "${subnet_info}"

if [[ -z "${WIRELESS_PASSWORD}" ]]; then
  WIRELESS_PASSWORD="$(openssl rand -base64 18 | tr -d '=+/' | cut -c 1-16)"
  printf '%s\n' "${WIRELESS_PASSWORD}" >"${WIRELESS_PASSWORD_TEXT_FILE}"
  chmod 0600 "${WIRELESS_PASSWORD_TEXT_FILE}"
else
  printf '%s\n' "${WIRELESS_PASSWORD}" >"${WIRELESS_PASSWORD_TEXT_FILE}"
  chmod 0600 "${WIRELESS_PASSWORD_TEXT_FILE}"
fi

echo "==> Enabling IPv4 forwarding"
cat >/etc/sysctl.d/99-rrms-wireless-ap.conf <<EOF
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null

echo "==> Configuring hostapd"
install -d /etc/hostapd
cat >"${HOSTAPD_CONFIG}" <<EOF
country_code=${WIRELESS_COUNTRY}
interface=${WIFI_IFACE}
driver=nl80211
ssid=${WIRELESS_SSID}
hw_mode=${WIRELESS_HW_MODE}
channel=${WIRELESS_CHANNEL}
ieee80211n=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=${WIRELESS_PASSWORD}
EOF

if grep -q '^#*DAEMON_CONF=' /etc/default/hostapd; then
  sed -i "s|^#*DAEMON_CONF=.*|DAEMON_CONF=\"${HOSTAPD_CONFIG}\"|" /etc/default/hostapd
else
  printf 'DAEMON_CONF="%s"\n' "${HOSTAPD_CONFIG}" >>/etc/default/hostapd
fi

echo "==> Configuring dnsmasq DHCP"
install -d /etc/dnsmasq.d
cat >/etc/dnsmasq.d/rrms-wireless-ap.conf <<EOF
interface=${WIFI_IFACE}
bind-interfaces
dhcp-authoritative
dhcp-range=${DHCP_START},${DHCP_END},${DHCP_LEASE_TIME}
dhcp-option=option:router,${GATEWAY_IP}
dhcp-option=option:dns-server,${GATEWAY_IP}
EOF

IFS=',' read -r -a dns_servers <<<"${DNS_UPSTREAM}"
{
  for dns_server in "${dns_servers[@]}"; do
    [[ -n "${dns_server}" ]] && printf 'server=%s\n' "${dns_server}"
  done
} >/etc/dnsmasq.d/rrms-wireless-ap-dns.conf

echo "==> Configuring Wi-Fi interface setup service"
cat >/etc/systemd/system/rrms-wireless-ap-setup.service <<EOF
[Unit]
Description=Prepare RRMS wireless access point interface
Before=hostapd.service dnsmasq.service
Wants=network-pre.target
After=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/rfkill unblock wlan
ExecStart=/usr/sbin/ip link set ${WIFI_IFACE} down
ExecStart=/usr/sbin/ip addr flush dev ${WIFI_IFACE}
ExecStart=/usr/sbin/ip addr add ${GATEWAY_IP}/${PREFIX_LEN} dev ${WIFI_IFACE}
ExecStart=/usr/sbin/ip link set ${WIFI_IFACE} up

[Install]
WantedBy=multi-user.target
EOF

if systemctl list-unit-files "wpa_supplicant@${WIFI_IFACE}.service" | grep -q "wpa_supplicant@${WIFI_IFACE}.service"; then
  systemctl disable --now "wpa_supplicant@${WIFI_IFACE}.service" >/dev/null 2>&1 || true
fi

if systemctl list-unit-files NetworkManager.service | grep -q '^NetworkManager.service'; then
  echo "==> Marking ${WIFI_IFACE} unmanaged by NetworkManager"
  install -d /etc/NetworkManager/conf.d
  cat >/etc/NetworkManager/conf.d/99-rrms-wireless-ap.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:${WIFI_IFACE}
EOF
  systemctl reload NetworkManager.service >/dev/null 2>&1 || systemctl restart NetworkManager.service >/dev/null 2>&1 || true
fi

echo "==> Configuring nftables NAT"
install -d /etc/nftables.d
if [[ ! -f /etc/nftables.conf ]]; then
  cat >/etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f

flush ruleset
EOF
fi
if ! grep -Fq 'include "/etc/nftables.d/rrms-wireless-ap.nft"' /etc/nftables.conf; then
  printf '\ninclude "/etc/nftables.d/rrms-wireless-ap.nft"\n' >>/etc/nftables.conf
fi

if [[ "${ENABLE_NAT}" == "1" ]]; then
  cat >/etc/nftables.d/rrms-wireless-ap.nft <<EOF
table inet rrms_filter {
  chain forward {
    type filter hook forward priority 0; policy drop;
    iifname "${WIFI_IFACE}" oifname "${UPSTREAM_IFACE}" accept
    iifname "${UPSTREAM_IFACE}" oifname "${WIFI_IFACE}" ct state established,related accept
  }
}

table ip rrms_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "${UPSTREAM_IFACE}" ip saddr ${NETWORK_CIDR} masquerade
  }
}
EOF
else
  : >/etc/nftables.d/rrms-wireless-ap.nft
fi

echo "==> Enabling services"
systemctl unmask hostapd.service >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable nftables.service rrms-wireless-ap-setup.service hostapd.service dnsmasq.service
nft delete table inet rrms_filter >/dev/null 2>&1 || true
nft delete table ip rrms_nat >/dev/null 2>&1 || true
systemctl restart nftables.service
systemctl restart rrms-wireless-ap-setup.service
systemctl restart dnsmasq.service
systemctl restart hostapd.service

cat >/root/RRMS_WIRELESS_FIRST_RUN.txt <<EOF
RRMS wireless LAN is configured.

SSID: ${WIRELESS_SSID}
Password file: ${WIRELESS_PASSWORD_TEXT_FILE}
Wireless interface: ${WIFI_IFACE}
Wireless gateway: ${GATEWAY_IP}/${PREFIX_LEN}
Wireless subnet: ${NETWORK_CIDR}
DHCP range: ${DHCP_START} - ${DHCP_END}
NAT enabled: ${ENABLE_NAT}
Upstream interface: ${UPSTREAM_IFACE:-none}

Useful overrides:
  WIRELESS_SSID=RRMS WIRELESS_PASSWORD=change-me-123 WIRELESS_SUBNET=10.50.0.0/24 WIFI_IFACE=wlan0 bash /root/deploy_wireless_lan_debian13.sh
EOF
chmod 0600 /root/RRMS_WIRELESS_FIRST_RUN.txt

echo
echo "Wireless deployment complete."
echo "SSID: ${WIRELESS_SSID}"
echo "Gateway: ${GATEWAY_IP}/${PREFIX_LEN}"
echo "DHCP: ${DHCP_START} - ${DHCP_END}"
echo "Password file: ${WIRELESS_PASSWORD_TEXT_FILE}"
