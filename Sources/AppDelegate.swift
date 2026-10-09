import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let temperatureMonitor = TemperatureMonitor()
    private let batteryMonitor = BatteryMonitor()
    private let energyMonitor = EnergyMonitor()
    private var energy: EnergySnapshot?
    private var state = MonitorState()
    private var temperatureColor = TemperatureColorState()
    private var rows: [String: NSMenuItem] = [:]
    private var detailsMenu: NSMenu?
    private let popover = NSPopover()
    private let panel = MonitorPanelController()
    private var timers: [Timer] = []
    private var nextTemperatureAttempt = Date.distantPast
    private var diskRequest = UUID()
    private var sleeping = false
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        popover.contentViewController = panel
        popover.contentSize = MonitorPanelController.size
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        panel.onRefresh = { [weak self] in self?.refreshNow() }
        panel.onOpenActivityMonitor = { [weak self] in self?.openActivityMonitor() }
        panel.onQuit = { [weak self] in self?.quit() }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.setAccessibilityLabel("Mac 三条测试版：左温度，中磁盘已用，右电池剩余")
        temperatureMonitor.onSample = { [weak self] sample in
            guard let self else { return }
            self.state.temperature = sample
            self.state.temperatureMessage = ""
            _ = self.temperatureColor.update(sample.highest)
            self.render()
        }
        temperatureMonitor.onFailure = { [weak self] message in
            guard let self, !self.quitting else { return }
            self.state.temperature = nil
            self.state.temperatureMessage = message
            self.temperatureColor.reset()
            self.nextTemperatureAttempt = Date().addingTimeInterval(10)
            self.render()
        }
        batteryMonitor.onChange = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let sample): self.state.battery = sample; self.state.batteryMessage = ""
            case .failure(let error): self.state.battery = nil; self.state.batteryMessage = error.localizedDescription
            }
            self.refreshEnergy()
            self.render()
        }
        energyMonitor.onUpdate = { [weak self] snapshot in
            guard let self, !self.sleeping, !self.quitting else { return }
            self.energy = snapshot
            self.render()
        }
        temperatureMonitor.start()
        refreshDisk()
        batteryMonitor.start()
        schedule(every: 5) { $0.checkFreshness() }
        schedule(every: 60) { $0.refreshDisk() }
        schedule(every: 30) { $0.batteryMonitor.refresh() }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        render()
    }

    func applicationWillTerminate(_ notification: Notification) {
        quitting = true
        popover.close()
        timers.forEach { $0.invalidate() }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        temperatureMonitor.stop()
        batteryMonitor.stop()
        energyMonitor.markBoundary()
    }

    private func schedule(every interval: TimeInterval, action: @escaping (AppDelegate) -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.sleeping, !self.quitting else { return }
                action(self)
            }
        }
        timer.tolerance = min(2, interval / 5)
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    private func configureMenu() {
        let menu = NSMenu()
        for (key, title) in [
            ("name", "Mac 三条 · 测试版"), ("legend", "从左到右：温度 / 磁盘已用 / 电池剩余"),
            ("temperature", "温度：等待采样…"), ("sensors", "CPU —  ·  GPU —"),
            ("temperatureUpdated", "温度更新：—"), ("disk", "磁盘：正在读取…"),
            ("capacity", "可用 —  /  总量 —"), ("diskUpdated", "磁盘更新：—"),
            ("battery", "电量：正在读取…"), ("power", "电源：—"), ("batteryUpdated", "电量更新：—"),
            ("runtime", "续航估算：等待样本…"), ("runtimeBasis", "离电后按电量下降估算"),
            ("historyStatus", "")
        ] {
            if ["temperature", "disk", "battery"].contains(key) { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            rows[key] = item
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, action, key) in [("打开活动监视器", #selector(openActivityMonitor), ""),
                                   ("立即刷新", #selector(refreshNow), "r"), ("退出测试版", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        // 保留完整详情的数据模型，读数通过可读的原生面板呈现。
        detailsMenu = menu
    }

    private func refreshEnergy(forceProcesses: Bool = false) {
        energyMonitor.refresh(battery: state.freshBattery(at: Date()), forceProcesses: forceProcesses)
    }

    private func refreshDisk() {
        let request = UUID()
        diskRequest = request
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try DiskReader.read() }
            DispatchQueue.main.async {
                guard let self, self.diskRequest == request, !self.quitting else { return }
                switch result {
                case .success(let sample): self.state.disk = sample; self.state.diskMessage = ""
                case .failure(let error): self.state.disk = nil; self.state.diskMessage = error.localizedDescription
                }
                self.render()
            }
        }
    }

    private func checkFreshness() {
        let now = Date()
        if state.freshTemperature(at: now) == nil {
            if state.temperature != nil {
                state.temperature = nil
                state.temperatureMessage = "温度超过 20 秒未更新，正在重连…"
                temperatureColor.reset()
            }
            let noDataTooLong = temperatureMonitor.startedAt.map { now.timeIntervalSince($0) > 20 } ?? false
            if (!temperatureMonitor.isRunning || noDataTooLong) && now >= nextTemperatureAttempt {
                nextTemperatureAttempt = now.addingTimeInterval(10)
                temperatureMonitor.start()
            }
        }
        render()
    }

    private func render() {
        let now = Date()
        let temperature = state.freshTemperature(at: now)
        let disk = state.freshDisk(at: now)
        let battery = state.freshBattery(at: now)
        if let button = statusItem.button {
            button.image = IconRenderer.image(temperature: temperature?.highest, band: temperatureColor.band,
                disk: disk?.usedFraction, battery: battery?.fraction, charging: battery?.isCharging == true,
                appearance: button.effectiveAppearance)
        }
        let temperatureText = temperature.map { "温度 \(Int($0.highest.rounded()))°C" } ?? "温度 —"
        let diskText = disk.map { "磁盘已用估算 \(Self.gb($0.estimatedUsed))（\(Int(($0.usedFraction * 100).rounded()))%）· 可用 \(Self.gb($0.available)) · 总量 \(Self.gb($0.total))" } ?? "磁盘 —"
        let batteryText = battery.map { "电量 \($0.percent)% · \($0.powerDescription)" } ?? "电量 —"
        statusItem.button?.toolTip = "Mac 三条 · 测试版（左 / 中 / 右）\n\(temperatureText)\n\(diskText)\n\(batteryText)"
        statusItem.button?.setAccessibilityValue("\(temperatureText)，\(diskText)，\(batteryText)")
        rows["temperature"]?.title = temperature.map { "温度  \(Int($0.highest.rounded()))°C（CPU / GPU 平均值取较高者）" } ?? "温度  \(state.temperatureMessage.isEmpty ? "读数已过期" : state.temperatureMessage)"
        rows["sensors"]?.title = "CPU  \(Self.degrees(temperature?.cpu))  ·  GPU  \(Self.degrees(temperature?.gpu))"
        rows["disk"]?.title = disk.map { "磁盘已用估算  \(Self.gb($0.estimatedUsed))（\(Int(($0.usedFraction * 100).rounded()))%）" } ?? "磁盘  \(state.diskMessage.isEmpty ? "读数已过期" : state.diskMessage)"
        rows["capacity"]?.title = disk.map { "可用 \(Self.gb($0.available))  /  总量 \(Self.gb($0.total))（卷级）" } ?? "可用 —  /  总量 —"
        rows["battery"]?.title = battery.map { "Mac 电池剩余  \($0.percent)%" } ?? "电量  \(state.batteryMessage.isEmpty ? "读数已过期" : state.batteryMessage)"
        rows["power"]?.title = "电源  \(battery?.powerDescription ?? "—")"
        let freshEnergy = energy.flatMap { now.timeIntervalSince($0.capturedAt) <= 120 ? $0 : nil }
        rows["runtime"]?.title = freshEnergy?.runtime.title ?? "续航估算  等待新样本…"
        rows["runtimeBasis"]?.title = freshEnergy?.runtime.basis ?? "离电后按电量下降估算"
        rows["historyStatus"]?.title = freshEnergy?.historyMessage ?? ""
        rows["historyStatus"]?.isHidden = freshEnergy?.historyMessage == nil
        if let freshEnergy {
            statusItem.button?.toolTip?.append("\n\(freshEnergy.runtime.title)")
        }
        for (key, label, date) in [("temperatureUpdated", "温度", state.temperature?.capturedAt),
                                   ("diskUpdated", "磁盘", state.disk?.capturedAt),
                                   ("batteryUpdated", "电量", state.battery?.capturedAt)] {
            rows[key]?.title = "\(label)更新  \(date.map { Self.timeFormatter.string(from: $0) } ?? "—")"
        }
        // 关闭面板时只更新菜单栏读数，避免后台反复布局详情文字。
        if popover.isShown { updatePanel(at: now) }
    }

    private func updatePanel(at now: Date) {
        panel.update(state: state, band: temperatureColor.band, energy: energy,
            detailLines: detailsMenu?.items.filter { !$0.isHidden && !$0.isSeparatorItem && $0.action == nil }.map(\.title) ?? [], now: now)
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        panel.resetPage()
        render()
        updatePanel(at: Date())
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }
    func popoverDidClose(_ notification: Notification) { panel.resetPage() }

    @objc private func refreshNow() {
        state.temperature = nil
        state.temperatureMessage = "等待新采样…"
        temperatureColor.reset()
        nextTemperatureAttempt = Date().addingTimeInterval(10)
        temperatureMonitor.start()
        refreshDisk()
        batteryMonitor.refresh()
        refreshEnergy(forceProcesses: true)
        render()
    }
    @objc private func openActivityMonitor() {
        popover.performClose(nil)
        ActivityMonitorLauncher.open { result in
            if case .failure(let error) = result {
                let alert = NSAlert()
                alert.messageText = "无法打开活动监视器"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
    }
    @objc private func willSleep() { sleeping = true; temperatureMonitor.stop(); energyMonitor.markBoundary() }
    @objc private func didWake() { sleeping = false; refreshNow() }
    @objc private func quit() { NSApp.terminate(nil) }

    // 程序内集成验证：读取本实例真实菜单模型，不依赖外部辅助功能权限。
    var verificationReady: Bool {
        state.temperature != nil && state.disk != nil && state.battery != nil && energy != nil
    }
    func verificationReport() -> [String: Any] {
        let controlsPassed = panel.verifyControls()
        statusItem.button?.performClick(nil)
        let opened = popover.isShown
        statusItem.button?.performClick(nil)
        let closed = !popover.isShown
        return ["ready": verificationReady, "runtimeLoadSampleAvailable": energy?.processes != nil,
         "bundledTemperatureSampler": TemperatureMonitor.usesBundledSampler,
         "activityMonitorAvailable": ActivityMonitorLauncher.applicationURL != nil,
         "statusButtonWidth": statusItem.button?.bounds.width ?? 0,
         "tooltip": statusItem.button?.toolTip ?? "",
         "menuTitles": detailsMenu?.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map(\.title) ?? [],
         "panel": panel.report, "panelControlsPassed": controlsPassed,
         "popoverTogglePassed": opened && closed, "popoverBehavior": "transient"]
    }
    func renderMenuPreview(to directory: String) throws {
        guard let menu = detailsMenu else { throw ReadFailure.message("菜单尚未初始化") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try panel.renderPreview(to: URL(fileURLWithPath: directory).appendingPathComponent("monitor-panel-live.png"), appearance: .aqua)
        panel.showDetailsForVerification()
        try panel.renderPreview(to: URL(fileURLWithPath: directory).appendingPathComponent("monitor-panel-details-live.png"), appearance: .aqua)
        panel.resetPage()
        let items = menu.items.filter { !$0.isHidden }
        let height = CGFloat(items.reduce(48) { $0 + ($1.isSeparatorItem ? 12 : 26) })
        let preview = NSImage(size: NSSize(width: 720, height: height))
        preview.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 720, height: height)).fill()
        ("菜单文字预览 · 程序内实际菜单数据" as NSString).draw(at: NSPoint(x: 22, y: height - 30),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
        var y = height - 54
        for item in items {
            if item.isSeparatorItem {
                NSColor.separatorColor.setFill()
                NSBezierPath(rect: NSRect(x: 18, y: y + 10, width: 684, height: 1)).fill()
                y -= 12
            } else {
                (item.title as NSString).draw(at: NSPoint(x: 22, y: y), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
                y -= 26
            }
        }
        preview.unlockFocus()
        guard let cg = preview.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw ReadFailure.message("无法导出菜单文字预览")
        }
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("monitor-menu-preview.png"))
    }
    private static func degrees(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))°C" } ?? "—" }
    private static func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"; return formatter
    }()
}
