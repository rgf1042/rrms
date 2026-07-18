#!/usr/bin/env bash
set -euo pipefail

# Deploy a simple dedicated JMRI workstation on Debian 13/Xfce.
# Run as root on the target host.

JMRI_USER="${JMRI_USER:-jmri}"
JMRI_FULL_NAME="${JMRI_FULL_NAME:-JMRI}"
JMRI_DOWNLOAD_URL="${JMRI_DOWNLOAD_URL:-https://github.com/JMRI/JMRI/releases/download/v5.14/JMRI.5.14+Rdea51dcccf.tgz}"
JMRI_SHA256="${JMRI_SHA256:-757ae54505f8896a91167bd1ca3b8ad7470b1f635526ef07497d72bf9370ba0e}"
FORCE_JMRI_REINSTALL="${FORCE_JMRI_REINSTALL:-0}"
VNC_PORT="${VNC_PORT:-5900}"
VNC_LISTEN="${VNC_LISTEN:-0.0.0.0}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
VNC_PASSWORD_TEXT_FILE="${VNC_PASSWORD_TEXT_FILE:-/root/x11vnc.password.txt}"
VNC_NCACHE="${VNC_NCACHE:-0}"
XORG_DUMMY="${XORG_DUMMY:-1}"
XORG_DUMMY_MODE="${XORG_DUMMY_MODE:-1280x720}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "==> Installing packages"
apt-get update
apt-get install -y \
  ca-certificates \
  curl \
  dbus-x11 \
  default-jre \
  lightdm \
  openssl \
  tar \
  x11vnc \
  x11-utils \
  xserver-xorg-video-dummy \
  xfce4 \
  xfce4-terminal

echo "==> Creating/updating user ${JMRI_USER}"
if ! id "${JMRI_USER}" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "${JMRI_FULL_NAME}" "${JMRI_USER}"
fi
usermod -a -G dialout,plugdev,tty,video,input "${JMRI_USER}"

JMRI_HOME="$(getent passwd "${JMRI_USER}" | cut -d: -f6)"
install -d -o "${JMRI_USER}" -g "${JMRI_USER}" "${JMRI_HOME}/bin" "${JMRI_HOME}/.config" "${JMRI_HOME}/.config/autostart"
chown -R "${JMRI_USER}:${JMRI_USER}" "${JMRI_HOME}/.config"

echo "==> Installing JMRI"
if [[ -d "${JMRI_HOME}/JMRI" && "${FORCE_JMRI_REINSTALL}" != "1" ]]; then
  echo "    Existing JMRI install found; leaving it in place."
else
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT
  archive="${tmpdir}/jmri.tgz"
  curl -fsSL "${JMRI_DOWNLOAD_URL}" -o "${archive}"
  echo "${JMRI_SHA256}  ${archive}" | sha256sum -c -

  extract_dir="${tmpdir}/extract"
  install -d "${extract_dir}"
  tar xzf "${archive}" -C "${extract_dir}"
  jmri_src="$(find "${extract_dir}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ -z "${jmri_src}" ]]; then
    echo "Could not find extracted JMRI directory." >&2
    exit 1
  fi

  if [[ -d "${JMRI_HOME}/JMRI" ]]; then
    backup="${JMRI_HOME}/JMRI.backup.$(date +%Y%m%d%H%M%S)"
    echo "    Existing JMRI install found; moving it to ${backup}"
    mv "${JMRI_HOME}/JMRI" "${backup}"
  fi
  mv "${jmri_src}" "${JMRI_HOME}/JMRI"
  chown -R "${JMRI_USER}:${JMRI_USER}" "${JMRI_HOME}/JMRI"
fi

echo "==> Creating JMRI Xfce autostart launcher"
cat >"${JMRI_HOME}/bin/disable-desktop-locking.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

while ! xdpyinfo >/dev/null 2>&1; do
  sleep 1
done

xset s off -dpms s noblank || true
pkill -u "${USER}" light-locker 2>/dev/null || true
pkill -u "${USER}" xfce4-screensaver 2>/dev/null || true
EOF
chmod 0755 "${JMRI_HOME}/bin/disable-desktop-locking.sh"
chown "${JMRI_USER}:${JMRI_USER}" "${JMRI_HOME}/bin/disable-desktop-locking.sh"

cat >"${JMRI_HOME}/bin/start-jmri.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export JMRI_HOME="${HOME}/JMRI"
export JMRI_USERHOME="${HOME}"
export JMRI_PREFSDIR="${HOME}/.jmri"

mkdir -p "${HOME}/.jmri/log"
cd "${JMRI_HOME}"

while ! xdpyinfo >/dev/null 2>&1; do
  sleep 1
done

sleep 8
exec "${JMRI_HOME}/PanelPro" >>"${HOME}/.jmri/log/panelpro-autostart.log" 2>&1
EOF
chmod 0755 "${JMRI_HOME}/bin/start-jmri.sh"
chown "${JMRI_USER}:${JMRI_USER}" "${JMRI_HOME}/bin/start-jmri.sh"

cat >"${JMRI_HOME}/.config/autostart/disable-desktop-locking.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Disable Desktop Locking
Comment=Disable screen locking and blanking for the JMRI appliance desktop
Exec=${JMRI_HOME}/bin/disable-desktop-locking.sh
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

cat >"${JMRI_HOME}/.config/autostart/light-locker.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Light Locker
Hidden=true
EOF

cat >"${JMRI_HOME}/.config/autostart/xfce4-screensaver.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Xfce Screensaver
Hidden=true
EOF

cat >"${JMRI_HOME}/.config/autostart/jmri-panelpro.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=JMRI PanelPro
Comment=Start JMRI PanelPro at login
Exec=${JMRI_HOME}/bin/start-jmri.sh
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
rm -f "${JMRI_HOME}/.config/autostart/jmri-panelpro.desktop.disabled"
chown "${JMRI_USER}:${JMRI_USER}" \
  "${JMRI_HOME}/.config/autostart/disable-desktop-locking.desktop" \
  "${JMRI_HOME}/.config/autostart/light-locker.desktop" \
  "${JMRI_HOME}/.config/autostart/xfce4-screensaver.desktop" \
  "${JMRI_HOME}/.config/autostart/jmri-panelpro.desktop"

cat >"${JMRI_HOME}/.dmrc" <<EOF
[Desktop]
Session=xfce
EOF
chown "${JMRI_USER}:${JMRI_USER}" "${JMRI_HOME}/.dmrc"
chmod 0644 "${JMRI_HOME}/.dmrc"

echo "==> Configuring lightweight Xfce defaults"
xfce_config="${JMRI_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml"
install -d -o "${JMRI_USER}" -g "${JMRI_USER}" "${xfce_config}"
rm -f "${xfce_config}/displays.xml"

cat >"${xfce_config}/xfwm4.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
EOF

cat >"${xfce_config}/xfce4-power-manager.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="blank-on-ac" type="int" value="0"/>
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="lock-screen-suspend-hibernate" type="bool" value="false"/>
    <property name="show-tray-icon" type="bool" value="false"/>
  </property>
</channel>
EOF

cat >"${xfce_config}/xfce4-desktop.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="0"/>
          <property name="rgba1" type="array">
            <value type="double" value="0.18"/>
            <value type="double" value="0.20"/>
            <value type="double" value="0.22"/>
            <value type="double" value="1.00"/>
          </property>
        </property>
      </property>
    </property>
  </property>
</channel>
EOF

chown -R "${JMRI_USER}:${JMRI_USER}" "${JMRI_HOME}/.config"

echo "==> Configuring LightDM autologin"
install -d /etc/lightdm/lightdm.conf.d
cat >/etc/lightdm/lightdm.conf.d/50-jmri-autologin.conf <<EOF
[Seat:*]
autologin-user=${JMRI_USER}
autologin-user-timeout=0
user-session=xfce
EOF

echo "==> Configuring Xorg display"
install -d /etc/X11/xorg.conf.d
if [[ "${XORG_DUMMY}" == "1" ]]; then
  case "${XORG_DUMMY_MODE}" in
    1024x768)
      dummy_modeline='Modeline "1024x768" 65.00 1024 1048 1184 1344 768 771 777 806 -HSync -VSync'
      ;;
    1280x720)
      dummy_modeline='Modeline "1280x720" 74.25 1280 1390 1430 1650 720 725 730 750 +HSync +VSync'
      ;;
    1920x1080)
      dummy_modeline='Modeline "1920x1080" 148.50 1920 2008 2052 2200 1080 1084 1089 1125 +HSync +VSync'
      ;;
    *)
      echo "Unsupported XORG_DUMMY_MODE=${XORG_DUMMY_MODE}; use 1024x768, 1280x720, or 1920x1080." >&2
      exit 1
      ;;
  esac

  cat >/etc/X11/xorg.conf.d/20-jmri-dummy-display.conf <<EOF
Section "Device"
    Identifier  "JMRI Dummy Video"
    Driver      "dummy"
    VideoRam    256000
EndSection

Section "Monitor"
    Identifier  "JMRI Dummy Monitor"
    HorizSync   28.0-80.0
    VertRefresh 48.0-75.0
    ${dummy_modeline}
EndSection

Section "Screen"
    Identifier "JMRI Dummy Screen"
    Device     "JMRI Dummy Video"
    Monitor    "JMRI Dummy Monitor"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "${XORG_DUMMY_MODE}"
        Virtual ${XORG_DUMMY_MODE%x*} ${XORG_DUMMY_MODE#*x}
    EndSubSection
EndSection

Section "ServerLayout"
    Identifier "JMRI Headless Layout"
    Screen     "JMRI Dummy Screen"
EndSection
EOF
else
  rm -f /etc/X11/xorg.conf.d/20-jmri-dummy-display.conf
fi

echo "==> Configuring x11vnc"
if [[ -n "${VNC_PASSWORD}" ]]; then
  VNC_PASSWORD="${VNC_PASSWORD:0:8}"
  x11vnc -storepasswd "${VNC_PASSWORD}" /etc/x11vnc.pass >/dev/null
  printf '%s\n' "${VNC_PASSWORD}" >"${VNC_PASSWORD_TEXT_FILE}"
  chmod 0600 /etc/x11vnc.pass "${VNC_PASSWORD_TEXT_FILE}"
elif [[ ! -f /etc/x11vnc.pass || ! -f "${VNC_PASSWORD_TEXT_FILE}" ]]; then
  VNC_PASSWORD="$(openssl rand -hex 4)"
  x11vnc -storepasswd "${VNC_PASSWORD}" /etc/x11vnc.pass >/dev/null
  printf '%s\n' "${VNC_PASSWORD}" >"${VNC_PASSWORD_TEXT_FILE}"
  chmod 0600 /etc/x11vnc.pass "${VNC_PASSWORD_TEXT_FILE}"
else
  echo "    Existing x11vnc password found; leaving it in place."
  chmod 0600 /etc/x11vnc.pass
fi

x11vnc_cache_args=""
if [[ "${VNC_NCACHE}" != "0" ]]; then
  x11vnc_cache_args="-ncache ${VNC_NCACHE} -ncache_cr"
fi

cat >/etc/systemd/system/jmri-panelpro.service <<EOF
[Unit]
Description=Deprecated: JMRI PanelPro is started by Xfce autostart
After=display-manager.service
Requires=display-manager.service

[Service]
Type=simple
User=${JMRI_USER}
Environment=DISPLAY=:0
Environment=XAUTHORITY=${JMRI_HOME}/.Xauthority
ExecStart=${JMRI_HOME}/bin/start-jmri.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/x11vnc.service <<EOF
[Unit]
Description=x11vnc for the JMRI desktop session
After=display-manager.service
Requires=display-manager.service

[Service]
Type=simple
ExecStartPre=/bin/sleep 4
ExecStart=/usr/bin/x11vnc -display :0 -auth guess -forever -shared -repeat -solid grey -nowf -noscr ${x11vnc_cache_args} -wait 20 -defer 10 -rfbport ${VNC_PORT} -listen ${VNC_LISTEN} -rfbauth /etc/x11vnc.pass -o /var/log/x11vnc.log
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable lightdm.service
systemctl disable --now jmri-panelpro.service >/dev/null 2>&1 || true
systemctl enable x11vnc.service
systemctl restart lightdm.service
systemctl restart x11vnc.service

cat >"${JMRI_HOME}/JMRI_FIRST_RUN.txt" <<EOF
JMRI is installed in ${JMRI_HOME}/JMRI and PanelPro starts when ${JMRI_USER} logs in.

To make the JMRI Web Server start automatically on a new profile:
1. Attach to the desktop with VNC.
2. In PanelPro open Edit > Preferences > Start Up.
3. Add "Perform action..." and select "Start JMRI Web Server".
4. Save preferences and restart PanelPro.

The default JMRI web server URL is:
  http://$(hostname -I | awk '{print $1}'):12080/

x11vnc is listening on:
  ${VNC_LISTEN}:${VNC_PORT}

The generated x11vnc password is stored on the target at ${VNC_PASSWORD_TEXT_FILE}.
Set your own password with:
  VNC_PASSWORD=yourpass bash /root/deploy_jmri_debian13.sh
EOF
chown "${JMRI_USER}:${JMRI_USER}" "${JMRI_HOME}/JMRI_FIRST_RUN.txt"

echo
echo "Deployment complete."
echo "User: ${JMRI_USER}"
echo "JMRI: ${JMRI_HOME}/JMRI"
echo "VNC: ${VNC_LISTEN}:${VNC_PORT}"
echo "VNC password file: ${VNC_PASSWORD_TEXT_FILE}"
echo "Read: ${JMRI_HOME}/JMRI_FIRST_RUN.txt"
