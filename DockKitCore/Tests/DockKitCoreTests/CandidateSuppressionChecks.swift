import Foundation
import DockKitCore

private func ball(_ x: Double, _ y: Double, _ w: Double = 0.01, _ h: Double = 0.018,
                  _ confidence: Double) -> BallCandidate {
    BallCandidate(x: x, y: y, width: w, height: h, confidence: confidence)
}

private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

func checkCandidateSuppressionIoU() throws {
    let a = ball(0.5, 0.5, 0.1, 0.1, 0.9)
    try expectEqual(CandidateSuppression.iou(a, a), 1)
    // Shifted by half a width: overlap 0.05 x 0.1, union 0.015.
    try expectTrue(close(CandidateSuppression.iou(a, ball(0.55, 0.5, 0.1, 0.1, 0.5)), 1.0 / 3))
    try expectEqual(CandidateSuppression.iou(a, ball(0.8, 0.5, 0.1, 0.1, 0.5)), 0)
    // Touching edges do not overlap; invalid boxes give 0.
    try expectTrue(CandidateSuppression.iou(a, ball(0.6, 0.5, 0.1, 0.1, 0.5)) < 1e-9)
    try expectEqual(CandidateSuppression.iou(a, ball(.nan, 0.5, 0.1, 0.1, 0.5)), 0)
    try expectEqual(CandidateSuppression.iou(a, ball(0.5, 0.5, 0, 0.1, 0.5)), 0)
    // Same IoU after stretching x, as between normalized and pixel coordinates.
    let b = ball(0.53, 0.5, 0.1, 0.1, 0.5)
    let stretched = { (c: BallCandidate) in
        BallCandidate(x: c.x * 1.78, y: c.y, width: c.width * 1.78, height: c.height, confidence: c.confidence)
    }
    try expectTrue(close(CandidateSuppression.iou(a, b), CandidateSuppression.iou(stretched(a), stretched(b))))
}

func checkCandidateSuppressionDropsNearDuplicates() throws {
    // A near-duplicate of the ball (IoU about 0.82), a separate candidate and a weaker
    // partial overlap (IoU about 0.33) that a 0.7 threshold keeps.
    let main = ball(0.40, 0.60, 0.01, 0.018, 0.80)
    let duplicate = ball(0.4005, 0.6005, 0.01, 0.018, 0.55)
    let other = ball(0.70, 0.30, 0.012, 0.02, 0.30)
    let partial = ball(0.405, 0.60, 0.01, 0.018, 0.20)
    try expectTrue(CandidateSuppression.iou(main, duplicate) > 0.7)
    let result = CandidateSuppression.suppress([duplicate, other, main, partial])
    try expectEqual(result.dropped, 1)
    // Original order is kept for the survivors.
    try expectEqual(result.kept.map(\.confidence), [0.30, 0.80, 0.20])

    // A chain: B overlaps A (IoU 0.82) and C (0.82), but A and C overlap only at 0.67.
    // B is removed by A, so it cannot remove C: greedy NMS keeps A and C.
    let a = ball(0.50, 0.5, 0.1, 0.1, 0.9)
    let b2 = ball(0.51, 0.5, 0.1, 0.1, 0.8)
    let c = ball(0.52, 0.5, 0.1, 0.1, 0.7)
    try expectTrue(CandidateSuppression.iou(a, b2) > 0.7)
    try expectTrue(CandidateSuppression.iou(b2, c) > 0.7)
    try expectTrue(CandidateSuppression.iou(a, c) < 0.7)
    let chain = CandidateSuppression.suppress([c, b2, a])
    try expectEqual(chain.kept.map(\.confidence), [0.7, 0.9])
    try expectEqual(chain.dropped, 1)
}

func checkCandidateSuppressionEdgeCases() throws {
    try expectEqual(CandidateSuppression.suppress([]).dropped, 0)
    let single = ball(0.5, 0.5, 0.01, 0.01, 0.4)
    try expectEqual(CandidateSuppression.suppress([single]).kept.count, 1)
    // Equal confidences: the earlier candidate wins.
    let first = ball(0.5, 0.5, 0.1, 0.1, 0.6)
    let second = ball(0.501, 0.5, 0.1, 0.1, 0.6)
    let tie = CandidateSuppression.suppress([first, second])
    try expectEqual(tie.kept.count, 1)
    try expectEqual(tie.kept[0].x, 0.5)
    // A non-finite confidence never suppresses and is never suppressed.
    let broken = ball(0.5, 0.5, 0.1, 0.1, .nan)
    try expectEqual(CandidateSuppression.suppress([broken, first]).kept.count, 2)
    // Threshold 1 keeps everything but exact copies are still at IoU 1, not above it.
    try expectEqual(CandidateSuppression.suppress([first, first], iouThreshold: 1).dropped, 0)
    try expectEqual(CandidateSuppression.suppress([first, first]).dropped, 1)
}
