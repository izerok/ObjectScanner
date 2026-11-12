import ARKit
import AVFoundation
import RealityKit
import RoomPlan
// Cross-import overlay: `ObjectCaptureSession` needs both modules in scope.
import SwiftUI

/// Every capability is queried from the framework at runtime.
///
/// The tempting alternative — matching `utsname.machine` against a list of
/// model identifiers — breaks on every new device and on the simulator. Apple
/// exposes real predicates for all of this; use them.
///
/// `@MainActor` because `ObjectCaptureSession.isSupported` is main-actor isolated.
@MainActor
enum DeviceCapabilities {

    /// Guided Object Capture. Needs a LiDAR-class device; RealityKit decides.
    static var supportsObjectCapture: Bool {
        ObjectCaptureSession.isSupported
    }

    /// On-device photogrammetry. Separate from capture support — a device can
    /// in principle capture but not reconstruct, so check both.
    static var supportsPhotogrammetry: Bool {
        PhotogrammetrySession.isSupported
    }

    /// Front structured-light depth sensor. The Faz 2 engine's hard requirement.
    static var hasTrueDepthCamera: Bool {
        AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) != nil
    }

    /// Rear LiDAR scene mesh — useful later for hybrid alignment.
    static var supportsSceneReconstruction: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    /// RoomPlan room capture. Also LiDAR-gated, but asked separately: it is a
    /// different framework with its own support predicate.
    static var supportsRoomCapture: Bool {
        RoomCaptureSession.isSupported
    }

    static var cameraAuthorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func requestCameraAccess() async -> Bool {
        if cameraAuthorization == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .video)
    }

    // MARK: - Rear camera inventory

    /// Every rear capture device the system will hand out.
    ///
    /// This is the honest way to spot a damaged camera module: a dead lens simply
    /// does not enumerate, and the virtual combination devices that depend on it
    /// (dual, triple, LiDAR-depth) disappear along with it. Comparing this list
    /// between two units of the same model is conclusive in a way that no single
    /// support flag is.
    ///
    /// An earlier version of this file tried `AVCaptureDevice.extrinsicMatrix(from:to:)`
    /// between the wide camera and the LiDAR device as a calibration probe. That
    /// was invalid: the header states extrinsics exist only for *physical* cameras
    /// and that "virtual device cameras return nil" — and `.builtInLiDARDepthCamera`
    /// is itself a virtual YUV+LiDAR pair, so the probe returned nil on healthy
    /// hardware too.
    static var rearCaptureDevices: [(label: String, isVirtual: Bool)] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            .builtInLiDARDepthCamera,
            .builtInDualCamera,
            .builtInDualWideCamera,
            .builtInTripleCamera,
        ]

        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .back
        )

        return session.devices.map { device in
            (label: device.localizedName, isVirtual: !device.constituentDevices.isEmpty)
        }
    }

    /// Physical (non-virtual) rear lenses the system reports.
    static var physicalRearLensCount: Int {
        rearCaptureDevices.filter { !$0.isVirtual }.count
    }

    /// Only genuinely blocking conditions produce a warning. Anything softer is
    /// left to the diagnostics list — a scary banner that fires on healthy
    /// hardware is worse than no banner at all.
    static var blockingHardwareWarning: String? {
        if AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) == nil {
            return String(localized: "Arka ana kamera bulunamadı. Tarama yapılamaz.")
        }
        if !supportsObjectCapture {
            return String(localized: "Object Capture bu cihazda desteklenmiyor. LiDAR'lı bir iPhone/iPad Pro gerekiyor.")
        }
        if !supportsPhotogrammetry {
            return String(localized: "Bu cihaz cihaz-üstü fotogrametriyi desteklemiyor.")
        }
        return nil
    }

    /// Whether the front and rear cameras are factory-calibrated against each other.
    ///
    /// This decides whether a rear-then-front hybrid can be aligned by calibration
    /// or has to be aligned by content (ICP). The header says extrinsics exist only
    /// "for physical cameras for which factory calibrations exist", and the two
    /// camera clusters are separate modules — so this is expected to be nil. It is
    /// measured rather than assumed because the answer changes the whole design.
    static var hasFrontToRearCalibration: Bool {
        guard let rear = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let front = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
        else { return false }
        return AVCaptureDevice.extrinsicMatrix(from: rear, to: front) != nil
    }

    /// Human-readable summary for the diagnostics row in mode selection.
    static var summary: [(label: String, value: Bool)] {
        [
            ("Object Capture", supportsObjectCapture),
            (String(localized: "Fotogrametri (cihaz üstü)"), supportsPhotogrammetry),
            (String(localized: "Oda taraması (RoomPlan)"), supportsRoomCapture),
            (String(localized: "LiDAR sahne mesh'i"), supportsSceneReconstruction),
            (String(localized: "LiDAR derinlik cihazı"), AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) != nil),
            (String(localized: "Ultra geniş kamera"), AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil),
            (String(localized: "Telefoto kamera"), AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) != nil),
            (String(localized: "TrueDepth sensörü"), hasTrueDepthCamera),
            (String(localized: "Ön↔arka kalibrasyon (hibrit için)"), hasFrontToRearCalibration),
        ]
    }
}
