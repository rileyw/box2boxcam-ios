import Foundation

/// Summary of repeated latency samples, in milliseconds. Percentiles use the nearest-rank
/// method on the sorted samples (p50 of 4 samples is the 2nd, p90 of 10 is the 9th).
public struct LatencySummary: Codable, Equatable, Sendable {
    public let count: Int
    public let meanMs: Double
    public let minMs: Double
    public let p50Ms: Double
    public let p90Ms: Double
    public let p99Ms: Double
    public let maxMs: Double

    /// Samples in seconds; non-finite or negative values are dropped. Nil when none is left.
    public init?(seconds: [Double]) {
        let ms = seconds.filter { $0.isFinite && $0 >= 0 }.map { $0 * 1000 }.sorted()
        guard !ms.isEmpty else { return nil }
        func rank(_ p: Double) -> Double {
            ms[max(0, min(ms.count - 1, Int((p * Double(ms.count)).rounded(.up)) - 1))]
        }
        count = ms.count
        meanMs = ms.reduce(0, +) / Double(ms.count)
        minMs = ms[0]
        p50Ms = rank(0.50)
        p90Ms = rank(0.90)
        p99Ms = rank(0.99)
        maxMs = ms[ms.count - 1]
    }

    /// Analyses per second if the model ran back to back at its median latency.
    public var medianRateHz: Double { p50Ms > 0 ? 1000 / p50Ms : .infinity }
}

/// One model timed with one compute-unit choice.
public struct ModelBenchmarkResult: Codable, Equatable, Sendable {
    /// Core ML resource name, e.g. "PitchLensBallSmallV006".
    public let model: String
    /// What the model was given, e.g. "1920x1080 frame, Vision scaleFit".
    public let input: String
    /// "all", "cpuAndNeuralEngine", "cpuAndGPU" or "cpuOnly".
    public let computeUnits: String
    /// MLModel loading time; the first load after an install includes on-device compilation.
    public let loadSeconds: Double?
    public let latency: LatencySummary?
    public let error: String?

    public init(model: String, input: String, computeUnits: String,
                loadSeconds: Double?, latency: LatencySummary?, error: String?) {
        self.model = model
        self.input = input
        self.computeUnits = computeUnits
        self.loadSeconds = loadSeconds
        self.latency = latency
        self.error = error
    }
}

/// A shareable latency report for one device, written as JSON.
public struct ModelBenchmarkReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// ISO 8601.
    public let date: String
    /// Hardware identifier, e.g. "iPhone18,1".
    public let device: String
    /// e.g. "iOS 26.1".
    public let system: String
    public let appVersion: String
    public let warmup: Int
    public let iterations: Int
    public let inputNote: String
    public let thermalStateStart: String
    public let thermalStateEnd: String
    public let lowPowerMode: Bool
    /// 0...1, nil when the device does not report it.
    public let batteryLevel: Double?
    public let results: [ModelBenchmarkResult]

    public init(date: String, device: String, system: String, appVersion: String,
                warmup: Int, iterations: Int, inputNote: String,
                thermalStateStart: String, thermalStateEnd: String,
                lowPowerMode: Bool, batteryLevel: Double?, results: [ModelBenchmarkResult]) {
        schemaVersion = Self.currentSchemaVersion
        self.date = date
        self.device = device
        self.system = system
        self.appVersion = appVersion
        self.warmup = warmup
        self.iterations = iterations
        self.inputNote = inputNote
        self.thermalStateStart = thermalStateStart
        self.thermalStateEnd = thermalStateEnd
        self.lowPowerMode = lowPowerMode
        self.batteryLevel = batteryLevel
        self.results = results
    }

    /// Name of a `ProcessInfo.ThermalState` raw value.
    public static func thermalStateName(_ rawValue: Int) -> String {
        ["nominal", "fair", "serious", "critical"].indices.contains(rawValue)
            ? ["nominal", "fair", "serious", "critical"][rawValue] : "unknown(\(rawValue))"
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ModelBenchmarkReport {
        try JSONDecoder().decode(ModelBenchmarkReport.self, from: data)
    }

    /// One row per model and compute-unit choice, for pasting into an issue.
    public var markdownTable: String {
        func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "-" }
        var lines = [
            "\(device) · \(system) · thermal \(thermalStateStart) → \(thermalStateEnd)"
                + (lowPowerMode ? " · low power" : ""),
            "",
            "| model | units | load s | p50 ms | p90 ms | p99 ms | ≈ Hz |",
            "|---|---|---:|---:|---:|---:|---:|",
        ]
        for r in results {
            if let error = r.error {
                lines.append("| \(r.model) | \(r.computeUnits) | - | error: \(error) | | | |")
                continue
            }
            let hz = r.latency.map { String(format: "%.0f", $0.medianRateHz) } ?? "-"
            lines.append("| \(r.model) | \(r.computeUnits) | \(r.loadSeconds.map { String(format: "%.2f", $0) } ?? "-") "
                + "| \(ms(r.latency?.p50Ms)) | \(ms(r.latency?.p90Ms)) | \(ms(r.latency?.p99Ms)) | \(hz) |")
        }
        return lines.joined(separator: "\n")
    }
}
