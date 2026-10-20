#!/bin/bash
# Optional ROG Flow Z13 (2025, GZ302) fixes for Fedora. Independent of the widget.
# Run with: sudo bash fixes.sh      Undo with: sudo bash fixes.sh --undo
#
# 1. Speakers: Linux loads the CS35L41 amps' 15.5 dB gain config, so they're
#    much quieter than on Windows. linux-firmware also ships a 19.5 dB config;
#    we point the kernel at it via /lib/firmware/updates (searched before
#    /lib/firmware), so stock files are untouched and package updates won't
#    undo it. The amps' speaker-protection DSP stays active.
# 2. Screen flicker: disable eDP Panel Self Refresh and Panel Replay
#    (amdgpu.dcdebugmask=0x410). Costs a little battery at idle.
# 3. Spurious wake: with the keyboard folded over the screen, it keeps waking
#    the machine over USB. Disable wake on its USB controller (0000:c6:00.0).
#    Opening the lid still wakes it (lid switch goes through the EC, not USB),
#    as does the power button.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

fwdir=/lib/firmware/updates/cirrus
bincfg=cs35l41/bincfgs/cs35l41-dsp1-19_5dB.bincfg.xz
kargs="amdgpu.dcdebugmask=0x410"
kbd_xhci=0000:c6:00.0
udev_rule=/etc/udev/rules.d/90-z13-keyboard-nowake.rules

if [[ ${1:-} == --undo ]]; then
    rm -fv "$fwdir"/cs35l41-dsp1-spk-prot-10431fb3-{l0,r0}.bincfg.xz
    grubby --update-kernel=ALL --remove-args="$kargs"
    rm -fv "$udev_rule"
    echo enabled > /sys/bus/pci/devices/$kbd_xhci/power/wakeup
    echo "Undone. Reboot to finish."
    exit 0
fi

echo "== Speakers"
if [[ -e /lib/firmware/cirrus/$bincfg ]]; then
    mkdir -p "$fwdir"
    for side in l0 r0; do
        ln -sfnv "../../cirrus/$bincfg" "$fwdir/cs35l41-dsp1-spk-prot-10431fb3-$side.bincfg.xz"
    done
    restorecon -R /lib/firmware/updates 2>/dev/null || true
else
    echo "19.5 dB config not found in linux-firmware; skipped."
fi

echo "== Screen flicker"
grubby --update-kernel=ALL --args="$kargs"
grubby --info=DEFAULT | grep ^args

echo "== Keyboard wake"
cat > "$udev_rule" <<EOF
# Keyboard folio's USB controller: don't let it wake the system from suspend.
ACTION=="add", SUBSYSTEM=="pci", KERNEL=="$kbd_xhci", ATTR{power/wakeup}="disabled"
EOF
echo disabled > /sys/bus/pci/devices/$kbd_xhci/power/wakeup
echo "$kbd_xhci wakeup: $(cat /sys/bus/pci/devices/$kbd_xhci/power/wakeup)"

echo
echo "Done. Reboot to apply the speaker and flicker fixes (keyboard wake is already active)."
echo "If the bass distorts above ~80% volume or anything else is off: sudo bash $0 --undo"
