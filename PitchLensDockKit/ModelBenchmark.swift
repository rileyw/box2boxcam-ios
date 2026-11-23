import CoreImage
import CoreML
import CoreVideo
import Foundation
import UIKit
import Vision

/// Times each Core ML model of the app on its own, for every compute-unit choice, so
/// latency can be compared across iPhones. Inference goes through Vision with scaleFit, as
/// in the live pipeline, on a fixed synthetic frame (pitch-green noise), so the numbers do
/// not depend on the scene; detection-heavy scenes add some NMS time. The camera is stopped
/// while it runs so live analysis does not compete for the Neural Engine.
@MainActor
final class ModelBenchmark: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progress = ""
    @Published private(set) var report: ModelBenchmarkReport?
    @Published private(set) var reportURL: URL?

    enum Input: Sendable {
        case frame, personCrop
        var note: String {
            switch self {
            case .frame: return "1920x1080 frame, Vision scaleFit"
            case .personCrop: return "192x384 person crop, Vision scaleFit"
            }
        }
    }

    struct Case: Sendable {
        let model: String
        let input: Input
    }

    static let cases = [
        Case(model: BallDetectorProfile.smallV006.resource, input: .frame),
        Case(model: "PitchLensPeople", input: .frame),
        Case(model: "PitchLensPose", input: .personCrop),
    ]

    static let computeUnits: [(name: String, value: MLComputeUnits)] = [
        ("all", .all),
        ("cpuAndNeuralEngine", .cpuAndNeuralEngine),
        ("cpuAndGPU", .cpuAndGPU),
        ("cpuOnly", .cpuOnly),
    ]

    func run(camera: CameraController, warmup: Int = 10, iterations: Int = 60) async {
        guard !isRunning else { return }
        isRunning = true
        report = nil
        reportURL = nil
        let resumeCamera = camera.isRunning
        camera.stop()
        // Let in-flight live analyses finish before timing anything.
        try? await Task.sleep(nanoseconds: 500_000_000)

        UIDevice.current.isBatteryMonitoringEnabled = true
        let battery = UIDevice.current.batteryLevel
        let thermalStart = ProcessInfo.processInfo.thermalState.rawValue
        let runs = Self.cases.flatMap { c in Self.computeUnits.map { (c, $0) } }
        var results: [ModelBenchmarkResult] = []
        for (index, (benchCase, units)) in runs.enumerated() {
            progress = "\(index + 1)/\(runs.count) · \(benchCase.model) · \(units.name)"
            let unitsValue = units.value
            let result = await Task.detached(priority: .userInitiated) {
                Self.measure(benchCase, units: unitsValue, warmup: warmup, iterations: iterations)
            }.value
            results.append(ModelBenchmarkResult(
                model: benchCase.model, input: benchCase.input.note, computeUnits: units.name,
                loadSeconds: result.loadSeconds, latency: result.samples.flatMap { LatencySummary(seconds: $0) },
                error: result.error))
        }

        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let finished = ModelBenchmarkReport(
            date: ISO8601DateFormatter().string(from: Date()),
            device: Self.hardwareIdentifier,
            system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            appVersion: version, warmup: warmup, iterations: iterations,
            inputNote: "Synthetic pitch-green noise; camera stopped during the run.",
            thermalStateStart: ModelBenchmarkReport.thermalStateName(thermalStart),
            thermalStateEnd: ModelBenchmarkReport.thermalStateName(ProcessInfo.processInfo.thermalState.rawValue),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            batteryLevel: battery >= 0 ? Double(battery) : nil,
            results: results)
        report = finished
        do {
            reportURL = try Self.write(finished)
            progress = "Terminé"
        } catch {
            progress = "Rapport non enregistré : \(error.localizedDescription)"
        }
        isRunning = false
        if resumeCamera { await camera.start() }
    }

    private struct Measurement: Sendable {
        var loadSeconds: Double?
        var samples: [Double]?
        var error: String?
    }

    private nonisolated static func measure(_ benchCase: Case, units: MLComputeUnits,
                                            warmup: Int, iterations: Int) -> Measurement {
        do {
            guard let url = Bundle.main.url(forResource: benchCase.model, withExtension: "mlmodelc") else {
                return Measurement(error: "model missing from the app")
            }
            guard let frame = syntheticFrame() else { return Measurement(error: "cannot create the input frame") }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            let loadStart = ProcessInfo.processInfo.systemUptime
            let model = try MLModel(contentsOf: url, configuration: configuration)
            let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
            let request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
            request.imageCropAndScaleOption = .scaleFit

            let crop: CGImage?
            switch benchCase.input {
            case .frame: crop = nil
            case .personCrop:
                let image = CIImage(cvPixelBuffer: frame).cropped(to: CGRect(x: 864, y: 348, width: 192, height: 384))
                crop = CIContext(options: [.cacheIntermediates: false]).createCGImage(image, from: image.extent)
                if crop == nil { return Measurement(error: "cannot create the person crop") }
            }
            var samples: [Double] = []
            samples.reserveCapacity(iterations)
            for index in 0..<(warmup + iterations) {
                // A new handler per analysis, as for live frames.
                let start = ProcessInfo.processInfo.systemUptime
                try autoreleasepool {
                    let handler = crop.map { VNImageRequestHandler(cgImage: $0) }
                        ?? VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up)
                    try handler.perform([request])
                }
                if index >= warmup { samples.append(ProcessInfo.processInfo.systemUptime - start) }
            }
            return Measurement(loadSeconds: loadSeconds, samples: samples)
        } catch {
            return Measurement(error: error.localizedDescription)
        }
    }

    /// 1920x1080 BGRA, pitch green with deterministic noise.
    private nonisolated static func syntheticFrame(width: Int = 1920, height: Int = 1080) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var seed: UInt32 = 0x2545_F491
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = UInt8(truncatingIfNeeded: seed >> 27)
                row[x * 4] = 40 &+ noise      // B
                row[x * 4 + 1] = 120 &+ noise // G
                row[x * 4 + 2] = 50 &+ noise  // R
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    /// e.g. "iPhone18,1".
    nonisolated static var hardwareIdentifier: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func write(_ report: ModelBenchmarkReport) throws -> URL {
        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
            .appendingPathComponent("benchmarks", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = report.date.replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("model-latency-\(report.device)-\(stamp).json")
        try report.jsonData().write(to: url, options: .atomic)
        return url
    }
}
