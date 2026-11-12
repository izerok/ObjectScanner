import AVFoundation
import Foundation
import os

/// Owns the `AVCaptureSession` for the LiDAR turntable engine and keeps the
/// most recent depth frame available for on-demand sampling.
///
/// Streaming depth output rather than photo capture: the fusion pipeline
/// needs the depth map and its calibration, never the 48 MP still, and a
/// stream lets a shot be "taken" instantly from the latest frame.
final class DepthStreamSession: NSObject, AVCaptureDepthDataOutputDelegate, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.example.ObjectScanner", category: "lidar-turntable")

    enum SetupError: LocalizedError {
        case noLidarCamera
        case configurationFailed(String)

        var errorDescription: String? {
            switch self {
            case .noLidarCamera: String(localized: "LiDAR derinlik kamerası bulunamadı.")
            case .configurationFailed(let detail): detail
            }
        }
    }

    let session = AVCaptureSession()

    private let depthOutput = AVCaptureDepthDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.example.ObjectScanner.lidar.session")
    private let depthQueue = DispatchQueue(label: "com.example.ObjectScanner.lidar.depth")

    private let frameLock = NSLock()
    private var latestDepth: AVDepthData?
    private var latestDepthTimestamp: CMTime = .invalid

    /// Newest depth frame, if the stream has delivered one yet.
    func snapshotDepth() -> AVDepthData? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return latestDepth
    }

    /// Capture timestamp of the newest frame — `AVDepthData` itself does not
    /// carry one in Swift; the delegate receives it alongside.
    var latestTimestamp: CMTime {
        frameLock.lock()
        defer { frameLock.unlock() }
        return latestDepthTimestamp
    }

    func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else {
            throw SetupError.noLidarCamera
        }

        // A depth-capable format is a hard requirement; among those, prefer
        // the largest video dimensions (the depth map scales with the format).
        let depthFormats = device.formats.filter { !$0.supportedDepthDataFormats.isEmpty }
        guard let format = depthFormats.max(by: {
            Int($0.formatDescription.dimensions.width) * Int($0.formatDescription.dimensions.height)
                < Int($1.formatDescription.dimensions.width) * Int($1.formatDescription.dimensions.height)
        }) else {
            throw SetupError.configurationFailed(String(localized: "LiDAR derinlik kamerası bulunamadı."))
        }
        let depthFormat = format.supportedDepthDataFormats.max(by: {
            Int($0.formatDescription.dimensions.width) * Int($0.formatDescription.dimensions.height)
                < Int($1.formatDescription.dimensions.width) * Int($1.formatDescription.dimensions.height)
        })

        session.beginConfiguration()
        // Depth data delivery is documented and sampled against the photo
        // preset; with the default preset the session runs and the preview
        // shows, but the depth delegate may simply never fire. The
        // photogrammetry coordinator in this app uses .photo for the same
        // reason. (v0.3.1: this was the prime suspect for "buttons do
        // nothing" — the stream underneath the UI was never alive.)
        session.sessionPreset = .photo
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            if let depthFormat { device.activeDepthDataFormat = depthFormat }
            device.unlockForConfiguration()

            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw SetupError.configurationFailed(String(localized: "Girdi eklenemedi."))
            }
            session.addInput(input)
        } catch let error as SetupError {
            session.commitConfiguration()
            throw error
        } catch {
            session.commitConfiguration()
            throw SetupError.configurationFailed(error.localizedDescription)
        }

        depthOutput.isFilteringEnabled = true
        depthOutput.setDelegate(self, callbackQueue: depthQueue)
        guard session.canAddOutput(depthOutput) else {
            session.commitConfiguration()
            throw SetupError.configurationFailed(String(localized: "Fotoğraf çıktısı eklenemedi."))
        }
        session.addOutput(depthOutput)
        session.commitConfiguration()

        Self.logger.info("LiDAR derinlik akışı hazır")
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

    // MARK: - AVCaptureDepthDataOutputDelegate

    func depthDataOutput(
        _ output: AVCaptureDepthDataOutput,
        didOutput depthData: AVDepthData,
        timestamp: CMTime,
        connection: AVCaptureConnection
    ) {
        frameLock.lock()
        latestDepth = depthData
        latestDepthTimestamp = timestamp
        frameLock.unlock()
    }

    func depthDataOutput(
        _ output: AVCaptureDepthDataOutput,
        didDrop depthData: AVDepthData,
        timestamp: CMTime,
        connection: AVCaptureConnection,
        reason: AVCaptureOutput.DataDroppedReason
    ) {}
}
