#!/usr/bin/env bash
# Install mod-3d-ap on a Raspberry Pi (Raspberry Pi OS / Debian 13).
#   sudo ./install.sh
# Safe to re-run; it never overwrites /etc/mod-3d-ap/mod-3d-ap.conf.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR=/etc/mod-3d-ap
CONF="$CONF_DIR/mod-3d-ap.conf"
AP_DRIVER=rtw88_8822bu

[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0" >&2; exit 1; }
step() { echo; echo "==> $*"; }

step "Installing packages"
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q hostapd dnsmasq-base nftables iw chrony
# We run our own hostapd unit; keep the distro one out of the way.
systemctl disable --now hostapd.service 2>/dev/null || true
systemctl mask hostapd.service

step "Installing files"
install -m 0755 "$REPO/bin/mod-3d-ap" /usr/local/sbin/mod-3d-ap
install -m 0644 "$REPO"/systemd/mod-3d-ap*.service /etc/systemd/system/
install -m 0644 "$REPO/systemd/10-mod-3d-ap.link" /etc/systemd/network/
install -m 0644 "$REPO/systemd/90-mod-3d-ap-unmanaged.conf" /etc/NetworkManager/conf.d/
install -d -m 0755 "$CONF_DIR" "$CONF_DIR/dnsmasq.d"
install -m 0644 "$REPO/config/bambu-domains.txt" "$CONF_DIR/bambu-domains.txt"

new_conf=no
if [[ ! -e "$CONF" ]]; then
    install -m 0600 "$REPO/config/mod-3d-ap.conf.example" "$CONF"
    new_conf=yes
fi

# Interactive first-time setup of SSID and passphrase.
if [[ $new_conf == yes && -t 0 ]]; then
    step "Configure the access point"
    read -rp "SSID [modalic-3d]: " ssid
    ssid=${ssid:-modalic-3d}
    while true; do
        read -rsp "WPA2 passphrase (8-63 chars): " pass; echo
        (( ${#pass} >= 8 && ${#pass} <= 63 )) && break
        echo "  must be 8-63 characters"
    done
    tmp=$(mktemp)
    SSID_LINE=$(printf 'SSID=%q' "$ssid") PASS_LINE=$(printf 'PASSPHRASE=%q' "$pass") \
        awk '/^SSID=/{print ENVIRON["SSID_LINE"]; next}
             /^PASSPHRASE=/{print ENVIRON["PASS_LINE"]; next} {print}' "$CONF" > "$tmp"
    install -m 0600 "$tmp" "$CONF"
    rm -f "$tmp"
fi

step "Reloading NetworkManager and systemd"
systemctl reload NetworkManager 2>/dev/null || true
systemctl daemon-reload

# Rename the adapter to ap0 now instead of waiting for a reboot.
if [[ ! -e /sys/class/net/ap0 ]]; then
    for dev in /sys/class/net/*; do
        drv=$(basename "$(readlink -f "$dev/device/driver" 2>/dev/null)" 2>/dev/null || true)
        if [[ "$drv" == "$AP_DRIVER" ]]; then
            ifname=$(basename "$dev")
            step "Renaming $ifname -> ap0"
            nmcli device set "$ifname" managed no 2>/dev/null || true
            ip link set "$ifname" down
            udevadm trigger --action=add "$dev"
            udevadm settle
        fi
    done
fi
[[ -e /sys/class/net/ap0 ]] || echo "warning: ap0 not present yet (plug in the adapter or reboot)" >&2

systemctl enable mod-3d-ap.service

if /usr/local/sbin/mod-3d-ap check; then
    step "Starting access point"
    /usr/local/sbin/mod-3d-ap apply
else
    echo
    echo "Edit $CONF (sudoedit $CONF), then run: sudo mod-3d-ap apply"
fi
