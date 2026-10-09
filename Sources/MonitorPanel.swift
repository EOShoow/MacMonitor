import AppKit

// 原生弹出面板。三个指标使用同一行模板，轨道位置和宽度完全一致。
@MainActor
final class MonitorPanelController: NSViewController {
    static let size = NSSize(width: 360, height: 462)
    var onRefresh: (() -> Void)?
    var onOpenActivityMonitor: (() -> Void)?
    var onQuit: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: "Mac 三条")
    private let refreshButton = NSButton()
    private let detailButton = NSButton(title: "详情", target: nil, action: nil)
    private let quitButton = NSButton(title: "退出", target: nil, action: nil)
    private let activityMonitorButton = NSButton(title: "打开活动监视器", target: nil, action: nil)
    private let content = PanelSurface(frame: NSRect(origin: .zero, size: size))
    private let summary = FlippedView(frame: NSRect(x: 0, y: 52, width: 360, height: size.height - 104))
    private let details = NSScrollView(frame: NSRect(x: 20, y: 56, width: 320, height: size.height - 108))
    private let detailsText = NSTextView()
    private let temperatureRow = MetricRow(title: "温度", symbol: "thermometer")
    private let diskRow = MetricRow(title: "磁盘已用", symbol: "internaldrive.fill")
    private let batteryRow = MetricRow(title: "电池剩余", symbol: "battery.100")
    private var showingDetails = false

    override func loadView() {
        view = content
        preferredContentSize = Self.size
        titleLabel.frame = NSRect(x: 20, y: 16, width: 240, height: 24)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        content.addSubview(titleLabel)
        configureButton(refreshButton, symbol: "arrow.clockwise", label: "立即刷新", action: #selector(refresh))
        refreshButton.frame = NSRect(x: 310, y: 11, width: 30, height: 30)
        refreshButton.keyEquivalent = "r"
        content.addSubview(refreshButton)
        content.addSubview(summary)
        for (index, row) in [temperatureRow, diskRow, batteryRow].enumerated() {
            row.frame = NSRect(x: 20, y: CGFloat(index * 104), width: 320, height: 104)
            summary.addSubview(row)
        }
        activityMonitorButton.frame = NSRect(x: 20, y: 322, width: 320, height: 32)
        activityMonitorButton.bezelStyle = .rounded
        activityMonitorButton.font = .systemFont(ofSize: 13)
        activityMonitorButton.imagePosition = .imageLeading
        activityMonitorButton.imageScaling = .scaleProportionallyDown
        activityMonitorButton.image = ActivityMonitorLauncher.icon
        activityMonitorButton.toolTip = "查看 CPU、内存与能耗"
        activityMonitorButton.setAccessibilityLabel("打开活动监视器")
        activityMonitorButton.target = self
        activityMonitorButton.action = #selector(openActivityMonitor)
        summary.addSubview(activityMonitorButton)
        details.hasVerticalScroller = true
        details.autohidesScrollers = true
        details.drawsBackground = false
        details.borderType = .noBorder
        details.isHidden = true
        detailsText.isEditable = false
        detailsText.isSelectable = true
        detailsText.drawsBackground = false
        detailsText.font = .systemFont(ofSize: 13)
        detailsText.textColor = .labelColor
        detailsText.textContainerInset = NSSize(width: 0, height: 8)
        detailsText.isVerticallyResizable = true
        detailsText.isHorizontallyResizable = false
        detailsText.autoresizingMask = [.width]
        detailsText.textContainer?.widthTracksTextView = true
        details.documentView = detailsText
        content.addSubview(details)
        configureTextButton(detailButton, action: #selector(toggleDetails))
        detailButton.frame = NSRect(x: 13, y: Self.size.height - 43, width: 70, height: 30)
        content.addSubview(detailButton)
        configureTextButton(quitButton, action: #selector(quit))
        quitButton.frame = NSRect(x: 283, y: Self.size.height - 43, width: 64, height: 30)
        quitButton.keyEquivalent = "q"
        content.addSubview(quitButton)
    }

    func update(state: MonitorState, band: TemperatureBand?, energy: EnergySnapshot?, detailLines: [String], now: Date = Date()) {
        _ = view
        let temperature = state.freshTemperature(at: now)
        let disk = state.freshDisk(at: now)
        let battery = state.freshBattery(at: now)
        let color: NSColor
        switch band {
        case .cool: color = .systemBlue
        case .middle: color = .systemGreen
        case .warm: color = .systemOrange
        case .hot: color = .systemRed
        case nil: color = .secondaryLabelColor
        }
        temperatureRow.update(value: temperature.map { "\(Int($0.highest.rounded()))°C" } ?? "—",
            first: temperature.map { "CPU \(Self.degrees($0.cpu)) · GPU \(Self.degrees($0.gpu))" } ?? "温度读数不可用",
            second: temperature == nil ? state.temperatureMessage : "刻度 0–100°C",
            fraction: temperature.map { $0.highest / 100 }, color: color)
        let diskColor: NSColor = (disk?.usedFraction ?? 0) >= 0.95 ? .systemRed : (disk?.usedFraction ?? 0) >= 0.85 ? .systemOrange : .labelColor
        diskRow.update(value: disk.map { Self.gb($0.estimatedUsed) } ?? "—",
            first: disk.map { "可用 \(Self.gb($0.available)) · 总量 \(Self.gb($0.total))" } ?? "磁盘读数不可用",
            second: disk.map { "已用估算 \(Int(($0.usedFraction * 100).rounded()))%" } ?? state.diskMessage,
            fraction: disk?.usedFraction, color: diskColor)
        let batteryColor: NSColor = (battery?.fraction ?? 1) <= 0.10 ? .systemRed : (battery?.fraction ?? 1) <= 0.20 ? .systemOrange : .systemGreen
        let percent = battery?.percent ?? 0
        let level = percent >= 88 ? 100 : percent >= 63 ? 75 : percent >= 38 ? 50 : percent >= 13 ? 25 : 0
        batteryRow.setSymbol(battery?.isCharging == true ? "battery.100.bolt" : "battery.\(level)", label: "电池剩余")
        let freshEnergy = energy.flatMap { now.timeIntervalSince($0.capturedAt) <= 120 ? $0 : nil }
        let runtime: String
        if battery?.isOnAC == true || battery?.isCharging == true { runtime = "续航：插电中" }
        else { runtime = freshEnergy?.runtime.title.replacingOccurrences(of: "续航估算  ", with: "续航：") ?? "续航：等待新样本…" }
        let power = battery.map { $0.powerDescription.replacingOccurrences(of: "外接电源", with: "已接电") } ?? "电池读数不可用"
        batteryRow.update(value: battery.map { "\($0.percent)%" } ?? "—", first: power,
            second: battery == nil ? state.batteryMessage : runtime, fraction: battery?.fraction, color: batteryColor)
        detailsText.string = detailLines.joined(separator: "\n\n")
        let viewportHeight = details.contentSize.height
        detailsText.frame = NSRect(x: 0, y: 0, width: 306, height: viewportHeight)
        detailsText.textContainer?.containerSize = NSSize(width: 306, height: CGFloat.greatestFiniteMagnitude)
        if let layout = detailsText.layoutManager, let container = detailsText.textContainer {
            layout.ensureLayout(for: container)
            detailsText.setFrameSize(NSSize(width: 306, height: max(viewportHeight, layout.usedRect(for: container).height + 24)))
        }
    }

    private func configureButton(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self; button.action = action
    }
    private func configureTextButton(_ button: NSButton, action: Selector) {
        button.bezelStyle = .inline; button.isBordered = false
        button.font = .systemFont(ofSize: 13)
        button.target = self; button.action = action
    }
    @objc private func refresh() { onRefresh?() }
    @objc private func openActivityMonitor() { onOpenActivityMonitor?() }
    @objc private func quit() { onQuit?() }
    @objc private func toggleDetails() {
        showingDetails.toggle()
        summary.isHidden = showingDetails; details.isHidden = !showingDetails
        titleLabel.stringValue = showingDetails ? "监测详情" : "Mac 三条"
        detailButton.title = showingDetails ? "返回" : "详情"
    }
    func resetPage() { if showingDetails { toggleDetails() } }
    func showDetailsForVerification() { if !showingDetails { toggleDetails() } }

    // 同一组真实 AppKit 控件既用于交互，也用于渲染检查。
    func renderPreview(to url: URL, appearance: NSAppearance.Name) throws {
        _ = view
        view.appearance = NSAppearance(named: appearance)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw ReadFailure.message("无法创建面板截图")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ReadFailure.message("无法导出面板 PNG") }
        try png.write(to: url)
    }
    var report: [String: Any] {
        ["width": view.bounds.width, "height": view.bounds.height, "detailsVisible": showingDetails,
         "values": [temperatureRow.valueText, diskRow.valueText, batteryRow.valueText],
         "barFrames": [temperatureRow, diskRow, batteryRow].map { NSStringFromRect($0.track.frame) },
         "detailText": detailsText.string, "activityMonitorButton": activityMonitorButton.title,
         "activityMonitorIconPresent": activityMonitorButton.image != nil,
         "missingSymbolCount": [temperatureRow, diskRow, batteryRow].filter { $0.icon.image == nil }.count]
    }
    func verifyControls() -> Bool {
        _ = view
        var refreshes = 0, launches = 0, quits = 0
        let previous = (onRefresh, onOpenActivityMonitor, onQuit)
        defer { (onRefresh, onOpenActivityMonitor, onQuit) = previous; resetPage() }
        onRefresh = { refreshes += 1 }; onOpenActivityMonitor = { launches += 1 }; onQuit = { quits += 1 }
        refreshButton.performClick(nil); activityMonitorButton.performClick(nil); quitButton.performClick(nil)
        detailButton.performClick(nil)
        let opened = showingDetails && summary.isHidden && !details.isHidden
        detailButton.performClick(nil)
        return refreshes == 1 && launches == 1 && quits == 1 && opened && !showingDetails && !summary.isHidden
    }
    private static func degrees(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))°C" } ?? "—" }
    private static func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
}

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
private final class PanelSurface: FlippedView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? NSColor(calibratedWhite: 0.13, alpha: 1) : .white).setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 20, y: bounds.height - 50, width: 320, height: 0.5).fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
private final class MetricTrack: NSView {
    var fraction: Double? { didSet { needsDisplay = true } }
    var color: NSColor = .labelColor { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
        NSColor.labelColor.withAlphaComponent(0.10).setFill(); path.fill()
        guard let fraction else { return }
        NSGraphicsContext.saveGraphicsState(); path.addClip()
        color.setFill()
        let fill = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(min(1, max(0, fraction))), height: bounds.height)
        if fill.width > 0 { NSBezierPath(roundedRect: fill, xRadius: min(5, fill.width / 2), yRadius: 5).fill() }
        NSGraphicsContext.restoreGraphicsState()
    }
}
private final class MetricRow: FlippedView {
    let icon = NSImageView()
    let track = MetricTrack()
    private let value = NSTextField(labelWithString: "—")
    private let first = NSTextField(labelWithString: "")
    private let second = NSTextField(labelWithString: "")
    var valueText: String { value.stringValue }
    init(title: String, symbol: String) {
        super.init(frame: .zero)
        icon.frame = NSRect(x: 0, y: 4, width: 30, height: 30)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(.init(pointSize: 28, weight: .regular))
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 40, y: 8, width: 98, height: 22)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        addSubview(label)
        value.frame = NSRect(x: 133, y: 1, width: 187, height: 36)
        value.font = .monospacedDigitSystemFont(ofSize: 25, weight: .semibold)
        value.alignment = .right
        value.setAccessibilityLabel(title)
        addSubview(value)
        track.frame = NSRect(x: 0, y: 43, width: 320, height: 10)
        track.setAccessibilityElement(false)
        addSubview(track)
        for (index, field) in [first, second].enumerated() {
            field.frame = NSRect(x: 0, y: CGFloat(60 + index * 18), width: 320, height: 17)
            field.font = .systemFont(ofSize: 12)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            addSubview(field)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setSymbol(_ symbol: String, label: String) {
        icon.image = (NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: "battery.0", accessibilityDescription: label))?.withSymbolConfiguration(.init(pointSize: 28, weight: .regular))
    }
    func update(value: String, first: String, second: String, fraction: Double?, color: NSColor) {
        self.value.stringValue = value
        self.first.stringValue = first; self.first.toolTip = first
        self.second.stringValue = second; self.second.toolTip = second
        icon.contentTintColor = fraction == nil ? .secondaryLabelColor : color
        track.fraction = fraction; track.color = color
        setAccessibilityLabel("\(value)，\(first)，\(second)")
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 102, width: bounds.width, height: 0.5).fill()
    }
}
