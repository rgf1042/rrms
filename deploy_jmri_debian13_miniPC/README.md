# Debian 13 JMRI Dedicated Host

This directory contains a simple deployment script for a Debian 13 Xfce machine that should boot directly into a dedicated `jmri` desktop, start JMRI PanelPro, and allow remote attachment with `x11vnc`.

## What It Does

- Installs Debian's default Java runtime, Xfce, LightDM, JMRI, and x11vnc.
- Creates a dedicated user, default `jmri`.
- Adds the user to serial/device groups used by USB layout hardware.
- Installs JMRI under `/home/jmri/JMRI`.
- Configures LightDM autologin for the JMRI user.
- Adds an Xfce autostart entry to start PanelPro inside the real `jmri` desktop session.
- Adds and enables an `x11vnc.service` attached to display `:0`.
- Configures a stable dummy Xorg display for headless/VNC use.
- Tunes x11vnc with a solid background, modest update throttling, and disabled wireframe/scroll heuristics for cleaner Java/Swing repainting.

JMRI itself stores layout profiles, panels, rosters, and preferences in `/home/jmri/.jmri`.

## Run On The Target

```bash
sudo ./deploy_jmri_debian13.sh
```

Useful overrides:

```bash
sudo JMRI_USER=railroad VNC_PORT=5901 ./deploy_jmri_debian13.sh
```

For very slow VNC links, increase the x11vnc client-side cache:

```bash
sudo VNC_NCACHE=20 ./deploy_jmri_debian13.sh
```

Leave `VNC_NCACHE=0` for normal LAN use. x11vnc client-side caching makes the advertised desktop much taller in many viewers, which can feel like broken rendering even on a fast network.

The default headless display is `1280x720`. Useful overrides:

```bash
sudo XORG_DUMMY_MODE=1024x768 ./deploy_jmri_debian13.sh
sudo XORG_DUMMY_MODE=1920x1080 ./deploy_jmri_debian13.sh
```

To set a known VNC password:

```bash
sudo VNC_PASSWORD=jmri2026 ./deploy_jmri_debian13.sh
```

x11vnc's classic password authentication uses the first 8 characters. The readable password is stored on the target in `/root/x11vnc.password.txt`; the x11vnc auth file itself is `/etc/x11vnc.pass`.

To replace an existing `/home/<user>/JMRI` install:

```bash
sudo FORCE_JMRI_REINSTALL=1 ./deploy_jmri_debian13.sh
```

By default the script installs JMRI 5.14, the current production release noted on the JMRI download page when this script was written.

## First JMRI Server Setup

For a new JMRI profile, attach by VNC once and enable the web server startup action:

1. Open PanelPro.
2. Go to `Edit > Preferences > Start Up`.
3. Add `Perform action...`.
4. Select `Start JMRI Web Server`.
5. Save preferences and restart PanelPro.

The default web URL is:

```text
http://TARGET_IP:12080/
```

## Remote Deploy From This Workstation

```bash
scp deploy_jmri_debian13.sh root@192.168.75.208:/root/
ssh root@192.168.75.208 'bash /root/deploy_jmri_debian13.sh'
```

## Optional Wireless LAN

`deploy_wireless_lan_debian13.sh` configures the target as a local Wi-Fi access point for phones/tablets:

- Enables IPv4 forwarding.
- Installs and configures `hostapd` for WPA2 Wi-Fi.
- Installs and configures `dnsmasq` for DHCP/DNS on the wireless subnet.
- Installs and configures `nftables` NAT from the wireless LAN to the detected upstream interface.

Run on the target:

```bash
sudo WIRELESS_PASSWORD=change-me-123 WIRELESS_SUBNET=10.42.0.0/24 ./deploy_wireless_lan_debian13.sh
```

Useful overrides:

```bash
sudo WIFI_IFACE=wlp2s0 WIRELESS_SSID=RRMS WIRELESS_PASSWORD=change-me-123 WIRELESS_SUBNET=10.50.0.0/24 ./deploy_wireless_lan_debian13.sh
sudo UPSTREAM_IFACE=enp1s0 ./deploy_wireless_lan_debian13.sh
sudo ENABLE_NAT=0 ./deploy_wireless_lan_debian13.sh
```

If `WIRELESS_PASSWORD` is omitted, the script generates one and stores it in `/root/rrms-wireless.password.txt`.

Remote deploy:

```bash
scp deploy_wireless_lan_debian13.sh root@192.168.75.208:/root/
ssh root@192.168.75.208 'WIRELESS_PASSWORD=change-me-123 WIRELESS_SUBNET=10.42.0.0/24 bash /root/deploy_wireless_lan_debian13.sh'
```
