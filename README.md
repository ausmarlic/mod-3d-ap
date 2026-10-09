# mod-3d-ap

A Raspberry Pi 4 that serves a small, isolated WiFi network (`modalic-3d`) for
Bambu Lab 3D printers and the laptops that drive them. Internet access for the
printers is off by default, and can be opened to Bambu's cloud only, or briefly
to the whole internet for firmware updates.

```
                    ┌──────────────────────── Raspberry Pi 4 ─────────────────────────┐
 home WiFi ─────────┤ wlan0 (onboard)                       ap0 (TP-Link, USB)        ├──── modalic-3d
 (SSH, upstream)    │ NetworkManager       nftables           hostapd · dnsmasq · chrony│     10.42.0.0/24
                    └─────────────────────── mode: isolated | bambu | update ──────────┘     printers + laptops
```

| | |
|---|---|
| Hardware | Raspberry Pi 4, TP-Link Archer T3U Plus (AC1300, RTL8822BU, USB `2357:0138`) |
| OS | Raspberry Pi OS / Debian 13 (trixie), kernel 6.18 |
| Driver | In-kernel `rtw88_8822bu`, which supports AP mode on 2.4 and 5 GHz, so no driver build is needed. It has a known stall under load; see [Known issue](#known-issue-rtw88-usb-stall-under-load). |
| AP subnet | `10.42.0.1/24`, DHCP `.50–.250`, local domain `mod3d.lan` |

## Quick start

On the Pi (it needs read access to this repo; see [Deploy key](#deploy-key)):

```bash
git clone git@github.com:ausmarlic/mod-3d-ap.git ~/mod-3d-ap
cd ~/mod-3d-ap
sudo ./install.sh
```

On first install, the installer prompts for the SSID (default `modalic-3d`) and
a WPA2 passphrase, then does the following:

1. Installs `hostapd`, `dnsmasq-base`, `nftables`, `iw` and `chrony`, and masks the stock `hostapd.service`.
2. Renames the TP-Link to `ap0` (`/etc/systemd/network/10-mod-3d-ap.link`), so it can never swap names with `wlan0`.
3. Tells NetworkManager to leave `ap0` alone.
4. Installs `/usr/local/sbin/mod-3d-ap` and the systemd units, enables them at boot, and starts the AP.

Re-running `install.sh` is safe and is how you deploy updates. It never overwrites your config.

```bash
cd ~/mod-3d-ap && git pull && sudo ./install.sh
```

## Modes

| Mode | Clients on `modalic-3d` can reach | Use it for |
|------|-----------------------------------|------------|
| `isolated` | Each other, plus DHCP/DNS/NTP/SSH on the Pi | Printers in LAN-only mode. The default. |
| `bambu` | Bambu's cloud only (DNS-based allowlist, NAT via `wlan0`) | Using Bambu Handy / Bambu Studio from the real WiFi or a phone, through the cloud |
| `update` | The internet | Firmware updates. **Always temporary** (default 1 h). |

The boot-time default is `UPLINK_MODE` in the config (`isolated` or `bambu`).
Switch modes at runtime without restarting the WiFi:

```bash
sudo mod-3d-ap mode                      # current mode and revert time
sudo mod-3d-ap mode update --for 45min   # firmware-update window, then auto-revert
sudo mod-3d-ap mode bambu --for 2h       # temporary cloud access
sudo mod-3d-ap mode bambu                # cloud access until reboot
sudo mod-3d-ap mode default              # back to UPLINK_MODE now
```

Guarantees, in every mode:

- A runtime mode lives in `/run`, so **a reboot always returns to `UPLINK_MODE`**.
- **Clients can never reach the home LAN** or any other private range (RFC 1918, link-local, CGNAT/Tailscale).
- **Every forwarded packet is checked** against the current mode, with no blanket "established" accept. Switching back to `isolated` cuts off open connections immediately.
- Client DNS (port 53) is forced to dnsmasq and client NTP (UDP 123) to chrony on the Pi. Printers use hard-coded NTP servers and need correct time for TLS, even in LAN-only mode.

### How `bambu` mode works

```
printer ──DNS──▶ dnsmasq ──▶ upstream DNS
                    │  answer for *.bambulab.com etc.
                    ▼
            nft set bambu4 (1-day timeout) ──▶ forward chain: allow ap0 → wlan0 only to @bambu4
```

The allowed domains are in [`config/bambu-domains.txt`](config/bambu-domains.txt),
and each entry also matches its subdomains. Bambu says its list is not
exhaustive, so expect occasional upkeep. `amazonaws.com` and `aliyuncs.com` are
included for file and firmware storage, but they are broad, so comment them out
for a stricter policy.

This is a routed setup, not a layer-2 bridge, because a WiFi client link can't
be bridged. Cloud camera view is **best-effort**: its TUTK relays are handed
out as raw IPs that a DNS allowlist never sees.

### Firmware updates

Whether an update is started from the printer screen, Bambu Studio, or Bambu
Handy, the printer downloads the firmware from Bambu's servers itself. It
therefore needs internet and must not be in LAN-only mode while it updates.

1. Try `sudo mod-3d-ap mode bambu --for 1h` first; the allowlist may be enough.
2. If the download stalls, use `sudo mod-3d-ap mode update --for 1h`.
3. Fully offline alternative: update from an SD card using the files on Bambu's wiki.

## Configuration

The config file is `/etc/mod-3d-ap/mod-3d-ap.conf` (root-only, **not in git**).
See [`config/mod-3d-ap.conf.example`](config/mod-3d-ap.conf.example) for every option.

```bash
sudoedit /etc/mod-3d-ap/mod-3d-ap.conf
sudo mod-3d-ap apply        # validates, then restarts the AP (clients reconnect)
```

| Key | Default | Notes |
|-----|---------|-------|
| `SSID`, `PASSPHRASE` | `modalic-3d`, *(prompted)* | WPA2-PSK, 8–63 characters |
| `BAND`, `CHANNEL` | `2.4`, `6` | Keep 2.4 GHz for the printers (see below) |
| `COUNTRY` | `US` | Regulatory domain |
| `UPLINK_IFACE` | `wlan0` | Used by `bambu` and `update` |
| `AP_ADDR`, `DHCP_*` | `10.42.0.1`, `.50–.250`, `12h` | |
| `UPLINK_MODE` | `isolated` | Boot default: `isolated` or `bambu` |
| `ALLOW_SSH_FROM_AP` | `yes` | SSH to the Pi from `modalic-3d` |

Fixed IPs for printers go in `/etc/mod-3d-ap/dnsmasq.d/printers.conf`; run
`sudo mod-3d-ap apply` after editing:

```
dhcp-host=aa:bb:cc:dd:ee:ff,x1c-01,10.42.0.10
```

Printers then also resolve as `x1c-01.mod3d.lan`.

## Operating

```bash
sudo mod-3d-ap status                 # mode, units, connected stations, leases, allow set
journalctl -u 'mod-3d-ap*' -f         # live logs (hostapd joins, DHCP, mode changes)
sudo mod-3d-ap reset                  # reload the adapter driver (see "Known issue")
sudo mod-3d-ap check                  # validate config only
sudo mod-3d-ap render                 # write generated configs to /run/mod-3d-ap for inspection
sudo ./uninstall.sh                   # remove units/files; keeps /etc/mod-3d-ap and packages
```

The systemd units are listed below. `mod-3d-ap.service` is bound to the `ap0`
device, so unplugging the adapter stops the AP and plugging it back in starts it again.

| Unit | Role |
|------|------|
| `mod-3d-ap.service` | Oneshot: renders configs, addresses `ap0`, loads nftables, configures chrony |
| `mod-3d-ap-hostapd.service` | The access point |
| `mod-3d-ap-dnsmasq.service` | DHCP and DNS, and fills the `bambu4` allow set |
| `mod-3d-ap-watchdog.timer` | Every 30 s: resets the adapter if it stalls (see below) |
| `mod-3d-ap-revert.timer` | Transient; created by `mode … --for` |

## Known issue: rtw88 USB stall under load

**Symptom:** after a few minutes of heavy traffic (for example a printer
firmware download), every client suddenly fails to connect with "wrong
password". The AP keeps beaconing, and `ap0`'s `rx_packets` stops increasing.
The kernel logs nothing.

**Cause:** this is a known bug in the in-kernel `rtw88` USB driver for
RTL8822BU and RTL8821CU, and it is still present in 6.18. The driver queues all
broadcast/multicast frames in a HIGH queue that the firmware drains only once
per DTIM beacon. When that queue backs up, the adapter's shared TX buffer pool
runs dry, and EAPOL handshake frames and data stall. A fix has been posted
upstream (rtw-next `c710c7c2e038` plus a follow-up series); it is not in a
released kernel yet.

**Mitigations installed here:**

| Mitigation | Where |
|------------|-------|
| `multicast_to_unicast=1`, `dtim_period=1` (keeps broadcast off the HIGH queue and drains it every beacon) | generated `hostapd.conf` |
| avahi does not announce on `ap0` | `/etc/avahi/avahi-daemon.conf` (`deny-interfaces=ap0`) |
| Adapter kept in USB 2 mode (USB 3 interferes with 2.4 GHz) | `/etc/modprobe.d/mod-3d-ap.conf` |
| Watchdog: when RX is frozen ≥ 90 s *and* handshakes are failing, the driver is reloaded | `mod-3d-ap-watchdog.timer` |

**Manual recovery:** `sudo mod-3d-ap reset`. A plain `systemctl restart`
may not clear the stall. To see past watchdog resets, run
`journalctl -u mod-3d-ap-watchdog | grep resetting`.

**If it keeps happening:** use a MediaTek adapter with an in-kernel `mt76`
driver. The MT7610U (e.g. ALFA AWUS036ACHM) is widely recommended for 2.4 GHz
AP mode, and the MT7612U (e.g. ALFA AWUS036ACM) is a solid dual-band choice.
Both need driver-match changes in `systemd/10-mod-3d-ap.link` and `install.sh`.

## WiFi compatibility

- **2.4 GHz only:** X1C, P1P/P1S, A1/A1 mini. Dual-band: H2D, P2S. Keep `BAND=2.4` on channel 1, 6 or 11, and avoid channels 12 and 13.
- **Security:** WPA2-PSK/CCMP with PMF off. WPA3 is not used, since printer support is undocumented.
- **Radio settings:** 20 MHz channels, SSID broadcast on, and `ap_isolate=0`. Clients must see each other because Bambu Studio finds printers by SSDP broadcast.
- **Laptops must join `modalic-3d`** to use LAN mode. Discovery (UDP 1990/2021) does not cross subnets.

LAN ports between laptops and printers: MQTT/TLS 8883, FTPS 990 (+ passive
50000–50100), RTSPS 322 (X1/H2/P2S), camera 6000 (A1/P1), SSDP UDP 1990/2021.
Reference: <https://wiki.bambulab.com/en/general/printer-network-ports>.

## Accessing the Pi

The Pi stays on the home WiFi via `wlan0` and advertises itself over mDNS as
`mod-3d-ap.local`. From a laptop, add this to `~/.ssh/config`:

```
Host mod-3d-ap
  HostName mod-3d-ap.local
  User mod-3d-ap
  IdentityFile ~/.ssh/mod-3d-ap
```

From inside `modalic-3d`, the Pi is at `10.42.0.1`. If `mod-3d-ap.local`
occasionally fails to resolve (for example while `ap0` is coming up), retry, or
use the Pi's IP. A DHCP reservation on the home router makes the IP stable.

### Deploy key

The Pi pulls this repo with its own key, `~/.ssh/mod-3d-ap-deploy`, which is
registered as a **read-only** deploy key on this repo only. `~/.ssh/config` on
the Pi maps `github.com` to that key. Never copy a laptop key to the Pi.

## Repository layout

```
bin/mod-3d-ap                       CLI: setup/teardown (used by systemd), mode, status, apply, check, render
config/mod-3d-ap.conf.example       Config template → /etc/mod-3d-ap/mod-3d-ap.conf
config/bambu-domains.txt            bambu-mode allowlist → /etc/mod-3d-ap/bambu-domains.txt
systemd/mod-3d-ap*.service          Units → /etc/systemd/system/
systemd/10-mod-3d-ap.link           Renames the TP-Link to ap0 → /etc/systemd/network/
systemd/90-mod-3d-ap-unmanaged.conf NetworkManager ignores ap0 → /etc/NetworkManager/conf.d/
install.sh / uninstall.sh
```

## Possible next steps

- **Direct LAN access from the home WiFi:** let Bambu Studio on the home
  network reach printers without the cloud. This needs an SSDP relay and port
  forwards for 8883/990/322/6000. Not implemented.
- If the rtw88 stall persists, move to an MT7610U/MT7612U adapter, or build rtw88
  with the upstream fix.
- Validate the `bambu` allowlist against real printer traffic. Check
  `sudo mod-3d-ap status` and the dnsmasq logs for blocked domains.
