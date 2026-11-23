import Foundation
import Darwin

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T,
                                file: StaticString = #filePath, line: UInt = #line) throws {
    guard actual == expected else {
        throw CheckFailure(description: "\(file):\(line): expected \(expected), received \(actual)")
    }
}

func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    guard value else { throw CheckFailure(description: "\(file):\(line): expected true") }
}

func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    guard !value else { throw CheckFailure(description: "\(file):\(line): expected false") }
}

@main
struct CheckRunner {
    @MainActor
    static func main() async {
        let tests = MotorControllerTests()
        let checks: [(String, () async throws -> Void)] = [
            ("orientation v2 bounded correction and backward-running veto", checkOrientationRefinementV2),
            ("orientation v2 coherent motion rejects jitter and reversals", checkOrientationMotionEvidenceV2),
            ("manual zoom preserves field coordinates and rejects crossed calibration", checkManualZoomFieldTransform),
            ("pitch calibration from centre spot and goals, on-pitch test, markings", checkPitchCalibrationGeometry),
            ("pitch calibration behind a goal from both goals", checkBehindGoalCalibration),
            ("player pan leash around the last ball direction", checkPlayerPanLeash),
            ("goal taps choose the behind-goal or touchline model", checkGoalModelChoice),
            ("people cut off next to the camera", checkCutOffNearCamera),
            ("camera pose rays and projection round trip", checkCameraPoseProjection),
            ("hybrid continuity has priority over detector score", checkHybridContinuity),
            ("hybrid association rejects teleports and duplicate frames", checkHybridOutlierAndDuplicates),
            ("hybrid camera registration removes false ball motion", checkHybridCameraCompensation),
            ("hybrid gaps, stale frames and motor freshness", checkHybridLossAndFreshness),
            ("hybrid remembers the side of a probable exit", checkHybridExitSide),
            ("hybrid field prior allows airborne balls", checkHybridFieldAndAirborne),
            ("hybrid field rejects drift and nearby outside proposals throughout tracking", checkHybridFieldDuringTracking),
            ("hybrid field constrains prediction in compensated coordinates", checkHybridFieldPredictionAndCameraShift),
            ("hybrid offscreen people have zero influence", checkHybridOffscreenPeople),
            ("hybrid shared reference is rate limited", checkHybridReferenceRate),
            ("hybrid rejects invalid body geometry", checkHybridBodyGeometryInvalid),
            ("hybrid orientation confirmation is timed at sparse pose rates", checkHybridSparseOrientationConfirmation),
            ("hybrid confidence weighting off unchanged, low score never acquires, high score acquires", checkHybridConfidenceWeightingOffAndAcquisition),
            ("hybrid confidence weighting keeps an active ball through a score dip, releases on a sustained drop", checkHybridConfidenceWeightingRetain),
            ("hybrid ball floor: 0.20 accepted at 0.10, ignored at 0.25", checkHybridMinimumBallConfidence),
            ("hybrid stay with group off unchanged, lead scaled at 100/55/40 % of the peak", checkHybridStayWithGroupOffAndLeadScaling),
            ("hybrid stay with group returns to the peak position, leaves on recovery or 6 s, weak continuation refused", checkHybridStayWithGroupReturnAndWeakContinuation),
            ("pulse: disable tracking, move, zero", tests.testPulseDisablesTrackingThenMovesAndStops),
            ("trigger re-enabling system tracking is taken back", tests.testAccessoryReenablingSystemTrackingIsTakenBack),
            ("yield to accessory then take back", tests.testYieldToAccessoryThenPrepareTakesBack),
            ("keep-alive zero only when ready and idle", tests.testKeepAliveSendsZeroOnlyWhenReadyAndIdle),
            ("stop during in-flight write", tests.testStopWaitsForInflightWriteThenSendsZeroWithoutAnotherMovement),
            ("stop interrupts pulse delay", tests.testStopInterruptsOneSecondPulseDelay),
            ("disconnect invalidates motion", tests.testCloseDuringInflightWriteRejectsFutureCommands),
            ("system/manual handover", tests.testSystemTrackingStopsManualMotionBeforeEnablingAndStopTakesControlBack),
            ("failed move attempts zero", tests.testFailedMotionStillAttemptsZeroAndRequiresRecovery),
            ("failed stop stays failed", tests.testFailedStopDoesNotReportReady),
            ("invalid and overlapping pulses", tests.testInvalidAndOverlappingPulsesNeverReachTransport),
            ("following coalesces and honors stop", tests.testFollowingCoalescesAndStopInvalidatesQueuedMotion),
            ("following expires after late acknowledgement", tests.testFollowingLeaseStopsAfterLateAcknowledgement),
            ("following refresh survives old acknowledgement, expires, honors stop", tests.testFollowingRefreshSurvivesOldAcknowledgementButStillExpires),
            ("following error stops motion", tests.testFollowingErrorStopsAndRejectsFurtherVelocity),
            ("ball dead zone, acceleration, confidence, freshness", checkBallPolicy),
            ("ball trail capture timing, smoothed velocity, bounds, duplicates", checkBallMotionMeasurement),
            ("ball trail loss, invalid frames, gaps, jumps, clock resets", checkBallMotionInvalidation),
            ("trajectory confirmation, multi-candidate association, teleport rejection", checkTrajectoryAssociation),
            ("trajectory capture-age prediction and bounded lead", checkTrajectoryPrediction),
            ("trajectory compensates camera shift across a missing frame", checkCameraShiftAcrossMissingFrame),
            ("trajectory loss, reacquisition, invalid frames and zero motor target", checkTrajectoryLossAndMotorTarget),
            ("trajectory jitter reduction and real direction reversal", checkTrajectorySmoothingAndTurn),
            ("trajectory confirmation survives short dropped frames and estimates initial motion", checkSparseTrajectoryConfirmation),
            ("raw detection visibility is independent from confirmed motor target and expires", checkRawDetectionSeparatedFromMotorTarget),
            ("manual ball selection rejects spare ball, survives loss, resets to auto", checkManualBallSelection),
            ("frame rotation, aspect fit and touch mapping", checkFrameGeometry),
            ("search window size, border clamping and Vision box mapping", checkSearchWindowGeometry),
            ("search window needs a fresh track, full frame every 5th and after 2 misses", checkSearchWindowPolicy),
            ("static filter dwell threshold, width radius, gap tolerance, forgetting", checkStaticFilterDwellAndGaps),
            ("static filter keeps moving balls, compensates camera pan, bounded memory", checkStaticFilterMotionAndMemory),
            ("angle limits: soft zone, zero outward at limit, inward free, no overshoot", checkAngleLimits),
            ("auto zoom: 0.8 s wait, slow tighten, hold brief loss, fast widen, invalid input", checkAutoZoomRatesAndWaits),
            ("auto zoom: unseen people ignored, visible group, off-centre action, no zoom feedback loop", checkAutoZoomPlayersAndFeedback),
            ("highlights: sustained fast ball, reacquired after long loss, 8 s rate limit", checkHighlightDetector),
            ("match log beyond 15 seconds, video timestamps, all balls and finalization", checkMatchLogTimeline),
            ("match log bounded backpressure and concurrent writes", checkMatchLogBackpressure),
            ("match log encoding failure and existing recording protection", checkMatchLogFailure),
            ("latency summary: nearest-rank percentiles, mean and rate", checkLatencySummaryPercentiles),
            ("latency summary drops non-finite and negative samples", checkLatencySummaryRejectsInvalidSamples),
            ("model benchmark report: JSON round trip and markdown table", checkModelBenchmarkReportRoundTrip)
        ]
        var failures = 0
        for (name, check) in checks {
            do { try await check(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(checks.count - failures)/\(checks.count) app core checks passed")
        if failures > 0 { exit(1) }
    }
}
