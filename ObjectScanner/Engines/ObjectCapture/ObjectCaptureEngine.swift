import Foundation
import Observation
import RealityKit
// `ObjectCaptureSession` lives in the RealityKit↔SwiftUI cross-import overlay,
// so it only resolves in a file that imports both modules.
import SwiftUI
import os

/// Phase 1 engine: guided photogrammetry via `ObjectCaptureSession`.
///
/// The session drives its own state machine; this class translates that machine
/// into `ScanPhase`, owns the workspace, and chains reconstruction on the end.
@MainActor
@Observable
final class ObjectCaptureEngine: ScanEngine {
    private static let logger = Logger(subsystem: "com.example.ObjectScanner", category: "objectcapture")

    static let kind: ScanEngineKind = .objectCapture

    static var availability: EngineAvailability {
        guard DeviceCapabilities.supportsObjectCapture else {
            return .unsupportedDevice(reason: String(localized: "Object Capture bu cihazda desteklenmiyor. LiDAR'lı bir iPhone/iPad Pro gerekiyor."))
        }
        guard DeviceCapabilities.supportsPhotogrammetry else {
            return .unsupportedDevice(reason: String(localized: "Bu cihaz cihaz-üstü fotogrametriyi desteklemiyor."))
        }
        return .available
    }

    // MARK: - Observable state

    private(set) var phase: ScanPhase = .idle

    /// Handed to `ObjectCaptureView`. Non-nil from `start()` until teardown.
    private(set) var session: ObjectCaptureSession?

    /// Live coaching hints, already turned into Turkish sentences.
    private(set) var hints: [String] = []

    /// Set when world tracking degrades — the usual cause of a warped mesh.
    private(set) var trackingWarning: String?

    /// Why detection has not started yet, shown while in `.readyToDetect`.
    private(set) var detectionHint: String?

    /// False once the session reports the object cannot be turned over. Latched
    /// rather than momentary — the feedback appears briefly and the answer does
    /// not change for the rest of the scan.
    private(set) var isObjectFlippable = true

    /// True once the user has orbited the object fully. Until then, finishing
    /// yields a one-sided model, so the UI withholds the finish button.
    private(set) var canFinishCurrentPass = false

    private(set) var completedPasses = 0
    private(set) var shotCount = 0

    /// What the solved camera poses say about the capture, shown with the result.
    /// Empty when the numbers look healthy — advice nobody needs is noise.
    private(set) var poseAdvice: [String] = []

    // MARK: - Private

    private let storage: ScanStorage
    private let reconstructor = PhotogrammetryReconstructor()
    private var workspace: ScanWorkspace?
    private var observers: [Task<Void, Never>] = []
    private var detectionRetry: Task<Void, Never>?
    private var passTransition: Task<Void, Never>?

    /// Resumed by the state observer when the session reaches `.completed`, so
    /// `finish()` can await capture teardown before reconstructing. The state
    /// stream has a single consumer — this is how a second waiter hooks in.
    private var completionWaiter: CheckedContinuation<Void, Error>?

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

        let session = ObjectCaptureSession()
        self.session = session
        observe(session)

        var configuration = ObjectCaptureSession.Configuration()
        configuration.checkpointDirectory = workspace.checkpointURL
        // More input images than the guided minimum. Costs capture time and disk,
        // buys mesh coverage — the right trade for a geometry-first app.
        configuration.isOverCaptureEnabled = true

        session.start(imagesDirectory: workspace.imagesURL, configuration: configuration)

        // Capture happens while the user is looking at the object, not the screen,
        // so the per-shot tick is the main feedback channel.
        session.shouldPlayHaptics = true
    }

    func finish() async throws -> ScanRecord {
        guard let session, let workspace else {
            throw ScanEngineError.sessionUnavailable(String(localized: "Aktif oturum yok."))
        }

        // iOS offers exactly one detail level for on-device photogrammetry, so
        // there is nothing to choose. See `ReconstructionDetail`.
        let detail = ReconstructionDetail.reduced

        // Ask the capture session to wrap up, then wait for it to actually reach
        // `.completed`: its writes to the images directory are not all flushed
        // when `finish()` returns.
        if session.state != .completed {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                completionWaiter = continuation
                session.finish()
            }
        }

        let capturedShots = shotCount
        phase = .reconstructing(ReconstructionProgress())

        let output: PhotogrammetryReconstructor.Output
        do {
            output = try await reconstructor.reconstruct(workspace: workspace, detail: detail) { [weak self] progress in
                self?.phase = .reconstructing(progress)
            }
        } catch {
            phase = .failed(message: error.localizedDescription)
            throw error
        }

        // Recorded for both modes on purpose: the same three numbers are what make
        // an orbit pass and a turntable pass directly comparable.
        if let poses = output.poses {
            poseAdvice = poses.advice
        }

        let record = ScanRecord(
            id: workspace.id,
            name: Self.defaultName(for: Date()),
            engine: Self.kind,
            isMetricallyScaled: true,
            imageCount: capturedShots,
            detail: detail,
            summary: output.poses?.summaryText
        )
        storage.commit(record, workspace: workspace)

        teardownObservers()
        self.session = nil
        phase = .done(record)
        return record
    }

    func cancel() {
        teardownObservers()
        completionWaiter?.resume(throwing: ScanEngineError.cancelled)
        completionWaiter = nil
        session?.cancel()
        session = nil
        if let workspace {
            storage.discard(workspace)
            self.workspace = nil
        }
        phase = .cancelled
    }

    // MARK: - Capture flow, driven by the UI

    /// Try to move from `.readyToDetect` into `.detecting`.
    ///
    /// Retried on a short delay rather than once, because the precondition it
    /// depends on — a mounted, tracking camera feed — becomes true a moment after
    /// the session reports `.ready`.
    func attemptDetection(retriesRemaining: Int = 8) {
        guard let session, session.state == .ready else { return }

        if session.startDetecting() {
            detectionHint = nil
            return
        }

        Self.logger.debug(
            "startDetecting() false — durum: \(String(describing: session.state), privacy: .public), takip: \(String(describing: session.cameraTracking), privacy: .public)"
        )

        guard retriesRemaining > 0 else {
            detectionHint = String(localized: "Algılama başlamadı. Cihazı objeye doğrultup tekrar deneyin.")
            return
        }

        detectionHint = session.cameraTracking.warning ?? String(localized: "Cihazı objeye doğrultun")
        detectionRetry?.cancel()
        detectionRetry = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.attemptDetection(retriesRemaining: retriesRemaining - 1)
        }
    }

    /// Accept the detected bounding box and begin orbiting.
    func beginCapture() {
        session?.startCapturing()
    }

    /// Re-run object detection, e.g. the box latched onto the table instead.
    func resetDetection() {
        session?.resetDetection()
    }

    /// Another orbit at a different height, object left in place.
    func beginAdditionalPass() {
        beginPass(flipped: false)
    }

    /// Another orbit after turning the object over, to capture its underside.
    func beginPassAfterFlip() {
        beginPass(flipped: true)
    }

    /// Starts the next scan pass.
    ///
    /// Both begin-pass calls require a **paused** session; from `.capturing`
    /// RealityKit logs "Must be .paused from .capturing" and then *traps* rather
    /// than throwing, so an unpaused call takes the whole app down. `pause()` is
    /// also not synchronous, hence the bounded wait: the API is only ever called
    /// once `isPaused` is actually observed to be true.
    private func beginPass(flipped: Bool) {
        guard let session, session.state == .capturing else { return }

        passTransition?.cancel()
        passTransition = Task { [weak self] in
            if !session.isPaused { session.pause() }

            var pausedConfirmed = session.isPaused
            for _ in 0..<20 where !pausedConfirmed {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                pausedConfirmed = session.isPaused
            }

            guard let self, !Task.isCancelled else { return }

            guard pausedConfirmed else {
                Self.logger.error("Oturum duraklatılamadı, geçiş iptal edildi")
                self.detectionHint = String(localized: "Oturum duraklatılamadı. Bitirip modeli oluşturmayı deneyin.")
                return
            }

            if flipped {
                session.beginNewScanPassAfterFlip()
            } else {
                session.beginNewScanPass()
            }
            session.resume()

            self.completedPasses += 1
            self.canFinishCurrentPass = false
        }
    }

    // MARK: - Observation

    /// Each observable property has its own `Updates` stream; using them beats
    /// polling `session` on a timer, which is what an earlier draft did.
    private func observe(_ session: ObjectCaptureSession) {
        observers = [
            Task { [weak self] in
                for await state in session.stateUpdates {
                    guard let self else { return }
                    self.handle(state: state, session: session)
                }
            },
            Task { [weak self] in
                for await feedback in session.feedbackUpdates {
                    guard let self else { return }
                    self.hints = feedback.compactMap(\.hint)
                    // There is no `isObjectFlippable` property on the session — the
                    // only signal is this feedback, so it is latched here to keep
                    // the flip button from offering an impossible pass.
                    if feedback.contains(.objectNotFlippable) {
                        self.isObjectFlippable = false
                    }
                }
            },
            Task { [weak self] in
                for await shots in session.numberOfShotsTakenUpdates {
                    guard let self else { return }
                    self.shotCount = shots
                    if case .capturing = self.phase {
                        self.phase = .capturing(shots: shots, limit: session.maximumNumberOfInputImages)
                    }
                    // `cameraTrackingUpdates` is unusable: it is typed
                    // `Updates<Tracking>`, but the SDK never declares `Tracking`
                    // as `Sendable` (unlike `CaptureState` and `Feedback`), so the
                    // stream fails its own generic constraint. Reading the
                    // main-actor property alongside the shot counter gets the same
                    // information without crossing isolation.
                    self.trackingWarning = session.cameraTracking.warning
                }
            },
            Task { [weak self] in
                for await completed in session.userCompletedScanPassUpdates {
                    guard let self else { return }
                    self.canFinishCurrentPass = completed
                }
            },
        ]
    }

    private func handle(state: ObjectCaptureSession.CaptureState, session: ObjectCaptureSession) {
        Self.logger.debug("Oturum durumu: \(String(describing: state), privacy: .public)")

        switch state {
        case .initializing:
            phase = .preparing

        case .ready:
            // `startDetecting()` needs the camera feed already on screen, and
            // `.ready` can arrive before SwiftUI has mounted `ObjectCaptureView`.
            // A `false` here means "not yet", not "broken" — so it drops into
            // `.readyToDetect` and the user (or the retry below) tries again.
            phase = .readyToDetect
            attemptDetection()

        case .detecting:
            detectionRetry?.cancel()
            detectionRetry = nil
            detectionHint = nil
            phase = .framing

        case .capturing:
            phase = .capturing(shots: session.numberOfShotsTaken, limit: session.maximumNumberOfInputImages)

        case .finishing:
            break

        case .completed:
            completionWaiter?.resume()
            completionWaiter = nil

        case .failed(let error):
            completionWaiter?.resume(throwing: error)
            completionWaiter = nil
            phase = .failed(message: Self.describe(error))

        @unknown default:
            break
        }
    }

    private func teardownObservers() {
        for observer in observers { observer.cancel() }
        observers = []
        detectionRetry?.cancel()
        detectionRetry = nil
        passTransition?.cancel()
        passTransition = nil
        hints = []
        trackingWarning = nil
        detectionHint = nil
    }

    /// `ObjectCaptureSession.Error` cases carry actionable detail that
    /// `localizedDescription` alone buries.
    private static func describe(_ error: Error) -> String {
        guard let sessionError = error as? ObjectCaptureSession.Error else {
            return error.localizedDescription
        }
        switch sessionError {
        case .insufficientStorage(let requiredBytes):
            let needed = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
            return "Depolama yetersiz — en az \(needed) boş alan gerekiyor."
        case .directoryNotEmpty:
            return String(localized: "Çalışma klasörü boş değil. Uygulamayı yeniden başlatın.")
        case .sensorFailed:
            return String(localized: "Kamera veya derinlik sensörü yanıt vermedi.")
        case .trackingFailed:
            return String(localized: "Konum takibi kaybedildi. Daha dokulu bir zemin ve sabit ışık deneyin.")
        case .cancelled:
            return "Tarama iptal edildi."
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.dateFormat = "d MMM HH:mm"
        return "Tarama \(formatter.string(from: date))"
    }
}
