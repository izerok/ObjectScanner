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

    var canFinish: Bool { totalShots >= 30 && fusedPointCount > 500 }

    // MARK: - Private

    private let storage: ScanStorage
    private var workspace: ScanWorkspace?
    private var stream: DepthStreamSession?
    private let core = LidarFusionCore()
    private let motion = CMMotionManager()
    private var autoCaptureTask: Task<Void, Never>?
    private var streamMonitorTask: Task<Void, Never>?
    private var lastUsedTimestamp: CMTime = .invalid
    private var passPitchDegrees: Float?

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
            throw ScanEngineError.reconstructionFailed(String(localized: "Yeterli kare yok — en az 30 kare gerekir."))
        }

        isAutoCapturing = false
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
        case .awaitingElevation: break
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
        isProcessingShot = true
        statusMessage = nil
        let pitch = currentPitchDegrees
        let core = self.core
        let isFirstPass = passNumber == 1 && totalShots == 0
        let box = DepthFrameBox(depth)
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> LidarFusionCore.CalibrationResult in
                let objectPoints = TurntableFusion.points(from: box.depth, maskRect: mask, insideMask: true, stride: 2)
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
                let points = TurntableFusion.points(from: box.depth, maskRect: mask, insideMask: true, stride: 2)
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
                    statusMessage = String(localized: "Takip zayıf — daha yavaş çevirin.")
                } else {
                    statusMessage = nil
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
                try? await Task.sleep(for: .milliseconds(200))
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
        case accepted(deltaDegrees: Float, inliers: Float, meanMillimetres: Float, passRotationDegrees: Float, quality: TrackingQuality)
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

    // Continuous tracking state (v0.4): the reference is the previous
    // sampled frame as a distance field, replaced on every accepted frame.
    private var referenceField: VoxelDistanceField?
    private var consecutiveLost = 0
    private var passRotation: Float = 0

    var fusedPointCountSnapshot: Int { fusedCloud.pointCount }

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
        referenceField = VoxelDistanceField(
            points: TurntableFusion.subsample(objectPoints, limit: 2000), voxelSize: 0.005)
        consecutiveLost = 0
        passRotation = 0

        let localPoints = objectPoints.map { TurntableFusion.apply(transform, to: $0) }
        var yaw: Float = 0
        var yawWarning: String?

        if isFirstPass || volume == nil {
            // Establish the volume from this frame's extent about the axis.
            var maxRadial: Float = 0.05
            var maxY: Float = 0.05
            for point in localPoints {
                maxRadial = max(maxRadial, simd_length(SIMD2<Float>(point.x, point.z)))
                maxY = max(maxY, point.y)
            }
            let radius = maxRadial + 0.05
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
        return .begun(yawWarning: yawWarning)
    }

    /// One tracking sample of the continuous-rotation pipeline (v0.4). The
    /// frame is registered against the *previous sampled frame* — a degree
    /// or three away, inside a ±7° distance-scored search — and only
    /// integrated when the fit is genuinely good. A rejected frame changes
    /// nothing but the lost counter: bad geometry never enters the volume,
    /// which is the exact failure that sank the discrete-shot design.
    func trackFrame(objectPoints: [SIMD3<Float>]) -> TrackResult {
        guard let axis = passAxis, let volume, let referenceField else {
            return .rejected(quality: .lost, inliers: 0, meanMillimetres: 0)
        }
        guard objectPoints.count >= 150 else {
            return .rejected(quality: .degraded, inliers: 0, meanMillimetres: 0)
        }
        let sample = TurntableFusion.subsample(objectPoints, limit: 2000)
        let estimate = MicroAngleRegistration.estimate(
            reference: referenceField,
            points: sample,
            axisPoint: axis.point,
            axisDirection: axis.direction
        )
        let delta = estimate.delta
        // A winner at the search edge means the rotation outran the window.
        let atBoundary = abs(delta) > 6.8 * .pi / 180
        // Reversing direction mid-pass would corrupt the accumulation; small
        // jitter around zero is fine.
        let backwards = lockedSign.map { sign in
            delta != 0 && (delta > 0) != (sign > 0) && abs(delta) > 0.3 * .pi / 180
        } ?? false
        guard estimate.inliers >= 0.40, estimate.meanDistance <= 0.013, !atBoundary, !backwards else {
            consecutiveLost += 1
            return .rejected(
                quality: consecutiveLost >= 3 ? .lost : .degraded,
                inliers: estimate.inliers,
                meanMillimetres: estimate.meanDistance * 1000
            )
        }

        if lockedSign == nil, abs(delta) >= 0.2 * .pi / 180 {
            lockedSign = delta > 0 ? 1 : -1
        }
        cumulativeAngle += delta
        passRotation += abs(delta)

        let unrotate = TurntableFusion.rotationMatrix(axis: axis.direction, angleRadians: -cumulativeAngle)
        let yawRotation = TurntableFusion.rotationMatrix(axis: SIMD3<Float>(0, 1, 0), angleRadians: passYaw)
        let worldPoints = objectPoints.map { point in
            let unrotated = axis.point + unrotate * (point - axis.point)
            return yawRotation * TurntableFusion.apply(passTransform, to: unrotated)
        }
        volume.integrate(points: worldPoints, cameraOrigin: passCameraOriginWorld)
        fusedCloud.insert(TurntableFusion.subsample(worldPoints, limit: 6000))
        previousRawPoints = objectPoints
        self.referenceField = VoxelDistanceField(points: sample, voxelSize: 0.005)
        consecutiveLost = 0

        return .accepted(
            deltaDegrees: abs(delta * 180 / .pi),
            inliers: estimate.inliers,
            meanMillimetres: estimate.meanDistance * 1000,
            passRotationDegrees: passRotation * 180 / .pi,
            quality: estimate.inliers >= 0.65 ? .good : .degraded
        )
    }

    /// Re-anchors tracking after a pause: the next frame becomes the
    /// reference without being integrated and without touching the
    /// accumulated angle (the object is assumed not to have moved while
    /// paused — the UI says so).
    func reseedReference(objectPoints: [SIMD3<Float>]) {
        guard objectPoints.count >= 150 else { return }
        referenceField = VoxelDistanceField(
            points: TurntableFusion.subsample(objectPoints, limit: 2000), voxelSize: 0.005)
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
