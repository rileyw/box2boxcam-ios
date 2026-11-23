import Foundation
import DockKitCore

func checkLatencySummaryPercentiles() throws {
    // 1...100 ms: nearest rank gives the 50th, 90th and 99th samples.
    let samples = (1...100).reversed().map { Double($0) / 1000 }
    let summary = try unwrap(LatencySummary(seconds: samples))
    try expectEqual(summary.count, 100)
    try expectClose(summary.minMs, 1)
    try expectClose(summary.maxMs, 100)
    try expectClose(summary.p50Ms, 50)
    try expectClose(summary.p90Ms, 90)
    try expectClose(summary.p99Ms, 99)
    try expectTrue(abs(summary.meanMs - 50.5) < 1e-9)
    try expectTrue(abs(summary.medianRateHz - 20) < 1e-9)

    // Four samples: p50 is the 2nd, p90 and p99 the 4th.
    let small = try unwrap(LatencySummary(seconds: [0.004, 0.001, 0.003, 0.002]))
    try expectClose(small.p50Ms, 2)
    try expectClose(small.p90Ms, 4)
    try expectClose(small.p99Ms, 4)
}

func checkLatencySummaryRejectsInvalidSamples() throws {
    try expectTrue(LatencySummary(seconds: []) == nil)
    try expectTrue(LatencySummary(seconds: [.nan, .infinity, -0.001]) == nil)
    let summary = try unwrap(LatencySummary(seconds: [.nan, 0.010, -1]))
    try expectEqual(summary.count, 1)
    try expectClose(summary.p99Ms, 10)
}

func checkModelBenchmarkReportRoundTrip() throws {
    let report = ModelBenchmarkReport(
        date: "2026-11-23T12:00:00Z", device: "iPhone18,1", system: "iOS 26.1", appVersion: "1.0 (1)",
        warmup: 10, iterations: 60, inputNote: "synthetic 1920x1080 frame",
        thermalStateStart: ModelBenchmarkReport.thermalStateName(0),
        thermalStateEnd: ModelBenchmarkReport.thermalStateName(2),
        lowPowerMode: false, batteryLevel: 0.8,
        results: [
            ModelBenchmarkResult(model: "PitchLensBallSmallV006", input: "frame", computeUnits: "all",
                                 loadSeconds: 0.42, latency: LatencySummary(seconds: [0.020, 0.030]), error: nil),
            ModelBenchmarkResult(model: "PitchLensPose", input: "crop", computeUnits: "cpuOnly",
                                 loadSeconds: nil, latency: nil, error: "missing"),
        ])
    let decoded = try ModelBenchmarkReport.decode(try report.jsonData())
    try expectEqual(decoded, report)
    try expectEqual(decoded.schemaVersion, ModelBenchmarkReport.currentSchemaVersion)
    try expectEqual(decoded.thermalStateEnd, "serious")
    try expectEqual(ModelBenchmarkReport.thermalStateName(7), "unknown(7)")

    let table = report.markdownTable
    try expectTrue(table.contains("iPhone18,1 · iOS 26.1 · thermal nominal → serious"))
    try expectTrue(table.contains("| PitchLensBallSmallV006 | all | 0.42 | 20.0 | 30.0 | 30.0 | 50 |"))
    try expectTrue(table.contains("| PitchLensPose | cpuOnly | - | error: missing |"))
}

private struct MissingValue: Error {}

private func expectClose(_ actual: Double, _ expected: Double,
                         file: StaticString = #filePath, line: UInt = #line) throws {
    try expectTrue(abs(actual - expected) < 1e-9, file: file, line: line)
}

private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw MissingValue() }
    return value
}
