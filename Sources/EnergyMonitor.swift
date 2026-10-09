import Foundation

struct DrainItem {
    let name: String
    let cpu: Double
    let rssMB: Int
    let count: Int
    var detail: String {
        var parts = [String(format: "CPU %.1f%%", cpu)]
        if count > 1 { parts.append("\(count) 进程") }
        if rssMB >= 200 { parts.append("\(rssMB) MB") }
        return parts.joined(separator: " · ")
    }
}

struct ProcessSample {
    let items: [DrainItem]
    let capturedAt: Date
    let duration: TimeInterval
}

enum ProcessReader {
    static func read() throws -> ProcessSample {
        let started = Date()
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid=,pcpu=,rss=,args="]
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw ReadFailure.message("进程采样不可用（\(task.terminationStatus)）")
        }
        return ProcessSample(items: try parse(String(decoding: data, as: UTF8.self), excluding: [getpid(), task.processIdentifier]),
            capturedAt: Date(), duration: Date().timeIntervalSince(started))
    }

    static func parse(_ output: String, excluding pids: Set<Int32> = []) throws -> [DrainItem] {
        var validRows = 0
        var groups: [String: (cpu: Double, rssKB: Int, count: Int)] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(maxSplits: 4, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 5, let pid = Int32(parts[0]), let ppid = Int(parts[1]),
                  let cpu = Double(parts[2]), cpu.isFinite, cpu >= 0,
                  let rss = Int(parts[3]), rss >= 0 else { continue }
            validRows += 1
            let args = String(parts[4])
            guard !pids.contains(pid), !isMonitor(args), let name = category(args, ppid: ppid, cpu: cpu) else { continue }
            let previous = groups[name] ?? (0, 0, 0)
            groups[name] = (previous.cpu + cpu, previous.rssKB + rss, previous.count + 1)
        }
        guard validRows > 0 else { throw ReadFailure.message("未读到有效进程样本") }
        return groups.map { DrainItem(name: $0.key, cpu: $0.value.cpu, rssMB: $0.value.rssKB / 1024, count: $0.value.count) }
            .filter { $0.cpu >= 1 }
            .sorted {
                if $0.cpu != $1.cpu { return $0.cpu > $1.cpu }
                if $0.rssMB != $1.rssMB { return $0.rssMB > $1.rssMB }
                return $0.name < $1.name
            }
            .prefix(5).map { $0 }
    }

    private static func isMonitor(_ args: String) -> Bool {
        args.contains("MacMonitorPreview") || args.contains("PowerWatch") || args.contains("power-watch") ||
        args.contains("MacTemperature") || args.contains("/macmon ")
    }

    private static func category(_ args: String, ppid: Int, cpu: Double) -> String? {
        let mcp = args.localizedCaseInsensitiveContains("mcp") || args.contains("server.cjs --stdio")
        let likec4 = args.localizedCaseInsensitiveContains("likec4") || args.contains("mcp-server.mjs")
        if ppid == 1 && mcp { return likec4 ? "孤儿 LikeC4 MCP" : "孤儿 MCP" }
        if likec4 { return "LikeC4 MCP" }
        for (pattern, name) in [
            ("WindowServer", "WindowServer"), ("systemstatusd", "菜单栏状态服务"),
            ("SystemStatusServer", "菜单栏状态服务"), ("syspolicyd", "系统安全校验"),
            ("trustd", "系统安全校验"), ("PerfPowerServices", "性能/电源服务"),
            ("XProtect", "系统安全扫描"), ("openAndSavePanelService", "打开/保存面板"),
            ("SkyComputerUseClient", "Computer Use"), ("WeChat", "微信"), ("微信", "微信"),
            ("WeType", "微信输入法"), ("Safari", "Safari/WebKit"), ("WebKit", "Safari/WebKit"),
            ("Clash", "Clash"), ("mihomo", "Clash"), ("coreaudiod", "音频"),
            ("airportd", "Wi-Fi 服务"), ("WiFiAgent", "Wi-Fi 服务"), ("/dasd", "后台任务调度"),
            ("/configd", "网络配置服务")
        ] where args.localizedCaseInsensitiveContains(pattern) { return name }
        if args.contains("Codex.app") || args.contains("/.codex/") || args.contains("/codex") || args.contains("ChatGPT.app") {
            return "Codex"
        }
        // App 路径可含空格；提取 .app 名称，把同一应用的 helper 归在一起。
        if let match = appName.firstMatch(in: args, range: NSRange(args.startIndex..., in: args)),
           let range = Range(match.range(at: 1), in: args) { return String(args[range]) }
        guard cpu >= 2 else { return nil }
        let executable = args.split(separator: " ").first.map(String.init) ?? ""
        let name = URL(fileURLWithPath: executable).lastPathComponent
        return name.isEmpty ? "其他进程" : name
    }
    private static let appName = try! NSRegularExpression(pattern: #"([^/]+)\.app/Contents/"#)
}

struct RuntimePoint: Codable {
    let time: Date
    let percent: Double
    let onAC: Bool
    let charging: Bool
    let session: UUID
}

struct RuntimeEstimate {
    let state: String
    let remainingHours: Double?
    let fullHours: Double?
    let detail: String
    var title: String {
        if let remainingHours { return "续航估算  约\(Self.duration(remainingHours))（\(state)）" }
        return "续航估算  \(state)"
    }
    var basis: String {
        let full = fullHours.map { " · 满电参考 \(Self.duration($0))" } ?? ""
        return "\(detail)\(full)"
    }
    static func duration(_ hours: Double) -> String {
        let minutes = max(0, Int((hours * 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60)小时\(minutes % 60)分钟" : "\(minutes)分钟"
    }

    static func evaluate(battery: BatterySample?, points: [RuntimePoint], now: Date,
                         loadChanged: Bool = false, processVerified: Bool = true) -> RuntimeEstimate {
        func unavailable(_ state: String, _ reason: String) -> RuntimeEstimate {
            RuntimeEstimate(state: state, remainingHours: nil, fullHours: nil, detail: reason)
        }
        guard let battery, now.timeIntervalSince(battery.capturedAt) <= 90 else {
            return unavailable("不可用", "电池读数缺失或过期")
        }
        if battery.isOnAC || battery.isCharging { return unavailable("插电中，暂停学习", "离电后按电量下降估算") }
        if loadChanged { return unavailable("负载突变", "重新积累当前负载下的离电样本") }
        guard let last = points.last, !last.onAC, !last.charging else {
            return unavailable("学习中", "需要约 10 分钟的连续离电样本和实际电量下降")
        }
        if now.timeIntervalSince(last.time) > 15 * 60 {
            return unavailable("样本失效", "最近离电样本已超过 15 分钟")
        }
        let cutoff = now.addingTimeInterval(-3 * 60 * 60)
        let window = points.filter { $0.session == last.session && !$0.onAC && !$0.charging && $0.time >= cutoff && $0.time <= now }
        guard let first = window.first, let end = window.last, window.count >= 2 else {
            return unavailable("学习中", "需要约 10 分钟的连续离电样本和实际电量下降")
        }
        if zip(window, window.dropFirst()).contains(where: {
            $1.time.timeIntervalSince($0.time) > 5 * 60 || $1.time <= $0.time || $1.percent > $0.percent + 0.5
        }) {
            return unavailable("样本失效", "离电样本不连续或电量发生跳变")
        }
        let span = end.time.timeIntervalSince(first.time) / 3600
        let consumed = first.percent - end.percent
        guard span >= 0.16, consumed > 0 else {
            return unavailable("学习中", "样本跨度不足或尚未观测到电量下降")
        }
        let rate = consumed / span
        let remaining = battery.fraction * 100 / rate
        let full = 100 / rate
        guard remaining.isFinite, full.isFinite, full > 0, full <= 72 else {
            return unavailable("样本失效", "电量下降速率不足以支持可靠估算")
        }
        let state = span >= 0.33 && processVerified ? "中可信" : "低可信"
        let detail = "按最近 \(Int(span * 60)) 分钟离电样本估算" + (processVerified ? "" : " · 负载未核对")
        return RuntimeEstimate(state: state, remainingHours: remaining, fullHours: full, detail: detail)
    }
}

struct ProcessLoadTracker {
    private var previousSignature: Set<String>?
    private var previousTotal: Double?
    mutating func changed(_ items: [DrainItem]) -> Bool {
        let signature = Set(items.filter { $0.cpu >= 15 }.map(\.name))
        let total = items.reduce(0) { $0 + $1.cpu }
        defer { previousSignature = signature; previousTotal = total }
        guard let previousSignature, let previousTotal else { return items.contains { $0.cpu >= 40 } }
        return signature != previousSignature || abs(total - previousTotal) >= 30
    }
}

final class RuntimeHistory {
    private(set) var points: [RuntimePoint]
    private(set) var message: String?
    private var needsBoundary = false
    private var session: UUID
    private let url: URL
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/mac-monitor-preview/runtime-samples.json")
    }

    init(url: URL = RuntimeHistory.defaultURL) {
        self.url = url
        points = []
        if FileManager.default.fileExists(atPath: url.path) {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
               let data = try? Data(contentsOf: url), let loaded = try? JSONDecoder().decode([RuntimePoint].self, from: data),
               loaded.allSatisfy({ $0.percent.isFinite && (0...100).contains($0.percent) && $0.time <= Date() }) {
                points = Array(loaded.sorted { $0.time < $1.time }.suffix(4500))
            } else { message = "旧续航样本无法读取，重新学习" }
        }
        session = points.last?.session ?? UUID()
    }

    func markBoundary() { needsBoundary = true }

    @discardableResult
    func record(_ battery: BatterySample, now: Date, persist: Bool = true) -> Bool {
        guard abs(now.timeIntervalSince(battery.capturedAt)) <= 90 else { return false }
        if let last = points.last, battery.capturedAt < last.time { return false }
        let percent = battery.fraction * 100
        let boundary = needsBoundary || points.last.map {
            battery.capturedAt.timeIntervalSince($0.time) > 5 * 60 || $0.onAC != battery.isOnAC ||
            $0.charging != battery.isCharging || (!battery.isOnAC && percent > $0.percent + 0.5)
        } == true
        if boundary { session = UUID() }
        guard boundary || points.last.map({ battery.capturedAt.timeIntervalSince($0.time) >= 55 }) != false else { return false }
        needsBoundary = false
        points.append(RuntimePoint(time: battery.capturedAt, percent: percent, onAC: battery.isOnAC,
            charging: battery.isCharging, session: session))
        points = Array(points.filter { $0.time >= now.addingTimeInterval(-3 * 24 * 3600) }.suffix(4500))
        if persist {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try JSONEncoder().encode(points).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                message = nil
            } catch { message = "续航样本保存失败，本次继续使用内存样本" }
        }
        return true
    }
}

struct EnergySnapshot {
    let runtime: RuntimeEstimate
    let processes: ProcessSample?
    let processMessage: String?
    let historyMessage: String?
    let capturedAt: Date
}

// 扫进程、维护样本都在独立串行队列，不阻塞菜单栏；不调用电源策略 helper。
final class EnergyMonitor {
    var onUpdate: ((EnergySnapshot) -> Void)?
    private let queue = DispatchQueue(label: "com.eoshow.mac-monitor-preview.energy", qos: .utility)
    private var history: RuntimeHistory?
    private var processes: ProcessSample?
    private var processMessage: String?
    private var loadTracker = ProcessLoadTracker()
    private var loadChangedAt: Date?
    private var request = UUID()

    func refresh(battery: BatterySample?, forceProcesses: Bool = false) {
        let token = UUID()
        request = token
        queue.async { [weak self] in
            guard let self else { return }
            if self.history == nil { self.history = RuntimeHistory() }
            let now = Date()
            // 进程读数只服务于离电估算的负载变化判断；接电时无需扫描。
            let needsLoadSample = battery?.isOnAC == false && battery?.isCharging == false
            if !needsLoadSample {
                self.processes = nil
                self.processMessage = nil
                self.loadTracker = ProcessLoadTracker()
                self.loadChangedAt = nil
            } else if forceProcesses || self.processes.map({ now.timeIntervalSince($0.capturedAt) >= 300 }) != false {
                do {
                    let sample = try ProcessReader.read()
                    if self.loadTracker.changed(sample.items), battery?.isOnAC == false {
                        self.history?.markBoundary()
                        self.loadChangedAt = now
                    }
                    self.processes = sample
                    self.processMessage = nil
                } catch {
                    self.processes = nil
                    self.processMessage = error.localizedDescription
                }
            }
            if let battery { self.history?.record(battery, now: now) }
            let changed = self.loadChangedAt.map { now.timeIntervalSince($0) < 5 * 60 } ?? false
            let result = EnergySnapshot(runtime: RuntimeEstimate.evaluate(battery: battery, points: self.history?.points ?? [],
                now: now, loadChanged: changed, processVerified: self.processes != nil), processes: self.processes,
                processMessage: self.processMessage, historyMessage: self.history?.message, capturedAt: now)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request == token else { return }
                self.onUpdate?(result)
            }
        }
    }

    func markBoundary() {
        request = UUID()
        queue.async { [weak self] in self?.history?.markBoundary() }
    }
}
