import Foundation

/// How a turntable scan's real-world scale was established.
enum ScaleCalibrationMethod: String, Codable, Sendable {
    /// A calibration cube of known height was reconstructed in the same scan
    /// and measured in the mesh.
    case visualCube
    /// The user measured one real dimension of the object with a caliper and
    /// the whole model was scaled uniformly to match.
    case caliper

    var displayName: String {
        switch self {
        case .visualCube: String(localized: "Kalibrasyon küpü (görsel)")
        case .caliper: String(localized: "Kumpas (tek boyut)")
        }
    }
}

/// The scale audit trail for one scan: which references were found, what each
/// of them says the object's size is, and which factor was finally applied.
///
/// Persisted on `ScanRecord` so the library can show the reconciliation long
/// after the scan, and re-run it when the user corrects a caliper value.
struct ScaleCalibration: Codable, Hashable, Sendable {
    var method: ScaleCalibrationMethod

    /// Millimetres represented by one model unit under the applied factor.
    var millimetresPerUnit: Double

    /// The object's bounding box in raw model units, longest axis last-free —
    /// stored so a later caliper value can be turned into a factor without
    /// re-reading the mesh.
    var objectDimensionsUnits: [Double]

    /// Object dimensions as the depth (sensor) scale reads them, in mm.
    /// Nil when the reconstruction carried no depth.
    var depthDimensionsMillimetres: [Double]?

    /// Object dimensions as the calibration-cube scale reads them, in mm.
    var visualDimensionsMillimetres: [Double]?

    /// Fitted height of the calibration cube in model units.
    var cubeHeightUnits: Double?

    /// The cube's real height as measured with a caliper, in mm.
    var cubeRealHeightMillimetres: Double?

    /// |visual − depth| / depth × 100, when both scales exist. The two routes
    /// are independent, so a small number is real evidence the scale is right.
    var discrepancyPercent: Double?

    /// For the caliper method: the real length the user measured, in mm.
    var caliperMeasuredMillimetres: Double?
}
