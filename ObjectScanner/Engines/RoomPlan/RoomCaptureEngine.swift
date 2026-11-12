import Foundation
import Observation
import RoomPlan
import os

/// Room scanning via RoomPlan.
///
/// Deliberately a *different* technique from the object modes rather than a
/// bigger version of them. Photogrammetry solves geometry from surface detail,
/// which a bare painted wall does not have; RoomPlan instead runs LiDAR plus a
/// trained model that recognises walls, doors, windows and furniture, and emits
/// them as understood entities. That is why it succeeds on exactly the surfaces
/// the other modes fail on — and why it will never give you a detailed model of
/// the chair, only a chair-shaped box.
///
/// `RoomCaptureView` brings its own live wireframe and coaching UI, so this
/// engine owns the view and the flow view merely displays it. What is added here
/// is the app's own contract: a workspace, a USDZ at `model.usdz`, a persisted
/// `ScanRecord` — which means preview, thumbnail, export and library all work
/// unchanged.
@MainActor
@Observable
final class RoomCaptureEngine: ScanEngine {
    private static let logger = Logger(subsystem: "com.example.ObjectScanner", category: "roomplan")

    static let kind: ScanEngineKind = .roomPlan

    static var availability: EngineAvailability {
        guard RoomCaptureSession.isSupported else {
            return .unsupportedDevice(reason: String(localized: "Oda taraması LiDAR gerektiriyor; bu cihaz desteklemiyor."))
        }
        return .available
    }

    // MARK: - Observable state

    private(set) var phase: ScanPhase = .idle
    /// Filled in once processing completes, so the result screen can say what was
    /// actually found rather than just "hazır".
    private(set) var summary: RoomSummary?

    /// Chosen before finishing: the export is the only place it matters.
    var exportStyle: RoomExportStyle = .parametric

    /// Also collect stills during the walk and reconstruct a textured model from
    /// them. Must be set before `beginCapture()` — frames not collected during the
    /// walk cannot be recovered afterwards.
    var capturesPhotographicModel = false

    /// The second, photographic model, once it exists. A separate `ScanRecord`
    /// rather than a second file on the first one: they are different geometry from
    /// different techniques, and as two records they inherit preview, thumbnail,
    /// export and the Mac hand-off with no downstream changes at all.
    private(set) var photographicRecord: ScanRecord?

    /// Why there is no photographic model, when one was asked for.
    private(set) var photographicNote: String?

    var keyframeCount: Int { keyframeCollector?.savedCount ?? 0 }

    /// Longest edge of the collected stills, once the first one lands.
    var frameResolution: Int? { keyframeCollector?.frameResolution }

    /// Compass sectors that already have a wall-level frame.
    var wallSectors: Set<Int> { keyframeCollector?.wallSectors ?? [] }

    /// Compass sectors that already have a downward-looking frame.
    var floorSectors: Set<Int> { keyframeCollector?.floorSectors ?? [] }

    /// Live camera heading in radians, for the coverage needle.
    var heading: Double? { keyframeCollector?.heading }

    /// Set when the camera feed has not produced a frame after several seconds.
    ///
    /// Polled from `arSession.currentFrame` rather than observed: taking the
    /// session delegate would switch off `RoomCaptureView`'s own live rendering,
    /// so this is the only non-destructive way to tell "camera never started" from
    /// "camera runs, rendering is broken".
    private(set) var cameraDiagnostic: String?

    /// Owned here rather than by the view so it survives being unmounted while
    /// RoomPlan is still processing the captured data.
    ///
    /// A real starting frame rather than `.zero`: the renderer sizes itself from
    /// the view, and a zero-sized drawable is one of the ways this ends up black.
    let captureView = RoomCaptureView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))

    // MARK: - Private

    private let storage: ScanStorage
    private let reconstructor = PhotogrammetryReconstructor()
    private let delegateProxy = RoomCaptureDelegateProxy()
    private var workspace: ScanWorkspace?
    private var hasStartedSession = false
    private var cameraWatchdog: Task<Void, Never>?

    /// The photographic model gets its own workspace so the two models never
    /// compete for `model.usdz`.
    private var photoWorkspace: ScanWorkspace?
    private var keyframeCollector: RoomKeyframeCollector?

    init(storage: ScanStorage) {
        self.storage = storage
        captureView.delegate = delegateProxy
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

        // Deliberately does *not* run the session yet — see `beginCapture()`.
        phase = .preparing
    }

    /// Starts the capture session. Must be called only once `captureView` is on
    /// screen and laid out.
    ///
    /// Splitting this out of `start()` is not tidiness: running the session while
    /// the view is still detached — which it is for as long as the setup guide is
    /// up — gives a live session rendering into nothing, and the user sees a black
    /// screen with Apple's coaching animation on top of it. Exactly the same trap
    /// as `ObjectCaptureSession.startDetecting()` needing its view mounted first.
    func beginCapture() {
        guard !hasStartedSession, workspace != nil else { return }
        hasStartedSession = true

        var configuration = RoomCaptureSession.Configuration()
        // Apple's own coaching overlay: "move closer to the wall", "slow down".
        // Reimplementing it would mean taking over the session delegate, which is
        // also what draws the live wireframe.
        configuration.isCoachingEnabled = true
        captureView.captureSession.run(configuration: configuration)

        if capturesPhotographicModel {
            startKeyframeCollection()
        }

        phase = .capturing(shots: 0, limit: 0)
        startCameraWatchdog()
    }

    /// Rides along on the AR session RoomPlan is already running, so the stills and
    /// the room come from one walk rather than two.
    private func startKeyframeCollection() {
        do {
            let photoWorkspace = try storage.makeWorkspace()
            self.photoWorkspace = photoWorkspace
            let collector = RoomKeyframeCollector(directory: photoWorkspace.imagesURL)
            collector.start(arSession: captureView.captureSession.arSession)
            keyframeCollector = collector
        } catch {
            // The room scan is the main event; losing the extra model is a note, not
            // a failure.
            Self.logger.error("Kare toplayıcı başlatılamadı: \(error.localizedDescription, privacy: .public)")
            photographicNote = "Fotoğraflı model için çalışma alanı açılamadı: \(error.localizedDescription)"
        }
    }

    func finish() async throws -> ScanRecord {
        guard let workspace else {
            throw ScanEngineError.sessionUnavailable(String(localized: "Aktif oturum yok."))
        }

        guard hasStartedSession else {
            throw ScanEngineError.sessionUnavailable(String(localized: "Kamera oturumu henüz başlamadı."))
        }

        cameraWatchdog?.cancel()
        cameraWatchdog = nil
        keyframeCollector?.stop()
        phase = .reconstructing(ReconstructionProgress())

        let room: CapturedRoom
        do {
            room = try await stopAndProcess()
        } catch {
            phase = .failed(message: error.localizedDescription)
            throw error
        }

        let style = exportStyle
        let modelURL = workspace.modelURL
        do {
            // Off the main actor: `export` writes the whole USDZ synchronously and
            // would visibly freeze the UI on a large room.
            try await Task.detached(priority: .userInitiated) {
                try room.export(to: modelURL, exportOptions: style.options)
            }.value
        } catch {
            Self.logger.error("Oda dışa aktarılamadı: \(error.localizedDescription, privacy: .public)")
            phase = .failed(message: error.localizedDescription)
            throw ScanEngineError.reconstructionFailed(error.localizedDescription)
        }

        let summary = RoomSummary(room: room)
        self.summary = summary

        let record = ScanRecord(
            id: workspace.id,
            name: Self.defaultName(for: Date()),
            engine: Self.kind,
            // ARKit world tracking with LiDAR: the geometry is in real metres.
            isMetricallyScaled: true,
            dimensionsMillimetres: summary.dimensionsMillimetres,
            summary: summary.text
        )
        // Committed before the photographic attempt starts, on purpose: that attempt
        // is the uncertain half, and a room the user walked for two minutes must not
        // be lost to a failure in the optional extra.
        storage.commit(record, workspace: workspace)
        self.workspace = nil

        await reconstructPhotographicModel(roomName: record.name)

        phase = .done(record)
        return record
    }

    /// Turns the collected stills into a textured model.
    ///
    /// Never throws: every outcome here is a note attached to a room scan that has
    /// already been saved.
    private func reconstructPhotographicModel(roomName: String) async {
        guard let photoWorkspace, let collector = keyframeCollector else { return }
        defer {
            self.photoWorkspace = nil
            keyframeCollector = nil
        }

        let frames = collector.savedCount
        guard frames >= RoomKeyframeCollector.minimumFrames else {
            storage.discard(photoWorkspace)
            photographicNote = "Fotoğraflı model için yeterli kare toplanamadı (\(frames)/\(RoomKeyframeCollector.minimumFrames)). Odayı daha geniş dolaşmak gerekiyor."
            return
        }

        do {
            let output = try await reconstructor.reconstruct(
                workspace: photoWorkspace,
                detail: .reduced,
                // The room is the subject. Object masking would try to find a single
                // thing in each frame and cut the rest of the room away.
                enableObjectMasking: false,
                // The cameras walked *through* this subject, so the orbit coverage
                // measures do not apply.
                framing: .interior,
                onWarning: { [weak self] note in
                    self?.photographicNote = note
                }
            ) { [weak self] progress in
                self?.phase = .reconstructing(progress)
            }

            let photoRecord = ScanRecord(
                id: photoWorkspace.id,
                name: "\(roomName) · fotoğraflı",
                engine: Self.kind,
                // Stills alone carry no scale. The parametric model next to it does,
                // which is how this one can be scaled later.
                isMetricallyScaled: false,
                imageCount: frames,
                detail: .reduced,
                summary: output.poses?.summaryText
            )
            storage.commit(photoRecord, workspace: photoWorkspace)
            photographicRecord = photoRecord

            if let advice = output.poses?.advice, !advice.isEmpty {
                photographicNote = advice.joined(separator: " ")
            }
        } catch {
            Self.logger.error("Fotoğraflı model başarısız: \(error.localizedDescription, privacy: .public)")
            storage.discard(photoWorkspace)
            photographicNote = "Fotoğraflı model oluşturulamadı: \(error.localizedDescription)"
        }
    }

    func cancel() {
        cameraWatchdog?.cancel()
        cameraWatchdog = nil
        keyframeCollector?.stop()
        keyframeCollector = nil
        if let photoWorkspace {
            storage.discard(photoWorkspace)
            self.photoWorkspace = nil
        }
        // Clearing the handler first is what tells the proxy to skip the expensive
        // build that `stop()` would otherwise kick off.
        delegateProxy.onProcessed = nil
        // Only if it ever ran: stopping a session that was never started is not
        // something the framework promises to tolerate.
        if hasStartedSession {
            captureView.captureSession.stop()
        }
        if let workspace {
            storage.discard(workspace)
            self.workspace = nil
        }
        phase = .cancelled
    }

    // MARK: - Private

    /// Reports whether the camera is actually delivering frames.
    ///
    /// A black preview has two very different causes and they need opposite fixes,
    /// so guessing is not good enough: no frames at all points at the session
    /// (permissions, a competing capture session, a failed start), while frames
    /// arriving into a black screen points at the view.
    private func startCameraWatchdog() {
        cameraWatchdog = Task { [weak self] in
            var elapsed = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                elapsed += 0.5
                guard let self else { return }
                guard case .capturing = phase else { continue }

                if captureView.captureSession.arSession.currentFrame == nil {
                    if elapsed >= 3 {
                        cameraDiagnostic = "Kamera \(Int(elapsed)) saniyedir kare üretmiyor — ARKit oturumu başlamamış."
                    }
                } else {
                    cameraDiagnostic = nil
                    // Frames are flowing; nothing left for this task to catch.
                    return
                }
            }
        }
    }

    /// Stops capture and waits for RoomPlan to turn the raw data into a room.
    ///
    /// The work happens inside `RoomCaptureView`, which reports back through its
    /// delegate; there is no progress to report along the way.
    private func stopAndProcess() async throws -> CapturedRoom {
        try await withCheckedThrowingContinuation { continuation in
            delegateProxy.onProcessed = { result in
                continuation.resume(with: result)
            }
            captureView.captureSession.stop()
        }
    }

    private static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.dateFormat = "d MMM HH:mm"
        return "Oda \(formatter.string(from: date))"
    }
}

/// Bridges `RoomCaptureView`'s delegate back to the engine.
///
/// Kept separate because `RoomCaptureViewDelegate` inherits `NSCoding` and
/// carries no actor isolation, while the engine is `@MainActor` and
/// `@Observable`; making one type serve both roles means fighting all three.
///
/// `@unchecked Sendable` by main-thread confinement: `RoomCaptureView` is
/// `@MainActor`, so every callback below originates there.
/// The explicit Objective-C name is required, not decorative: `NSCoding` demands a
/// stable archived class name, which a private Swift type does not have.
@objc(OSRoomCaptureDelegateProxy)
private final class RoomCaptureDelegateProxy: NSObject, RoomCaptureViewDelegate, @unchecked Sendable {

    /// One-shot: it backs a continuation, which must be resumed exactly once.
    /// Nil also doubles as "nobody is waiting" — see `captureView(shouldPresent:)`.
    var onProcessed: (@MainActor @Sendable (Result<CapturedRoom, ScanEngineError>) -> Void)?

    override init() { super.init() }

    // NSCoding, inherited via the delegate protocol. Nothing here is archivable
    // and nothing ever archives it.
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {}

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool {
        guard onProcessed != nil else { return false }

        if let error {
            // Returning false means `didPresent` never fires, so this is the only
            // chance to report the failure — otherwise the caller waits forever.
            deliver(.failure(.reconstructionFailed(error.localizedDescription)))
            return false
        }
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: (any Error)?) {
        if let error {
            deliver(.failure(.reconstructionFailed(error.localizedDescription)))
        } else {
            deliver(.success(processedResult))
        }
    }

    private func deliver(_ result: Result<CapturedRoom, ScanEngineError>) {
        guard let handler = onProcessed else { return }
        onProcessed = nil
        // Hopped rather than asserted with `assumeIsolated`: there is nothing to
        // order against here, so a hop costs nothing and cannot trap if RoomPlan
        // ever calls back from somewhere else.
        Task { @MainActor in handler(result) }
    }
}
