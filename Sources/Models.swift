import Foundation

enum ReadFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}

struct TemperatureSample {
    let cpu: Double?
    let gpu: Double?
    let capturedAt: Date
    var highest: Double { [cpu, gpu].compactMap { $0 }.max() ?? 0 }

    init?(cpu: Double?, gpu: Double?, capturedAt: Date = Date()) {
        func usable(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value > 0, value < 150 else { return nil }
            return value
        }
        self.cpu = usable(cpu)
        self.gpu = usable(gpu)
        self.capturedAt = capturedAt
        guard self.cpu != nil || self.gpu != nil else { return nil }
    }

    static func parse(_ line: String) -> TemperatureSample? {
        struct Payload: Decodable {
            struct Temperature: Decodable {
                let cpu_temp_avg: Double?
                let gpu_temp_avg: Double?
            }
            let temp: Temperature
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(line.utf8)) else {
            return nil
        }
        return TemperatureSample(cpu: payload.temp.cpu_temp_avg, gpu: payload.temp.gpu_temp_avg)
    }
}

struct DiskSample {
    let total: Int64
    let available: Int64
    let capturedAt: Date
    let path: String
    var estimatedUsed: Int64 { total - available }
    var usedFraction: Double { Double(estimatedUsed) / Double(total) }

    init(total: Int64, available: Int64, path: String, capturedAt: Date = Date()) throws {
        guard total > 0, available >= 0, available <= total else {
            throw ReadFailure.message("卷容量读数无效")
        }
        self.total = total
        self.available = available
        self.path = path
        self.capturedAt = capturedAt
    }
}

struct BatterySample {
    let fraction: Double
    let isCharging: Bool
    let isOnAC: Bool
    let capturedAt: Date
    var percent: Int { Int((fraction * 100).rounded()) }
    var powerDescription: String {
        if isCharging { return "正在充电" }
        if isOnAC { return percent == 100 ? "外接电源 · 已充满" : "外接电源 · 未充电" }
        return "使用电池"
    }

    init(current: Double, maximum: Double, isCharging: Bool, isOnAC: Bool,
         capturedAt: Date = Date()) throws {
        guard current.isFinite, maximum.isFinite, maximum > 0, current >= 0, current <= maximum else {
            throw ReadFailure.message("电量读数无效")
        }
        fraction = current / maximum
        self.isCharging = isCharging
        self.isOnAC = isOnAC
        self.capturedAt = capturedAt
    }
}

enum TemperatureBand: Int {
    case cool, middle, warm, hot
    static let boundaries: [Double] = [45, 80, 90]
    static func direct(_ temperature: Double) -> TemperatureBand {
        TemperatureBand(rawValue: boundaries.filter { temperature >= $0 }.count) ?? .cool
    }
}

struct TemperatureColorState {
    private(set) var band: TemperatureBand?

    mutating func reset() { band = nil }
    mutating func update(_ temperature: Double) -> TemperatureBand {
        var index = band?.rawValue ?? TemperatureBand.direct(temperature).rawValue
        while index < 3 && temperature >= TemperatureBand.boundaries[index] { index += 1 }
        // 降温需越过边界 2°C，避免边界附近反复变色；允许一次跨越多档。
        while index > 0 && temperature < TemperatureBand.boundaries[index - 1] - 2 { index -= 1 }
        let result = TemperatureBand(rawValue: index) ?? .cool
        band = result
        return result
    }
}

struct MonitorState {
    var temperature: TemperatureSample?
    var disk: DiskSample?
    var battery: BatterySample?
    var temperatureMessage = "等待温度采样…"
    var diskMessage = "正在读取磁盘…"
    var batteryMessage = "正在读取电量…"

    func freshTemperature(at now: Date) -> TemperatureSample? {
        guard let temperature, now.timeIntervalSince(temperature.capturedAt) <= 20 else { return nil }
        return temperature
    }
    func freshDisk(at now: Date) -> DiskSample? {
        guard let disk, now.timeIntervalSince(disk.capturedAt) <= 180 else { return nil }
        return disk
    }
    func freshBattery(at now: Date) -> BatterySample? {
        guard let battery, now.timeIntervalSince(battery.capturedAt) <= 90 else { return nil }
        return battery
    }
}
