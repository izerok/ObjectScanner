import AVFoundation
import SwiftUI

/// Capture flow for the pure-LiDAR turntable: device fixed per pass, object
/// rotating, model fused from depth alone. Passes are the unit of work —
/// each pass calibrates its own axis, and moving the phone between passes is
/// a measured step (live pitch readout), never an assumption.
struct LidarTurntableFlowView: View {
    @Environment(ScanStorage.self) private var storage
    @Environment(\.dismiss) private var dismiss

    @State private var engine: LidarTurntableEngine?
    @State private var finishedRecord: ScanRecord?
    @State private var startupError: String?
    @State private var hasSeenGuide = false

    @State private var maskFrame = CGRect(x: 80, y: 240, width: 220, height: 260)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let engine {
                content(for: engine)
            } else if let startupError {
                LidarMessageView(
                    title: String(localized: "Kamera açılamadı"),
                    message: startupError,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange
                ) { dismiss() }
            } else {
                ProgressView("Hazırlanıyor…").tint(.white)
            }
        }
        .preferredColorScheme(.dark)
        .task { startIfNeeded() }
        .onDisappear {
            if finishedRecord == nil { engine?.cancel() }
        }
    }

    @ViewBuilder
    private func content(for engine: LidarTurntableEngine) -> some View {
        switch engine.phase {
        case .idle, .preparing:
            ProgressView("Kamera hazırlanıyor…").tint(.white)

        case .framing, .capturing:
            if hasSeenGuide {
                captureStage(engine: engine)
            } else {
                LidarSetupGuide {
                    hasSeenGuide = true
                } onCancel: {
                    engine.cancel()
                    dismiss()
                }
            }

        case .reconstructing(let progress):
            LidarProgressView(progress: progress)

        case .done(let record):
            LidarResultView(record: record) { dismiss() }
                .task { finishedRecord = record }

        case .failed(let message):
            LidarMessageView(
                title: String(localized: "Tarama başarısız"),
                message: message,
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            ) { dismiss() }

        case .cancelled:
            Color.clear.task { dismiss() }

        default:
            ProgressView("Hazırlanıyor…").tint(.white)
        }
    }

    private func captureStage(engine: LidarTurntableEngine) -> some View {
        ZStack {
            if let session = engine.session {
                CameraPreviewView(session: session, maskFrame: maskFrame) { normalized in
                    engine.objectMaskRect = normalized
                }
                .ignoresSafeArea()
            }

            ObjectMaskRectangle(frame: $maskFrame)
                .allowsHitTesting(engine.passState == .framing)

            LidarOverlay(engine: engine) {
                engine.cancel()
                dismiss()
            }
        }
    }

    private func startIfNeeded() {
        guard engine == nil else { return }
        let engine = LidarTurntableEngine(storage: storage)
        do {
            try engine.start()
            self.engine = engine
        } catch {
            startupError = error.localizedDescription
        }
    }
}

// MARK: - Setup guide

private struct LidarSetupGuide: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label(String(localized: "Saf LiDAR"), systemImage: "sensor.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.white)

                    guideRow(
                        systemImage: "iphone.slash",
                        text: String(localized: "Telefonu sabitleyin, objeyi tabla üzerinde çevirin — model yalnızca LiDAR derinliğinden oluşur, fotoğraf kullanılmaz.")
                    )
                    guideRow(
                        systemImage: "square.dashed",
                        text: String(localized: "Çerçeve objeyi sarsın ama tabla yüzeyinin bir kısmı çerçeve dışında görünsün — dönme ekseni o yüzeyden bulunur.")
                    )
                    guideRow(
                        systemImage: "arrow.up.and.down",
                        text: String(localized: "Geçişler arasında objeye dokunmayın; yalnızca telefonu yeni yüksekliğe taşıyın. Her geçiş kendi eksenini yeniden bulur.")
                    )
                    guideRow(
                        systemImage: "tornado",
                        text: String(localized: "Başladıktan sonra objeyi yavaşça ve durmadan çevirin — bir tur yaklaşık 40-60 saniye sürsün. Takip kaybolursa yavaşça geri çevirin.")
                    )
                    guideRow(
                        systemImage: "paintbrush",
                        text: String(localized: "Desensiz, düz renkli objelerde en iyi sonucu verir; çok parlak ve şeffaf yüzeylerde derinlik ölçülemez.")
                    )
                }
                .padding()
            }

            VStack(spacing: 10) {
                Button(action: onContinue) {
                    Text(String(localized: "Başla"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TurntablePrimaryButton())

                Button(String(localized: "Vazgeç"), action: onCancel)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding()
        }
        .background(Color.black)
    }

    private func guideRow(systemImage: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.yellow)
                .frame(width: 28)
            Text(text)
                .foregroundStyle(.white.opacity(0.9))
                .font(.subheadline)
        }
    }
}

// MARK: - Overlay

private struct LidarOverlay: View {
    let engine: LidarTurntableEngine
    let onCancel: () -> Void

    @State private var isFinishing = false
    @State private var isConfirmingCancel = false
    @State private var finishError: String?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            if let message = engine.statusMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.9), in: Capsule())
                    .padding(.bottom, 8)
            }
            bottomPanel
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .confirmationDialog(String(localized: "Taramayı iptal et?"), isPresented: $isConfirmingCancel, titleVisibility: .visible) {
            Button(String(localized: "İptal Et ve Çık"), role: .destructive, action: onCancel)
            Button(String(localized: "Taramaya Dön"), role: .cancel) {}
        } message: {
            Text(String(localized: "\(engine.totalShots) kare silinecek."))
        }
        .alert(
            String(localized: "Model oluşturulamadı"),
            isPresented: Binding(get: { finishError != nil }, set: { if !$0 { finishError = nil } })
        ) {
            Button(String(localized: "Tamam")) { finishError = nil }
        } message: {
            Text(finishError ?? "")
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                isConfirmingCancel = true
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(10)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .foregroundStyle(.white)

            Spacer()

            Text(String(localized: "Geçiş \(engine.passNumber) · \(engine.shotsThisPass)/\(engine.totalShots) kare · \(engine.fusedPointCount) nokta"))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)

            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var bottomPanel: some View {
        switch engine.passState {
        case .framing:
            VStack(spacing: 10) {
                depthStreamStatusLine
                Text(String(localized: "Çerçeveyi objenin üzerine yerleştirin; tabla kenarı çerçeve dışında kalsın."))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                Button {
                    engine.primaryAction()
                } label: {
                    HStack {
                        if engine.isProcessingShot { ProgressView().tint(.black) }
                        Text(engine.passNumber == 1 ? String(localized: "Kalibre Et ve Başla") : String(localized: "Yeni Geçişi Kalibre Et"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(TurntablePrimaryButton())
                .disabled(engine.isProcessingShot)
            }
            .panelBackground()

        case .capturing:
            VStack(spacing: 10) {
                trackingStatusRow
                ProgressView(value: min(Double(engine.passRotationDegrees), 360), total: 360)
                    .tint(trackingTint)
                statsRow
                HStack(spacing: 10) {
                    Button {
                        engine.primaryAction()
                    } label: {
                        Label(
                            engine.trackingPaused ? String(localized: "Devam Et") : String(localized: "Duraklat"),
                            systemImage: engine.trackingPaused ? "play.fill" : "pause.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TurntablePrimaryButton())

                    Button {
                        engine.beginElevationChange()
                    } label: {
                        Label(String(localized: "Yüksekliği Değiştir"), systemImage: "arrow.up.and.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TurntableSecondaryButton())
                }
                Button {
                    finish()
                } label: {
                    HStack {
                        if isFinishing { ProgressView().tint(.black) }
                        Text(String(localized: "Bitir ve Modeli Oluştur"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(TurntablePrimaryButton())
                .disabled(!engine.canFinish || isFinishing)
                if engine.passRotationDegrees >= 355 {
                    Text(String(localized: "Bir tur tamamlandı — böyle devam edebilir veya yüksekliği değiştirebilirsiniz."))
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .multilineTextAlignment(.center)
                }
            }
            .panelBackground()

        case .awaitingElevation:
            VStack(spacing: 10) {
                Label(String(localized: "Yüksekliği Değiştirin"), systemImage: "arrow.up.and.down")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(String(localized: "Telefonu yeni yüksekliğe taşıyın; obje ve tablaya dokunmayın."))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                HStack(spacing: 16) {
                    pitchReadout(
                        title: String(localized: "Önceki geçiş eğimi"),
                        value: engine.previousPassPitchDegrees
                    )
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.white.opacity(0.6))
                    pitchReadout(
                        title: String(localized: "Şu anki eğim"),
                        value: engine.currentPitchDegrees
                    )
                }
                if let change = engine.pitchChangeDegrees, change >= 10 {
                    Label(String(localized: "Yükseklik değişimi algılandı"), systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                }
                Button {
                    engine.confirmNewElevation()
                } label: {
                    Text(String(localized: "Yeni Yükseklik Hazır — Çerçeveyi Ayarla"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TurntablePrimaryButton())
            }
            .panelBackground()
        }
    }

    private var depthStreamStatusLine: some View {
        HStack(spacing: 6) {
            switch engine.depthStreamState {
            case .waiting:
                ProgressView().tint(.white).scaleEffect(0.7)
                Text(String(localized: "Derinlik akışı bekleniyor…"))
            case .live:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(String(localized: "Derinlik akışı hazır"))
            case .stalled:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(String(localized: "Derinlik akışı kesildi"))
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white.opacity(0.9))
    }

    private var trackingTint: Color {
        switch engine.trackingQuality {
        case .good: return .green
        case .degraded: return .yellow
        case .lost: return .red
        }
    }

    private var trackingStatusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(trackingTint)
                .frame(width: 10, height: 10)
            Text(
                engine.trackingPaused
                    ? String(localized: "Duraklatıldı")
                    : engine.trackingQuality == .good
                        ? String(localized: "Takip iyi")
                        : engine.trackingQuality == .degraded
                            ? String(localized: "Takip zayıf")
                            : String(localized: "Takip kayboldu")
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            Spacer()
            Text(String(localized: "Tur: \(Int(engine.passRotationDegrees.rounded()))° / 360°"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var statsRow: some View {
        HStack(spacing: 14) {
            if !engine.isDepthLive {
                Label(String(localized: "Derinlik akışı kesildi"), systemImage: "sensor.fill")
                    .foregroundStyle(.orange)
            }
            Label("\(Int(engine.rotationSpeedDegPerSec.rounded()))°/s", systemImage: "speedometer")
            Label("\(engine.totalShots)", systemImage: "square.stack.3d.up")
            if engine.rejectedShots > 0 {
                Label("\(engine.rejectedShots)", systemImage: "camera.metering.none")
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white.opacity(0.9))
    }

    private func pitchReadout(title: String, value: Float?) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
            Text(value.map { "\(Int($0.rounded()))°" } ?? "—")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
        }
    }

    private func finish() {
        isFinishing = true
        Task {
            do {
                _ = try await engine.finish()
            } catch {
                finishError = error.localizedDescription
            }
            isFinishing = false
        }
    }
}

// MARK: - Progress / result / message

private struct LidarProgressView: View {
    let progress: ReconstructionProgress

    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: progress.fraction)
                .tint(.yellow)
                .padding(.horizontal, 40)
            if let stage = progress.stage {
                Label(stage.displayName, systemImage: stage.symbolName)
                    .foregroundStyle(.white)
            }
            Text(String(localized: "Model oluşturuluyor…"))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

private struct LidarResultView: View {
    let record: ScanRecord
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
            Text(String(localized: "Model hazır"))
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text(record.name)
                .foregroundStyle(.white.opacity(0.85))
            if let summary = record.summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let dimensions = record.dimensionsMillimetres, dimensions.count == 3 {
                Text("\(dimensions[0]) × \(dimensions[1]) × \(dimensions[2]) mm")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            Button(action: onDone) {
                Text(String(localized: "Tamam"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TurntablePrimaryButton())
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .padding()
    }
}

private struct LidarMessageView: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(tint)
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text(message)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            Button(action: onDismiss) {
                Text(String(localized: "Tamam"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TurntablePrimaryButton())
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .padding()
    }
}

// MARK: - Shared styling

private extension View {
    func panelBackground() -> some View {
        self
            .padding(12)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
    }
}
