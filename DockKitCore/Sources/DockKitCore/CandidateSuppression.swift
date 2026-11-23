import Foundation

/// Greedy non-maximum suppression of ball candidates at a standard IoU threshold.
///
/// The Core ML pipeline already ends with Apple's NMS, but that stage does not read its
/// `iouThreshold` (0.7, set by the Ultralytics export) as a standard IoU threshold: it keeps
/// near-duplicate boxes, like a standard NMS at about 0.9. On the public test split of the
/// box2boxcam dataset, v1.0 through Core ML returned 184 false positives at confidence 0.25;
/// this pass at 0.7 after it brought them to 79 with the same balls found (see
/// docs/core_ml_parity_20261123.md in box2boxcam-football-vision).
///
/// IoU is unchanged by scaling x and y separately, so normalized boxes can be compared
/// directly whatever the image aspect ratio.
public enum CandidateSuppression {
    public static let defaultIoUThreshold = 0.7

    /// IoU (0...1) of two candidates given as centre, width and height; 0 for invalid boxes.
    public static func iou(_ a: BallCandidate, _ b: BallCandidate) -> Double {
        let values = [a.x, a.y, a.width, a.height, b.x, b.y, b.width, b.height]
        guard values.allSatisfy(\.isFinite), a.width > 0, a.height > 0, b.width > 0, b.height > 0 else {
            return 0
        }
        let overlapWidth = min(a.x + a.width / 2, b.x + b.width / 2) - max(a.x - a.width / 2, b.x - b.width / 2)
        let overlapHeight = min(a.y + a.height / 2, b.y + b.height / 2) - max(a.y - a.height / 2, b.y - b.height / 2)
        guard overlapWidth > 0, overlapHeight > 0 else { return 0 }
        let intersection = overlapWidth * overlapHeight
        // Clamped: rounding can put identical boxes a hair above 1.
        return min(1, intersection / (a.width * a.height + b.width * b.height - intersection))
    }

    /// Keeps a candidate unless a more confident kept one overlaps it with IoU above the
    /// threshold. Kept candidates stay in their original order; ties keep the earlier one.
    /// Candidates with a non-finite confidence are never used to suppress others and are
    /// kept, so this pass only ever removes duplicates.
    public static func suppress(_ candidates: [BallCandidate],
                                iouThreshold: Double = defaultIoUThreshold) -> (kept: [BallCandidate], dropped: Int) {
        guard candidates.count > 1, iouThreshold.isFinite else { return (candidates, 0) }
        let order = candidates.indices.sorted { lhs, rhs in
            let a = candidates[lhs].confidence, b = candidates[rhs].confidence
            switch (a.isFinite, b.isFinite) {
            case (true, true): return a != b ? a > b : lhs < rhs
            case (true, false): return true
            case (false, true): return false
            case (false, false): return lhs < rhs
            }
        }
        var keptIndices: [Int] = []
        var removed = Set<Int>()
        for index in order {
            let candidate = candidates[index]
            let duplicate = candidate.confidence.isFinite && keptIndices.contains { kept in
                candidates[kept].confidence.isFinite && iou(candidates[kept], candidate) > iouThreshold
            }
            if duplicate { removed.insert(index) } else { keptIndices.append(index) }
        }
        let kept = candidates.indices.filter { !removed.contains($0) }.map { candidates[$0] }
        return (kept, removed.count)
    }
}
