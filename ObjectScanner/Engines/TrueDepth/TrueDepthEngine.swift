import ARKit
import Foundation
import Observation
import simd
import os

/// Faz 2 engine: metric point cloud from the front structured-light sensor.
///
/// Uses `ARFaceTrackingConfiguration` with world tracking rather than a raw
/// `AVCaptureSession`, because that hands back depth *and* a synchronised 6DoF
/// pose from the same `ARFrame`. Doing it with AVFoundation would mean solving
/// pose separately — ICP or a turntable rig — for no benefit.
///
/// Worth knowing: with world tracking enabled the pose comes from the **back**
/// camera's visual-inertial odometry while the front sensor supplies depth. The
/// room behind you needs texture, not the object.
@MainActor
@Observable
final class TrueDepthEngine: ScanEngine {
    private static let logger = Logger(subsystem: "com.example.ObjectScanner", category: "truedepth")

    static let kind: ScanEngineKind = .trueDepth

    static var availability: EngineAvailability {
        guard ARFaceTrackingConfiguration.isSupported else {
            return .unsupportedDevice(reason: String(localized: "TrueDepth sensörü bulunamadı."))
        }
        guard ARFaceTrackingConfiguration.supportsWorldTracking else {
            return .unsupportedDevice(reason: String(localized: "Bu cihaz ön kamerayla dünya takibini desteklemiyor. Poz bilgisi olmadan tarama birleştirilemez."))
        }
        return .available
    }

    // MARK: - Observable state

    private(set) var phase: ScanPhase = .idle
    private(set) var snapshot = DepthFrameReceiver.Snapshot()
    private(set) var trackingWarning: String?

    /// Exposed so the capture screen can flip mirroring while pointed at a real
    /// object — the correct sign is far quicker to confirm than to derive.
    var processorOptions = DepthFrameProcessor.Options() {
        didSet { restartIfRunning() }
    }

    /// Half-width of the region locked around the aim point, in metres.
    /// 0.15 suits a mug or a controller; 0.30 a shoebox.
    var regionHalfExtent: Float = 0.15

    /// The live ARKit session, handed to the capture view for the camera feed.
    private(set) var session: ARSession?

    // MARK: - Private

    private let storage: ScanStorage
    private var receiver: DepthFrameReceiver?
    private var workspace: ScanWorkspace?

    /// Frames are unprojected here, never on the main actor.
    private let frameQueue = DispatchQueue(label: "com.example.ObjectScanner.depth", qos: .userInitiated)

    init(storage: ScanStorage) {
        self.storage = storage
    }

    // MARK: - ScanEngine

    func start() throws {
        guard case .available = Self.availability else {
            throw ScanEngineError.sessionUnavailable(Self.availability.blockedReason ?? String(localized: "Bilinmeyen sebep"))
        }

        phase = .preparing

        let workspace: ScanWorkspace
        do {
            workspace = try storage.makeWorkspace()
        } catch {
            phase = .failed(message: error.localizedDescription)
            throw ScanEngineError.sessionUnavailable(error.localizedDescription)
        }
        self.workspace = workspace

        let receiver = DepthFrameReceiver(
            processor: DepthFrameProcessor(options: processorOptions),
            voxelSize: DepthPointCloud.defaultVoxelSize,
            onSnapshot: { [weak self] snapshot in
                Task { @MainActor in self?.apply(snapshot) }
            },
            onTrackingChange: { [weak self] state in
                Task { @MainActor in self?.apply(trackingState: state) }
            }
        )
        self.receiver = receiver

        let session = ARSession()
        session.delegateQueue = frameQueue
        session.delegate = receiver
        self.session = session

        let configuration = ARFaceTrackingConfiguration()
        configuration.isWorldTrackingEnabled = true
        // Faces are irrelevant here; the configuration is only the vehicle for
        // front-camera depth. Tracking none avoids the mesh work entirely.
        configuration.maximumNumberOfTrackedFaces = 0

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        phase = .capturing(shots: 0, limit: 0)
        Self.logger.info("TrueDepth oturumu başladı")
    }

    func finish() async throws -> ScanRecord {
        guard let session, let receiver, let workspace else {
            throw ScanEngineError.sessionUnavailable(String(localized: "Aktif oturum yok."))
        }

        phase = .reconstructing(ReconstructionProgress(fraction: 0.2, stage: .pointCloudGeneration))
        session.pause()

        // The receiver owns the cloud on the frame queue; this is the handoff.
        let cloud = frameQueue.sync { receiver.finalise() }

        guard !cloud.isEmpty else {
            phase = .failed(message: String(localized: "Hiç geçerli derinlik örneği toplanmadı. Objeye 20–100 cm mesafede kalın."))
            throw ScanEngineError.reconstructionFailed(String(localized: "Nokta bulutu boş."))
        }

        phase = .reconstructing(ReconstructionProgress(fraction: 0.7, stage: .optimization))

        let points = cloud.points
        let outputURL = workspace.root.appending(path: "cloud.ply", directoryHint: .notDirectory)

        do {
            try await Task.detached(priority: .userInitiated) {
                try PointCloudFile.write(points: points, to: outputURL)
            }.value
        } catch {
            phase = .failed(message: error.localizedDescription)
            throw ScanEngineError.reconstructionFailed(error.localizedDescription)
        }

        let dimensions = cloud.dimensions.map { size in
            [Int((size.x * 1000).rounded()), Int((size.y * 1000).rounded()), Int((size.z * 1000).rounded())]
        }

        let record = ScanRecord(
            id: workspace.id,
            name: Self.defaultName(for: Date()),
            engine: Self.kind,
            modelFileName: "cloud.ply",
            isMetricallyScaled: true,
            pointCount: points.count,
            dimensionsMillimetres: dimensions
        )
        storage.commit(record, workspace: workspace)

        teardown()
        phase = .done(record)
        return record
    }

    func cancel() {
        session?.pause()
        teardown()
        if let workspace {
            storage.discard(workspace)
            self.workspace = nil
        }
        phase = .cancelled
    }

    // MARK: - Region of interest

    /// Confines accumulation to a box around whatever the user is aiming at.
    ///
    /// The sensor's angular resolution is fixed, so this adds no samples. What it
    /// does is stop the table and the far wall from dominating the cloud, the live
    /// view and the reported dimensions — which is the actual fix for "the object
    /// is small in the frame".
    func lockRegion() {
        guard let aim = snapshot.aimPoint, let receiver else { return }
        let region = DepthFrameProcessor.Region(center: aim, halfExtent: regionHalfExtent)
        frameQueue.async { receiver.setRegion(region) }
    }

    func clearRegion() {
        guard let receiver else { return }
        frameQueue.async { receiver.setRegion(nil) }
    }

    /// Distance coaching.
    ///
    /// Sample density falls with the square of distance, so scanning at 25 cm rather
    /// than 50 cm roughly quadruples the samples landing on the object. That is the
    /// cheapest quality lever available and costs nothing but standing closer.
    var distanceAdvice: (text: String, isGood: Bool)? {
        guard let depth = snapshot.medianDepth else { return nil }
        switch depth {
        case ..<0.22: return (String(localized: "Çok yakın — sensör ölçemiyor"), false)
        case 0.22..<0.35: return (String(localized: "İdeal mesafe"), true)
        case 0.35..<0.55: return (String(localized: "Biraz yaklaşın — detay belirgin artar"), false)
        default: return (String(localized: "Çok uzak — objeye yaklaşın"), false)
        }
    }

    // MARK: - Private

    private func apply(_ snapshot: DepthFrameReceiver.Snapshot) {
        self.snapshot = snapshot
        if case .capturing = phase {
            phase = .capturing(shots: snapshot.pointCount, limit: 0)
        }
    }

    private func apply(trackingState: ARCamera.TrackingState) {
        switch trackingState {
        case .normal:
            trackingWarning = nil
        case .notAvailable:
            trackingWarning = String(localized: "Konum takibi yok — cihazı hareket ettirin")
        case .limited(let reason):
            switch reason {
            case .initializing:
                trackingWarning = String(localized: "Takip başlatılıyor…")
            case .relocalizing:
                trackingWarning = String(localized: "Konum yeniden bulunuyor — bu sırada veri toplanmıyor")
            case .excessiveMotion:
                trackingWarning = String(localized: "Çok hızlı hareket — yavaşlayın")
            case .insufficientFeatures:
                // Worth naming the cause: people point the back camera at a blank
                // wall without realising that is where the pose comes from.
                trackingWarning = String(localized: "Arka kameranın gördüğü ortamda doku yok — poz buradan geliyor, dokulu bir yöne dönün")
            @unknown default:
                trackingWarning = String(localized: "Takip zayıf")
            }
        }
    }

    /// Mirroring changes how every sample is unprojected, so the cloud collected
    /// under the old setting cannot be merged with the new one.
    private func restartIfRunning() {
        guard case .capturing = phase else { return }
        Self.logger.info("İşleme ayarı değişti, oturum sıfırlanıyor")
        session?.pause()
        if let workspace { storage.discard(workspace) }
        workspace = nil
        session = nil
        receiver = nil
        snapshot = DepthFrameReceiver.Snapshot()
        try? start()
    }

    private func teardown() {
        session?.delegate = nil
        session = nil
        receiver = nil
        trackingWarning = nil
    }

    private static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.dateFormat = "d MMM HH:mm"
        return "Derinlik \(formatter.string(from: date))"
    }
}
