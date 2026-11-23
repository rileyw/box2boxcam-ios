import AVFoundation
import CoreML
import CoreImage
import Vision

enum BallDetectorProfile: String, CaseIterable, Identifiable, Sendable {
    // The open box2boxcam ball model v1.0 (YOLO26s, 960 px), downloaded by scripts/fetch-models.sh.
    case smallV006
    var id: String { rawValue }
    var title: String { "box2boxcam ball v1.0" }
    var resource: String { "PitchLensBallSmallV006" }
    var label: String { "sports ball" }
    var floor: Double { 0.10 }
    var description: String { "YOLO26 Small · 960 px · open model from Hugging Face." }
}

struct BallDetectionFrame: Sendable {
    var hybridPeople: HybridPeopleSnapshot? = nil
    var hybridCameraCenter = HybridVector(0.5, 0.5)
    var hybridMotionValid = false
    var hybridReferenceID: UUID? = nil
    var searchWindow: BallSearchWindow? = nil // Set only while the local window setting is on.
    var staticDropped: Int? = nil // Set only while the static candidate filter is on.
    var duplicatesDropped = 0 // Near-duplicate boxes removed by CandidateSuppression.
    let generation: UUID
    let box: CGRect? // Normalized, top-left origin, upright image matching the preview.
    let confidence: Double
    let candidates: [BallCandidate]
    let capturedAt: TimeInterval
    let completedAt: TimeInterval
    let latency: TimeInterval
    let analysesPerSecond: Double?
    let imageSize: CGSize
    let profile: BallDetectorProfile
    let rotationAngle: Int
    let pixelFormat: OSType
    let candidateCount: Int
    let otherObjects: String
    let error: String?
    let captureTelemetry: CaptureTelemetry
    var pixelFormatDescription: String {
        let bytes = [24, 16, 8, 0].map { UInt8((pixelFormat >> $0) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? String(pixelFormat)
    }
    var scoreDescription: String? {
        guard box != nil else { return nil }
        if confidence > 0, confidence < 0.0001 { return "< 0,01 %" }
        return String(format: "%.2f %%", confidence * 100)
    }
}

struct BallDiagnosticSnapshot: Sendable {
    let imageURL: URL
    let rawImageURL: URL
    let reportURL: URL
    let frame: BallDetectionFrame
}

/// The capture delegate queue performs one inference at a time, discarding late frames.
final class BallDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "pitchlens.ball-inference", qos: .userInitiated)
    /// Set once by the camera controller before capture starts. Sample timestamps follow the
    /// session's synchronization clock, which becomes the microphone's clock once audio is
    /// recorded; that clock drifts from the host clock (about 50 µs per second on 18 Nov 2026,
    /// enough to make every analysis look stale after a few minutes). They are converted.
    weak var captureSession: AVCaptureSession?

    /// Seconds on the host clock (ProcessInfo.systemUptime) for a capture-clock time.
    static func hostSeconds(_ time: CMTime, session: AVCaptureSession?) -> Double {
        guard let clock = session?.synchronizationClock else { return CMTimeGetSeconds(time) }
        let host = CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock())
        let seconds = CMTimeGetSeconds(host)
        return host.isValid && seconds.isFinite ? seconds : CMTimeGetSeconds(time)
    }
    var onResult: ((BallDetectionFrame) -> Void)?
    private var generation = UUID()
    private var enabled = false
    private var requests: [BallDetectorProfile: VNCoreMLRequest] = [:]
    private var loadErrors: [BallDetectorProfile: String] = [:]
    private var profile = BallDetectorProfile.smallV006
    private var rotationAngle = 90
    private var previousCompletion: TimeInterval?
    private var smoothedAnalysisInterval: TimeInterval?
    private var lastPixels: CVPixelBuffer?
    private var lastFrame: BallDetectionFrame?
    private var lastObjects: [[String: Any]] = []
    private let snapshotQueue = DispatchQueue(label: "pitchlens.snapshot", qos: .utility)
    private var captureSequence = 0
    private var droppedFrames = 0
    private let cameraMotion = CameraMotionEstimator()
    private let peopleProcessor = HybridVisionProcessor()
    private var motionReference: UUID?
    private var hybridEnabled = true
    private var localWindowEnabled = false
    private var localWindowThreshold = 0.25
    private var searchWindow = BallSearchWindowPolicy()
    private var staticFilterEnabled = false
    private var staticFilter = StaticCandidateFilter()

    func setStaticCandidateFilter(enabled: Bool) {
        queue.async {
            self.staticFilterEnabled = enabled
            self.staticFilter.reset()
        }
    }

    func setLocalSearchWindow(enabled: Bool, followThreshold: Double) {
        queue.async {
            self.localWindowEnabled = enabled
            self.localWindowThreshold = followThreshold
            self.searchWindow.reset()
        }
    }

    func setHybridEnabled(_ enabled: Bool) {
        queue.async {
            self.hybridEnabled = enabled
            self.cameraMotion.reset()
            self.motionReference = self.cameraMotion.referenceID
            self.peopleProcessor.configure(reference: self.cameraMotion.referenceID)
        }
    }

    func configure(enabled: Bool, generation: UUID, profile: BallDetectorProfile, rotationAngle: Int) {
        queue.async {
            self.enabled = enabled
            self.generation = generation
            self.profile = profile
            self.rotationAngle = rotationAngle
            self.previousCompletion = nil
            self.smoothedAnalysisInterval = nil
            self.lastPixels = nil
            self.lastFrame = nil
            self.lastObjects = []
            self.captureSequence = 0
            self.droppedFrames = 0
            self.searchWindow.reset()
            self.staticFilter.reset()
            self.cameraMotion.reset()
            self.motionReference = self.cameraMotion.referenceID
            self.peopleProcessor.configure(reference: self.cameraMotion.referenceID)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard enabled, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        captureSequence += 1
        let device = (connection.inputPorts.first(where: { $0.mediaType == .video })?.input as? AVCaptureDeviceInput)?.device
        func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
        let telemetry = CaptureTelemetry(
            exposureSeconds: finite(device.map { CMTimeGetSeconds($0.exposureDuration) }),
            iso: finite(device.map { Double($0.iso) }), zoom: finite(device.map { Double($0.videoZoomFactor) }),
            cameraPosition: device.map { $0.position == .front ? "front" : "back" },
            transferFunction: CVBufferCopyAttachment(pixels, kCVImageBufferTransferFunctionKey, nil) as? String,
            colorPrimaries: CVBufferCopyAttachment(pixels, kCVImageBufferColorPrimariesKey, nil) as? String,
            videoHDREnabled: device.map { $0.isVideoHDREnabled },
            droppedFrames: droppedFrames, sequence: captureSequence,
            thermalState: ProcessInfo.processInfo.thermalState.rawValue)
        // Analyze every available frame. The serial delegate queue and
        // alwaysDiscardsLateVideoFrames keep slow inference from building a backlog.
        // Capture time on the host clock, rather than the completion time.
        let capturedAt = Self.hostSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), session: captureSession)
        let rawSize = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        let angle = rotationAngle
        let portrait = angle == 90 || angle == 270
        let size = portrait ? CGSize(width: rawSize.height, height: rawSize.width) : rawSize
        let profile = profile
        let token = generation
        autoreleasepool {
            do {
                if requests[profile] == nil && loadErrors[profile] == nil {
                    do {
                        guard let url = Bundle.main.url(forResource: profile.resource, withExtension: "mlmodelc") else {
                            throw NSError(domain: "PitchLens.Model", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "Modèle de ballon absent de l’app"])
                        }
                        let configuration = MLModelConfiguration()
                        configuration.computeUnits = .all
                        let model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: configuration))
                        let request = VNCoreMLRequest(model: model)
                        request.imageCropAndScaleOption = .scaleFit
                        requests[profile] = request
                    } catch { loadErrors[profile] = error.localizedDescription }
                }
                guard let request = requests[profile] else {
                    throw NSError(domain: "PitchLens.Model", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: loadErrors[profile] ?? "Modèle indisponible"])
                }
                // Capture pixels remain unrotated; Vision receives the same rotation
                // as the preview, BEFORE inference. Its boxes are already upright.
                let orientation: CGImagePropertyOrientation
                switch angle {
                case 90: orientation = .right
                case 180: orientation = .down
                case 270: orientation = .left
                default: orientation = .up
                }
                // The static filter reuses the hybrid registration, also when hybrid is off.
                let motionValid = hybridEnabled || staticFilterEnabled
                    ? cameraMotion.update(pixels: pixels, orientation: orientation) : false
                if motionReference != cameraMotion.referenceID {
                    motionReference = cameraMotion.referenceID
                    peopleProcessor.configure(reference: cameraMotion.referenceID)
                }
                if hybridEnabled {
                    peopleProcessor.submit(pixels: pixels, orientation: orientation, center: cameraMotion.center,
                        timestamp: capturedAt, reference: cameraMotion.referenceID,
                        horizontalFOV: device.map { d in
                            let focal = Double(rawSize.width) / (2 * tan(Double(d.activeFormat.videoFieldOfView) * .pi / 360)) * Double(d.videoZoomFactor)
                            return atan(Double(size.width) / (2 * focal)) * 360 / .pi
                        } ?? 60)
                }
                // Same single inference; off, the region stays Vision's default full frame.
                // The region is in the upright (oriented) image, bottom-left origin, and a
                // 960 px square on the square model input needs no scaleFit letterbox.
                let window = localWindowEnabled ? searchWindow.window(imageWidth: Double(size.width),
                    imageHeight: Double(size.height), timestamp: capturedAt) : .fullFrame
                request.regionOfInterest = window.visionRegion
                try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation).perform([request])
                // Vision boxes are relative to the region; map them to the whole image first.
                func fullImageBox(_ object: VNRecognizedObjectObservation) -> CGRect {
                    window.isFullFrame ? object.boundingBox : window.fullImageVisionBox(object.boundingBox)
                }
                guard let observations = request.results as? [VNRecognizedObjectObservation] else {
                    throw NSError(domain: "PitchLens.Model", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Sortie du modèle incompatible avec Vision"])
                }
                let candidates = observations.compactMap { observation -> (CGRect, Double)? in
                    guard let label = observation.labels.first(where: { $0.identifier == profile.label }) else { return nil }
                    // Vision normalizes label confidence across classes; a single class
                    // can have label confidence 1 even when the detection is uncertain.
                    let confidence = Double(observation.confidence * label.confidence)
                    guard confidence > 0 else { return nil }
                    let b = fullImageBox(observation)
                    let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
                        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                    guard !box.isNull, box.width > 0, box.height > 0 else { return nil }
                    return (box, confidence)
                }
                let best = candidates.max { $0.1 < $1.1 }
                let otherObjects = observations.sorted { $0.confidence > $1.confidence }.prefix(3).compactMap { object -> String? in
                    guard let label = object.labels.first else { return nil }
                    return String(format: "%@ %.1f %%", label.identifier, object.confidence * label.confidence * 100)
                }.joined(separator: ", ")
                lastObjects = observations.map { object -> [String: Any] in
                    let b = fullImageBox(object)
                    return ["box_bottom_left": [b.minX, b.minY, b.width, b.height],
                     "object_confidence": Double(object.confidence),
                     "labels": object.labels.filter {
                         $0.identifier == profile.label || object.labels.prefix(8).contains($0)
                     }.map {
                         ["name": $0.identifier, "confidence": Double($0.confidence),
                          "joint_confidence": Double(object.confidence * $0.confidence)] as [String: Any]
                     }]
                }
                let completedAt = ProcessInfo.processInfo.systemUptime
                // Before every tracker; box, score and candidateCount stay unfiltered diagnostics.
                // The model's own NMS stage keeps near-duplicate boxes (it reads its IoU 0.7
                // like a standard NMS at about 0.9), so suppress them at a standard IoU 0.7.
                // The best box is always kept.
                let deduplicated = CandidateSuppression.suppress(candidates.map {
                    BallCandidate(x: $0.0.midX, y: $0.0.midY, width: $0.0.width, height: $0.0.height, confidence: $0.1)
                })
                var ballCandidates = deduplicated.kept
                var staticDropped: Int?
                if staticFilterEnabled {
                    let filtered = staticFilter.filter(ballCandidates, timestamp: capturedAt,
                        imageAspectRatio: Double(size.width / max(1, size.height)),
                        camera: motionValid ? (cameraMotion.referenceID, cameraMotion.center) : nil)
                    ballCandidates = filtered.kept
                    staticDropped = filtered.dropped
                }
                if localWindowEnabled {
                    searchWindow.record(window, candidates: ballCandidates, timestamp: capturedAt,
                                        now: completedAt, minimumConfidence: localWindowThreshold)
                }
                var frame = BallDetectionFrame(generation: token, box: best?.0, confidence: best?.1 ?? 0,
                    candidates: ballCandidates,
                    capturedAt: capturedAt, completedAt: completedAt, latency: completedAt - now,
                    analysesPerSecond: recordCompletion(at: completedAt),
                    imageSize: size, profile: profile, rotationAngle: angle,
                    pixelFormat: CVPixelBufferGetPixelFormatType(pixels),
                    candidateCount: candidates.count, otherObjects: otherObjects, error: nil, captureTelemetry: telemetry)
                if localWindowEnabled { frame.searchWindow = window }
                frame.staticDropped = staticDropped
                frame.duplicatesDropped = deduplicated.dropped
                if hybridEnabled {
                    frame.hybridPeople = peopleProcessor.latest(reference: cameraMotion.referenceID)
                    frame.hybridCameraCenter = cameraMotion.center
                    frame.hybridMotionValid = motionValid
                    frame.hybridReferenceID = cameraMotion.referenceID
                }
                lastPixels = pixels
                lastFrame = frame
                onResult?(frame)
            } catch {
                lastPixels = nil
                lastFrame = nil
                lastObjects = []
                previousCompletion = nil
                smoothedAnalysisInterval = nil
                let completedAt = ProcessInfo.processInfo.systemUptime
                onResult?(BallDetectionFrame(generation: token, box: nil, confidence: 0, candidates: [],
                    capturedAt: capturedAt, completedAt: completedAt, latency: completedAt - now,
                    analysesPerSecond: nil,
                    imageSize: size, profile: profile, rotationAngle: angle,
                    pixelFormat: CVPixelBufferGetPixelFormatType(pixels),
                    candidateCount: 0, otherObjects: "", error: error.localizedDescription, captureTelemetry: telemetry))
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if enabled { droppedFrames += 1 }
    }

    // Measure completed analyses on the inference queue, independently of UI
    // delivery: a busy MainActor must not turn queued callbacks into fake FPS.
    private func recordCompletion(at time: TimeInterval) -> Double? {
        defer { previousCompletion = time }
        guard let previousCompletion else { return nil }
        let interval = time - previousCompletion
        guard interval > 0, interval <= 1, interval.isFinite else {
            smoothedAnalysisInterval = nil
            return nil
        }
        let smoothed = smoothedAnalysisInterval.map { $0 * 0.8 + interval * 0.2 } ?? interval
        smoothedAnalysisInterval = smoothed
        return 1 / smoothed
    }

    /// Save only when the user requests a diagnostic, using the exact last analyzed
    /// buffer and its matching results. This image never becomes a motor target.
    func captureDiagnosticFrame(completion: @escaping (Result<BallDiagnosticSnapshot, Error>) -> Void) {
        queue.async {
            guard self.enabled, let pixels = self.lastPixels, let frame = self.lastFrame,
                  frame.generation == self.generation else {
                completion(.failure(NSError(domain: "PitchLens.Snapshot", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Attends une analyse caméra puis réessaie"])))
                return
            }
            let objects = self.lastObjects
            self.snapshotQueue.async {
            do {
                let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true)
                    .appendingPathComponent("DetectionDiagnostics", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let context = CIContext()
                let raw = CIImage(cvPixelBuffer: pixels)
                let orientation: CGImagePropertyOrientation
                switch frame.rotationAngle {
                case 90: orientation = .right
                case 180: orientation = .down
                case 270: orientation = .left
                default: orientation = .up
                }
                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
                guard let rawPNG = context.pngRepresentation(of: raw, format: .RGBA8,
                          colorSpace: colorSpace),
                      let uprightPNG = context.pngRepresentation(of: raw.oriented(orientation),
                          format: .RGBA8, colorSpace: colorSpace) else {
                    throw NSError(domain: "PitchLens.Snapshot", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Capture d’image impossible"])
                }
                let rawURL = directory.appendingPathComponent("capteur.png")
                let imageURL = directory.appendingPathComponent("image-analysee.png")
                let reportURL = directory.appendingPathComponent("detection.json")
                try rawPNG.write(to: rawURL, options: .atomic)
                try uprightPNG.write(to: imageURL, options: .atomic)
                let report: [String: Any] = ["profile": frame.profile.rawValue,
                    "rotation_degrees": frame.rotationAngle,
                    "capture_pixel_format": frame.pixelFormatDescription,
                    "captured_at_uptime": frame.capturedAt, "inference_seconds": frame.latency,
                    "completed_at_uptime": frame.completedAt,
                    "analyses_per_second": frame.analysesPerSecond.map { $0 as Any } ?? NSNull(),
                    "snapshot_age_seconds": ProcessInfo.processInfo.systemUptime - frame.capturedAt,
                    "ball_score_available": frame.box == nil ? NSNull() : frame.confidence as Any,
                    "export_nms_confidence": frame.profile.floor, "objects": objects,
                    "camera_telemetry": ["exposure_seconds": frame.captureTelemetry.exposureSeconds.map { $0 as Any } ?? NSNull(),
                        "iso": frame.captureTelemetry.iso.map { $0 as Any } ?? NSNull(),
                        "zoom": frame.captureTelemetry.zoom.map { $0 as Any } ?? NSNull(),
                        "sequence": frame.captureTelemetry.sequence, "dropped_frames": frame.captureTelemetry.droppedFrames,
                        "thermal_state": frame.captureTelemetry.thermalState,
                        "camera_position": frame.captureTelemetry.cameraPosition ?? "unknown",
                        "transfer_function": frame.captureTelemetry.transferFunction ?? "unknown",
                        "color_primaries": frame.captureTelemetry.colorPrimaries ?? "unknown",
                        "video_hdr_enabled": frame.captureTelemetry.videoHDREnabled.map { $0 as Any } ?? NSNull()],
                    "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?"]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: reportURL, options: .atomic)
                completion(.success(BallDiagnosticSnapshot(imageURL: imageURL, rawImageURL: rawURL,
                                                           reportURL: reportURL, frame: frame)))
            } catch { completion(.failure(error)) }
            }
        }
    }
}
