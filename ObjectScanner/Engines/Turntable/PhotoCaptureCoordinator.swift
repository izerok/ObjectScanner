import AVFoundation
import os

/// Owns the `AVCaptureSession` for turntable capture and writes stills to disk.
///
/// Separate from the engine because AVFoundation delivers on its own queues and
/// wants an `NSObject` delegate, while the engine is a main-actor observable.
final class PhotoCaptureCoordinator: NSObject, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.example.ObjectScanner", category: "turntable")

    enum SetupError: LocalizedError {
        case noCamera
        case configurationFailed(String)
        case noPhotoData

        var errorDescription: String? {
            switch self {
            case .noCamera: String(localized: "Arka kamera bulunamadı.")
            case .configurationFailed(let detail): "Kamera yapılandırılamadı: \(detail)"
            case .noPhotoData: String(localized: "Fotoğraf verisi alınamadı.")
            }
        }
    }

    let session = AVCaptureSession()

    /// True when the capture device can attach depth to each photo. Without it the
    /// reconstruction still works but comes out unscaled, so the caller records the
    /// difference on the `ScanRecord` instead of quietly claiming real dimensions.
    private(set) var deliversDepth = false

    /// Largest photo resolution the active format offers, in megapixels — surfaced so
    /// the UI can show what it is actually capturing at.
    private(set) var megapixels = 0

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.example.ObjectScanner.turntable")
    private let imagesDirectory: URL

    private var device: AVCaptureDevice?
    private var maxDimensions = CMVideoDimensions(width: 0, height: 0)

    /// One delegate per in-flight photo, keyed by settings id — the shape
    /// `AVCapturePhotoOutput` expects, since it only holds the delegate weakly.
    private var pendingCaptures: [Int64: PhotoDelegate] = [:]
    private let pendingLock = NSLock()

    private var shotIndex = 0

    /// Best sharpness observed this session, used as the reference for rejection.
    /// Absolute sharpness values mean nothing across scenes; relative ones do.
    private var bestSharpness: Float = 0

    /// A frame scoring below this fraction of the session best is discarded.
    private let sharpnessFloor: Float = 0.45

    private let onShotSaved: @Sendable (Int) -> Void
    private let onShotRejected: @Sendable (String) -> Void
    private let onFailure: @Sendable (String) -> Void

    init(
        imagesDirectory: URL,
        onShotSaved: @escaping @Sendable (Int) -> Void,
        onShotRejected: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.imagesDirectory = imagesDirectory
        self.onShotSaved = onShotSaved
        self.onShotRejected = onShotRejected
        self.onFailure = onFailure
        super.init()
    }

    // MARK: - Lifecycle

    func configure() throws {
        // Prefer the LiDAR-backed device: it is the only way to get depth attached
        // to the photos, and depth is what carries metric scale through to the mesh.
        let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)

        guard let device else { throw SetupError.noCamera }
        self.device = device

        session.beginConfiguration()
        session.sessionPreset = .photo

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw SetupError.configurationFailed("Girdi eklenemedi.")
            }
            session.addInput(input)
        } catch let error as SetupError {
            session.commitConfiguration()
            throw error
        } catch {
            session.commitConfiguration()
            throw SetupError.configurationFailed(error.localizedDescription)
        }

        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            throw SetupError.configurationFailed(String(localized: "Fotoğraf çıktısı eklenemedi."))
        }
        session.addOutput(photoOutput)

        // Must be raised on the output before any per-shot request can ask for it.
        photoOutput.maxPhotoQualityPrioritization = .quality

        // Photogrammetry detail scales directly with pixels on the subject, so take
        // the largest resolution the active format supports rather than the default.
        if let largest = device.activeFormat.supportedMaxPhotoDimensions
            .max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            maxDimensions = largest
            photoOutput.maxPhotoDimensions = largest
            megapixels = Int((Double(largest.width) * Double(largest.height) / 1_000_000).rounded())
        }

        if photoOutput.isDepthDataDeliverySupported {
            photoOutput.isDepthDataDeliveryEnabled = true
            deliversDepth = true
        }

        session.commitConfiguration()

        // Stabilisation warps pixels relative to the published intrinsics, which is
        // exactly what the solver relies on.
        if let connection = photoOutput.connection(with: .video), connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }

        Self.logger.info("Turntable kamerası hazır — \(self.megapixels, privacy: .public) MP, derinlik: \(self.deliversDepth, privacy: .public)")
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// Waits until every in-flight capture has been fully handled — file
    /// written and sharpness judged — bounded by `timeout`.
    ///
    /// `stop()` only stops the session; photo processing continues on its
    /// own. `finish()` enumerates the images directory for reconstruction,
    /// so a capture still in flight at that point would either be missed
    /// by the solver or deleted mid-enumeration by the sharpness check
    /// (v0.7: drain before enumerating — the race was long-standing).
    func drainPendingCaptures(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            pendingLock.lock()
            let pending = pendingCaptures.count
            pendingLock.unlock()
            if pending == 0 { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Self.logger.error("Kalan çekimler zaman aşımında boşaltılamadı")
    }

    // MARK: - Locking

    /// Converges focus, exposure and white balance once, then freezes all three.
    ///
    /// This matters more than it sounds. Refocusing between shots causes focus
    /// breathing — the effective focal length shifts, so the intrinsics the solver
    /// assumes no longer match the image. Drifting exposure and white balance change
    /// the appearance of the same physical point from frame to frame, which is
    /// exactly what feature matching is trying to rely on. A turntable keeps the
    /// subject at a fixed distance, so there is nothing to gain from tracking.
    ///
    /// - Parameter completion: called once the settings are locked, or immediately if
    ///   the device cannot lock.
    func lockCameraSettings(completion: @escaping @Sendable (Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else {
                completion(false)
                return
            }

            do {
                try device.lockForConfiguration()
            } catch {
                completion(false)
                return
            }

            // One-shot converge on the centre of the frame, where the object is.
            let centre = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = centre }
            if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = centre }
            if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
            if device.isWhiteBalanceModeSupported(.autoWhiteBalance) {
                device.whiteBalanceMode = .autoWhiteBalance
            }
            device.unlockForConfiguration()

            // Wait for convergence before freezing, otherwise a blurry focus gets
            // locked in. Polled rather than observed: bounded, and this queue is
            // already serial.
            for _ in 0..<40 where device.isAdjustingFocus || device.isAdjustingExposure || device.isAdjustingWhiteBalance {
                Thread.sleep(forTimeInterval: 0.05)
            }

            guard (try? device.lockForConfiguration()) != nil else {
                completion(false)
                return
            }
            if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            device.unlockForConfiguration()

            Self.logger.info("Odak, pozlama ve beyaz dengesi kilitlendi")
            completion(true)
        }
    }

    // MARK: - Capture

    func capture() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }

            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }

            if self.maxDimensions.width > 0 {
                settings.maxPhotoDimensions = self.maxDimensions
            }
            settings.photoQualityPrioritization = .quality

            if self.photoOutput.isDepthDataDeliveryEnabled {
                settings.isDepthDataDeliveryEnabled = true
                // Embedding rather than handling depth separately means
                // `PhotogrammetrySession` picks it up straight from the file, and
                // the existing folder-based reconstruction path stays untouched.
                settings.embedsDepthDataInPhoto = true
            }

            // A small preview accompanies the full-resolution photo and is what the
            // sharpness check runs on — measuring 48 MP would cost far more than the
            // decision is worth.
            if let previewFormat = settings.availablePreviewPhotoPixelFormatTypes.first {
                settings.previewPhotoFormat = [
                    kCVPixelBufferPixelFormatTypeKey as String: previewFormat,
                    kCVPixelBufferWidthKey as String: 512,
                    kCVPixelBufferHeightKey as String: 384,
                ]
            }

            self.shotIndex += 1
            let index = self.shotIndex
            let destination = self.imagesDirectory
                .appending(path: String(format: "shot_%04d.heic", index), directoryHint: .notDirectory)

            // Lifted out before the closure: `AVCapturePhotoSettings` is not
            // `Sendable`, but its id is a plain `Int64`.
            let settingsID = settings.uniqueID

            let delegate = PhotoDelegate(destination: destination) { [weak self] result in
                guard let self else { return }
                // Handle first, unregister after: `drainPendingCaptures`
                // reads an empty pending set as "every file is final", so
                // the entry must outlive the handling itself (the sharpness
                // check can still delete the file inside `handle`).
                self.handle(result: result, index: index, destination: destination)
                self.pendingLock.lock()
                self.pendingCaptures[settingsID] = nil
                self.pendingLock.unlock()
            }

            self.pendingLock.lock()
            self.pendingCaptures[settingsID] = delegate
            self.pendingLock.unlock()

            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    private func handle(result: Result<PhotoDelegate.Capture, Error>, index: Int, destination: URL) {
        switch result {
        case .failure(let error):
            onFailure(error.localizedDescription)

        case .success(let capture):
            guard let sharpness = capture.sharpness else {
                // No usable preview to judge; keeping the frame beats guessing.
                onShotSaved(index)
                return
            }

            bestSharpness = max(bestSharpness, sharpness)

            if sharpness < bestSharpness * sharpnessFloor {
                // Discarded on purpose: a soft frame contributes wrong matches, and
                // the auto-capture loop will cover this angle again shortly.
                try? FileManager.default.removeItem(at: destination)
                shotIndex -= 1
                Self.logger.debug("Bulanık kare atıldı: \(sharpness, privacy: .public) / \(self.bestSharpness, privacy: .public)")
                onShotRejected(String(localized: "Bulanık kare atlandı — daha yavaş çevirin"))
            } else {
                onShotSaved(index)
            }
        }
    }
}

/// One-shot photo delegate: writes the file, scores its preview and reports back.
private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    struct Capture {
        var sharpness: Float?
    }

    private let destination: URL
    private let completion: @Sendable (Result<Capture, Error>) -> Void

    init(destination: URL, completion: @escaping @Sendable (Result<Capture, Error>) -> Void) {
        self.destination = destination
        self.completion = completion
        super.init()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            completion(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(PhotoCaptureCoordinator.SetupError.noPhotoData))
            return
        }

        let sharpness = photo.previewPixelBuffer.flatMap(SharpnessMeter.score)

        do {
            try data.write(to: destination, options: .atomic)
            completion(.success(Capture(sharpness: sharpness)))
        } catch {
            completion(.failure(error))
        }
    }
}
