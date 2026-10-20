#!/bin/bash
# Installs the Z13 Control widget and everything it needs on Fedora KDE.
# Run as your normal user (it asks for sudo when needed):
#   ./install.sh               install or update
#   ./install.sh --uninstall   remove the widget, its rules and services (packages stay)
#   ./install.sh --force       skip the GZ302 model check
set -euo pipefail

cd "$(dirname "$0")"
ID=org.slug.z13control
RULES="70-z13-rear.rules 90-z13-uinput.rules"
UNITS="z13-rear.service ydotoold.service"
UNITDIR=~/.config/systemd/user

[[ $EUID -ne 0 ]] || { echo "Run as your normal user, not with sudo."; exit 1; }

if [[ ${1:-} == --uninstall ]]; then
    systemctl --user disable --now $UNITS 2>/dev/null || true
    for u in $UNITS; do rm -fv "$UNITDIR/$u"; done
    systemctl --user daemon-reload
    for r in $RULES; do sudo rm -fv "/etc/udev/rules.d/$r"; done
    sudo udevadm control --reload
    kpackagetool6 -t Plasma/Applet -r $ID || true
    rm -fv ~/.config/z13control-rear
    echo "Uninstalled. asusctl, ydotool and the other packages were left installed."
    exit 0
fi

model=$(cat /sys/class/dmi/id/board_name 2>/dev/null || true)
if [[ $model != GZ302* && ${1:-} != --force ]]; then
    echo "This is built for the ROG Flow Z13 2025 (GZ302); this machine reports '$model'."
    echo "Re-run with --force to install anyway."
    exit 1
fi
grep -q '^ID=fedora' /etc/os-release || echo "Warning: only tested on Fedora 44 KDE."

echo "== Packages"
# asusctl (asusd) isn't in Fedora's repos; it comes from the asus-linux COPR.
if ! rpm -q asusctl >/dev/null; then
    sudo dnf copr enable -y lukenukem/asus-linux
fi
pkgs="asusctl ydotool python3 libkscreen plasma-keyboard libksysguard kf6-kquickcharts plasma5support"
# Mode syncing talks to the power-profiles D-Bus API, which tuned-ppd (Fedora's default)
# and power-profiles-daemon both provide. Only add one if neither is there.
rpm -q tuned-ppd >/dev/null || rpm -q power-profiles-daemon >/dev/null || pkgs="$pkgs tuned-ppd"
sudo dnf install -y $pkgs
# asusd is a static unit (udev/D-Bus start it at boot); just make sure it runs now.
sudo systemctl start asusd

echo "== Device access"
# Rear light bar (hidraw) and /dev/uinput (arrow pad) for the logged-in user.
for r in $RULES; do sudo install -m 644 "system/$r" /etc/udev/rules.d/; done
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=hidraw
sudo udevadm trigger --name-match=uinput

echo "== Widget"
if kpackagetool6 -t Plasma/Applet -s $ID >/dev/null 2>&1; then
    kpackagetool6 -t Plasma/Applet -u widget
else
    kpackagetool6 -t Plasma/Applet -i widget
fi

echo "== User services"
mkdir -p "$UNITDIR"
for u in $UNITS; do install -m 644 "system/$u" "$UNITDIR/"; done
systemctl --user daemon-reload
sleep 1  # let udev apply the uinput permission before ydotoold opens it
systemctl --user enable --now $UNITS
systemctl --user is-active ydotoold.service

echo
echo "Done. Add it with right-click on the panel > Add or Manage Widgets > \"Z13 Control\","
echo "or give it a shortcut in System Settings > Keyboard > Shortcuts (search \"Z13\")."
echo "If the widget was already on your panel, log out and back in to load the new version."
