#!/usr/bin/python3 -I
"""Z13 rear light bar (0b05:18c6). asusd 6.x doesn't drive it, so this writes the
hidraw interfaces directly. Aura output reports on interface 0 wake it, set power
and brightness, and set the effect; the firmware then animates it as long as the
LampArray on interface 1 is left in autonomous mode. Wake packets come from asusctl
PR #390; the effect needs a SetMode for zone 0 (which carries the colour) and zone 1.
asusd re-sends its own stored colour for this device, so restore runs after every
asusd lighting write and whenever the device appears (udev -> z13-rear.service).

  rear.py <brightness 0-3> <mode 0|1|10> <r> <g> <b>   apply and remember
  rear.py restore                                      re-apply the remembered setting
  rear.py status                                       print rearbright=, rearmode=, rearcolour=
"""
import fcntl, glob, os, sys

STATE = os.path.expanduser("~/.config/z13control-rear")


def node(iface):
    for h in glob.glob("/sys/class/hidraw/hidraw*"):
        with open(h + "/device/uevent") as f:
            if "0B05:000018C6" not in f.read():
                continue
        with open(h + "/device/../bInterfaceNumber") as f:
            if f.read().strip() == iface:
                return "/dev/" + os.path.basename(h)
    sys.exit("rear light bar not found")


def load():
    try:
        with open(STATE) as f:
            level, mode, r, g, b = map(int, f.read().split())
            return level, mode, [r, g, b]
    except (OSError, ValueError):
        return 2, 0, [0, 60, 255]


def apply(level, mode, rgb):
    # SetMode: zone, mode, colour, speed (med), direction, flag, second colour (black, for breathe)
    flag = 0xFF if not any(rgb) else 1 if mode == 1 else 0
    packets = [b"\x5d\xb9", b"]ASUS Tech.Inc.", b"\x5d\x05\x20\x31\x00\x1a", b"\x5d\xc0\x03\x01",
               b"\x5d\xbd\x01\xff\x1f\xff\xff\xff" if level else b"\x5d\xbd\x01\x00\x00\x00\x00\xff",
               bytes([0x5D, 0xBA, 0xC5, 0xC4, level])]
    for zone in 0, 1:
        packets += [bytes([0x5D, 0xB3, zone, mode, *rgb, 0xEB, 0, flag, 0, 0, 0]),
                    b"\x5d\xb5\x00\x00\x00", b"\x5d\xb4"]
    aura = os.open(node("00"), os.O_WRONLY)
    for p in packets:
        os.write(aura, p.ljust(64, b"\0"))
    os.close(aura)

    lamp = os.open(node("01"), os.O_RDWR)
    fcntl.ioctl(lamp, 0xC0004806 | 2 << 16, bytearray(b"\x06\x01"))  # HIDIOCSFEATURE: autonomous mode on
    os.close(lamp)


cmd = sys.argv[1:]
if cmd == ["status"]:
    level, mode, rgb = load()
    print(f"rearbright={level}\nrearmode={mode}\nrearcolour={' '.join(map(str, rgb))}")
elif cmd == ["restore"]:
    apply(*load())
elif len(cmd) == 5:
    level, mode, *rgb = map(int, cmd)
    apply(level, mode, rgb)
    with open(STATE, "w") as f:
        f.write(" ".join(map(str, cmd)) + "\n")
else:
    sys.exit(__doc__)
