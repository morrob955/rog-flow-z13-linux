#!/bin/sh
# Z13 Control backend. Talks to asusd over D-Bus directly: asusctl 6.3.8 reports
# stale PPT values and asusd silently skips PPT writes unless the active
# profile's tuning group is enabled, so every power write enables it first.
B="busctl --system"
D=xyz.ljones.Asusd
P="$D /xyz/ljones xyz.ljones.Platform"
ARM=/sys/class/firmware-attributes/asus-armoury/attributes
REAR="$(dirname "$0")/rear.py"
PPD="org.freedesktop.UPower.PowerProfiles /org/freedesktop/UPower/PowerProfiles org.freedesktop.UPower.PowerProfiles"
# KDE numbers its displays per session (display0, display1, ...); use the built-in one.
display() {
    for d in $(busctl --user get-property org.kde.ScreenBrightness /org/kde/ScreenBrightness org.kde.ScreenBrightness DisplaysDBusNames | cut -d' ' -f3- | tr -d '"'); do
        [ "$(busctl --user get-property org.kde.ScreenBrightness /org/kde/ScreenBrightness/$d org.kde.ScreenBrightness.Display IsInternal)" = "b true" ] && { echo "/org/kde/ScreenBrightness/$d"; return; }
    done
}
BD=$(display)
SB="org.kde.ScreenBrightness $BD org.kde.ScreenBrightness.Display"

hwmon() { # name file
    for h in /sys/class/hwmon/hwmon*; do
        [ "$(cat "$h/name")" = "$1" ] && cat "$h/$2" && return
    done
    echo 0
}

aura() { $B tree --list $D | grep /aura/; }

armoury() { $B set-property $D /xyz/ljones/asus_armoury/"$1" xyz.ljones.AsusArmoury CurrentValue i "$2"; }

ppt() { # spl sppt fppt
    $B set-property $P EnablePptGroup b true
    armoury ppt_pl3_fppt "$3"
    armoury ppt_pl2_sppt "$2"
    armoury ppt_pl1_spl "$1"
}

profile() { # platform profile number; also becomes the default for the current power source
    $B set-property $P PlatformProfile u $1
    if [ "$(cat /sys/class/power_supply/AC0/online)" = 1 ]; then
        $B set-property $P PlatformProfileOnAc u $1
    else
        $B set-property $P PlatformProfileOnBattery u $1
    fi
}

refresh() { # Hz on the built-in panel, keeping its current resolution
    res=$(kscreen-doctor -o | sed 's/\x1b\[[0-9;]*m//g' | sed -n '/eDP-1/,/Geometry/p' | grep -o '[0-9]*x[0-9]*@[0-9.]*\*' | cut -d@ -f1)
    [ -n "$res" ] && kscreen-doctor output.eDP-1.mode.$res@$1 >/dev/null 2>&1
}

undervolt() { # platform profile: apply its saved Curve Optimizer offset, if undervolting is set up
    v=$(sed -n "s/^$1=//p" ~/.config/z13control-undervolt 2>/dev/null)
    [ -n "$v" ] && [ -x /usr/local/sbin/z13-undervolt ] && sudo -n /usr/local/sbin/z13-undervolt auto "$v" >/dev/null 2>&1
    return 0
}

case "$1" in
status)
    echo "mode=$(cat /sys/firmware/acpi/platform_profile)"
    echo "spl=$(cat $ARM/ppt_pl1_spl/current_value)"
    echo "overdrive=$(cat $ARM/panel_overdrive/current_value)"
    echo "charge=$(cat /sys/class/power_supply/BAT0/charge_control_end_threshold)"
    echo "kbd=$(cat /sys/class/leds/asus::kbd_backlight/brightness)"
    # LedModeData prints: (uu(yyy)(yyy)ss) mode zone r g b r2 g2 b2 speed direction
    set -- $($B get-property $D "$(aura | head -1)" xyz.ljones.Aura LedModeData)
    echo "lightmode=$2"
    echo "colour=$4 $5 $6"
    $REAR status
    echo "temp=$(($(hwmon k10temp temp1_input) / 1000))"
    echo "fan=$(hwmon asus fan1_input)"
    # Monitor tab extras; batuw is battery draw in µW (charge or discharge, see batstate).
    echo "fan2=$(hwmon asus fan2_input)"
    echo "tgpu=$(($(hwmon amdgpu temp1_input) / 1000))"
    echo "tssd=$(($(hwmon nvme temp1_input) / 1000))"
    echo "twifi=$(($(hwmon mt7925_phy0 temp1_input) / 1000))"
    echo "bat=$(cat /sys/class/power_supply/BAT0/capacity)"
    echo "batuw=$(cat /sys/class/power_supply/BAT0/power_now)"
    echo "batstate=$(cat /sys/class/power_supply/BAT0/status)"
    echo "energy=$(cat /sys/class/power_supply/BAT0/energy_now)"
    echo "energyfull=$(cat /sys/class/power_supply/BAT0/energy_full)"
    echo "ac=$(cat /sys/class/power_supply/AC0/online)"
    set -- $(busctl --user get-property $SB Brightness MaxBrightness)
    echo "bright=$(($2 * 100 / $4))"
    echo "brightmax=$4"
    echo "brightpath=$BD"
    # Which fan preset is active, recognised by the first point of the CPU curve.
    if [ "$(hwmon asus_custom_fan_curve pwm1_enable)" != 1 ]; then
        echo "fans=auto"
    else
        t1=$(hwmon asus_custom_fan_curve pwm1_auto_point1_temp)
        p1=$(hwmon asus_custom_fan_curve pwm1_auto_point1_pwm)
        if [ "$t1" = 55 ]; then echo "fans=quiet"
        elif [ "$t1" = 30 ] && [ "$p1" -lt 200 ]; then echo "fans=cool"
        elif [ "$t1" = 30 ]; then echo "fans=max"
        else echo "fans=custom"; fi
    fi
    ;;
mode) # quiet|balanced|performance; also becomes the default for the current power source
    case "$2" in
    quiet) n=2; p=power-saver; hz=60; set -- 40 50 60 ;;
    balanced) n=0; p=balanced; hz=180; set -- 60 75 86 ;;
    performance) n=1; p=performance; hz=180; set -- 80 92 93 ;;
    *) exit 1 ;;
    esac
    # tuned-ppd owns CPU boost, EPP and device power saving (it doesn't reliably follow
    # asusd). It also writes the platform profile, so let it settle before asusd's turn.
    $B set-property $PPD ActiveProfile s $p
    sleep 1
    profile $n
    ppt "$@"
    refresh $hz
    undervolt "$(cat /sys/firmware/acpi/platform_profile)"
    # tuned-ppd sometimes loses a race with asusd's write and lands on the wrong profile.
    # Re-asserting is safe: an unchanged platform profile keeps the PPTs just set.
    [ "$($B get-property $PPD ActiveProfile)" = "s \"$p\"" ] || $B set-property $PPD ActiveProfile s $p
    ;;
power) # sustained watts; boost limits keep the factory 60/75/86 spacing.
    # The profile follows the watts, split halfway between the mode presets (40/60/80).
    s=$2
    if [ $s -lt 50 ]; then n=2; p=power-saver; elif [ $s -lt 70 ]; then n=0; p=balanced; else n=1; p=performance; fi
    # Keep tuned-ppd's profile in step, as `mode` does; only wait for it when it changes.
    [ "$($B get-property $PPD ActiveProfile)" = "s \"$p\"" ] || { $B set-property $PPD ActiveProfile s $p; sleep 1; }
    profile $n
    t=$((s + 15)); f=$((s + 26))
    [ $t -gt 92 ] && t=92
    [ $f -gt 93 ] && f=93
    ppt $s $t $f
    [ "$($B get-property $PPD ActiveProfile)" = "s \"$p\"" ] || $B set-property $PPD ActiveProfile s $p
    ;;
fans) # auto|quiet|cool|max; a preset applies to every power mode
    case "$2" in
    auto)
        for u in 0 1 2; do $B call $D /xyz/ljones xyz.ljones.FanCurves SetFanCurvesEnabled ub $u false; done
        exit
        ;;
    quiet) c="55c:0%,60c:8%,65c:14%,70c:20%,75c:28%,80c:40%,85c:60%,90c:90%" ;;
    cool) c="30c:20%,45c:30%,55c:45%,62c:60%,68c:72%,74c:85%,80c:100%,85c:100%" ;;
    max) c="30c:100%,40c:100%,50c:100%,60c:100%,70c:100%,80c:100%,90c:100%,100c:100%" ;;
    *) exit 1 ;;
    esac
    for m in quiet balanced performance; do
        asusctl fan-curve --mod-profile $m --fan cpu --data "$c"
        asusctl fan-curve --mod-profile $m --fan gpu --data "$c"
        asusctl fan-curve --mod-profile $m --enable-fan-curves true
    done >/dev/null 2>&1
    ;;
charge) $B set-property $P ChargeControlEndThreshold y "$2" ;;
lights) # effect (0 static, 1 breathe, 10 pulse) r g b
    for o in $(aura); do
        $B set-property $D "$o" xyz.ljones.Aura LedModeData "(uu(yyy)(yyy)ss)" "$2" 0 "$3" "$4" "$5" 0 0 0 Med Right
    done
    $REAR restore # asusd also writes its colour to the rear bar's device
    ;;
kbd) # asusd also writes the rear bar's device, so put the rear back afterwards
    for o in $(aura); do
        $B set-property $D "$o" xyz.ljones.Aura Brightness u "$2"
    done
    $REAR restore
    ;;
rear) $REAR "$2" $3 $4 $5 $6 ;; # brightness 0-3, mode 0|1|3|10, r g b
overdrive) armoury panel_overdrive "$2" ;;
osk) # show the on-screen keyboard once the widget has closed and focus is back on the app
    sleep 0.4
    busctl --user call org.kde.KWin /VirtualKeyboard org.kde.kwin.VirtualKeyboard forceActivate
    ;;
brightness) # percent; flag 1 hides the on-screen indicator since the slider shows it
    set -- "$2" $(busctl --user get-property $SB MaxBrightness)
    busctl --user call $SB SetBrightness iu $(($1 * $3 / 100)) 1
    ;;
undervolt) undervolt "$(cat /sys/firmware/acpi/platform_profile)" ;; # re-apply for the current mode (login)
*) exit 1 ;;
esac
