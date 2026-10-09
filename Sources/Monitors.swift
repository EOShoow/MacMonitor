import Foundation
import IOKit.ps

// 每次连接使用独立缓冲区。旧进程退出/残留输出不能污染重连后的读数。
private final class TemperatureStream {
    private let queue = DispatchQueue(label: "com.eoshow.mac-monitor-preview.parser")
    private var buffer = ""

    func consume(_ data: Data, deliver: @escaping (TemperatureSample) -> Void) {
        queue.async {
            self.buffer.append(String(decoding: data, as: UTF8.self))
            while let end = self.buffer.firstIndex(of: "\n") {
                let line = String(self.buffer[..<end])
                self.buffer.removeSubrange(...end)
                if let sample = TemperatureSample.parse(line) {
                    DispatchQueue.main.async { deliver(sample) }
                }
            }
            if self.buffer.utf8.count > 1_048_576 { self.buffer = "" }
        }
    }
}

final class TemperatureMonitor {
    var onSample: ((TemperatureSample) -> Void)?
    var onFailure: ((String) -> Void)?
    private var process: Process?
    private var pipe: Pipe?
    private var generation = UUID()
    private(set) var startedAt: Date?
    var isRunning: Bool { process?.isRunning == true }

    static var macmonPath: String? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/macmon").path
        return [bundled, "/opt/homebrew/bin/macmon", "/usr/local/bin/macmon"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    static var usesBundledSampler: Bool {
        macmonPath == Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/macmon").path
    }

    func start() {
        stop()
        let token = generation
        startedAt = Date()
        guard let path = Self.macmonPath else {
            onFailure?("未找到 macmon，温度不可用")
            return
        }
        let task = Process()
        let output = Pipe()
        let stream = TemperatureStream()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
        task.arguments = ["-b", "/usr/bin/nice", "-n", "15", path, "pipe", "-s", "0", "-i", "5000"]
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            stream.consume(data) { [weak self] sample in
                guard let self, self.generation == token else { return }
                self.onSample?(sample)
            }
        }
        task.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.pipe?.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.pipe = nil
                self.onFailure?("温度采集已退出（\(finished.terminationStatus)），稍后重连")
            }
        }
        process = task
        pipe = output
        do { try task.run() }
        catch {
            stop()
            onFailure?("无法启动温度采集：\(error.localizedDescription)")
        }
    }

    func stop() {
        generation = UUID()
        pipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        pipe = nil
        startedAt = nil
    }
}

enum DiskReader {
    static func read() throws -> DiskSample {
        // total 与 available 来自同一次、同一卷查询；不混用 Data 卷 df 的 used。
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        guard let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity else {
            throw ReadFailure.message("未读到卷容量")
        }
        return try DiskSample(total: Int64(total), available: Int64(available), path: home.path)
    }
}

final class BatteryMonitor {
    var onChange: ((Result<BatterySample, Error>) -> Void)?
    private var source: CFRunLoopSource?

    func start() {
        if source == nil {
            let context = Unmanaged.passUnretained(self).toOpaque()
            source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
            }, context)?.takeRetainedValue()
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        }
        refresh()
    }

    func refresh() { onChange?(Result { try Self.read() }) }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        source = nil
    }

    static func read() throws -> BatterySample {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            throw ReadFailure.message("无法读取电源信息")
        }
        for item in list {
            guard let raw = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue(),
                  let description = raw as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            guard let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
                  let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue else {
                throw ReadFailure.message("内置电池容量不可用")
            }
            return try BatterySample(
                current: current, maximum: maximum,
                isCharging: (description[kIOPSIsChargingKey] as? NSNumber)?.boolValue == true,
                isOnAC: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        throw ReadFailure.message("未检测到 Mac 内置电池")
    }
}
