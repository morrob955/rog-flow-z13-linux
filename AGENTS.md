# Instructions for AI agents

You are probably helping someone set up **Z13 Control**, a KDE Plasma widget for the ASUS ROG Flow Z13 2025 (GZ302) on Fedora. Follow these steps in order and report the results to the user truthfully.

## 1. Check the machine first

```bash
cat /sys/class/dmi/id/board_name     # must start with GZ302
grep -E '^(ID|VERSION_ID)=' /etc/os-release   # expected: fedora, 44
echo $XDG_CURRENT_DESKTOP            # expected: KDE
plasmashell --version                # expected: 6.x (tested on 6.7)
uname -r                             # recent kernel with asus-armoury
ls /sys/class/firmware-attributes/asus-armoury/attributes   # must list ppt_pl1_spl, panel_overdrive
```

If the model isn't GZ302 or the desktop isn't KDE Plasma, tell the user it's unsupported and stop. Only continue if they still want to try. `install.sh --force` skips the model check, but the hardware paths are GZ302-specific.

If `asus-armoury` is missing, the kernel is too old. Suggest `sudo dnf upgrade --refresh` and a reboot. Don't build kernels.

## 2. Install

```bash
git clone https://github.com/morrob955/rog-flow-z13-linux.git
cd rog-flow-z13-linux
./install.sh
```

- Run it as the normal user, **never with sudo**. It calls sudo itself for the dnf, udev and asusd steps.
- sudo needs the user's password. If your shell can't prompt for one, ask the user to run `./install.sh` themselves in a terminal (in Claude Code they can type `! ./install.sh`).
- It enables the `lukenukem/asus-linux` COPR to get `asusctl`. Tell the user this before running it: it adds a third-party repo.

## 3. Verify

```bash
systemctl is-active asusd                       # active
systemctl --user is-active ydotoold z13-rear    # active / active or inactive (z13-rear is a oneshot: inactive after a successful run is fine)
getfacl /dev/uinput | grep "user:$USER"         # user:<name>:rw-
kpackagetool6 -t Plasma/Applet -s org.slug.z13control   # prints the widget's details
sh ~/.local/share/plasma/plasmoids/org.slug.z13control/contents/code/z13.sh status   # key=value lines, e.g. mode=balanced spl=60
```

`getfacl` only shows the ACL after udev has re-triggered for an active session. If it's missing, have the user log out and back in.

Then tell the user to add the widget: right-click the panel → **Add or Manage Widgets** → **Z13 Control**. Optionally they can bind a key to it in System Settings → Keyboard → Shortcuts.

## 4. Optional fixes (ask first)

`fixes.sh` changes kernel arguments, firmware lookup and a udev rule (quiet speakers, screen flicker, keyboard waking from suspend). **Don't run it without the user's explicit OK.** Explain the three fixes from the README, then have them run `sudo bash fixes.sh` and reboot. Revert with `sudo bash fixes.sh --undo`.

## Troubleshooting

| Problem | What to check |
|---|---|
| Power/fan controls don't change anything | `systemctl status asusd`; `asusctl --version` should be 6.3.x. Other major versions may have a different D-Bus API (`xyz.ljones.Asusd` is expected). |
| Mode switches but CPU boost stays off/on | `busctl --system get-property org.freedesktop.UPower.PowerProfiles /org/freedesktop/UPower/PowerProfiles org.freedesktop.UPower.PowerProfiles ActiveProfile` should match the mode (power-saver / balanced / performance). Needs tuned-ppd or power-profiles-daemon. |
| Arrow pad does nothing | `systemctl --user status ydotoold`; the socket must exist at `$XDG_RUNTIME_DIR/.ydotool_socket`; `/dev/uinput` must be writable by the user. Test with `ydotool key 103:1 103:0` (Up). |
| Keyboard button does nothing | Expected with mouse or keyboard input: KWin only shows the on-screen keyboard after touch or pen input. |
| Rear light bar ignored | `/etc/udev/rules.d/70-z13-rear.rules` present; `ls -l /dev/hidraw*` ACLs; reboot. |
| Widget shows old version after update | Log out and back in (or `systemctl --user restart plasma-plasmashell`). |

## Layout

- `widget/`: the Plasma package (`metadata.json`, `contents/ui/main.qml` UI, `contents/code/z13.sh` backend, `contents/code/rear.py` rear light bar driver)
- `system/`: udev rules and user systemd units installed by `install.sh`
- `install.sh`: install, update (`./install.sh`) and `--uninstall`
- `fixes.sh`: optional system fixes, independent of the widget

## Uninstall

`./install.sh --uninstall` removes the widget, its udev rules, user services and saved light bar state. It leaves packages and the COPR in place. Tell the user they can remove those with `sudo dnf remove asusctl ydotool` and `sudo dnf copr remove lukenukem/asus-linux` if they want.
