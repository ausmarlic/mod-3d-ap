#!/usr/bin/env bash
# Remove mod-3d-ap. Leaves /etc/mod-3d-ap and installed packages in place.
#   sudo ./uninstall.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0" >&2; exit 1; }

systemctl disable --now mod-3d-ap.service 2>/dev/null || true
systemctl stop mod-3d-ap-hostapd.service mod-3d-ap-dnsmasq.service 2>/dev/null || true
rm -f /etc/systemd/system/mod-3d-ap*.service \
      /etc/systemd/network/10-mod-3d-ap.link \
      /etc/NetworkManager/conf.d/90-mod-3d-ap-unmanaged.conf \
      /etc/chrony/conf.d/mod-3d-ap.conf \
      /usr/local/sbin/mod-3d-ap
systemctl daemon-reload
systemctl try-restart chrony.service 2>/dev/null || true
systemctl reload NetworkManager 2>/dev/null || true
systemctl unmask hostapd.service 2>/dev/null || true
echo "Removed. Config kept in /etc/mod-3d-ap; the adapter returns to its kernel name after a reboot."
