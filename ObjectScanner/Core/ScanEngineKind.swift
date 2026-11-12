import Foundation

/// Which capture technology produced — or is about to produce — a scan.
///
/// Both engines converge on the same `ScanRecord`, so everything downstream
/// (preview, export, library) is written once and stays engine-agnostic.
enum ScanEngineKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Guided photogrammetry: the user orbits a stationary object.
    case objectCapture
    /// Photogrammetry with the device fixed and the object rotating.
    case turntable
    /// Structured-light IR depth from the front-facing sensor.
    case trueDepth
    /// RoomPlan: LiDAR room capture producing walls, openings and furniture.
    case roomPlan

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .objectCapture: String(localized: "Fotogrametri")
        case .turntable: String(localized: "Döner Tabla")
        // A product name, identical in every language.
        case .trueDepth: "TrueDepth"
        case .roomPlan: String(localized: "Oda")
        }
    }

    var tagline: String {
        switch self {
        case .objectCapture: String(localized: "Arka kamera • sen dönersin • rehberli akış")
        case .turntable: String(localized: "Arka kamera • obje döner • telefon sabit")
        case .trueDepth: String(localized: "Ön sensör • desensiz yüzeylerde bile ölçüm")
        case .roomPlan: String(localized: "LiDAR • odayı dolaş • duvar, kapı, mobilya")
        }
    }

    var symbolName: String {
        switch self {
        case .objectCapture: "camera.viewfinder"
        case .turntable: "arrow.trianglehead.clockwise.rotate.90"
        case .trueDepth: "faceid"
        case .roomPlan: "house"
        }
    }

    /// Kept as a flag so a future mode can be listed before it works, without
    /// scattering checks through the UI.
    var isImplemented: Bool {
        switch self {
        case .objectCapture, .turntable, .trueDepth, .roomPlan: true
        }
    }

    /// What the engine writes. The photogrammetry and RoomPlan modes produce a
    /// Quick Look-renderable mesh; the depth engine currently produces a point
    /// cloud, which needs different handling everywhere downstream.
    var producesMesh: Bool {
        switch self {
        case .objectCapture, .turntable, .roomPlan: true
        case .trueDepth: false
        }
    }

    /// How dependable the mode is in practice — a separate question from whether
    /// it compiles and runs, which `isImplemented` already covers.
    ///
    /// Labelling a mode honestly is cheaper than letting someone spend forty
    /// shots discovering it for themselves.
    var maturity: Maturity {
        switch self {
        case .objectCapture, .roomPlan: .stable
        // Solving poses from images alone, with no world tracking to lean on, is
        // the weakest link in the app: it fails on featureless objects and on
        // backgrounds that move with the subject.
        case .turntable, .trueDepth: .beta
        }
    }

    enum Maturity: Sendable {
        case stable
        case beta

        /// Nil when there is nothing worth flagging.
        var badge: String? {
            switch self {
            case .stable: nil
            case .beta: "beta"
            }
        }
    }
}
