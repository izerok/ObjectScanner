import Foundation

/// Runs the scale audit on a finished turntable reconstruction: find the
/// calibration cube in the mesh, derive the visual scale from its measured
/// height, and reconcile it against the depth (sensor) scale when present.
enum TurntableScaleAnalyzer {

    struct Outcome: Sendable {
        /// The audit trail to persist. Nil when no cube was found — a
        /// depth-only scan needs no trail, its record flags already say
        /// the scale is real.
        var calibration: ScaleCalibration?
        /// The object's bounding box in millimetres under the applied
        /// factor (visual first, depth second). Nil when neither exists.
        var objectDimensionsMillimetres: [Int]?
        /// Object bounding box in raw model units — the library needs it
        /// to apply a later caliper value without re-reading the mesh.
        var objectDimensionsUnits: [Double]
    }

    static func analyze(
        modelAt url: URL,
        isMetricallyScaled: Bool,
        cubeRealHeightMillimetres: Double,
        designatedCalibrator: Bool = false
    ) -> Outcome? {
        guard let geometry = MeshGeometry.load(from: url) else { return nil }

        // Guided path (v0.7): the user designated the calibration object at
        // framing time, and a metric mesh gives the search a prior — the
        // expected height in model units — so it verifies a candidate at
        // the designated scale instead of hunting any cube-shaped thing.
        // A located-but-eroded candidate yields no visual scale (the depth
        // factor stays applied) but is recorded, so the result can say what
        // happened instead of pretending the object was never there.
        // Without the depth prior there is no expectation to verify
        // against, and the legacy shape-based search below stays in charge.
        if designatedCalibrator, isMetricallyScaled,
           let guided = GuidedCalibrator.analyze(
            positions: geometry.positions,
            indices: geometry.indices,
            expectedHeightUnits: Float(cubeRealHeightMillimetres / 1000.0)
           ) {
            return guidedOutcome(guided, cubeRealHeightMillimetres: cubeRealHeightMillimetres)
        }

        guard let segmentation = ScaleCalibrator.analyze(
            positions: geometry.positions,
            indices: geometry.indices
        ) else { return nil }

        let dimsUnits = [
            Double(segmentation.objectDimensionsUnits.x),
            Double(segmentation.objectDimensionsUnits.y),
            Double(segmentation.objectDimensionsUnits.z),
        ]
        // Photogrammetry with depth speaks metres; without depth the unit
        // is arbitrary and only the cube (or a caliper) can anchor it.
        let depthFactor: Double? = isMetricallyScaled ? 1000.0 : nil
        let visualFactor: Double? = segmentation.cubeHeightUnits.map {
            cubeRealHeightMillimetres / Double($0)
        }

        let depthDims = depthFactor.map { factor in dimsUnits.map { $0 * factor } }
        let visualDims = visualFactor.map { factor in dimsUnits.map { $0 * factor } }

        var calibration: ScaleCalibration?
        if let visualFactor, let cubeHeight = segmentation.cubeHeightUnits {
            calibration = ScaleCalibration(
                method: .visualCube,
                millimetresPerUnit: visualFactor,
                objectDimensionsUnits: dimsUnits,
                depthDimensionsMillimetres: depthDims,
                visualDimensionsMillimetres: visualDims,
                cubeHeightUnits: Double(cubeHeight),
                cubeRealHeightMillimetres: cubeRealHeightMillimetres,
                discrepancyPercent: depthFactor.map {
                    abs(visualFactor - $0) / $0 * 100
                },
                caliperMeasuredMillimetres: nil
            )
        }

        let applied = visualFactor ?? depthFactor
        return Outcome(
            calibration: calibration,
            objectDimensionsMillimetres: applied.map { factor in
                dimsUnits.map { Int(($0 * factor).rounded()) }
            },
            objectDimensionsUnits: dimsUnits
        )
    }

    /// Builds the audit outcome for the guided search. The depth factor is
    /// always present on this path (it was the prior), so even a missed
    /// designation leaves a metric record with the verdict attached.
    private static func guidedOutcome(
        _ guided: GuidedCalibrator.Result,
        cubeRealHeightMillimetres: Double
    ) -> Outcome {
        let dimsUnits = [
            Double(guided.objectDimensionsUnits.x),
            Double(guided.objectDimensionsUnits.y),
            Double(guided.objectDimensionsUnits.z),
        ]
        let depthFactor = 1000.0
        let depthDims = dimsUnits.map { $0 * depthFactor }

        func miss(heightUnits: Float?, outcome: DesignatedCalibratorOutcome) -> Outcome {
            let calibration = ScaleCalibration(
                method: .guidedCube,
                millimetresPerUnit: depthFactor,
                objectDimensionsUnits: dimsUnits,
                depthDimensionsMillimetres: depthDims,
                visualDimensionsMillimetres: nil,
                cubeHeightUnits: heightUnits.map { Double($0) },
                cubeRealHeightMillimetres: cubeRealHeightMillimetres,
                discrepancyPercent: nil,
                caliperMeasuredMillimetres: nil,
                designatedOutcome: outcome,
                locatedHeightMillimetres: heightUnits.map { Double($0) * depthFactor }
            )
            return Outcome(
                calibration: calibration,
                objectDimensionsMillimetres: depthDims.map { Int($0.rounded()) },
                objectDimensionsUnits: dimsUnits
            )
        }

        switch guided.verdict {
        case .found(let heightUnits):
            let visualFactor = cubeRealHeightMillimetres / Double(heightUnits)
            let visualDims = dimsUnits.map { $0 * visualFactor }
            let calibration = ScaleCalibration(
                method: .guidedCube,
                millimetresPerUnit: visualFactor,
                objectDimensionsUnits: dimsUnits,
                depthDimensionsMillimetres: depthDims,
                visualDimensionsMillimetres: visualDims,
                cubeHeightUnits: Double(heightUnits),
                cubeRealHeightMillimetres: cubeRealHeightMillimetres,
                discrepancyPercent: abs(visualFactor - depthFactor) / depthFactor * 100,
                caliperMeasuredMillimetres: nil,
                designatedOutcome: .found,
                locatedHeightMillimetres: Double(heightUnits) * depthFactor
            )
            return Outcome(
                calibration: calibration,
                objectDimensionsMillimetres: visualDims.map { Int($0.rounded()) },
                objectDimensionsUnits: dimsUnits
            )
        case .eroded(let heightUnits):
            return miss(heightUnits: heightUnits, outcome: .eroded)
        case .oversized(let heightUnits):
            return miss(heightUnits: heightUnits, outcome: .oversized)
        case .notFound:
            return miss(heightUnits: nil, outcome: .notFound)
        }
    }
}
