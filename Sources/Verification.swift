import AppKit

@MainActor
enum Verification {
    static func verifyMenu(to directory: String) {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        let deadline = Date().addingTimeInterval(15)
        let timer = Timer(timeInterval: 0.5, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard delegate.verificationReady || Date() >= deadline else { return }
                timer.invalidate()
                var report = delegate.verificationReport()
                do { try delegate.renderMenuPreview(to: directory); report["previewRendered"] = true }
                catch { report["previewError"] = error.localizedDescription }
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                }
                delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                exit(delegate.verificationReady && report["activityMonitorAvailable"] as? Bool == true && report["previewRendered"] as? Bool == true && report["panelControlsPassed"] as? Bool == true && report["popoverTogglePassed"] as? Bool == true ? 0 : 1)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        app.run()
    }

    static func runTests() {
        var failures: [String] = []
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures.append(name) }
        }
        var colors = TemperatureColorState()
        check(colors.update(40) == .cool, "低温蓝色")
        check(colors.update(45) == .middle, "45°C 升档")
        check(colors.update(44) == .middle, "45°C 边界回差")
        check(colors.update(42.9) == .cool, "越过回差后降档")
        check(colors.update(80) == .warm, "跳过中间档直接升橙")
        check(colors.update(79) == .warm, "80°C 边界不抖动")
        check(colors.update(77.9) == .middle, "低于 78°C 降绿")
        check(colors.update(90) == .hot, "90°C 升红")
        check(colors.update(89) == .hot, "90°C 边界不抖动")
        check(colors.update(87.9) == .warm, "低于 88°C 降橙")
        check(colors.update(38) == .cool, "降温可一次跨多档")
        colors.reset()
        check(colors.update(79) == .middle, "断线后不沿用旧颜色状态")
        let partial = TemperatureSample.parse("{\"temp\":{\"cpu_temp_avg\":null,\"gpu_temp_avg\":86}}")
        check(partial?.highest == 86 && partial?.cpu == nil, "缺一个温度传感器仍可显示")
        check(TemperatureSample.parse("{\"temp\":{\"cpu_temp_avg\":0,\"gpu_temp_avg\":0}}") == nil,
              "无效零温度不能显示为低温")
        check(TemperatureSample.parse("invalid-json") == nil, "畸形输出安全忽略")
        check(TemperatureSample(cpu: .nan, gpu: nil) == nil, "无效数值不进入条形图")
        let now = Date()
        let disk = try! DiskSample(total: 500_000_000_000, available: 300_000_000_000, path: "/test", capturedAt: now)
        check(abs(disk.usedFraction - 0.4) < 0.000001, "卷级 total / available 换算一致")
        check((try? DiskSample(total: 100, available: 101, path: "/test")) == nil,
              "拒绝不同口径造成的可用空间超总量")
        check((try? BatterySample(current: 10, maximum: 0, isCharging: false, isOnAC: false)) == nil,
              "电池最大容量为零时显示不可用")
        let full = try! BatterySample(current: 100, maximum: 100, isCharging: false, isOnAC: true, capturedAt: now)
        let plugged = try! BatterySample(current: 80, maximum: 100, isCharging: false, isOnAC: true)
        check(!full.isCharging && full.powerDescription.contains("已充满"), "满电接电不误标充电中")
        check(!plugged.isCharging && plugged.powerDescription.contains("未充电"), "充电限制不误标正在充电")
        var state = MonitorState()
        state.disk = disk
        state.battery = full
        state.temperature = TemperatureSample(cpu: 88, gpu: 70, capturedAt: now.addingTimeInterval(-21))
        check(state.freshTemperature(at: now) == nil && state.freshDisk(at: now) != nil && state.freshBattery(at: now) != nil,
              "温度过期只隐藏温度条")
        state.temperature = nil
        check(state.freshDisk(at: now) != nil && state.freshBattery(at: now) != nil, "温度采集失败不影响其他两项")
        check(state.freshDisk(at: now.addingTimeInterval(181)) == nil, "过期磁盘数据不冒充实时值")
        verifyEnergy(check: check)
        if failures.isEmpty { print("PASS: \(checks) checks") }
        else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
    }

    private static func verifyEnergy(check: (Bool, String) -> Void) {
        let now = Date()
        let session = UUID()
        func battery(_ percent: Double, ac: Bool = false, charging: Bool = false, at: Date? = nil) -> BatterySample {
            try! BatterySample(current: percent, maximum: 100, isCharging: charging, isOnAC: ac, capturedAt: at ?? now)
        }
        func points(minutes: Int, start: Double, end: Double) -> [RuntimePoint] {
            (0...minutes).map { step in
                RuntimePoint(time: now.addingTimeInterval(Double(step - minutes) * 60),
                    percent: start + (end - start) * Double(step) / Double(minutes), onAC: false, charging: false, session: session)
            }
        }
        let low = RuntimeEstimate.evaluate(battery: battery(78), points: points(minutes: 11, start: 80, end: 78), now: now)
        check(low.state == "低可信" && abs((low.remainingHours ?? 0) - 7.15) < 0.01, "短离电窗口按真实下降速率估算")
        let medium = RuntimeEstimate.evaluate(battery: battery(74), points: points(minutes: 40, start: 80, end: 74), now: now)
        check(medium.state == "中可信" && abs((medium.remainingHours ?? 0) - 74.0 / 9) < 0.01, "长离电窗口显示中可信估算")
        check(medium.title.contains("约") && medium.basis.contains("离电样本"), "续航数字携带估算和样本依据")
        check(RuntimeEstimate.evaluate(battery: battery(74, ac: true), points: points(minutes: 40, start: 80, end: 74), now: now).remainingHours == nil,
              "接电时不把历史续航当成当前剩余时长")
        check(RuntimeEstimate.evaluate(battery: battery(74), points: [], now: now).state == "学习中", "没有样本时不使用固定小时数")
        check(RuntimeEstimate.evaluate(battery: battery(80), points: points(minutes: 40, start: 80, end: 80), now: now).remainingHours == nil,
              "电量没下降时不编造续航")
        check(RuntimeEstimate.evaluate(battery: battery(74), points: points(minutes: 40, start: 80, end: 74), now: now,
              loadChanged: true).state == "负载突变", "负载突变后不沿用旧估算")
        check(RuntimeEstimate.evaluate(battery: battery(74), points: points(minutes: 40, start: 80, end: 74), now: now,
              processVerified: false).state == "低可信", "进程读取失败降低估算可信度")
        let stalePoints = points(minutes: 40, start: 80, end: 74).map {
            RuntimePoint(time: $0.time.addingTimeInterval(-16 * 60), percent: $0.percent, onAC: false, charging: false, session: $0.session)
        }
        check(RuntimeEstimate.evaluate(battery: battery(74), points: stalePoints, now: now).state == "样本失效", "过期离电样本不产生续航数字")
        check(RuntimeEstimate.evaluate(battery: battery(74, at: now.addingTimeInterval(-91)), points: [], now: now).state == "不可用",
              "电池读数过期时续航不可用")
        let gap = [RuntimePoint(time: now.addingTimeInterval(-40 * 60), percent: 80, onAC: false, charging: false, session: session),
                   RuntimePoint(time: now, percent: 74, onAC: false, charging: false, session: session)]
        check(RuntimeEstimate.evaluate(battery: battery(74), points: gap, now: now).state == "样本失效", "不跨长时间空白推断下降速度")
        let changedSession = points(minutes: 40, start: 80, end: 74) + [
            RuntimePoint(time: now, percent: 74, onAC: false, charging: false, session: UUID())]
        check(RuntimeEstimate.evaluate(battery: battery(74), points: changedSession, now: now).remainingHours == nil,
              "充电或唤醒后不同样本段不混算")
        let fixture = """
        101 2 12.0 204800 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
        102 101 9.0 102400 /Applications/Google Chrome.app/Contents/Frameworks/Helper --private-token=do-not-retain
        103 1 4.0 20480 /opt/homebrew/bin/node /tools/mcp-server.cjs --stdio
        104 101 3.0 20480 /opt/homebrew/bin/node /tools/mcp-server.cjs --stdio
        105 2 99.0 20480 /Applications/MacMonitorPreview.app/Contents/MacOS/MacMonitorPreview
        bad row
        """
        let items = try! ProcessReader.parse(fixture)
        check(items.first?.name == "Google Chrome" && items.first?.cpu == 21 && items.first?.count == 2 && items.first?.rssMB == 300,
              "聚合同一应用的多个进程及带空格的 App 路径")
        check(items.contains { $0.name == "孤儿 MCP" && $0.cpu == 4 }, "只有 ppid 为 1 的 MCP 才标记孤儿")
        check(!items.contains { $0.name.contains("MacMonitorPreview") || $0.name.contains("private-token") },
              "忽略监控自身且不把命令行参数暴露到菜单")
        check((try? ProcessReader.parse("permission denied")) == nil, "采样失败不能伪装成无高耗电进程")
        var tracker = ProcessLoadTracker()
        check(!tracker.changed([DrainItem(name: "A", cpu: 20, rssMB: 0, count: 1)]), "初次中等负载建立基线")
        check(tracker.changed([DrainItem(name: "B", cpu: 20, rssMB: 0, count: 1)]), "高占用来源变化触发重学")
        check(!tracker.changed([DrainItem(name: "B", cpu: 22, rssMB: 0, count: 1)]), "稳定来源不持续重置估算")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mac-monitor-energy-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("samples.json")
        let history = RuntimeHistory(url: url)
        check(history.record(battery(80, at: now.addingTimeInterval(-120)), now: now.addingTimeInterval(-120)), "保存独立续航样本")
        check(!history.record(battery(80, at: now.addingTimeInterval(-110)), now: now.addingTimeInterval(-110)), "频繁通知不重复落盘")
        _ = history.record(battery(80, ac: true, at: now.addingTimeInterval(-60)), now: now.addingTimeInterval(-60))
        _ = history.record(battery(79), now: now)
        check(history.points.first?.session != history.points.last?.session, "充电再离电后开始独立样本段")
        let reloaded = RuntimeHistory(url: url)
        check(reloaded.points.count == 3, "退出重启后可读回样本")
        reloaded.markBoundary()
        _ = reloaded.record(battery(78, at: now.addingTimeInterval(60)), now: now.addingTimeInterval(60), persist: false)
        check(reloaded.points[2].session != reloaded.points[3].session, "唤醒或负载变化后立即开始新段")
        _ = reloaded.record(battery(77, at: now.addingTimeInterval(7 * 60)), now: now.addingTimeInterval(7 * 60), persist: false)
        check(reloaded.points[3].session != reloaded.points[4].session, "采样中断超过五分钟不跨空白估算")
    }

    static func snapshot() {
        let monitor = TemperatureMonitor()
        var temperature: TemperatureSample?
        var temperatureError: String?
        monitor.onSample = { temperature = $0 }
        monitor.onFailure = { temperatureError = $0 }
        monitor.start()
        let deadline = Date().addingTimeInterval(12)
        while temperature == nil && temperatureError == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        monitor.stop()
        var output: [String: Any] = ["temperature": NSNull(), "disk": NSNull(), "battery": NSNull(),
                                   "bundledTemperatureSampler": TemperatureMonitor.usesBundledSampler]
        if let temperature {
            output["temperature"] = ["cpuC": temperature.cpu as Any? ?? NSNull(),
                "gpuC": temperature.gpu as Any? ?? NSNull(), "displayC": temperature.highest]
        } else { output["temperatureError"] = temperatureError ?? "12 秒内未收到温度" }
        do {
            let disk = try DiskReader.read()
            output["disk"] = ["totalBytes": disk.total, "availableBytes": disk.available,
                "estimatedUsedBytes": disk.estimatedUsed,
                "estimatedUsedPercent": disk.usedFraction * 100]
        } catch { output["diskError"] = error.localizedDescription }
        do {
            let battery = try BatteryMonitor.read()
            output["battery"] = ["percent": battery.percent, "charging": battery.isCharging,
                "onAC": battery.isOnAC, "powerDescription": battery.powerDescription]
            let history = RuntimeHistory()
            history.record(battery, now: Date(), persist: false)
            var loadVerified = false
            if !battery.isOnAC && !battery.isCharging {
                do { _ = try ProcessReader.read(); loadVerified = true }
                catch { output["loadSampleError"] = error.localizedDescription }
            }
            let runtime = RuntimeEstimate.evaluate(battery: battery, points: history.points, now: Date(), processVerified: loadVerified)
            output["energy"] = ["runtimeTitle": runtime.title, "runtimeBasis": runtime.basis,
                "runtimeLoadSampleAvailable": loadVerified]
        } catch { output["batteryError"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
        if temperature == nil { exit(1) }
    }

    static func renderIcons(to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let cases: [(String, Double?, Double?, Double?, Bool)] = [
            ("36°C · 已用 37% · 电量 100%", 36, 0.37, 1, false),
            ("86°C · 已用 87% · 电量 18%", 86, 0.87, 0.18, false),
            ("95°C · 已用 97% · 电量 8% · 充电", 95, 0.97, 0.08, true),
            ("温度不可用 · 已用 37% · 电量 100%", nil, 0.37, 1, false)
        ]
        // 固定 @2x 导出，保证不同桌面会话的图标比较使用同一像素密度。
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 1120,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ReadFailure.message("无法创建图标预览画布")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        for (column, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let appearance = NSAppearance(named: name)!
            appearance.performAsCurrentDrawingAppearance {
                let x = CGFloat(column) * 450
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(rect: NSRect(x: x, y: 0, width: 450, height: 560)).fill()
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor]
                (column == 0 ? "浅色菜单栏 · 左 T / 中 D / 右 B" : "深色菜单栏 · 左 T / 中 D / 右 B" as NSString)
                    .draw(at: NSPoint(x: x + 24, y: 520), withAttributes: attributes)
                for (index, entry) in cases.enumerated() {
                    let y = CGFloat(400 - index * 125)
                    let icon = IconRenderer.image(temperature: entry.1, band: entry.1.map { TemperatureBand.direct($0) },
                        disk: entry.2, battery: entry.3, charging: entry.4, appearance: appearance)
                    icon.draw(in: NSRect(x: x + 30, y: y + 30, width: 22, height: 22))
                    NSGraphicsContext.current?.imageInterpolation = .none
                    icon.draw(in: NSRect(x: x + 85, y: y, width: 88, height: 88))
                    (entry.0 as NSString).draw(at: NSPoint(x: x + 185, y: y + 32), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ReadFailure.message("无法导出图标 PNG")
        }
        let path = URL(fileURLWithPath: directory).appendingPathComponent("three-bars-preview.png")
        try png.write(to: path)
        print(path.path)
    }

    static func renderPanel(to directory: String) throws {
        let url = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let now = Date()
        var state = MonitorState()
        state.temperature = TemperatureSample(cpu: 33, gpu: 34, capturedAt: now)
        state.disk = try DiskSample(total: 494_349_999_999, available: 313_199_999_998, path: "/fixture", capturedAt: now)
        state.battery = try BatterySample(current: 100, maximum: 100, isCharging: false, isOnAC: true, capturedAt: now)
        let energy = EnergySnapshot(runtime: RuntimeEstimate.evaluate(battery: state.battery, points: [], now: now),
            processes: nil, processMessage: nil, historyMessage: nil, capturedAt: now)
        let panel = MonitorPanelController()
        panel.update(state: state, band: .cool, energy: energy, detailLines: ["采样详情", "温度更新：17:19:50", "磁盘已用按卷级总量与可用空间计算"], now: now)
        guard panel.verifyControls() else { throw ReadFailure.message("面板按钮交互未通过") }
        guard (panel.report["missingSymbolCount"] as? Int) == 0 else { throw ReadFailure.message("系统图形缺失") }
        for (name, appearance) in [("monitor-panel-light.png", NSAppearance.Name.aqua), ("monitor-panel-dark.png", .darkAqua)] {
            try panel.renderPreview(to: url.appendingPathComponent(name), appearance: appearance)
        }
        panel.showDetailsForVerification()
        try panel.renderPreview(to: url.appendingPathComponent("monitor-panel-details.png"), appearance: .aqua)
        panel.resetPage()
        var output = panel.report
        output["controlsPassed"] = true
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url.appendingPathComponent("panel-fixture-report.json"))
        panel.update(state: MonitorState(), band: nil, energy: nil, detailLines: [], now: now)
        try panel.renderPreview(to: url.appendingPathComponent("monitor-panel-unavailable.png"), appearance: .aqua)
        state.temperature = TemperatureSample(cpu: 92, gpu: 89, capturedAt: now)
        state.disk = try DiskSample(total: 500_000_000_000, available: 10_000_000_000, path: "/fixture", capturedAt: now)
        state.battery = try BatterySample(current: 8, maximum: 100, isCharging: false, isOnAC: false, capturedAt: now)
        let stress = EnergySnapshot(runtime: RuntimeEstimate.evaluate(battery: state.battery, points: [], now: now),
            processes: nil,
            processMessage: nil, historyMessage: nil, capturedAt: now)
        panel.update(state: state, band: .hot, energy: stress, detailLines: [], now: now)
        try panel.renderPreview(to: url.appendingPathComponent("monitor-panel-alert.png"), appearance: .aqua)
        print("PASS: 原生面板渲染、系统图标、刷新、活动监视器按钮、详情往返与退出按钮")
    }

    static func openActivityMonitor() {
        var outcome: Result<NSRunningApplication, Error>?
        ActivityMonitorLauncher.open { outcome = $0 }
        let deadline = Date().addingTimeInterval(10)
        while outcome == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        switch outcome {
        case .success(let app): print("PASS: 已打开 \(app.bundleIdentifier ?? "—")，PID \(app.processIdentifier)")
        case .failure(let error): fputs("启动失败：\(error.localizedDescription)\n", stderr); exit(1)
        case nil: fputs("活动监视器启动超时\n", stderr); exit(1)
        }
    }
}
