import AVFoundation
import CoreMotion
import Foundation
import ModelIO
import Observation
import simd
import os

/// Pure-LiDAR turntable engine: the phone stays fixed, the object rotates,
/// and the model is fused entirely from LiDAR depth — photogrammetry never
/// runs. That trades surface detail (LiDAR noise is millimetre-scale) for
/// two things photos cannot give: true metric shape on textureless objects,
/// and a model that exists the moment capture ends.
///
/// Pipeline per pass: calibrate the turntable axis from the table plane in
/// the frame margins → for each shot, solve the single unknown (rotation
/// about the axis) against the previous shot → splat the frame into a TSDF
/// volume in turntable space. A new pass (phone moved to another height)
/// re-calibrates and yaw-registers its first frame against the fused model,
/// so passes stack into one volume.
@MainActor
@Observable
final class LidarTurntableEngine: ScanEngine {
    private static let logger = Logger(subsystem: "com.example.ObjectScanner", category: "lidar-turntable")

    static let kind: ScanEngineKind = .lidarTurntable

    static var availability: EngineAvailability {
        guard AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) != nil else {
            return .unsupportedDevice(reason: String(localized: "LiDAR derinlik kamerası bulunamadı."))
        }
        return .available
    }

    enum PassState: Equatable, Sendable {
        /// Aiming and framing the mask; the next primary action calibrates
        /// the axis and takes the pass's first frame.
        case framing
        /// The calibration revolution is being recorded (axis fitted,
        /// widths sampled for one full turn).
        case calibratingRev
        case capturing
        /// A pass is complete; the phone is being moved to a new height.
        /// Live pitch is shown so the move is *perceived*, not just asserted.
        case awaitingElevation
    }

    // MARK: - Observable state

    private(set) var phase: ScanPhase = .idle
    private(set) var passState: PassState = .framing
    private(set) var passNumber = 1
    private(set) var shotsThisPass = 0
    private(set) var totalShots = 0
    private(set) var fusedPointCount = 0
    private(set) var rejectedShots = 0
    private(set) var lastDeltaDegrees: Float?
    private(set) var lastHitRate: Float?
    /// Continuous tracking readouts (v0.4).
    private(set) var trackingQuality: LidarFusionCore.TrackingQuality = .good
    /// Last registration fit, shown in the UI so a failing pipeline is
    /// self-describing instead of silently dead (v0.4.1).
    private(set) var lastInliers: Float?
    private(set) var lastMeanMillimetres: Float?
    private(set) var passRotationDegrees: Float = 0
    private(set) var rotationSpeedDegPerSec: Float = 0
    private(set) var trackingPaused = false
    private(set) var statusMessage: String?
    private(set) var isProcessingShot = false
    var isAutoCapturing = false {
        didSet { restartAutoCapture() }
    }

    /// Live device pitch (degrees, 0 = camera level), plus the pitch of the
    /// last completed pass — the elevation-change readout.
    private(set) var currentPitchDegrees: Float?
    private(set) var previousPassPitchDegrees: Float?

    /// Health of the depth stream, watched continuously so a dead stream is
    /// visible in the UI instead of presenting as dead buttons (v0.3.1).
    enum DepthStreamState: Equatable, Sendable {
        case waiting
        case live
        case stalled
    }

    private(set) var depthStreamState: DepthStreamState = .waiting

    var isDepthLive: Bool { depthStreamState == .live }

    var pitchChangeDegrees: Float? {
        guard let currentPitchDegrees, let previousPassPitchDegrees else { return nil }
        return abs(currentPitchDegrees - previousPassPitchDegrees)
    }

    /// Normalised (capture-space) rectangle over the object, fed by the
    /// preview exactly as in the photogrammetry turntable flow.
    var objectMaskRect: CGRect?

    var session: AVCaptureSession? { stream?.session }

    var canFinish: Bool { totalShots >= 25 && fusedPointCount > 500 }

    // MARK: - Private

    private let storage: ScanStorage
    private var workspace: ScanWorkspace?
    private var stream: DepthStreamSession?
    private let core = LidarFusionCore()
    private let motion = CMMotionManager()
    private(set) var calibrationElapsed: Float = 0
    private var revTask: Task<Void, Never>?
    private var revStartedAt: CFTimeInterval = 0
    private var autoCaptureTask: Task<Void, Never>?
    private var streamMonitorTask: Task<Void, Never>?
    private var lastUsedTimestamp: CMTime = .invalid
    private var passPitchDegrees: Float?

    init(storage: ScanStorage) {
        self.storage = storage
        core.clock = { Float(CACurrentMediaTime()) }
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

        let stream = DepthStreamSession()
        do {
            try stream.configure()
        } catch {
            phase = .failed(message: error.localizedDescription)
            throw ScanEngineError.sessionUnavailable(error.localizedDescription)
        }
        self.stream = stream
        stream.start()

        startMotion()
        startStreamMonitor()
        phase = .framing
        Self.logger.info("LiDAR döner tabla oturumu başladı")
    }

    func finish() async throws -> ScanRecord {
        guard let workspace else {
            throw ScanEngineError.sessionUnavailable(String(localized: "Aktif oturum yok."))
        }
        guard canFinish else {
            throw ScanEngineError.reconstructionFailed(String(localized: "Yeterli kare yok — en az 25 kare gerekir."))
        }

        isAutoCapturing = false
        if let depth = freshDepth() {
            let mask = objectMaskRect ?? CGRect(x: 0.15, y: 0.2, width: 0.7, height: 0.6)
            let box = DepthFrameBox(depth)
            let core = self.core
            _ = await Task.detached(priority: .userInitiated) {
                let points = TurntableFusion.points(from: box.depth, maskRect: mask, insideMask: true, stride: 1)
                core.acceptFinalFrame(objectPoints: points)
            }.value
        }
        phase = .reconstructing(ReconstructionProgress(fraction: 0.3, stage: .pointCloudGeneration))
        stream?.stop()
        motion.stopDeviceMotionUpdates()

        let core = self.core
        let extracted = await Task.detached(priority: .userInitiated) {
            core.extractMeshAndPoints()
        }.value

        guard let extracted, !extracted.mesh.vertices.isEmpty, extracted.mesh.indices.count >= 3 else {
            let message = String(localized: "Model oluşturulamadı: yüzey çıkarılamadı. Daha fazla kareyle tekrar deneyin.")
            phase = .failed(message: message)
            throw ScanEngineError.reconstructionFailed(message)
        }

        phase = .reconstructing(ReconstructionProgress(fraction: 0.75, stage: .meshGeneration))

        let cloudURL = workspace.root.appending(path: "cloud.ply", directoryHint: .notDirectory)
        let mesh = extracted.mesh
        let points = extracted.points
        let workspaceRoot = workspace.root
        let modelFileName: String
        do {
            modelFileName = try await Task.detached(priority: .userInitiated) { () throws -> String in
                let fileName = try MeshFileWriter.write(mesh: mesh, toDirectory: workspaceRoot)
                // The point cloud is a byproduct; its failure must never fail
                // a scan whose mesh already succeeded (v0.3.3).
                if !points.isEmpty {
                    try? PointCloudFile.write(points: points, to: cloudURL)
                }
                return fileName
            }.value
        } catch {
            phase = .failed(message: error.localizedDescription)
            throw ScanEngineError.reconstructionFailed(error.localizedDescription)
        }

        let dimensions = extracted.dimensions.map { size in
            [Int((size.x * 1000).rounded()), Int((size.y * 1000).rounded()), Int((size.z * 1000).rounded())]
        }

        let record = ScanRecord(
            id: workspace.id,
            name: Self.defaultName(for: Date()),
            engine: Self.kind,
            modelFileName: modelFileName,
            isMetricallyScaled: true,
            imageCount: totalShots,
            pointCount: points.count,
            dimensionsMillimetres: dimensions,
            summary: String(localized: "LiDAR · \(passNumber) geçiş · \(totalShots) kare")
        )
        storage.commit(record, workspace: workspace)

        teardown()
        phase = .done(record)
        return record
    }

    func cancel() {
        isAutoCapturing = false
        autoCaptureTask?.cancel()
        stream?.stop()
        motion.stopDeviceMotionUpdates()
        teardown()
        if let workspace {
            storage.discard(workspace)
            self.workspace = nil
        }
        phase = .cancelled
    }

    // MARK: - Capture actions

    /// The one primary button: calibrates + first frame while framing,
    /// pauses/resumes tracking while capturing.
    func primaryAction() {
        guard !isProcessingShot else { return }
        switch passState {
        case .framing: calibrateAndBeginPass()
        case .capturing: setTrackingPaused(!trackingPaused)
        case .calibratingRev, .awaitingElevation: break
        }
    }

    /// Pause/resume for the tracking loop. Resuming re-anchors on the next
    /// frame, so the object must not move while paused.
    func setTrackingPaused(_ paused: Bool) {
        guard passState == .capturing else { return }
        trackingPaused = paused
        if paused {
            isAutoCapturing = false
        } else {
            reseedOnResume = true
            isAutoCapturing = true
        }
    }

    private func calibrateAndBeginPass() {
        guard let depth = freshDepth() else {
            statusMessage = String(localized: "Derinlik akışı henüz hazır değil — bir saniye bekleyin.")
            return
        }
        // The preview reports the mask continuously, so a nil here means its
        // first report has not landed yet — fall back to a centred frame
        // rather than stranding the tap (v0.3.1).
        let mask = objectMaskRect ?? CGRect(x: 0.15, y: 0.2, width: 0.7, height: 0.6)
        let isFirstPass = passNumber == 1 && totalShots == 0
        guard isFirstPass else {
            beginPassWithCurrentFrame()
            return
        }
        // First pass of a session (v0.8): fit the axis, then record one
        // full calibration revolution (width template + true period)
        // before fusing anything. The turntable must already be spinning.
        isProcessingShot = true
        statusMessage = nil
        let core = self.core
        let box = DepthFrameBox(depth)
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> LidarFusionCore.CalibrationResult in
                let objectPoints = TurntableFusion.points(from: box.depth, maskRect: mask, insideMask: true, stride: 1)
                let backgroundPoints = TurntableFusion.points(from: box.depth, maskRect: mask, insideMask: false, stride: 3)
                return core.calibrateAxisOnly(objectPoints: objectPoints, backgroundPoints: backgroundPoints)
            }.value
            isProcessingShot = false
            switch result {
            case .failed(let message):
                statusMessage = message
            case .begun:
                core.beginCalibrationRev()
                passState = .calibratingRev
                calibrationElapsed = 0
                revStartedAt = CACurrentMediaTime()
                statusMessage = String(localized: "Kalibrasyon turu kaydediliyor — tablayı bir tam tur döndürün.")
                startCalibrationRevLoop()
            }
        }
    }

    private func startCalibrationRevLoop() {
        revTask?.cancel()
        revTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.passState == .calibratingRev else { return }
                self.calibrationElapsed = Float(CACurrentMediaTime() - self.revStartedAt)
                self.calibrationTick()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private var revTickInFlight = false

    private func calibrationTick() {
        guard passState == .calibratingRev, !revTickInFlight else { return }
        guard let depth = freshDepth() else { return }
        let mask = objectMaskRect ?? CGRect(x: 0.15, y: 0.2, width: 0.7, height: 0.6)
        revTickInFlight = true
        let core = self.core
        let box = DepthFrameBox(depth)
        Task { @MainActor in
            _ = await Task.detached(priority: .userInitiated) { () -> Float? in
                let points = TurntableFusion.points(from: box.depth, maskRect: mask, insideMask: true, stride: 1)
                return core.tickCalibration(points: points)
            }.value
            revTickInFlight = false
        }
    }

    /// The user calls the revolution complete (the platter's mark is back
    /// at the front): freeze the period + template and start the pass.
    func completeCalibrationRev() {
        guard passState == .calibratingRev else { return }
        let cost = core.finishCalibrationRev()
        guard cost != nil else {
            statusMessage = String(localized: "Tur çok kısa — biraz daha döndürün.")
            return
        }
        let clockwise = UserDefaults.standard.bool(forKey: "turntable.clockwise")
        core.setDirection(clockwiseFromAbove: clockwise)
        UserDefaults.standard.set(Double(core.calibrationPeriod), forKey: "turntable.secondsPerRev")
        revTask?.cancel()
        if let cost, cost > 0.006 {
            statusMessage = String(localized: "Silüet başlangıçla tam eşleşmedi — işaret bir tur erken/geç çağrılmış olabilir.")
        } else {
            statusMessage = nil
        }
        beginPassWithCurrentFrame()
    }

    /// Aborts the calibration revolution and returns to framing.
    func cancelCalibrationRev() {
        guard passState == .calibratingRev else { return }
        revTask?.cancel()
        passState = .framing
        statusMessage = nil
    }

    /// Skips the calibration revolution: clock-only tracking from the
    /// stored/entered revolution period (no width phase lock).
    func skipCalibrationRev() {
        guard passState == .calibratingRev else { return }
        revTask?.cancel()
        let stored = UserDefaults.standard.double(forKey: "turntable.secondsPerRev")
        let period = stored > 2 ? stored : 12
        let clockwise = UserDefaults.standard.bool(forKey: "turntable.clockwise")
        core.omega = (clockwise ? -1 : 1) * 2 * .pi / Float(period)
        beginPassWithCurrentFrame()
    }

    private func beginPassWithCurrentFrame() {
        guard let depth = freshDepth() else {
            statusMessage = String(localized: "Derinlik akışı henüz hazır değil — bir saniye bekleyin.")
            return
        }
        let mask = objectMaskRect ?? CGRect(x: 0.15, y: 0.2, width: 0.7, height: 0.6)
        isProcessingShot = true
        statusMessage = nil
        let pitch = currentPitchDegrees
        let core = self.core
        let isFirstPass = passNumber == 1 && totalShots == 0
        let box = DepthFrameBox(depth)
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> LidarFusionCore.CalibrationResult in
                let objectPoints = TurntableFusion.points(from: box.depth, maskRect: mask, insideMask: true, stride: 1)
                let backgroundPoints = TurntableFusion.points(from: box.depth, maskRect: mask, insideMask: false, stride: 3)
                return core.beginPass(objectPoints: objectPoints, backgroundPoints: backgroundPoints, isFirstPass: isFirstPass)
            }.value

            isProcessingShot = false
            switch result {
            case .failed(let message):
                statusMessage = message
            case .begun(let yawWarning):
                passPitchDegrees = pitch
                shotsThisPass = 1
                totalShots += 1
                fusedPointCount = core.fusedPointCountSnapshot
                lastDeltaDegrees = nil
                lastHitRate = nil
                statusMessage = yawWarning
                passState = .capturing
                phase = .capturing(shots: totalShots, limit: 0)
                passRotationDegrees = 0
                rotationSpeedDegPerSec = 0
                trackingQuality = .good
                trackingPaused = false
                lastAcceptedTickDate = nil
                isAutoCapturing = true
            }
        }
    }

    private var tickInFlight = false
    private var reseedOnResume = false
    private var lastAcceptedTickDate: Date?

    private enum TickOutcome: Sendable {
        case tracked(LidarFusionCore.TrackResult)
        case reseeded
    }

    /// One tracking sample: register the newest depth frame against the
    /// previous one and fuse it if the fit holds. Runs ~5×/s while tracking.
    private func trackTick() {
        guard passState == .capturing, !tickInFlight else { return }
        guard let depth = freshDepth() else { return }
        let mask = objectMaskRect ?? CGRect(x: 0.15, y: 0.2, width: 0.7, height: 0.6)
        tickInFlight = true
        let core = self.core
        let box = DepthFrameBox(depth)
        let reseed = reseedOnResume
        reseedOnResume = false
        Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) { () -> TickOutcome in
                let points = TurntableFusion.points(from: box.depth, maskRect: mask, insideMask: true, stride: 1)
                if reseed {
                    core.reseedReference(objectPoints: points)
                    return .reseeded
                }
                return .tracked(core.trackFrame(objectPoints: points))
            }.value

            tickInFlight = false
            fusedPointCount = core.fusedPointCountSnapshot
            switch outcome {
            case .reseeded:
                trackingQuality = .good
                lastAcceptedTickDate = Date()
            case .tracked(.accepted(let deltaDegrees, let inliers, let meanMM, let rotation, let quality)):
                shotsThisPass += 1
                totalShots += 1
                lastDeltaDegrees = deltaDegrees
                lastInliers = inliers
                lastMeanMillimetres = meanMM
                trackingQuality = quality
                passRotationDegrees = rotation
                let now = Date()
                if let last = lastAcceptedTickDate {
                    let dt = max(0.05, now.timeIntervalSince(last))
                    let speed = deltaDegrees / Float(dt)
                    rotationSpeedDegPerSec = rotationSpeedDegPerSec == 0
                        ? speed
                        : rotationSpeedDegPerSec * 0.6 + speed * 0.4
                }
                lastAcceptedTickDate = now
                phase = .capturing(shots: totalShots, limit: 0)
                if rotation >= 355 {
                    isAutoCapturing = false
                    trackingPaused = true
                    statusMessage = String(localized: "Bu tur tamamlandı — bitirebilir veya yükseklik değiştirebilirsiniz.")
                } else if quality == .degraded {
                    statusMessage = String(localized: "Silüet kilidi zayıf — faz kayması olabilir, turu bitirip kontrol edin.")
                } else {
                    statusMessage = nil
                }
            case .tracked(.measured(let deltaDegrees, let inliers, let meanMM, let quality)):
                lastDeltaDegrees = abs(deltaDegrees)
                lastInliers = inliers
                lastMeanMillimetres = meanMM
                trackingQuality = quality
                if abs(deltaDegrees) >= 355, isAutoCapturing {
                    isAutoCapturing = false
                    trackingPaused = true
                    statusMessage = String(localized: "Bu tur tamamlandı — bitirebilir veya yükseklik değiştirebilirsiniz.")
                }
            case .tracked(.rejected(let quality, let inliers, let meanMM)):
                rejectedShots += 1
                lastInliers = inliers
                lastMeanMillimetres = meanMM
                trackingQuality = quality
                if quality == .lost {
                    statusMessage = String(localized: "Takip kayboldu — çevirmeyi bırakın, yavaşça geri çevirerek takibi yakalayın.")
                }
            }
        }
    }

    // MARK: - Elevation change

    /// Ends the current pass and starts watching the phone's pitch, so the
    /// move to a new height is measured rather than assumed.
    func beginElevationChange() {
        guard passState == .capturing else { return }
        isAutoCapturing = false
        previousPassPitchDegrees = passPitchDegrees
        passState = .awaitingElevation
    }

    /// Confirms the phone is at its new height. The mask must be re-framed
    /// (the object moved in the picture), then the pass calibrates afresh.
    func confirmNewElevation() {
        guard passState == .awaitingElevation else { return }
        passNumber += 1
        shotsThisPass = 0
        passState = .framing
        phase = .framing
        statusMessage = nil
        passRotationDegrees = 0
        trackingPaused = false
        trackingQuality = .good
    }

    // MARK: - Private helpers

    /// A depth frame newer than the last one consumed — auto-capture must
    /// never fuse the same frame twice.
    private func freshDepth() -> AVDepthData? {
        guard let stream, let depth = stream.snapshotDepth() else { return nil }
        let timestamp = stream.latestTimestamp
        guard timestamp.isValid else { return nil }
        if lastUsedTimestamp.isValid, CMTimeCompare(timestamp, lastUsedTimestamp) == 0 { return nil }
        lastUsedTimestamp = timestamp
        return depth
    }

    /// Watches the stream's frame timestamps: a stream that never delivers
    /// (or stops delivering) must be a visible state, not a silent failure.
    private func startStreamMonitor() {
        streamMonitorTask?.cancel()
        streamMonitorTask = Task { @MainActor [weak self] in
            var lastSeen: CMTime = .invalid
            var lastChange = Date()
            while !Task.isCancelled {
                guard let self else { return }
                if let stream = self.stream {
                    let timestamp = stream.latestTimestamp
                    if timestamp.isValid {
                        if !lastSeen.isValid || CMTimeCompare(timestamp, lastSeen) != 0 {
                            lastSeen = timestamp
                            lastChange = Date()
                        }
                        self.depthStreamState = Date().timeIntervalSince(lastChange) < 2.5 ? .live : .stalled
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let gravity = data?.gravity else { return }
            let z = max(-1, min(1, gravity.z))
            let pitch = Float(asin(z) * 180 / .pi)
            Task { @MainActor [weak self] in self?.currentPitchDegrees = pitch }
        }
    }

    private func restartAutoCapture() {
        autoCaptureTask?.cancel()
        guard isAutoCapturing, passState == .capturing else { return }
        autoCaptureTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isAutoCapturing, self.passState == .capturing else { return }
                self.trackTick()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func teardown() {
        stream = nil
        autoCaptureTask?.cancel()
        streamMonitorTask?.cancel()
    }

    private static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.dateFormat = "d MMM HH:mm"
        return "LiDAR \(formatter.string(from: date))"
    }
}

/// Carries one depth frame across a task boundary; `AVDepthData` is not
/// `Sendable`, and the frame is consumed read-only by exactly one task.
final class DepthFrameBox: @unchecked Sendable {
    let depth: AVDepthData
    init(_ depth: AVDepthData) { self.depth = depth }
}

// MARK: - Fusion core

/// Owns all fusion state. Every entry point does its own heavy lifting on
/// the caller's (detached) thread; calls are serialised by the engine's
/// one-shot-at-a-time discipline.
final class LidarFusionCore: @unchecked Sendable {
    enum CalibrationResult: Sendable {
        case begun(yawWarning: String?)
        case failed(message: String)
    }

    enum TrackingQuality: Sendable {
        case good, degraded, lost
    }

    enum TrackResult: Sendable {
        /// Solved and fused; the frame became the new anchor.
        case accepted(deltaDegrees: Float, inliers: Float, meanMillimetres: Float, passRotationDegrees: Float, quality: TrackingQuality)
        /// Solved against the current anchor but not yet far enough to
        /// fuse (baseline < 9°): tracking is alive, nothing was integrated.
        case measured(deltaDegrees: Float, inliers: Float, meanMillimetres: Float, quality: TrackingQuality)
        case rejected(quality: TrackingQuality, inliers: Float, meanMillimetres: Float)
    }

    private var volume: TSDFVolume?
    private var fusedCloud = DepthPointCloud(voxelSize: 0.0025)
    private var previousRawPoints: [SIMD3<Float>] = []
    private var passAxis: TurntableFusion.Axis?
    private var passTransform = simd_float4x4(1)
    private var passCameraOriginWorld = SIMD3<Float>.zero
    private var passYaw: Float = 0
    private var cumulativeAngle: Float = 0
    private var lockedSign: Float?

    // Continuous tracking state (v0.8): constant-speed clock + silhouette
    // phase lock. Offline simulation killed every per-frame depth
    // registration design (nearest-neighbour, TSDF field, projective,
    // patch flow): the visible skin of a convex object is nearly
    // invariant under small rotations, so their minima sit near zero
    // rotation — the petal/starburst failures on device. A motorised
    // turntable needs no per-frame registration at all: the angle is
    // omega x time, with omega timed over one full
    // revolution (silhouette closure). The one depth observable that DOES track phase is the
    // silhouette width (55->78mm over 45 degrees for a test box, phase
    // readout within a few degrees in simulation): a width template
    // recorded during the calibration revolution phase-locks the clock
    // during the pass, absorbing motor drift.
    /// Rotation rate (rad/s, signed). Set by the engine from the stored
    /// turntable profile before each pass.
    var omega: Float = 0
    /// Monotonic seconds source (engine: CACurrentMediaTime; tests: a
    /// virtual clock).
    var clock: () -> Float = { 0 }
    private var passStartTime: Float = 0
    private var phaseCorrection: Float = 0
    /// Template phase of the object at this pass's start (0 for the pass
    /// that follows calibration; solved/persisted for later passes).
    private var templatePhaseAtPassStart: Float = 0
    private var alignmentDone = false
    private var lastPhase: Float = 0
    private var lastFusedPhase: Float = 0
    private var lastLockCost: Float?
    // Calibration-revolution recording.
    private var calibrating = false
    private var calibrationStart: Float = 0
    private var calibrationWidths: [(elapsed: Float, widths: SIMD3<Float>)] = []
    private(set) var calibrationPeriod: Float = 0
    private var widthHistory: [(elapsed: Float, widths: SIMD3<Float>)] = []
    private var phaseSign: Float = 1
    private var phaseBase: Float = 0
    private var signChecked = false
    /// Silhouette width template over one revolution: (phase rad, widths
    /// in three height bands, metres). Recorded at calibration.
    private var widthTemplate: [(phase: Float, widths: SIMD3<Float>)] = []
    private var consecutiveLost = 0
    private var passRotation: Float = 0
    /// Set when the axis was fitted ahead of the calibration revolution;
    /// beginPass then reuses it instead of fitting again.
    private var axisPreCalibrated = false

    var fusedPointCountSnapshot: Int { fusedCloud.pointCount }

    /// Fits the turntable axis ahead of the calibration revolution (the
    /// revolution's width bands need the axis). beginPass reuses it.
    func calibrateAxisOnly(objectPoints: [SIMD3<Float>], backgroundPoints: [SIMD3<Float>]) -> CalibrationResult {
        guard objectPoints.count >= 150 else {
            return .failed(message: String(localized: "Çerçeve içinde yeterli derinlik yok — objeye yaklaşın."))
        }
        guard let axis = TurntableFusion.calibrateAxis(objectPoints: objectPoints, backgroundPoints: backgroundPoints) else {
            return .failed(message: String(localized: "Döner tabla ekseni bulunamadı — tabla yüzeyinin çerçeve dışında görünür olmasına dikkat edin."))
        }
        passAxis = axis
        passTransform = TurntableFusion.turntableTransform(axis: axis)
        axisPreCalibrated = true
        return .begun(yawWarning: nil)
    }

    func beginPass(objectPoints: [SIMD3<Float>], backgroundPoints: [SIMD3<Float>], isFirstPass: Bool) -> CalibrationResult {
        guard objectPoints.count >= 150 else {
            return .failed(message: String(localized: "Çerçeve içinde yeterli derinlik yok — objeye yaklaşın."))
        }
        guard let axis = TurntableFusion.calibrateAxis(objectPoints: objectPoints, backgroundPoints: backgroundPoints) else {
            return .failed(message: String(localized: "Döner tabla ekseni bulunamadı — tabla yüzeyinin çerçeve dışında görünür olmasına dikkat edin."))
        }

        let transform = TurntableFusion.turntableTransform(axis: axis)
        passAxis = axis
        passTransform = transform
        cumulativeAngle = 0
        lockedSign = nil
        previousRawPoints = objectPoints
        consecutiveLost = 0
        passRotation = 0

        let localPoints = objectPoints.map { TurntableFusion.apply(transform, to: $0) }
        var yaw: Float = 0
        var yawWarning: String?

        if isFirstPass || volume == nil {
            // Establish the volume from this frame's extent about the axis.
            // Robust (percentile) bounds: a few noise-lifted platter
            // points metres out must not blow up the volume.
            let radials = localPoints.map { simd_length(SIMD2<Float>($0.x, $0.z)) }.sorted()
            let heights = localPoints.map { $0.y }.sorted()
            func percentile(_ values: [Float], _ q: Float) -> Float {
                values[min(values.count - 1, max(0, Int(Float(values.count) * q)))]
            }
            let radius = max(0.05, percentile(radials, 0.995)) + 0.03
            let maxY = max(0.05, percentile(heights, 0.995))
            volume = TSDFVolume(
                boundsMin: SIMD3<Float>(-radius, -0.015, -radius),
                boundsMax: SIMD3<Float>(radius, maxY + 0.04, radius),
                voxelSize: 0.0025
            )
            guard volume != nil else {
                return .failed(message: String(localized: "Model oluşturulamadı: obje çok büyük."))
            }
        } else {
            // Register this pass against the fused model: only yaw is
            // unknown. Distance-scored (v0.4); the result is the alignment
            // rotation itself, applied directly below.
            let modelPoints = fusedCloud.sampledPoints(limit: 6000)
            let field = VoxelDistanceField(points: modelPoints, voxelSize: 0.005)
            let estimate = MicroAngleRegistration.estimateYaw(
                reference: field,
                points: TurntableFusion.subsample(localPoints, limit: 1500)
            )
            yaw = estimate.alignment
            if estimate.inliers < 0.30 {
                yawWarning = String(localized: "Yeni geçiş önceki modelle zayıf eşleşti — obje yerinden oynamış olabilir.")
            }
        }
        passYaw = yaw

        let yawRotation = TurntableFusion.rotationMatrix(axis: SIMD3<Float>(0, 1, 0), angleRadians: yaw)
        passCameraOriginWorld = yawRotation * TurntableFusion.apply(transform, to: .zero)

        let worldPoints = localPoints.map { yawRotation * $0 }
        volume?.integrate(points: worldPoints, cameraOrigin: passCameraOriginWorld)
        fusedCloud.insert(TurntableFusion.subsample(worldPoints, limit: 6000))
        passStartTime = clock()
        phaseCorrection = 0
        widthHistory.removeAll()
        lastFusedPhase = 0
        lastPhase = 0
        lastLockCost = nil
        // Alignment bookkeeping: with no template everything runs on the
        // bare clock. The pass after calibration knows its template phase
        // (0) but must still verify the rate's sign against the width
        // history; later passes keep the verified sign and re-solve the
        // template phase (the object did not move, only the phone did).
        phaseSign = omega < 0 ? -1 : 1
        phaseBase = 0
        if widthTemplate.isEmpty {
            alignmentDone = true
            signChecked = true
        } else if isFirstPass {
            alignmentDone = true
            signChecked = false
        } else {
            alignmentDone = false
            signChecked = true
        }
        return .begun(yawWarning: yawWarning)
    }

    // MARK: - Silhouette widths

    /// Silhouette widths in three height bands (metres): band = height
    /// above the turntable plane (8-16 / 16-26 / 26+ mm), width = the
    /// 2%-98% camera-x extent. A band with too few points reads -1.
    func silhouetteWidths(points: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard let axis = passAxis else { return nil }
        var bands: [[Float]] = [[], [], []]
        for point in points {
            let h = simd_dot(point - axis.point, axis.direction)
            if h >= 0.008 {
                bands[h < 0.016 ? 0 : h < 0.026 ? 1 : 2].append(point.x)
            }
        }
        var widths = SIMD3<Float>(-1, -1, -1)
        var valid = 0
        for band in 0..<3 where bands[band].count >= 30 {
            let sorted = bands[band].sorted()
            widths[band] = sorted[Int(Float(sorted.count) * 0.98)]
                - sorted[Int(Float(sorted.count) * 0.02)]
            valid += 1
        }
        return valid >= 2 ? widths : nil
    }

    private func widthCost(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        var sum: Float = 0
        var n = 0
        for i in 0..<3 where a[i] >= 0 && b[i] >= 0 {
            sum += abs(a[i] - b[i])
            n += 1
        }
        return n > 0 ? sum / Float(n) : .greatestFiniteMagnitude
    }

    private func templateWidths(at phase: Float) -> SIMD3<Float>? {
        guard widthTemplate.count >= 2 else { return nil }
        let twoPi = 2 * Float.pi
        var wrapped = phase.truncatingRemainder(dividingBy: twoPi)
        if wrapped < 0 { wrapped += twoPi }
        // Template phases are sorted ascending over [0, 2pi).
        var upper = widthTemplate.firstIndex { $0.phase >= wrapped } ?? widthTemplate.count
        if upper == 0 { upper = widthTemplate.count }
        let hi = widthTemplate[upper % widthTemplate.count]
        let lo = widthTemplate[upper - 1]
        let hiPhase = upper == widthTemplate.count ? hi.phase + twoPi : hi.phase
        let span = hiPhase - lo.phase
        guard span > 0 else { return hi.widths }
        let t = (wrapped - lo.phase) / span
        var result = SIMD3<Float>(0, 0, 0)
        for i in 0..<3 {
            result[i] = (lo.widths[i] < 0 || hi.widths[i] < 0)
                ? max(lo.widths[i], hi.widths[i])
                : lo.widths[i] + (hi.widths[i] - lo.widths[i]) * t
        }
        return result
    }

    // MARK: - Calibration revolution

    /// Starts recording the calibration revolution. The engine calls
    /// this right after axis calibration, with the turntable already
    /// spinning and the platter's reference mark at the front; the user
    /// ends the revolution with a tap when the mark comes back around.
    func beginCalibrationRev() {
        calibrating = true
        calibrationWidths.removeAll()
        calibrationStart = clock()
    }

    var isCalibrating: Bool { calibrating }

    /// Feeds one frame during the calibration revolution (width samples
    /// for the template). Returns the current width-match cost against
    /// the starting frame, for the UI's information.
    @discardableResult
    func tickCalibration(points: [SIMD3<Float>]) -> Float? {
        guard calibrating, let widths = silhouetteWidths(points: points) else { return nil }
        let elapsed = clock() - calibrationStart
        calibrationWidths.append((elapsed, widths))
        guard let first = calibrationWidths.first?.widths else { return nil }
        return widthCost(widths, first)
    }

    /// Ends the calibration revolution on the user's tap (the platter's
    /// mark is back at the front). Sets the period, the rate magnitude
    /// and the width template. Returns the width-match cost at closure —
    /// a large value suggests the tap was early or late. Silhouette
    /// auto-closure is deliberately NOT used: for a symmetric object the
    /// widths repeat every symmetry period, so only the user's eye can
    /// call the full turn.
    @discardableResult
    func finishCalibrationRev() -> Float? {
        guard calibrating, calibrationWidths.count >= 8,
              let first = calibrationWidths.first, let last = calibrationWidths.last else { return nil }
        let period = last.elapsed - first.elapsed
        guard period >= 2 else { return nil }
        calibrating = false
        calibrationPeriod = period
        widthTemplate = calibrationWidths.map {
            (phase: $0.elapsed / period * 2 * .pi, widths: $0.widths)
        }
        omega = 2 * .pi / period
        templatePhaseAtPassStart = 0
        return widthCost(last.widths, first.widths)
    }

    /// Applies the user's direction choice to the calibrated rate.
    func setDirection(clockwiseFromAbove: Bool) {
        let magnitude = abs(omega)
        guard magnitude > 0 else { return }
        // Counterclockwise seen from above = positive rotation about the
        // up axis (right-hand rule), which is the core's convention.
        omega = clockwiseFromAbove ? -magnitude : magnitude
    }

    var hasWidthTemplate: Bool { !widthTemplate.isEmpty }

    // MARK: - Tracking (clock + width phase lock)

    /// Local phase (rotation since this pass's first frame, signed).
    private func localPhase(elapsed: Float) -> Float {
        phaseBase + phaseSign * abs(omega) * elapsed
    }

    /// Verifies the rate's sign once per session by matching the width
    /// history against the template both ways; a clearly better reversed
    /// match flips the sign (mirroring the phase around the pass start).
    private func solveSignIfNeeded() {
        guard !signChecked, !widthTemplate.isEmpty, widthHistory.count >= 6,
              let first = widthHistory.first, let last = widthHistory.last,
              abs(omega) * (last.elapsed - first.elapsed) >= 35 * .pi / 180 else { return }
        func cost(sign: Float) -> Float {
            var total: Float = 0
            var n = 0
            for entry in widthHistory {
                if let tw = templateWidths(at: templatePhaseAtPassStart + sign * abs(omega) * entry.elapsed) {
                    total += widthCost(tw, entry.widths)
                    n += 1
                }
            }
            return n > 0 ? total / Float(n) : .greatestFiniteMagnitude
        }
        let current = cost(sign: phaseSign)
        let flipped = cost(sign: -phaseSign)
        if flipped <= 0.005, flipped < 0.6 * current {
            let rawElapsed = abs(omega) * (last.elapsed)
            let oldLocal = phaseBase + phaseSign * rawElapsed
            phaseSign = -phaseSign
            phaseBase = -oldLocal - phaseSign * rawElapsed
            omega = phaseSign * abs(omega)
        }
        signChecked = true
    }

    /// Solves the template phase at pass start for later passes by
    /// matching the recorded width history against the template.
    private func solveAlignmentIfNeeded() {
        guard !alignmentDone, !widthTemplate.isEmpty, widthHistory.count >= 6,
              let first = widthHistory.first, let last = widthHistory.last,
              abs(omega) * (last.elapsed - first.elapsed) >= 35 * .pi / 180 else { return }
        var best: (psi: Float, cost: Float) = (templatePhaseAtPassStart, .greatestFiniteMagnitude)
        var psi: Float = 0
        while psi < 2 * .pi {
            var total: Float = 0
            var n = 0
            for entry in widthHistory {
                if let tw = templateWidths(at: psi + phaseSign * abs(omega) * entry.elapsed) {
                    total += widthCost(tw, entry.widths)
                    n += 1
                }
            }
            if n > 0 {
                let cost = total / Float(n)
                if cost < best.cost { best = (psi, cost) }
            }
            psi += 3 * .pi / 180
        }
        if best.cost <= 0.005 {
            templatePhaseAtPassStart = best.psi
        }
        // Even a poor match (near-symmetric object) proceeds on the clock.
        alignmentDone = true
    }

    /// Current best local phase: the clock, phase-locked to the width
    /// template when one is available and alignment is settled.
    private func currentPhase(elapsed: Float, widths: SIMD3<Float>?) -> Float {
        let clockPhase = localPhase(elapsed: elapsed)
        guard alignmentDone, let widths, !widthTemplate.isEmpty else {
            lastLockCost = nil
            lastPhase = clockPhase + phaseCorrection
            return lastPhase
        }
        let base = templatePhaseAtPassStart + clockPhase + phaseCorrection
        var bestPhase = base
        var bestCost: Float = .greatestFiniteMagnitude
        var step: Float = -25 * .pi / 180
        while step <= 25 * .pi / 180 {
            let candidate = base + step
            if let tw = templateWidths(at: candidate) {
                let cost = widthCost(tw, widths)
                if cost < bestCost { bestCost = cost; bestPhase = candidate }
            }
            step += 1 * .pi / 180
        }
        lastLockCost = bestCost
        if bestCost <= 0.006 {
            let target = bestPhase - (templatePhaseAtPassStart + clockPhase)
            let delta = target - phaseCorrection
            let limit: Float = 3 * .pi / 180
            phaseCorrection += max(-limit, min(limit, delta))
        }
        lastPhase = clockPhase + phaseCorrection
        return lastPhase
    }

    private func fuse(points: [SIMD3<Float>], absoluteAngle: Float) {
        guard let axis = passAxis, let volume else { return }
        let points = points.filter { simd_dot($0 - axis.point, axis.direction) >= 0.004 }
        guard points.count >= 100 else { return }
        let unrotate = TurntableFusion.rotationMatrix(axis: axis.direction, angleRadians: -absoluteAngle)
        let yawRotation = TurntableFusion.rotationMatrix(axis: SIMD3<Float>(0, 1, 0), angleRadians: passYaw)
        let worldPoints = points.map { point in
            let unrotated = axis.point + unrotate * (point - axis.point)
            return yawRotation * TurntableFusion.apply(passTransform, to: unrotated)
        }
        volume.integrate(points: worldPoints, cameraOrigin: passCameraOriginWorld)
        fusedCloud.insert(TurntableFusion.subsample(worldPoints, limit: 6000))
        previousRawPoints = points
    }

    /// One tracking tick of the constant-speed pipeline (v0.8). The angle
    /// comes from the clock; the width template phase-locks it. Frames
    /// fuse at ~10-degree phase steps once alignment is settled.
    func trackFrame(objectPoints: [SIMD3<Float>]) -> TrackResult {
        guard passAxis != nil, volume != nil, omega != 0 else {
            return .rejected(quality: .lost, inliers: 0, meanMillimetres: 0)
        }
        guard objectPoints.count >= 150 else {
            return .rejected(quality: .degraded, inliers: 0, meanMillimetres: 0)
        }
        let elapsed = clock() - passStartTime
        let widths = silhouetteWidths(points: objectPoints)
        if let widths {
            widthHistory.append((elapsed: elapsed, widths: widths))
            if widthHistory.count > 600 { widthHistory.removeFirst(200) }
        }
        solveSignIfNeeded()
        solveAlignmentIfNeeded()
        let phase = currentPhase(elapsed: elapsed, widths: widths)
        // A steadily growing correction means the calibrated rate is off
        // (tap error): fold the accumulated correction into the rate so
        // the lock only has to track wobble, not a constant slope.
        if abs(phaseCorrection) >= 6 * .pi / 180, elapsed > 1 {
            let raw = phaseSign * abs(omega) * elapsed
            if abs(raw) > 20 * .pi / 180 {
                let scale = (raw + phaseCorrection) / raw
                if scale > 0.9, scale < 1.1 {
                    let newMagnitude = abs(omega) * scale
                    phaseBase = phase - phaseSign * newMagnitude * elapsed
                    omega = phaseSign * newMagnitude
                    phaseCorrection = 0
                }
            }
        }
        let ready = alignmentDone && signChecked
        let advance = (phase - lastFusedPhase) * phaseSign
        let lockCost = lastLockCost ?? 0
        let quality: TrackingQuality = !ready ? .degraded
            : (lastLockCost.map { $0 <= 0.003 } ?? true) ? .good : .degraded

        if ready, advance >= 10 * .pi / 180 {
            fuse(points: objectPoints, absoluteAngle: phase)
            lastFusedPhase = phase
            passRotation += advance
            consecutiveLost = 0
            return .accepted(
                deltaDegrees: advance * 180 / .pi,
                inliers: max(0, 1 - lockCost / 0.006),
                meanMillimetres: lockCost * 1000,
                passRotationDegrees: passRotation * 180 / .pi,
                quality: quality
            )
        }
        if advance < -3 * .pi / 180 {
            consecutiveLost += 1
            return .rejected(
                quality: consecutiveLost >= 3 ? .lost : .degraded,
                inliers: 0, meanMillimetres: lockCost * 1000
            )
        }
        return .measured(
            deltaDegrees: phase * 180 / .pi,
            inliers: max(0, 1 - lockCost / 0.006),
            meanMillimetres: lockCost * 1000,
            quality: quality
        )
    }

    /// Finish-time tail capture: fuse the latest frame if it sits at
    /// least 3 degrees past the last anchor, so the model doesn't lose
    /// the final wedge of surface.
    @discardableResult
    func acceptFinalFrame(objectPoints: [SIMD3<Float>]) -> Bool {
        guard alignmentDone, signChecked, objectPoints.count >= 150 else { return false }
        let phase = currentPhase(elapsed: clock() - passStartTime, widths: silhouetteWidths(points: objectPoints))
        guard (phase - lastFusedPhase) * phaseSign >= 3 * .pi / 180 else { return false }
        fuse(points: objectPoints, absoluteAngle: phase)
        passRotation += (phase - lastFusedPhase) * phaseSign
        lastFusedPhase = phase
        return true
    }

    /// Resume after a pause: shift the clock origin so the phase
    /// continues from the last estimate (the platter was stopped too, or
    /// the width lock will complain loudly via rejected frames).
    func reseedReference(objectPoints: [SIMD3<Float>]) {
        _ = objectPoints
        let rate = phaseSign * abs(omega)
        if rate != 0 {
            passStartTime = clock() - (lastPhase - phaseCorrection - phaseBase) / rate
        }
        consecutiveLost = 0
    }

    func extractMeshAndPoints() -> (mesh: SurfaceNets.Mesh, points: [SIMD3<Float>], dimensions: SIMD3<Float>?)? {
        guard let volume else { return nil }
        let mesh = SurfaceNets.extract(from: volume)
        // Pruning single-observation voxels suits a dense continuous stream
        // (TrueDepth). A turntable's frames are discrete: if registration is
        // a voxel off, nearly every cell is a single observation and pruning
        // would erase the whole cloud (v0.3.3). Fall back to the raw cloud.
        var pruned = fusedCloud
        pruned.pruneSingleObservations()
        let source = pruned.isEmpty ? fusedCloud : pruned
        let points = source.pointCount > 400_000 ? source.sampledPoints(limit: 400_000) : source.points
        return (mesh, points, source.dimensions)
    }
}

// MARK: - Mesh writing

enum MeshFileWriter {
    /// Writes a surface-nets mesh into `directory`, preferring USDZ and
    /// falling back to OBJ where ModelIO refuses USD export (v0.3.3).
    /// Returns the file name actually written.
    static func write(mesh: SurfaceNets.Mesh, toDirectory directory: URL) throws -> String {
        let usdzURL = directory.appending(path: "model.usdz", directoryHint: .notDirectory)
        if MDLAsset.canExportFileExtension("usdz") {
            do {
                try writeAsset(mesh: mesh, to: usdzURL)
                if FileManager.default.fileExists(atPath: usdzURL.path(percentEncoded: false)) {
                    return "model.usdz"
                }
            } catch {
                // Fall through to OBJ.
            }
        }
        let objURL = directory.appending(path: "model.obj", directoryHint: .notDirectory)
        do {
            try writeAsset(mesh: mesh, to: objURL)
            return "model.obj"
        } catch {
            // ModelIO itself is the failure (MDLErrorDomain 0 on device):
            // fall back to a hand-written OBJ, which cannot fail in any way
            // ModelIO can (v0.3.4).
            try writeOBJManually(mesh: mesh, to: objURL)
            return "model.obj"
        }
    }

    /// Plain-text OBJ: vertices, normals, faces. Deliberately primitive —
    /// this is the tier that exists for when the platform refuses to help.
    private static func writeOBJManually(mesh: SurfaceNets.Mesh, to url: URL) throws {
        var text = "# ObjectScanner pure-LiDAR turntable\n"
        text.reserveCapacity(mesh.vertices.count * 48 + mesh.indices.count * 8)
        for vertex in mesh.vertices {
            text += "v \(vertex.x) \(vertex.y) \(vertex.z)\n"
        }
        for normal in mesh.normals {
            text += "vn \(normal.x) \(normal.y) \(normal.z)\n"
        }
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.indices[i] + 1
            let b = mesh.indices[i + 1] + 1
            let c = mesh.indices[i + 2] + 1
            text += "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n"
            i += 3
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeAsset(mesh: SurfaceNets.Mesh, to url: URL) throws {
        var interleaved: [Float] = []
        interleaved.reserveCapacity(mesh.vertices.count * 6)
        for index in mesh.vertices.indices {
            interleaved.append(contentsOf: [mesh.vertices[index].x, mesh.vertices[index].y, mesh.vertices[index].z])
            let normal = mesh.normals[index]
            interleaved.append(contentsOf: [normal.x, normal.y, normal.z])
        }
        let vertexData = interleaved.withUnsafeBytes { Data($0) }
        let indexData = mesh.indices.withUnsafeBytes { Data($0) }

        let vertexBuffer = MDLMeshBufferData(type: .vertex, data: vertexData)
        let indexBuffer = MDLMeshBufferData(type: .index, data: indexData)

        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0
        )
        descriptor.attributes[1] = MDLVertexAttribute(
            name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0
        )
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: 24)

        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer,
            indexCount: mesh.indices.count,
            indexType: .uInt32,
            geometryType: .triangles,
            material: nil
        )
        let mdlMesh = MDLMesh(
            vertexBuffer: vertexBuffer,
            vertexCount: mesh.vertices.count,
            descriptor: descriptor,
            submeshes: [submesh]
        )
        let asset = MDLAsset()
        asset.add(mdlMesh)
        try asset.export(to: url)
    }
}
