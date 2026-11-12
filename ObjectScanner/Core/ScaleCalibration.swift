import Foundation

/// How a turntable scan's real-world scale was established.
enum ScaleCalibrationMethod: String, Codable, Sendable {
    /// A calibration cube of known height was reconstructed in the same scan
    /// and measured in the mesh.
    case visualCube
    /// The user designated the calibration object at framing time (v0.7):
    /// a 10 mm reference framed with the green rectangle. The audit searched
    /// for it where it was designated, guided by the depth-scale prior —
    /// see `designatedOutcome` for what it found there.
    case guidedCube
    /// The user measured one real dimension of the object with a caliper and
    /// the whole model was scaled uniformly to match.
    case caliper

    var displayName: String {
        switch self {
        case .visualCube: String(localized: "Kalibrasyon küpü (görsel)")
        case .guidedCube: String(localized: "Kalibrasyon nesnesi (belirlenen)")
        case .caliper: String(localized: "Kumpas (tek boyut)")
        }
    }
}

/// What the guided search found where the user designated the calibration
/// object. Persisted so the result screen and the library can say plainly
/// which reference the scale rests on — and so an eroded remnant is never
/// silently mistaken for a successful calibration.
enum DesignatedCalibratorOutcome: String, Codable, Sendable {
    /// Found at the expected size; the scale was derived from it.
    case found
    /// Located, but reconstructed far shorter than its real 10 mm — an
    /// eroded remnant. The scale fell back to depth; the remnant's faces
    /// are still removed on export.
    case eroded
    /// Located, but far taller than 10 mm — not the designated object.
    case oversized
    /// Nothing at the designated place matched.
    case notFound

    var displayName: String {
        switch self {
        case .found: String(localized: "Bulundu — ölçek ondan alındı")
        case .eroded: String(localized: "Aşınmış bulundu — ölçek derinlikten")
        case .oversized: String(localized: "Beklenenden büyük — ölçek derinlikten")
        case .notFound: String(localized: "Bulunamadı — ölçek derinlikten")
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

    /// For the guided method: what the search found at the designated
    /// place. Nil for scans that predate designation (and for the other
    /// methods). Optional so older records still decode.
    var designatedOutcome: DesignatedCalibratorOutcome? = nil

    /// For the guided method: the located candidate's fitted height in
    /// millimetres (under the depth scale), shown next to the real 10 mm
    /// so an erosion verdict carries its evidence. Nil when nothing was
    /// located.
    var locatedHeightMillimetres: Double? = nil
}
