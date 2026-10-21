import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PC3
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami
import org.kde.ksysguard.sensors as Sensors
import org.kde.quickcharts as Charts

PlasmoidItem {
    id: root

    readonly property string script: "sh '" + Qt.resolvedUrl("../code/z13.sh").toString().replace("file://", "") + "' "
    property var s: ({ mode: "", spl: 60, overdrive: 0, charge: 100, kbd: 0, temp: 0, fan: 0, fan2: 0, fans: "", lightmode: 0, colour: "", rearbright: 0, rearmode: 0, rearcolour: "",
                       tgpu: 0, tssd: 0, twifi: 0, bat: 0, batuw: 0, batstate: "", ac: 0 })
    property int tab: 0
    // Values picked in the UI but not yet confirmed by the backend, so controls move instantly:
    // key -> { value, src (command), done (ms when the command finished) }.
    property var pending: ({})
    // Battery draw smoothed over ~20 s of status polls so the estimate doesn't jump.
    property real drainAvg: 0
    onSChanged: {
        const w = s.batuw || 0
        drainAvg = w <= 0 ? 0 : drainAvg > 0 ? drainAvg * 0.9 + w * 0.1 : w
    }

    // Palette: the accent follows the power mode, like Armoury Crate.
    readonly property color fg: Kirigami.Theme.textColor
    readonly property color accent: modeColor(v("mode"))
    readonly property color cpuTint: "#4c8dff"
    readonly property color memTint: "#a36bff"
    readonly property color gpuTint: "#2fd08a"
    readonly property color powerTint: "#ffa630"

    Plasmoid.icon: "speedometer"
    // The Armoury key opens the controls on the built-in screen, never an external monitor.
    activationTogglesExpanded: false
    preferredRepresentation: compactRepresentation
    // Plasma only activates applets that have a full representation, and expands them when it does;
    // keep one but never let the panel popup show.
    fullRepresentation: controls
    onExpandedChanged: () => {
        if (root.expanded)
            root.expanded = false
    }
    // No panel icon: the applet stays in the panel only so its global shortcut (the Armoury key) works.
    compactRepresentation: Item {
        Layout.minimumWidth: 0
        Layout.preferredWidth: 0
        Layout.maximumWidth: 0
        Layout.minimumHeight: 0
        Layout.preferredHeight: 0
        Layout.maximumHeight: 0
    }
    toolTipMainText: "Z13 Control"
    toolTipSubText: modeName(v("mode")) + " · " + v("spl") + " W · " + s.temp + " °C"

    function modeName(m) {
        return { quiet: "Eco", balanced: "Balanced", performance: "Turbo" }[m] || "…"
    }
    function modeColor(m) {
        return { quiet: "#22c3b5", balanced: "#4c8dff", performance: "#ff3b4e" }[m] || "#4c8dff"
    }
    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
    // Green → amber → orange → red as a temperature or load climbs.
    function heat(v, cool, warm, hot) {
        return v < cool ? "#2fd08a" : v < warm ? "#f5c542" : v < hot ? "#ff8a3d" : "#ff3b4e"
    }
    function duration(hours) {
        if (!isFinite(hours) || hours <= 0) return ""
        const m = Math.round(hours * 60)
        return m < 60 ? m + "m" : Math.floor(m / 60) + "h " + (m % 60) + "m"
    }
    // "4h 12m left" on battery, "full in 1h 5m" while charging (to the charge limit).
    function batteryEstimate() {
        if (drainAvg <= 0) return ""
        if (s.batstate === "Discharging")
            return duration(s.energy / drainAvg) + " left"
        if (s.batstate === "Charging")
            return "full in " + duration((s.energyfull * Math.min(s.charge, 100) / 100 - s.energy) / drainAvg)
        return ""
    }
    function gib(bytes) { return ((bytes || 0) / 1073741824).toFixed(1) }
    function rpm(r) { return r >= 1000 ? (r / 1000).toFixed(1) + "k" : String(r || 0) }

    function run(args) { exec.connectSource(script + args) }
    function v(key) { return key in pending ? pending[key].value : s[key] }
    // Shows `values` right away and runs the backend command in the background.
    function set(values, args) {
        const next = Object.assign({}, pending)
        for (const k in values)
            next[k] = { value: values[k], src: script + args, done: 0 }
        pending = next
        run(args)
    }
    function modeForWatts(w) { return w < 50 ? "quiet" : w < 70 ? "balanced" : "performance" }
    function sendKey(code) { exec.connectSource("ydotool key " + code + ":1 " + code + ":0") }
    // Brightness goes straight to KDE (one busctl call, no helper script) so dragging stays smooth.
    // Flag 1 hides the on-screen indicator since the slider already shows the level.
    function setBrightness(pct) {
        const raw = Math.round(pct * (s.brightmax || 10000) / 100)
        exec.connectSource("busctl --user call org.kde.ScreenBrightness " + s.brightpath
                           + " org.kde.ScreenBrightness.Display SetBrightness iu " + raw + " 1")
    }

    function place() {
        const scr = Qt.application.screens.find(s => s.name === "eDP-1") || Qt.application.screens[0]
        const gap = Kirigami.Units.gridUnit
        floating.x = scr.virtualX + scr.width - floating.width - gap
        const y = scr.virtualY + scr.height * 0.3 - floating.height / 2
        floating.y = Math.max(scr.virtualY + gap, Math.min(y, scr.virtualY + scr.height - floating.height - gap))
    }

    function toggle() {
        // Pressing the key first deactivates the popup (which hides it), so treat a just-hidden popup as open.
        if (floating.visible || Date.now() - floating.hiddenAt < 300) {
            floating.visible = false
            return
        }
        place()
        floating.visible = true
        floating.requestActivate()
    }

    Connections {
        target: Plasmoid
        function onActivated() { root.toggle() }
    }

    PlasmaCore.Dialog {
        id: floating
        property real hiddenAt: 0
        onVisibleChanged: if (!visible) hiddenAt = Date.now()
        location: PlasmaCore.Types.Floating
        flags: Qt.WindowStaysOnTopHint
        hideOnWindowDeactivate: true
        // Fixed width so the layout never gets squeezed; height follows the content.
        mainItem: Loader {
            sourceComponent: controls
            width: Kirigami.Units.gridUnit * 22
            height: item ? item.implicitHeight : 0
        }
        onWidthChanged: place()
        onHeightChanged: place()
    }

    // Arrow pad: a notification-type window, so tapping it never takes keyboard focus
    // from the app the arrows are meant for.
    PlasmaCore.Dialog {
        id: pad
        type: PlasmaCore.Dialog.Notification
        location: PlasmaCore.Types.Floating
        flags: Qt.WindowStaysOnTopHint | Qt.WindowDoesNotAcceptFocus
        hideOnWindowDeactivate: false
        mainItem: Item {
            implicitWidth: keys.implicitWidth
            implicitHeight: keys.implicitHeight
            // Dragging anywhere off the keys moves the pad; where it's left is remembered.
            MouseArea {
                anchors.fill: parent
                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                property point grab
                onPressed: mouse => grab = Qt.point(mouse.x, mouse.y)
                onPositionChanged: mouse => {
                    pad.x += mouse.x - grab.x
                    pad.y += mouse.y - grab.y
                }
                onReleased: {
                    Plasmoid.configuration.padX = pad.x
                    Plasmoid.configuration.padY = pad.y
                }
            }
            GridLayout {
                id: keys
                anchors.fill: parent
                columns: 3
                rowSpacing: Kirigami.Units.smallSpacing
                columnSpacing: Kirigami.Units.smallSpacing
                Kirigami.Icon {
                    source: "transform-move-symbolic"
                    opacity: 0.4
                    implicitWidth: Kirigami.Units.iconSizes.small
                    implicitHeight: implicitWidth
                    Layout.alignment: Qt.AlignTop | Qt.AlignLeft
                }
                PadKey { code: 103; icon: "arrow-up-symbolic" }
                PC3.ToolButton {
                    icon.name: "window-close"
                    display: PC3.AbstractButton.IconOnly
                    text: "Close arrow pad"
                    Layout.alignment: Qt.AlignTop | Qt.AlignRight
                    onClicked: pad.visible = false
                }
                PadKey { code: 105; icon: "arrow-left-symbolic" }
                PadKey { code: 108; icon: "arrow-down-symbolic" }
                PadKey { code: 106; icon: "arrow-right-symbolic" }
            }
        }
    }

    // Back where it was last left, unless that spot is no longer on any screen.
    function placePad() {
        const x = Plasmoid.configuration.padX, y = Plasmoid.configuration.padY
        if (Qt.application.screens.some(s => x >= s.virtualX && y >= s.virtualY
                                           && x < s.virtualX + s.width && y < s.virtualY + s.height)) {
            pad.x = x
            pad.y = y
            return
        }
        const scr = Qt.application.screens.find(s => s.name === "eDP-1") || Qt.application.screens[0]
        const gap = Kirigami.Units.gridUnit * 2
        pad.x = scr.virtualX + scr.width - pad.width - gap
        pad.y = scr.virtualY + scr.height * 0.55 - pad.height / 2
    }

    P5Support.DataSource {
        id: exec
        engine: "executable"
        onNewData: (source, data) => {
            disconnectSource(source)
            if (source.startsWith("busctl") || source.startsWith("ydotool"))
                return
            const now = Date.now()
            if (!source.endsWith(" status")) {
                const next = Object.assign({}, pending)
                for (const k in next)
                    if (next[k].src === source && !next[k].done)
                        next[k] = Object.assign({}, next[k], { done: now })
                pending = next
                run("status")
                return
            }
            // A finished command's value stays until a poll that surely started after it.
            const kept = {}
            for (const k in pending)
                if (!pending[k].done || now - pending[k].done < 1500)
                    kept[k] = pending[k]
            pending = kept
            if (data["exit code"] !== 0)
                return
            const next = {}
            for (const line of data.stdout.trim().split("\n")) {
                const [k, v] = line.split("=")
                next[k] = isNaN(Number(v)) ? v : Number(v)
            }
            root.s = next
        }
    }

    Timer {
        interval: 2000
        repeat: true
        triggeredOnStart: true
        running: root.expanded || floating.visible
        onTriggered: run("status")
    }
    Component.onCompleted: run("rear restore")  // the bar forgets its colour on reboot; this also refreshes status

    // ───────────────────────── Building blocks ─────────────────────────

    component Card: Rectangle {
        radius: Kirigami.Units.cornerRadius * 2
        color: root.alpha(root.fg, 0.045)
        border.width: 1
        border.color: root.alpha(root.fg, 0.08)
    }

    component Caption: PC3.Label {
        font.pointSize: Kirigami.Theme.smallFont.pointSize
        font.weight: Font.DemiBold
        font.letterSpacing: 1.1
        font.capitalization: Font.AllUppercase
        opacity: 0.55
    }

    // Card-styled button: icon over a label, tinted with the accent while `on`.
    component TileButton: Rectangle {
        id: tile
        property string icon
        property string title
        property bool on: false
        signal clicked()
        Layout.fillWidth: true
        implicitHeight: Kirigami.Units.gridUnit * 3.4
        radius: Kirigami.Units.cornerRadius * 2
        color: on ? root.alpha(root.accent, 0.22) : root.alpha(root.fg, tileMouse.pressed ? 0.1 : tileMouse.containsMouse ? 0.07 : 0.045)
        border.width: 1
        border.color: on ? root.alpha(root.accent, 0.6) : root.alpha(root.fg, 0.08)
        Behavior on color { ColorAnimation { duration: 180 } }
        ColumnLayout {
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing
            Kirigami.Icon {
                source: tile.icon
                color: tile.on ? root.accent : root.fg
                isMask: true
                implicitWidth: Kirigami.Units.iconSizes.smallMedium
                implicitHeight: implicitWidth
                Layout.alignment: Qt.AlignHCenter
            }
            PC3.Label { text: tile.title; font.weight: Font.DemiBold; Layout.alignment: Qt.AlignHCenter }
        }
        MouseArea {
            id: tileMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: tile.clicked()
        }
    }

    // Arrow pad key: one press on touch, then repeats while held like a real key.
    component PadKey: Rectangle {
        id: pk
        property int code              // Linux input keycode
        property string icon
        implicitWidth: Kirigami.Units.gridUnit * 3.2
        implicitHeight: implicitWidth
        radius: Kirigami.Units.cornerRadius * 2
        color: root.alpha(root.fg, pkMouse.pressed ? 0.2 : 0.07)
        border.width: 1
        border.color: pkMouse.pressed ? root.alpha(root.accent, 0.7) : root.alpha(root.fg, 0.1)
        Kirigami.Icon {
            anchors.centerIn: parent
            source: pk.icon
            implicitWidth: Kirigami.Units.iconSizes.medium
            implicitHeight: implicitWidth
        }
        MouseArea {
            id: pkMouse
            anchors.fill: parent
            onPressed: { root.sendKey(pk.code); repeatDelay.restart() }
            onReleased: { repeatDelay.stop(); repeater.stop() }
            onCanceled: { repeatDelay.stop(); repeater.stop() }
        }
        Timer { id: repeatDelay; interval: 400; onTriggered: repeater.start() }
        Timer { id: repeater; interval: 70; repeat: true; onTriggered: root.sendKey(pk.code) }
    }

    // Segmented control with a pill that slides to the selected option.
    component Segmented: Item {
        id: seg
        property var options: []          // [[value, label, icon?], ...]
        property var current
        property color pill: root.accent
        property color pillText: "white"
        signal picked(var value)
        readonly property int idx: options.findIndex(o => o[0] === current)
        readonly property real cell: (width - 6) / Math.max(1, options.length)

        Layout.fillWidth: true
        implicitHeight: Kirigami.Units.gridUnit * 1.9

        Rectangle {
            anchors.fill: parent
            radius: Kirigami.Units.cornerRadius * 2
            color: root.alpha(root.fg, 0.06)
            border.width: 1
            border.color: root.alpha(root.fg, 0.06)
        }
        Rectangle {
            visible: seg.idx >= 0
            x: 3 + seg.idx * seg.cell
            y: 3
            width: seg.cell
            height: seg.height - 6
            radius: Kirigami.Units.cornerRadius * 2 - 2
            color: seg.pill
            Behavior on x { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 260 } }
            // soft top sheen
            Rectangle {
                anchors.fill: parent
                radius: parent.radius
                gradient: Gradient {
                    GradientStop { position: 0; color: Qt.rgba(1, 1, 1, 0.16) }
                    GradientStop { position: 0.6; color: Qt.rgba(1, 1, 1, 0) }
                }
            }
        }
        Row {
            anchors.fill: parent
            anchors.margins: 3
            Repeater {
                model: seg.options
                delegate: Item {
                    readonly property bool selected: index === seg.idx
                    width: seg.cell
                    height: parent.height
                    Rectangle {
                        anchors.fill: parent
                        radius: Kirigami.Units.cornerRadius * 2 - 2
                        color: root.alpha(root.fg, 0.07)
                        opacity: mouse.containsMouse && !parent.selected ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 150 } }
                    }
                    RowLayout {
                        anchors.centerIn: parent
                        spacing: Kirigami.Units.smallSpacing
                        Kirigami.Icon {
                            visible: modelData.length > 2
                            source: modelData[2] || ""
                            color: parent.parent.selected ? seg.pillText : root.fg
                            isMask: true
                            implicitWidth: Kirigami.Units.iconSizes.small
                            implicitHeight: Kirigami.Units.iconSizes.small
                        }
                        PC3.Label {
                            text: modelData[1]
                            color: parent.parent.selected ? seg.pillText : root.fg
                            opacity: parent.parent.selected ? 1 : 0.75
                            font.weight: parent.parent.selected ? Font.DemiBold : Font.Normal
                            Behavior on color { ColorAnimation { duration: 200 } }
                        }
                    }
                    MouseArea {
                        id: mouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: seg.picked(modelData[0])
                    }
                }
            }
        }
    }

    // Title + subtitle with an animated switch on the right.
    component Swatches: RowLayout {
        id: sw
        property string current
        signal picked(string value)
        Layout.fillWidth: true
        Repeater {
            model: ["255 0 0", "255 80 0", "255 200 0", "0 255 0", "0 255 255", "0 60 255", "160 0 255", "255 0 140", "255 255 255"]
            Item {
                readonly property var rgb: modelData.split(" ").map(Number)
                readonly property bool selected: sw.current === modelData
                Layout.fillWidth: true
                implicitHeight: Kirigami.Units.gridUnit * 1.6
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.height; height: width; radius: width / 2
                    color: "transparent"
                    border.width: 2
                    border.color: root.fg
                    opacity: parent.selected ? 0.9 : 0
                    Behavior on opacity { NumberAnimation { duration: 180 } }
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.height - 8; height: width; radius: width / 2
                    color: Qt.rgba(parent.rgb[0] / 255, parent.rgb[1] / 255, parent.rgb[2] / 255, 1)
                    scale: swatch.containsMouse ? 1.12 : 1
                    Behavior on scale { NumberAnimation { duration: 150 } }
                }
                MouseArea {
                    id: swatch
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: sw.picked(modelData)
                }
            }
        }
    }

    component ToggleRow: Item {
        id: tr
        property string title
        property string sub
        property bool checked
        signal toggled(bool value)

        Layout.fillWidth: true
        implicitHeight: Math.max(col.implicitHeight, track.height) + Kirigami.Units.smallSpacing * 2

        ColumnLayout {
            id: col
            anchors.left: parent.left
            anchors.right: track.left
            anchors.rightMargin: Kirigami.Units.largeSpacing
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0
            PC3.Label { text: tr.title; Layout.fillWidth: true; elide: Text.ElideRight }
            PC3.Label {
                text: tr.sub
                visible: text !== ""
                opacity: 0.55
                font: Kirigami.Theme.smallFont
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
        }
        Rectangle {
            id: track
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 42; height: 24; radius: 12
            color: tr.checked ? root.accent : root.alpha(root.fg, 0.16)
            Behavior on color { ColorAnimation { duration: 200 } }
            Rectangle {
                width: 20; height: 20; radius: 10
                y: 2
                x: tr.checked ? parent.width - width - 2 : 2
                color: "white"
                Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            }
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: tr.toggled(!tr.checked)
        }
    }

    // Slim accent slider with a gradient fill and a ringed handle.
    component AccentSlider: T.Slider {
        id: sl
        Layout.fillWidth: true
        implicitWidth: 200
        implicitHeight: 26
        stepSize: 1
        snapMode: T.Slider.SnapAlways
        background: Rectangle {
            x: sl.leftPadding
            y: sl.topPadding + sl.availableHeight / 2 - height / 2
            width: sl.availableWidth
            height: 6
            radius: 3
            color: root.alpha(root.fg, 0.12)
            Rectangle {
                width: sl.visualPosition * parent.width
                height: parent.height
                radius: 3
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: Qt.darker(root.accent, 1.4) }
                    GradientStop { position: 1; color: root.accent }
                }
            }
        }
        handle: Rectangle {
            x: sl.leftPadding + sl.visualPosition * (sl.availableWidth - width)
            y: sl.topPadding + sl.availableHeight / 2 - height / 2
            width: 20; height: 20; radius: 10
            color: "white"
            border.width: 4
            border.color: root.accent
            scale: sl.pressed ? 1.18 : sl.hovered ? 1.08 : 1
            Behavior on scale { NumberAnimation { duration: 150 } }
        }
    }

    // Rolling one-minute line chart of a single value.
    component Spark: Charts.LineChart {
        property real sample
        property color tint
        property real ceiling: 100      // 0 = scale to the data
        direction: Charts.XYChart.ZeroAtEnd
        interpolate: true
        lineWidth: 1.5
        fillOpacity: 0.22
        yRange { from: 0; to: ceiling; automatic: ceiling <= 0 }
        colorSource: Charts.SingleValueSource { value: tint }
        valueSources: Charts.HistoryProxySource {
            source: Charts.SingleValueSource { value: sample }
            maximumHistory: 60
            interval: 1000
            fillMode: Charts.HistoryProxySource.FillFromEnd
        }
    }

    // Headline metric with its own history graph behind it.
    component StatCard: Card {
        id: sc
        property string title
        property string value
        property string unit
        property string sub
        property color tint
        property real sample
        property real ceiling: 100

        Layout.fillWidth: true
        implicitHeight: Kirigami.Units.gridUnit * 5.6
        clip: true

        Spark {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 1
            height: parent.height * 0.55
            sample: sc.sample
            tint: sc.tint
            ceiling: sc.ceiling
        }
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: 0
            RowLayout {
                spacing: Kirigami.Units.smallSpacing
                Rectangle { width: 7; height: 7; radius: 3.5; color: sc.tint }
                Caption { text: sc.title }
            }
            RowLayout {
                spacing: 3
                PC3.Label {
                    text: sc.value
                    font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.9
                    font.weight: Font.DemiBold
                }
                PC3.Label {
                    text: sc.unit
                    opacity: 0.55
                    Layout.alignment: Qt.AlignBaseline
                }
            }
            PC3.Label {
                text: sc.sub
                opacity: 0.6
                font: Kirigami.Theme.smallFont
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
            Item { Layout.fillHeight: true }
        }
    }

    // Circular gauge for temperatures.
    component Ring: ColumnLayout {
        id: ring
        property real value
        property string label
        property real shown: value
        Behavior on shown { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
        onShownChanged: canvas.requestPaint()
        readonly property color tint: root.heat(value, 55, 72, 85)
        onTintChanged: canvas.requestPaint()

        spacing: Kirigami.Units.smallSpacing
        Layout.fillWidth: true
        Layout.preferredWidth: 1

        Item {
            Layout.alignment: Qt.AlignHCenter
            implicitWidth: Kirigami.Units.gridUnit * 3.4
            implicitHeight: implicitWidth
            Canvas {
                id: canvas
                anchors.fill: parent
                onPaint: {
                    const ctx = getContext("2d")
                    const r = width / 2 - 4
                    const start = Math.PI * 0.75, sweep = Math.PI * 1.5
                    ctx.reset()
                    ctx.lineWidth = 5
                    ctx.lineCap = "round"
                    ctx.strokeStyle = root.alpha(root.fg, 0.12)
                    ctx.beginPath()
                    ctx.arc(width / 2, height / 2, r, start, start + sweep)
                    ctx.stroke()
                    const f = Math.max(0, Math.min(1, ring.shown / 100))
                    if (f > 0) {
                        ctx.strokeStyle = ring.tint
                        ctx.beginPath()
                        ctx.arc(width / 2, height / 2, r, start, start + sweep * f)
                        ctx.stroke()
                    }
                }
            }
            PC3.Label {
                anchors.centerIn: parent
                text: Math.round(ring.value) + "°"
                font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.15
                font.weight: Font.DemiBold
            }
        }
        Caption { text: ring.label; Layout.alignment: Qt.AlignHCenter }
    }

    // Fan glyph that spins faster as RPM rises.
    component FanSpinner: Item {
        id: fs
        property real rpm
        property color tint: root.fg
        implicitWidth: Kirigami.Units.gridUnit * 1.6
        implicitHeight: implicitWidth
        Canvas {
            id: blades
            anchors.fill: parent
            onPaint: {
                const ctx = getContext("2d")
                const c = width / 2
                ctx.reset()
                ctx.fillStyle = fs.tint
                ctx.translate(c, c)
                for (let i = 0; i < 3; ++i) {
                    ctx.beginPath()
                    ctx.ellipse(-c * 0.28, -c * 0.95, c * 0.56, c * 0.9)
                    ctx.fill()
                    ctx.rotate(Math.PI * 2 / 3)
                }
                ctx.beginPath()
                ctx.arc(0, 0, c * 0.2, 0, Math.PI * 2)
                ctx.fill()
            }
            RotationAnimator on rotation {
                from: 0; to: 360
                loops: Animation.Infinite
                duration: Math.max(250, 900000 / Math.max(1, fs.rpm))
                running: fs.rpm > 0 && fs.visible
            }
        }
        onTintChanged: blades.requestPaint()
    }

    // ───────────────────────── Popup content ─────────────────────────

    Component {
        id: controls
        ColumnLayout {
            id: pane
            // Only the copy inside the floating popup polls sensors.
            readonly property bool live: floating.visible && Window.window === floating

            implicitWidth: Kirigami.Units.gridUnit * 24
            Layout.preferredWidth: Kirigami.Units.gridUnit * 24
            Layout.minimumWidth: Kirigami.Units.gridUnit * 22
            spacing: Kirigami.Units.largeSpacing

            // Tabs + live status pills
            RowLayout {
                spacing: Kirigami.Units.smallSpacing
                Segmented {
                    options: [[0, "Controls", "configure"], [1, "Monitor", "office-chart-line"]]
                    current: root.tab
                    pill: root.alpha(root.fg, 0.16)
                    pillText: root.fg
                    onPicked: v => root.tab = v
                }
                // Live pills
                Repeater {
                    model: [
                        { icon: "temperature-normal", text: root.s.temp + "°", tint: root.heat(root.s.temp, 55, 72, 85) },
                        { icon: root.s.ac ? "battery-full-charging-symbolic" : "battery-080",
                          text: root.s.bat + "%" + (root.s.batstate === "Discharging" && root.drainAvg > 0
                                                   ? " · " + root.duration(root.s.energy / root.drainAvg) : ""),
                          tint: root.fg }
                    ]
                    Rectangle {
                        implicitHeight: Kirigami.Units.gridUnit * 1.9
                        implicitWidth: pill.implicitWidth + Kirigami.Units.largeSpacing * 2
                        radius: Kirigami.Units.cornerRadius * 2
                        border.width: 1
                        border.color: root.alpha(root.fg, 0.06)
                        color: root.alpha(root.fg, 0.06)
                        RowLayout {
                            id: pill
                            anchors.centerIn: parent
                            spacing: 3
                            Kirigami.Icon {
                                source: modelData.icon
                                implicitWidth: Kirigami.Units.iconSizes.small
                                implicitHeight: implicitWidth
                            }
                            PC3.Label { text: modelData.text; color: modelData.tint; font.weight: Font.DemiBold }
                        }
                    }
                }
            }

            StackLayout {
                id: pages
                currentIndex: root.tab
                Layout.fillWidth: true
                onCurrentIndexChanged: {
                    const page = children[currentIndex]
                    page.opacity = 0
                    fade.target = page
                    fade.restart()
                }
                OpacityAnimator { id: fade; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic }

                // ───── Controls ─────
                ColumnLayout {
                    spacing: Kirigami.Units.largeSpacing

                    Card {
                        Layout.fillWidth: true
                        implicitHeight: brightRow.implicitHeight + Kirigami.Units.largeSpacing * 2
                        RowLayout {
                            id: brightRow
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.largeSpacing
                            spacing: Kirigami.Units.largeSpacing
                            Kirigami.Icon {
                                source: "brightness-high-symbolic"
                                implicitWidth: Kirigami.Units.iconSizes.smallMedium
                                implicitHeight: implicitWidth
                            }
                            AccentSlider {
                                id: brightness
                                from: 1; to: 100
                                property int sent: -1
                                // After letting go, ignore status polls briefly so a stale reading can't snap it back.
                                property bool holding: false
                                onPressedChanged: {
                                    if (!pressed) {
                                        root.setBrightness(Math.round(value))
                                        holding = true
                                        release.restart()
                                    }
                                }
                                // Apply every 50 ms while dragging.
                                Timer {
                                    interval: 50
                                    repeat: true
                                    running: brightness.pressed
                                    onTriggered: {
                                        const v = Math.round(brightness.value)
                                        if (v !== brightness.sent) {
                                            brightness.sent = v
                                            root.setBrightness(v)
                                        }
                                    }
                                }
                                Timer { id: release; interval: 2500; onTriggered: brightness.holding = false }
                            }
                            Binding { target: brightness; property: "value"; value: root.s.bright; when: !brightness.pressed && !brightness.holding }
                            PC3.Label {
                                text: Math.round(brightness.value) + "%"
                                font.weight: Font.DemiBold
                                horizontalAlignment: Text.AlignRight
                                Layout.minimumWidth: Kirigami.Units.gridUnit * 2.2
                            }
                        }
                    }

                    Caption { text: "Tablet input" }
                    RowLayout {
                        spacing: Kirigami.Units.largeSpacing
                        // Gets out of the way first so the keyboard opens for the window underneath.
                        TileButton {
                            icon: "input-keyboard-virtual-symbolic"
                            title: "Keyboard"
                            onClicked: {
                                floating.visible = false
                                root.expanded = false
                                run("osk")
                            }
                        }
                        TileButton {
                            icon: "transform-move-symbolic"
                            title: "Arrow pad"
                            on: pad.visible
                            onClicked: {
                                if (!pad.visible)
                                    root.placePad()
                                pad.visible = !pad.visible
                                floating.visible = false
                                root.expanded = false
                            }
                        }
                    }

                    Caption { text: "Performance" }
                    Segmented {
                        options: [["quiet", "Eco"], ["balanced", "Balanced"], ["performance", "Turbo"]]
                        current: root.v("mode")
                        onPicked: m => root.set({ mode: m, spl: { quiet: 40, balanced: 60, performance: 80 }[m] }, "mode " + m)
                    }

                    Card {
                        Layout.fillWidth: true
                        implicitHeight: powerCol.implicitHeight + Kirigami.Units.largeSpacing * 2
                        ColumnLayout {
                            id: powerCol
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.largeSpacing
                            spacing: Kirigami.Units.smallSpacing
                            RowLayout {
                                Caption { text: "Sustained power"; Layout.fillWidth: true }
                                PC3.Label {
                                    text: Math.round(power.value)
                                    font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.5
                                    font.weight: Font.DemiBold
                                }
                                PC3.Label { text: "W"; opacity: 0.55; Layout.alignment: Qt.AlignBaseline }
                                PC3.ToolButton {
                                    icon.name: "edit-reset"
                                    display: PC3.AbstractButton.IconOnly
                                    text: "Reset to 60 W"
                                    PC3.ToolTip.text: text
                                    PC3.ToolTip.visible: hovered
                                    onClicked: root.set({ spl: 60, mode: "balanced" }, "power 60")
                                }
                            }
                            AccentSlider {
                                id: power
                                from: 28; to: 80
                                onPressedChanged: {
                                    const w = Math.round(value)
                                    if (!pressed)
                                        root.set({ spl: w, mode: root.modeForWatts(w) }, "power " + w)
                                }
                            }
                            Binding { target: power; property: "value"; value: root.v("spl"); when: !power.pressed }
                            RowLayout {
                                PC3.Label { text: "28 W · cool & quiet"; opacity: 0.45; font: Kirigami.Theme.smallFont; Layout.fillWidth: true }
                                PC3.Label { text: "80 W · max"; opacity: 0.45; font: Kirigami.Theme.smallFont }
                            }
                        }
                    }

                    RowLayout {
                        Caption { text: "Fans"; Layout.fillWidth: true }
                        Caption { text: "custom curve"; visible: root.v("fans") === "custom" }
                    }
                    Segmented {
                        options: [["auto", "Auto"], ["quiet", "Quiet"], ["cool", "Cool"], ["max", "Max"]]
                        current: root.v("fans")
                        onPicked: f => root.set({ fans: f }, "fans " + f)
                    }

                    Caption { text: "Keyboard" }
                    Segmented {
                        options: [[0, "Off"], [1, "Low"], [2, "Med"], [3, "High"]]
                        current: root.v("kbd")
                        onPicked: b => root.set({ kbd: b }, "kbd " + b)
                    }
                    Segmented {
                        options: [[0, "Static"], [1, "Breathe"], [10, "Pulse"]]
                        current: root.s.lightmode
                        onPicked: v => run("lights " + v + " " + root.s.colour)
                    }
                    Swatches {
                        current: root.s.colour
                        onPicked: v => run("lights " + root.s.lightmode + " " + v)
                    }

                    Caption { text: "Back light" }
                    Segmented {
                        options: [[0, "Off"], [1, "Low"], [2, "Med"], [3, "High"]]
                        current: root.s.rearbright
                        onPicked: v => run("rear " + v + " " + root.s.rearmode + " " + root.s.rearcolour)
                    }
                    Segmented {
                        options: [[0, "Static"], [1, "Breathe"], [10, "Pulse"]]
                        current: root.s.rearmode
                        onPicked: v => run("rear " + Math.max(1, root.s.rearbright) + " " + v + " " + root.s.rearcolour)
                    }
                    Swatches {
                        current: root.s.rearcolour
                        onPicked: v => run("rear " + Math.max(1, root.s.rearbright) + " " + root.s.rearmode + " " + v)
                    }

                    Card {
                        Layout.fillWidth: true
                        implicitHeight: toggles.implicitHeight + Kirigami.Units.smallSpacing * 2
                        ColumnLayout {
                            id: toggles
                            anchors.fill: parent
                            anchors.leftMargin: Kirigami.Units.largeSpacing
                            anchors.rightMargin: Kirigami.Units.largeSpacing
                            anchors.topMargin: Kirigami.Units.smallSpacing
                            anchors.bottomMargin: Kirigami.Units.smallSpacing
                            spacing: 0
                            ToggleRow {
                                title: "Limit charge to 80%"
                                sub: "Extends battery lifespan"
                                checked: root.s.charge <= 80
                                onToggled: v => run("charge " + (v ? 80 : 100))
                            }
                            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.alpha(root.fg, 0.08) }
                            ToggleRow {
                                title: "Panel overdrive"
                                sub: "Faster pixel response, less ghosting"
                                checked: root.s.overdrive === 1
                                onToggled: v => run("overdrive " + (v ? 1 : 0))
                            }
                        }
                    }
                    Item { Layout.fillHeight: true }
                }

                // ───── Monitor ─────
                ColumnLayout {
                    spacing: Kirigami.Units.largeSpacing

                    Sensors.Sensor { id: cpuUse; sensorId: "cpu/all/usage"; enabled: pane.live }
                    Sensors.Sensor { id: cpuFreq; sensorId: "cpu/all/averageFrequency"; enabled: pane.live }
                    Sensors.Sensor { id: coreCount; sensorId: "cpu/all/coreCount" }
                    Sensors.Sensor { id: memUsed; sensorId: "memory/physical/used"; enabled: pane.live }
                    Sensors.Sensor { id: memTotal; sensorId: "memory/physical/total" }
                    Sensors.Sensor { id: memApp; sensorId: "memory/physical/application"; enabled: pane.live }
                    Sensors.Sensor { id: memCache; sensorId: "memory/physical/cache"; enabled: pane.live }
                    Sensors.Sensor { id: gpuUse; sensorId: "gpu/gpu0/usage"; enabled: pane.live }
                    Sensors.Sensor { id: gpuVram; sensorId: "gpu/gpu0/usedVram"; enabled: pane.live }
                    // On this APU the GPU's PPT reading is the whole chip's package power.
                    Sensors.Sensor { id: pkgPower; sensorId: "gpu/gpu0/power1"; enabled: pane.live }

                    GridLayout {
                        columns: 2
                        columnSpacing: Kirigami.Units.largeSpacing
                        rowSpacing: Kirigami.Units.largeSpacing
                        Layout.fillWidth: true

                        StatCard {
                            title: "CPU"
                            tint: root.cpuTint
                            sample: cpuUse.value || 0
                            value: Math.round(cpuUse.value || 0)
                            unit: "%"
                            sub: ((cpuFreq.value || 0) / 1000).toFixed(2) + " GHz · " + root.s.temp + " °C"
                        }
                        StatCard {
                            readonly property real pct: memTotal.value ? 100 * memUsed.value / memTotal.value : 0
                            title: "Memory"
                            tint: root.memTint
                            sample: pct
                            value: root.gib(memUsed.value)
                            unit: "/ " + root.gib(memTotal.value) + " GB"
                            sub: Math.round(pct) + "% used · " + root.gib((memTotal.value || 0) - (memUsed.value || 0)) + " GB free"
                        }
                        StatCard {
                            title: "GPU"
                            tint: root.gpuTint
                            sample: gpuUse.value || 0
                            value: Math.round(gpuUse.value || 0)
                            unit: "%"
                            sub: root.s.tgpu + " °C · " + root.gib(gpuVram.value) + " GB VRAM"
                        }
                        StatCard {
                            title: "Power"
                            tint: root.powerTint
                            sample: pkgPower.value || 0
                            // Scale to the current power limit plus boost headroom.
                            ceiling: root.s.spl + 30
                            value: (pkgPower.value || 0).toFixed(1)
                            unit: "W"
                            sub: root.s.batstate === "Discharging" || root.s.batstate === "Charging"
                                 ? root.batteryEstimate() + " · " + (root.s.batstate === "Charging" ? "+" : "−")
                                   + (root.drainAvg / 1e6).toFixed(1) + " W"
                                 : "Plugged in"
                        }
                    }

                    // Radial thread load: one spike per thread, clockwise from 12 o'clock.
                    // Every thread at 100% closes the starburst into a full ring.
                    RowLayout {
                        Caption { text: "CPU threads"; Layout.fillWidth: true }
                        Caption { text: (coreCount.value || 0) / 2 + " cores · " + (coreCount.value || 0) + " threads"; opacity: 0.4 }
                    }
                    Card {
                        id: radialCard
                        Layout.fillWidth: true
                        implicitHeight: Kirigami.Units.gridUnit * 10

                        property var shown: []
                        property int busiest: 0

                        Instantiator {
                            id: threads
                            model: coreCount.value || 0
                            delegate: Sensors.Sensor { sensorId: "cpu/cpu" + index + "/usage"; enabled: pane.live }
                        }
                        // Ease each spike toward its latest reading so the burst breathes instead of jumping.
                        Timer {
                            interval: 40
                            repeat: true
                            running: pane.live
                            onTriggered: {
                                const n = threads.count
                                const next = radialCard.shown.slice(0, n)
                                let moved = false, top = 0
                                for (let i = 0; i < n; ++i) {
                                    const target = Math.min(1, ((threads.objectAt(i) || {}).value || 0) / 100)
                                    const cur = next[i] || 0
                                    const v = cur + (target - cur) * 0.2
                                    if (Math.abs(v - cur) > 0.0005) moved = true
                                    next[i] = v
                                    if (target > Math.min(1, ((threads.objectAt(top) || {}).value || 0) / 100)) top = i
                                }
                                radialCard.busiest = top
                                if (moved || radialCard.shown.length !== n) {
                                    radialCard.shown = next
                                    burst.requestPaint()
                                }
                            }
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.largeSpacing
                            spacing: Kirigami.Units.largeSpacing * 2

                            Item {
                                Layout.fillHeight: true
                                Layout.preferredWidth: height
                                Canvas {
                                    id: burst
                                    anchors.fill: parent
                                    onPaint: {
                                        const ctx = getContext("2d")
                                        const v = radialCard.shown, n = v.length
                                        const cx = width / 2, cy = height / 2
                                        const R = Math.min(width, height) / 2 - 3
                                        const r0 = R * 0.46
                                        ctx.reset()
                                        if (!n) return
                                        ctx.lineCap = "round"
                                        ctx.lineWidth = Math.max(2.5, (2 * Math.PI * r0 / n) * 0.5)
                                        // inner hub ring
                                        ctx.strokeStyle = root.alpha(root.fg, 0.08)
                                        ctx.beginPath()
                                        ctx.arc(cx, cy, r0 - ctx.lineWidth * 1.5, 0, Math.PI * 2)
                                        ctx.stroke()
                                        for (let i = 0; i < n; ++i) {
                                            const a = -Math.PI / 2 + i * 2 * Math.PI / n
                                            const cos = Math.cos(a), sin = Math.sin(a)
                                            // full-length track
                                            ctx.shadowBlur = 0
                                            ctx.strokeStyle = root.alpha(root.fg, 0.07)
                                            ctx.beginPath()
                                            ctx.moveTo(cx + cos * r0, cy + sin * r0)
                                            ctx.lineTo(cx + cos * R, cy + sin * R)
                                            ctx.stroke()
                                            // live spike
                                            const len = r0 + (R - r0) * Math.max(0.03, v[i])
                                            const col = root.heat(v[i] * 100, 40, 70, 90)
                                            ctx.strokeStyle = col
                                            ctx.shadowColor = col
                                            ctx.shadowBlur = 6 + v[i] * 10
                                            ctx.beginPath()
                                            ctx.moveTo(cx + cos * r0, cy + sin * r0)
                                            ctx.lineTo(cx + cos * len, cy + sin * len)
                                            ctx.stroke()
                                        }
                                    }
                                }
                                ColumnLayout {
                                    anchors.centerIn: parent
                                    spacing: -2
                                    PC3.Label {
                                        text: Math.round(cpuUse.value || 0) + "%"
                                        font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.6
                                        font.weight: Font.DemiBold
                                        Layout.alignment: Qt.AlignHCenter
                                    }
                                    Caption { text: "total"; Layout.alignment: Qt.AlignHCenter }
                                }
                            }

                            // Side readouts
                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                spacing: Kirigami.Units.largeSpacing
                                Repeater {
                                    model: [
                                        ["Busiest thread", "#" + (radialCard.busiest + 1) + " · " + Math.round(((threads.objectAt(radialCard.busiest) || {}).value || 0)) + "%"],
                                        ["Clock", ((cpuFreq.value || 0) / 1000).toFixed(2) + " GHz"],
                                        ["Temperature", root.s.temp + " °C"]
                                    ]
                                    ColumnLayout {
                                        spacing: 0
                                        Caption { text: modelData[0] }
                                        PC3.Label {
                                            text: modelData[1]
                                            font.weight: Font.DemiBold
                                            font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.1
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Memory composition bar
                    RowLayout {
                        Caption { text: "Memory"; Layout.fillWidth: true }
                        Caption { text: root.gib(memTotal.value) + " GB usable"; opacity: 0.4 }
                    }
                    Item {
                        id: memBar
                        readonly property real total: memTotal.value || 1
                        Layout.fillWidth: true
                        implicitHeight: 10
                        Rectangle { anchors.fill: parent; radius: 5; color: root.alpha(root.fg, 0.1) }
                        Row {
                            anchors.fill: parent
                            Rectangle {
                                width: memBar.width * (memApp.value || 0) / memBar.total
                                height: parent.height
                                radius: 5
                                color: root.memTint
                                Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
                            }
                            Rectangle {
                                width: memBar.width * (memCache.value || 0) / memBar.total
                                height: parent.height
                                radius: 5
                                color: root.alpha(root.memTint, 0.4)
                                Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
                            }
                        }
                    }
                    RowLayout {
                        spacing: Kirigami.Units.largeSpacing
                        Repeater {
                            model: [
                                ["Apps", root.memTint, memApp.value],
                                ["Cache", root.alpha(root.memTint, 0.4), memCache.value],
                                ["Free", root.alpha(root.fg, 0.2), (memTotal.value || 0) - (memUsed.value || 0)]
                            ]
                            RowLayout {
                                spacing: 4
                                Rectangle { width: 8; height: 8; radius: 4; color: modelData[1] }
                                PC3.Label { text: modelData[0] + " " + root.gib(modelData[2]) + " GB"; opacity: 0.7; font: Kirigami.Theme.smallFont }
                            }
                        }
                        Item { Layout.fillWidth: true }
                    }

                    // Thermals and fans
                    Caption { text: "Thermals" }
                    Card {
                        Layout.fillWidth: true
                        implicitHeight: thermals.implicitHeight + Kirigami.Units.largeSpacing * 2
                        ColumnLayout {
                            id: thermals
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.largeSpacing
                            spacing: Kirigami.Units.largeSpacing
                            RowLayout {
                                Layout.fillWidth: true
                                Ring { value: root.s.temp; label: "CPU" }
                                Ring { value: root.s.tgpu; label: "GPU" }
                                Ring { value: root.s.tssd; label: "SSD" }
                                Ring { value: root.s.twifi; label: "Wi-Fi" }
                            }
                            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.alpha(root.fg, 0.08) }
                            RowLayout {
                                Layout.fillWidth: true
                                Repeater {
                                    model: [["CPU fan", root.s.fan], ["GPU fan", root.s.fan2]]
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Layout.preferredWidth: 1
                                        spacing: Kirigami.Units.smallSpacing
                                        FanSpinner { rpm: modelData[1]; tint: modelData[1] > 0 ? root.accent : root.alpha(root.fg, 0.35) }
                                        ColumnLayout {
                                            spacing: 0
                                            PC3.Label {
                                                text: modelData[1] > 0 ? root.rpm(modelData[1]) + " RPM" : "Idle"
                                                font.weight: Font.DemiBold
                                            }
                                            PC3.Label { text: modelData[0]; opacity: 0.55; font: Kirigami.Theme.smallFont }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Item { Layout.fillHeight: true }
                }
            }
        }
    }
}
