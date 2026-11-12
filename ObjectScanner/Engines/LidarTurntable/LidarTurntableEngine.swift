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
    private(set) var statusMessage: String?
    private(set) var isProcessingShot = false
    var isAutoCapturing = false {
        didSet { restartAutoCapture() }
    }

    /// Live device pitch (degrees, 0 = camera level), plus the pitch of the
    /// last completed pass — the elevation-change readout.
    private(set) var currentPitchDegrees: Float?
    private(set) var previousPassPitchDegrees: Float?

    var pitchChangeDegrees: Float? {
        guard let currentPitchDegrees, let previousPassPitchDegrees else { return nil }
        return abs(currentPitchDegrees - previousPassPitchDegrees)
    }

    /// Normalised (capture-space) rectangle over the object, fed by the
    /// preview exactly as in the photogrammetry turntable flow.
    var objectMaskRect: CGRect?

    var session: AVCaptureSession? { stream?.session }

    var canFinish: Bool { totalShots >= 8 && fusedPointCount > 500 }

    // MARK: - Private

    private let storage: ScanStorage
    private var workspace: ScanWorkspace?
    private var stream: DepthStreamSession?
    private let core = LidarFusionCore()
    private let motion = CMMotionManager()
    private var autoCaptureTask: Task<Void, Never>?
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
        phase = .framing
        Self.logger.info("LiDAR döner tabla oturumu başladı")
    }

    func finish() async throws -> ScanRecord {
        guard let workspace else {
            throw ScanEngineError.sessionUnavailable(String(localized: "Aktif oturum yok."))
        }
        guard canFinish else {
            throw ScanEngineError.reconstructionFailed(String(localized: "Yeterli kare yok — en az 8 kare ve bir tam tur gerekir."))
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

        let modelURL = workspace.modelURL
        let cloudURL = workspace.root.appending(path: "cloud.ply", directoryHint: .notDirectory)
        let mesh = extracted.mesh
        let points = extracted.points
        do {
            try await Task.detached(priority: .userInitiated) {
                try MeshFileWriter.write(mesh: mesh, to: modelURL)
                if !points.isEmpty {
                    try PointCloudFile.write(points: points, to: cloudURL)
                }
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
            modelFileName: "model.usdz",
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
    /// takes a frame while capturing.
    func primaryAction() {
        guard !isProcessingShot else { return }
        switch passState {
        case .framing: calibrateAndBeginPass()
        case .capturing: captureShot()
        case .awaitingElevation: break
        }
    }

    private func calibrateAndBeginPass() {
        guard let depth = freshDepth() else {
            statusMessage = String(localized: "Derinlik akışı henüz hazır değil — bir saniye bekleyin.")
            return
        }
        guard let mask = objectMaskRect else {
            statusMessage = String(localized: "Önce çerçeveyi objenin üzerine yerleştirin.")
            return
        }
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
                restartAutoCapture()
            }
        }
    }

    private func captureShot() {
        guard let depth = freshDepth() else { return }
        guard let mask = objectMaskRect else { return }
        isProcessingShot = true
        let core = self.core
        let box = DepthFrameBox(depth)
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> LidarFusionCore.ShotResult in
                let objectPoints = TurntableFusion.points(from: box.depth, maskRect: mask, insideMask: true, stride: 2)
                return core.captureShot(objectPoints: objectPoints)
            }.value

            isProcessingShot = false
            fusedPointCount = core.fusedPointCountSnapshot
            switch result {
            case .accepted(let deltaDegrees, let hitRate):
                shotsThisPass += 1
                totalShots += 1
                lastDeltaDegrees = deltaDegrees
                lastHitRate = hitRate
                statusMessage = nil
                phase = .capturing(shots: totalShots, limit: 0)
            case .rejected(let message):
                rejectedShots += 1
                statusMessage = message
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
                try? await Task.sleep(for: .seconds(2.2))
                guard let self, self.isAutoCapturing, self.passState == .capturing else { return }
                if !self.isProcessingShot { self.captureShot() }
            }
        }
    }

    private func teardown() {
        stream = nil
        autoCaptureTask?.cancel()
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

    enum ShotResult: Sendable {
        case accepted(deltaDegrees: Float, hitRate: Float)
        case rejected(message: String)
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
            // Register this pass against the fused model: only yaw is unknown.
            let modelPoints = fusedCloud.sampledPoints(limit: 6000)
            if let estimate = TurntableFusion.estimateYaw(currentWorld: localPoints, modelPoints: modelPoints) {
                yaw = estimate.yawRadians
                if estimate.hitRate < 0.25 {
                    yawWarning = String(localized: "Yeni geçiş önceki modelle zayıf eşleşti — obje yerinden oynamış olabilir.")
                }
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

    func captureShot(objectPoints: [SIMD3<Float>]) -> ShotResult {
        guard let axis = passAxis, let volume else {
            return .rejected(message: String(localized: "Önce çerçeveyi objenin üzerine yerleştirin."))
        }
        guard objectPoints.count >= 150 else {
            return .rejected(message: String(localized: "Çerçeve içinde yeterli derinlik yok — objeye yaklaşın."))
        }
        guard let estimate = TurntableFusion.estimateRotation(
            current: objectPoints,
            previous: previousRawPoints,
            axis: axis,
            lockedSign: lockedSign
        ), estimate.hitRate >= 0.30 else {
            return .rejected(message: String(localized: "Kare hizalanamadı — daha yavaş çevirin, her adım yaklaşık 10° olsun."))
        }

        lockedSign = estimate.sign
        cumulativeAngle += estimate.deltaRadians

        let unrotate = TurntableFusion.rotationMatrix(axis: axis.direction, angleRadians: -cumulativeAngle)
        let yawRotation = TurntableFusion.rotationMatrix(axis: SIMD3<Float>(0, 1, 0), angleRadians: passYaw)
        let worldPoints = objectPoints.map { point in
            let unrotated = axis.point + unrotate * (point - axis.point)
            return yawRotation * TurntableFusion.apply(passTransform, to: unrotated)
        }
        volume.integrate(points: worldPoints, cameraOrigin: passCameraOriginWorld)
        fusedCloud.insert(TurntableFusion.subsample(worldPoints, limit: 6000))
        previousRawPoints = objectPoints

        return .accepted(
            deltaDegrees: abs(estimate.deltaRadians * 180 / .pi),
            hitRate: estimate.hitRate
        )
    }

    func extractMeshAndPoints() -> (mesh: SurfaceNets.Mesh, points: [SIMD3<Float>], dimensions: SIMD3<Float>?)? {
        guard let volume else { return nil }
        let mesh = SurfaceNets.extract(from: volume)
        var cloud = fusedCloud
        cloud.pruneSingleObservations()
        return (mesh, cloud.points, cloud.dimensions)
    }
}

// MARK: - Mesh writing

enum MeshFileWriter {
    /// Writes a surface-nets mesh as USDZ via ModelIO.
    static func write(mesh: SurfaceNets.Mesh, to url: URL) throws {
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
