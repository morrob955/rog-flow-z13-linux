#!/bin/bash
# One-time setup for CPU undervolting (Curve Optimizer) on the ROG Flow Z13 (Ryzen AI Max+ 395),
# with Secure Boot left on. Optional, separate from install.sh (run that first).
# Run with: sudo bash undervolt.sh      Undo with: sudo bash undervolt.sh --undo
#
# 1. Builds the ryzen_smu driver (talks to the CPU's power controller) through dkms, which
#    signs it with a machine owner key (MOK) and rebuilds it on every kernel update.
# 2. Builds RyzenAdj, which sends the Curve Optimizer value through that driver.
# 3. Installs /usr/local/sbin/z13-undervolt, a small root helper the widget may run without a
#    password (only 0..50, nothing else), plus a boot guard and a resume hook. The undervolt
#    resets on every boot and resume, so those put it back. If the machine crashes while an
#    undervolt is on, the next boot skips it automatically.
# 4. Queues the MOK for enrollment. On the next restart a blue "MOK management" screen appears:
#    Enroll MOK > Continue > Yes > type the password you set here > Reboot.
# 5. Writes ~/.config/z13control-undervolt with a conservative -10 for every mode, if it doesn't
#    exist yet. The widget applies the active mode's value on every mode switch and at login.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

SMU_COMMIT=d2983668300dd2a598e5a7dc40e71ce0678cc270   # amkillam/ryzen_smu, 2026-08-15 (7.2 kernel fix)
SMU_VERSION=0.1.7
ADJ_TAG=v0.19.0                                       # FlyGoat/RyzenAdj, Strix Halo support
HELPER=/usr/local/sbin/z13-undervolt
STATE=/var/lib/z13-undervolt
SUDOERS=/etc/sudoers.d/z13-undervolt
GUARD=/etc/systemd/system/z13-undervolt-guard.service
SLEEP_HOOK=/usr/lib/systemd/system-sleep/z13-undervolt
user=${SUDO_USER:-$(logname)}

if [[ ${1:-} == --undo ]]; then
    systemctl disable --now z13-undervolt-guard.service 2>/dev/null || true
    rm -fv "$GUARD" "$SLEEP_HOOK" "$SUDOERS" "$HELPER" /usr/local/bin/ryzenadj /etc/modules-load.d/ryzen_smu.conf
    rm -rfv "$STATE"
    systemctl daemon-reload
    modprobe -r ryzen_smu 2>/dev/null || true
    dkms remove ryzen_smu/$SMU_VERSION --all 2>/dev/null || true
    rm -rf /usr/src/ryzen_smu-$SMU_VERSION
    echo "Undone. The enrolled key stays trusted (harmless); remove it with: mokutil --delete /var/lib/dkms/mok.pub"
    exit 0
fi

echo "== Build tools"
dnf install -y dkms kernel-devel "kernel-devel-$(uname -r)" gcc gcc-c++ make cmake pciutils-devel git mokutil openssl

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "== ryzen_smu driver"
git clone -q https://github.com/amkillam/ryzen_smu.git "$work/ryzen_smu"
git -C "$work/ryzen_smu" checkout -q $SMU_COMMIT
dkms remove ryzen_smu/$SMU_VERSION --all >/dev/null 2>&1 || true
rm -rf /usr/src/ryzen_smu-$SMU_VERSION
make -C "$work/ryzen_smu" dkms-install
echo ryzen_smu > /etc/modules-load.d/ryzen_smu.conf
echo "signer: $(modinfo -F signer ryzen_smu 2>/dev/null || echo none)"

echo "== RyzenAdj"
git -c advice.detachedHead=false clone -q --depth 1 --branch $ADJ_TAG https://github.com/FlyGoat/RyzenAdj.git "$work/RyzenAdj"
cmake -S "$work/RyzenAdj" -B "$work/RyzenAdj/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
make -C "$work/RyzenAdj/build" -j"$(nproc)" >/dev/null
install -m 755 "$work/RyzenAdj/build/ryzenadj" /usr/local/bin/ryzenadj

echo "== Undervolt helper"
mkdir -p "$STATE"
cat > "$HELPER" <<'EOF'
#!/bin/bash
# Z13 Control undervolt helper (root). Curve Optimizer all-core offset, 0..50 steps negative.
#   z13-undervolt set <n>   apply -n now (explicit user choice; clears a crash flag)
#   z13-undervolt auto <n>  apply -n unless the last boot crashed with an undervolt on
#   z13-undervolt resume    re-apply the current value after sleep (the CPU forgets it)
#   z13-undervolt status    print available=, undervolt=, crashed=, mp1=, rsmu=
set -euo pipefail
S=/var/lib/z13-undervolt
SMU=/sys/kernel/ryzen_smu_drv
mkdir -p $S

# Strix Halo takes the all-core offset on two mailboxes, like UXTU sends it: MP1 0x4C (what
# RyzenAdj sends) and RSMU 0x5D. Each reply is 1 when accepted (0xFE unknown, 0xFD rejected).
send() { # mailbox command value -> prints the reply code
    python3 -I - "$SMU" "$1" "$2" "$3" <<'PY'
import struct, sys
smu, box, cmd, val = sys.argv[1], sys.argv[2], int(sys.argv[3], 0), int(sys.argv[4], 0)
with open(f"{smu}/smu_args", "wb", buffering=0) as f:
    f.write(struct.pack("<6I", val, 0, 0, 0, 0, 0))
with open(f"{smu}/{box}_cmd", "wb", buffering=0) as f:
    f.write(struct.pack("<I", cmd))
with open(f"{smu}/{box}_cmd", "rb") as f:
    print(hex(struct.unpack("<I", f.read(4))[0]))
PY
}

apply() {
    [[ $1 =~ ^[0-9]+$ ]] && (( $1 <= 50 )) || { echo "undervolt must be 0..50" >&2; exit 2; }
    v=$((0x100000 - $1))
    echo "mp1=$(send mp1_smu 0x4C $v) rsmu=$(send rsmu 0x5D $v)" > $S/reply
    echo "$1" > $S/current
    # "armed" marks an undervolt as active; the guard turns a leftover one into "crashed" at boot.
    if (( $1 > 0 )); then touch $S/armed; else rm -f $S/armed; fi
    cat $S/reply
}

case "${1:-}" in
set) rm -f $S/crashed; apply "${2:-}" ;;
auto)
    if [[ -e $S/crashed ]]; then echo "skipped: last boot crashed with an undervolt on" >&2; exit 3; fi
    apply "${2:-}"
    ;;
resume) [[ -s $S/current && ! -e $S/crashed ]] && apply "$(cat $S/current)" || true ;;
status)
    [[ -e $SMU/drv_version ]] && echo available=1 || echo available=0
    echo "undervolt=$(cat $S/current 2>/dev/null || echo 0)"
    [[ -e $S/crashed ]] && echo crashed=1 || echo crashed=0
    tr ' ' '\n' < $S/reply 2>/dev/null || true
    ;;
*) sed -n '2,7p' "$0"; exit 1 ;;
esac
EOF
chmod 755 "$HELPER"

cat > "$SUDOERS" <<EOF
# Z13 Control: the widget may apply CPU undervolts without a password (helper validates 0..50).
$user ALL=(root) NOPASSWD: $HELPER
EOF
chmod 440 "$SUDOERS"
visudo -cf "$SUDOERS"

cat > "$GUARD" <<EOF
# Z13 Control: a boot that starts with "armed" still present means the last one ended without a
# clean shutdown while undervolted, so mark it crashed and keep the undervolt off until reset.
[Unit]
Description=Z13 undervolt crash guard

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'rm -f $STATE/current; [ -e $STATE/armed ] && mv $STATE/armed $STATE/crashed || true'
ExecStop=/bin/rm -f $STATE/armed

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now z13-undervolt-guard.service

cat > "$SLEEP_HOOK" <<EOF
#!/bin/sh
# Z13 Control: the CPU drops the Curve Optimizer value in sleep; put it back on wake.
[ "\$1" = post ] && $HELPER resume
exit 0
EOF
chmod 755 "$SLEEP_HOOK"

echo "== Per-mode values"
home=$(getent passwd "$user" | cut -d: -f6)
conf=$home/.config/z13control-undervolt
if [[ ! -e $conf ]]; then
    install -o "$user" -g "$(id -gn "$user")" -m 644 /dev/null "$conf"
    printf 'quiet=10\nbalanced=10\nperformance=10\n' > "$conf"
fi
echo "$conf:"; cat "$conf"

echo "== Signing key"
key=/var/lib/dkms/mok.pub
if [[ ! -e $key ]]; then
    echo "dkms didn't create $key; check 'dkms status' output above."; exit 1
fi
if mokutil --test-key "$key" 2>&1 | grep -q 'already enrolled'; then
    echo "Key already enrolled."
    modprobe ryzen_smu && echo "ryzen_smu loaded: $(cat /sys/kernel/ryzen_smu_drv/drv_version)"
else
    echo
    echo "Pick a one-time password now (you'll type it once on the blue screen after restarting):"
    mokutil --import "$key"
    echo
    echo "Done. Restart, and on the blue MOK management screen choose:"
    echo "  Enroll MOK > Continue > Yes > (type that password) > Reboot"
    echo "Use the physical keyboard there. If you miss it, nothing breaks: re-run this script and restart."
fi
