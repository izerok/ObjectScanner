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
        cubeRealHeightMillimetres: Double
    ) -> Outcome? {
        guard let geometry = MeshGeometry.load(from: url),
              let segmentation = ScaleCalibrator.analyze(
                positions: geometry.positions,
                indices: geometry.indices
              )
        else { return nil }

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
}
