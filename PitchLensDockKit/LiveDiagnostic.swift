import Foundation

struct CaptureTelemetry: Codable, Sendable {
    let exposureSeconds: Double?
    let iso: Double?
    let zoom: Double?
    let cameraPosition: String?
    let transferFunction: String?
    let colorPrimaries: String?
    let videoHDREnabled: Bool?
    let droppedFrames: Int
    let sequence: Int
    let thermalState: Int
}

struct LiveFrameRecord: Codable, Sendable {
    let generation: String
    let profile: String
    let capturedAt: Double?
    let deliveryAgeSeconds: Double?
    let ageAtAnalysisStartSeconds: Double?
    let analysisSeconds: Double?
    let rawBestScore: Double?
    let proposalsAboveFollowThreshold: Int
    let followThreshold: Double
    let outcome: String
    let pixelFormat: String
    let rotation: Int
    let manuallySelected: Bool
    let camera: CaptureTelemetry
    /// [x, y, width, height] analysed, normalized top-left upright; [0, 0, 1, 1] is the
    /// whole image. Absent (nil) while the local window setting is off.
    let searchWindow: [Double]?
    /// Candidates removed by the static candidate filter; absent while that setting is off.
    let staticDropped: Int?
    /// Near-duplicate boxes removed before tracking (CandidateSuppression, IoU 0.7).
    let duplicatesDropped: Int?

    init(frame: BallDetectionFrame, now: Double, threshold: Double, outcome: String, manuallySelected: Bool) {
        func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }
        generation = frame.generation.uuidString
        profile = frame.profile.rawValue
        capturedAt = finite(frame.capturedAt)
        deliveryAgeSeconds = finite(now - frame.capturedAt)
        ageAtAnalysisStartSeconds = finite(frame.completedAt - frame.latency - frame.capturedAt)
        analysisSeconds = finite(frame.latency)
        rawBestScore = frame.box == nil ? nil : finite(frame.confidence)
        proposalsAboveFollowThreshold = frame.candidates.filter { $0.confidence >= threshold }.count
        followThreshold = threshold
        self.outcome = outcome
        pixelFormat = frame.pixelFormatDescription
        rotation = frame.rotationAngle
        self.manuallySelected = manuallySelected
        camera = frame.captureTelemetry
        staticDropped = frame.staticDropped
        duplicatesDropped = frame.duplicatesDropped
        searchWindow = frame.searchWindow.map {
            [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height].map { Double($0) }
        }
    }
}

struct LiveSnapshotIndex: Codable, Sendable {
    let capturedAt: Double
    let profile: String
    let rawImage: String
    let uprightImage: String
    let detections: String
}

struct LiveDiagnosticReport: Codable, Sendable {
    let appBuild: String
    let startedAt: String
    let elapsedSeconds: Double
    let interrupted: Bool
    let frames: [LiveFrameRecord]
    let snapshots: [LiveSnapshotIndex]
    var notes = [
        "Captured locally after pressing Diagnostic du direct. No motor target is created by recording.",
        "Camera exposure/ISO/zoom are device readings near callback, not exposure metadata attached to the exact frame.",
        "PNG encoding runs outside the inference queue; recording still has some CPU/GPU/storage overhead.",
        "The report logs received results; sequence gaps within one generation indicate analyses coalesced before delivery.",
        "Snapshots use the exact last analyzed pixels and their matching Vision results; they may differ from ordinary Camera videos."
    ]
}

enum LiveDiagnosticFiles {
    /// Executed off the MainActor. forUploading packages a directory as a ZIP.
    static func finish(_ report: LiveDiagnosticReport, directory: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("live-report.json"), options: .atomic)
        let destination = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".zip")
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &coordinationError) { packaged in
            do { try FileManager.default.copyItem(at: packaged, to: destination) }
            catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw NSError(domain: "PitchLens.LiveDiagnostic", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Diagnostic non exportable"])
        }
        return destination
    }
}
