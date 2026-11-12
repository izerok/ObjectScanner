import Foundation

/// A finished scan, as persisted in the library.
///
/// Deliberately stores a *relative* file name rather than an absolute URL: the
/// app container path changes between installs, so absolute URLs go stale and
/// every model in the library silently 404s. `ScanStorage` resolves the real URL.
struct ScanRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    let engine: ScanEngineKind

    /// File name inside the scan's own directory, e.g. `model.usdz`.
    let modelFileName: String

    /// True when the geometry carries real-world dimensions. Photogrammetry gets
    /// this from LiDAR; a pure-photo reconstruction would not — but a later
    /// calibration (cube / caliper) can make it true after the fact.
    var isMetricallyScaled: Bool

    /// How many stills fed the reconstruction (nil for depth-based engines).
    let imageCount: Int?

    /// Points in the cloud (nil for photogrammetry).
    var pointCount: Int?

    /// Physical bounding box in metres, when the engine knows it. The fastest way
    /// to sanity-check metric scale — compare it against a ruler.
    var dimensionsMillimetres: [Int]?

    /// Reconstruction detail the model was built at. Photogrammetry only.
    let detail: ReconstructionDetail?

    /// One-line description of what the model contains, when the engine can say
    /// something more useful than a file size — RoomPlan knows it produced four
    /// walls and seven pieces of furniture, photogrammetry knows nothing of the
    /// sort. Optional, so records written before this existed still decode.
    var summary: String?

    /// The scale audit trail for turntable scans: which reference (calibration
    /// cube / caliper) anchored the scale, what the independent depth scale
    /// says, and the factor exports must bake in. Optional, so records written
    /// before this existed still decode.
    var scaleCalibration: ScaleCalibration?

    /// The framing-time designations for turntable scans (v0.7): which part
    /// of the frame the user marked as the subject and which as the 10 mm
    /// calibration object. Persisted so a library re-analysis can repeat
    /// the guided search instead of falling back to blind cube-hunting.
    /// Optional, so records written before this existed still decode.
    var designation: ScanDesignation?

    /// True when the file is a mesh Quick Look can render. Point clouds are not,
    /// so the library has to fall back to a stats view instead of a preview.
    var isPreviewable: Bool {
        modelFileName.hasSuffix(".usdz")
    }

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        engine: ScanEngineKind,
        modelFileName: String = "model.usdz",
        isMetricallyScaled: Bool,
        imageCount: Int? = nil,
        pointCount: Int? = nil,
        dimensionsMillimetres: [Int]? = nil,
        detail: ReconstructionDetail? = nil,
        summary: String? = nil,
        scaleCalibration: ScaleCalibration? = nil,
        designation: ScanDesignation? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.engine = engine
        self.modelFileName = modelFileName
        self.isMetricallyScaled = isMetricallyScaled
        self.imageCount = imageCount
        self.pointCount = pointCount
        self.dimensionsMillimetres = dimensionsMillimetres
        self.detail = detail
        self.summary = summary
        self.scaleCalibration = scaleCalibration
        self.designation = designation
    }
}

/// The user's framing-time designations, in capture-normalized coordinates
/// (0…1, origin top-left — the same space the mask rectangles live in).
struct ScanDesignation: Codable, Hashable, Sendable {
    /// [x, y, width, height] of the subject rectangle.
    var subjectRect: [Double]
    /// [x, y, width, height] of the calibration-object rectangle, when the
    /// user designated one. Nil means the scan ran subject-only.
    var calibratorRect: [Double]?
}

/// Mesh density the model was reconstructed at.
///
/// Only one case, and that is a platform limit rather than a design choice:
/// `PhotogrammetrySession.Request.Detail` declares `medium`, `full` and `raw`
/// **only on macOS**. The iOS SDK exposes `reduced` alone, so on-device
/// reconstruction cannot produce a high-poly mesh at any setting.
///
/// The path to full detail is to move the captured stills to a Mac — hence
/// `SourceImageBundle`, and hence keeping the images after reconstruction.
enum ReconstructionDetail: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The only level iOS offers for on-device photogrammetry.
    case reduced

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .reduced: String(localized: "Cihaz üstü (reduced)")
        }
    }

    var explanation: String {
        switch self {
        case .reduced:
            String(localized: "iOS cihaz üstü fotogrametride tek desteklenen seviye. Daha yüksek poligon için kaynak görüntüleri Mac'e aktarın.")
        }
    }
}
