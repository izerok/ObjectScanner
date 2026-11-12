import RealityKit
import SwiftUI

/// Full-screen capture flow for the photogrammetry engine.
///
/// Mirrors `ObjectCaptureSession`'s own state machine rather than inventing a
/// parallel one: the session decides when the object is framed and when an orbit
/// is complete, and this view only ever offers the actions legal in that state.
struct ObjectCaptureFlowView: View {
    @Environment(ScanStorage.self) private var storage
    @Environment(\.dismiss) private var dismiss

    @State private var engine: ObjectCaptureEngine?
    @State private var finishedRecord: ScanRecord?
    @State private var startupError: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let engine {
                content(for: engine)
            } else if let startupError {
                FailureOverlay(message: startupError) { dismiss() }
            } else {
                ProgressView("Hazırlanıyor…")
                    .tint(.white)
            }
        }
        .preferredColorScheme(.dark)
        .task { startIfNeeded() }
        .onDisappear {
            // Only tear down if we're leaving without a result; a committed scan
            // has already released the session.
            if finishedRecord == nil { engine?.cancel() }
        }
    }

    @ViewBuilder
    private func content(for engine: ObjectCaptureEngine) -> some View {
        switch engine.phase {
        // The camera feed must be mounted from the moment the session exists:
        // `startDetecting()` fails while `ObjectCaptureView` is absent, so gating
        // it on `.framing` created a deadlock — detection could never start
        // because the view it depends on was waiting for detection to start.
        case .idle, .preparing, .readyToDetect, .framing, .capturing:
            captureStage(engine: engine)

        case .reconstructing(let progress):
            ReconstructionOverlay(progress: progress)

        case .done(let record):
            CaptureResultView(record: record, poseAdvice: engine.poseAdvice) { dismiss() }
                .task { finishedRecord = record }

        case .failed(let message):
            FailureOverlay(message: message) { dismiss() }

        case .cancelled:
            Color.clear.task { dismiss() }
        }
    }

    private func captureStage(engine: ObjectCaptureEngine) -> some View {
        ZStack {
            if let session = engine.session {
                ObjectCaptureView(session: session)
                    .ignoresSafeArea()
            } else {
                ProgressView("Sensörler hazırlanıyor…")
                    .tint(.white)
            }

            CaptureOverlay(engine: engine, onCancel: {
                engine.cancel()
                dismiss()
            })
        }
    }

    private func startIfNeeded() {
        guard engine == nil else { return }
        let engine = ObjectCaptureEngine(storage: storage)
        do {
            try engine.start()
            self.engine = engine
        } catch {
            startupError = error.localizedDescription
        }
    }
}

// MARK: - Capture overlay

private struct CaptureOverlay: View {
    let engine: ObjectCaptureEngine
    let onCancel: () -> Void

    @State private var isFinishing = false
    @State private var finishError: String?
    @State private var isConfirmingCancel = false
    @State private var isConfirmingFinish = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            hintStack
            actionBar
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        // Abandoning a capture destroys every shot taken so far, so it asks first.
        // Losing a four-minute orbit to a mis-tap is the worst bug in this screen.
        .confirmationDialog(
            "Taramayı iptal et?",
            isPresented: $isConfirmingCancel,
            titleVisibility: .visible
        ) {
            Button("İptal Et ve Çık", role: .destructive, action: onCancel)
            Button("Taramaya Dön", role: .cancel) {}
        } message: {
            Text(engine.shotCount > 0
                 ? "\(engine.shotCount) görüntü silinecek."
                 : "Henüz görüntü yakalanmadı.")
        }
        // `ObjectCaptureSession.start()` requires an empty images directory, so a
        // finished scan can never be reopened to add a pass. Worth saying once,
        // while the object is still on the table.
        .confirmationDialog(
            "Alt yüz eksik kalacak",
            isPresented: $isConfirmingFinish,
            titleVisibility: .visible
        ) {
            Button("Yine de Bitir") { finish() }
            Button("Objeyi Çevireyim", role: .cancel) {}
        } message: {
            Text("Tek yörünge çektiniz. Bitirdikten sonra bu taramaya geçiş eklenemez — alt yüzü istiyorsanız şimdi çevirmeniz gerekiyor.")
        }
        .alert(
            "Model oluşturulamadı",
            isPresented: Binding(get: { finishError != nil }, set: { if !$0 { finishError = nil } })
        ) {
            Button("Tamam") { finishError = nil }
        } message: {
            Text(finishError ?? "")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button {
                isConfirmingCancel = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .tint(.white)
            .accessibilityLabel("Taramayı iptal et")

            Spacer()

            if case .capturing(let shots, let limit) = engine.phase {
                ShotCounter(shots: shots, limit: limit, passes: engine.completedPasses)
            }
        }
        .padding(.top, 4)
    }

    // MARK: Hints

    private var hintStack: some View {
        VStack(spacing: 6) {
            // Tracking trouble outranks framing hints: it is what actually warps
            // the resulting mesh, so it gets the top slot and a warning colour.
            if let warning = engine.trackingWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.9), in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }

            ForEach(engine.hints, id: \.self) { hint in
                Text(hint)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: engine.hints)
        .animation(.easeInOut(duration: 0.2), value: engine.trackingWarning)
        .padding(.bottom, 14)
    }

    // MARK: Actions

    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: 12) {
            switch engine.phase {
            case .idle, .preparing:
                instruction(String(localized: "Sensörler hazırlanıyor…"), systemImage: "circle.dotted")

            case .readyToDetect:
                instruction(String(localized: "Cihazı objeye doğrultun"), systemImage: "viewfinder")
                if let hint = engine.detectionHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                Button("Algılamayı Başlat") { engine.attemptDetection() }
                    .buttonStyle(PrimaryCapsuleStyle())

            case .framing:
                instruction(String(localized: "Objeyi kutunun içine alın"), systemImage: "cube")
                HStack(spacing: 10) {
                    Button("Kutuyu Sıfırla") { engine.resetDetection() }
                        .buttonStyle(SecondaryCapsuleStyle())
                    Button("Taramaya Başla") { engine.beginCapture() }
                        .buttonStyle(PrimaryCapsuleStyle())
                }

            case .capturing where engine.canFinishCurrentPass:
                instruction(String(localized: "Yörünge tamamlandı"), systemImage: "checkmark.circle.fill")
                Text(engine.isObjectFlippable
                     ? "Alt yüzü de istiyorsanız objeyi çevirip devam edin."
                     : "Bu obje çevrilerek taranamıyor — farklı yükseklikten yeni bir yörünge çekebilirsiniz.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    // Hidden rather than disabled when not flippable: the flip API
                    // traps on an object the session has rejected, so there is no
                    // reason to leave the affordance on screen.
                    if engine.isObjectFlippable {
                        Button("Çevir + Devam") { engine.beginPassAfterFlip() }
                            .buttonStyle(SecondaryCapsuleStyle())
                    }
                    Button("Yeni Yörünge") { engine.beginAdditionalPass() }
                        .buttonStyle(SecondaryCapsuleStyle())
                }

                Button {
                    // Only warns when no additional pass has been taken. Asking
                    // every time would train people to dismiss it.
                    if engine.completedPasses == 0 {
                        isConfirmingFinish = true
                    } else {
                        finish()
                    }
                } label: {
                    if isFinishing {
                        ProgressView().tint(.black)
                    } else {
                        Text("Bitir ve Modeli Oluştur")
                    }
                }
                .buttonStyle(PrimaryCapsuleStyle())
                .disabled(isFinishing)

            case .capturing:
                instruction(String(localized: "Objenin etrafında yavaşça dönün"), systemImage: "arrow.trianglehead.2.clockwise.rotate.90")

            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 22))
        .animation(.easeInOut(duration: 0.25), value: engine.canFinishCurrentPass)
        // A closed orbit is the moment the user needs to know about, and their eyes
        // are on the object rather than the screen.
        .sensoryFeedback(.success, trigger: engine.canFinishCurrentPass) { _, new in new }
    }

    private func instruction(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
    }

    private func finish() {
        isFinishing = true
        Task {
            do {
                _ = try await engine.finish()
            } catch is CancellationError {
                // User backed out; the phase change already drives the UI.
            } catch {
                finishError = error.localizedDescription
            }
            isFinishing = false
        }
    }
}

// MARK: - Shot counter

private struct ShotCounter: View {
    let shots: Int
    let limit: Int
    let passes: Int

    private var fraction: Double {
        limit > 0 ? min(Double(shots) / Double(limit), 1) : 0
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 22, height: 22)
            .animation(.easeOut(duration: 0.3), value: fraction)

            VStack(alignment: .leading, spacing: 0) {
                Text("\(shots)")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                if passes > 0 {
                    Text("\(passes + 1). geçiş")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.4), in: Capsule())
    }
}

// MARK: - Reconstruction

private struct ReconstructionOverlay: View {
    let progress: ReconstructionProgress

    var body: some View {
        VStack(spacing: 26) {
            ProgressRing(fraction: progress.fraction)
                .frame(width: 132, height: 132)

            VStack(spacing: 8) {
                Text(progress.stage?.displayName ?? String(localized: "Model oluşturuluyor"))
                    .font(.headline)
                    .contentTransition(.opacity)

                if let remaining = progress.remainingText {
                    Text("\(remaining) kaldı")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: progress.stage)

            StageTrack(current: progress.stage)

            Text("Uygulamayı arka plana almayın — iOS işlemi askıya alır.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
        .padding(28)
        // Reconstruction runs for minutes with no touch input; without this the
        // screen locks and the session is suspended mid-run.
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.15), lineWidth: 8)
            Circle()
                .trim(from: 0, to: max(fraction, 0.001))
                .stroke(
                    AngularGradient(colors: [.accentColor, .accentColor.opacity(0.55)], center: .center),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(Int(fraction * 100))%")
                .font(.title2.weight(.semibold).monospacedDigit())
        }
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

/// Six dots, one per pipeline stage, filled up to the current one.
private struct StageTrack: View {
    let current: ReconstructionStage?

    var body: some View {
        HStack(spacing: 7) {
            ForEach(ReconstructionStage.allCases) { stage in
                Capsule()
                    .fill(fillStyle(for: stage))
                    .frame(width: stage == current ? 22 : 7, height: 7)
            }
        }
        .animation(.spring(duration: 0.35), value: current)
        .accessibilityHidden(true)
    }

    private func fillStyle(for stage: ReconstructionStage) -> Color {
        guard let current else { return .white.opacity(0.2) }
        if stage.rawValue < current.rawValue { return .accentColor.opacity(0.55) }
        if stage == current { return .accentColor }
        return .white.opacity(0.2)
    }
}

// MARK: - Result

private struct CaptureResultView: View {
    let record: ScanRecord
    /// Measured from the solved camera poses, not guessed from the mesh.
    let poseAdvice: [String]
    let onDone: () -> Void

    @Environment(ScanStorage.self) private var storage

    var body: some View {
        // Scrollable: the pose diagnosis can run to three paragraphs.
        ScrollView {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 20) {
            ModelPreviewView(url: storage.modelURL(for: record))
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 6) {
                Label("Tarama hazır", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                if let count = record.imageCount {
                    Text("\(count) görüntü işlendi")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let summary = record.summary {
                    Text(summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            ForEach(poseAdvice, id: \.self) { note in
                Label(note, systemImage: "lightbulb.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Bitti", action: onDone)
                .buttonStyle(PrimaryCapsuleStyle())
                .padding(.horizontal, 40)
        }
        .padding()
        .sensoryFeedback(.success, trigger: record.id)
    }
}

private struct FailureOverlay: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .font(.subheadline)
            Button("Kapat", action: onDismiss)
                .buttonStyle(PrimaryCapsuleStyle())
                .padding(.horizontal, 40)
        }
        .padding(32)
        .sensoryFeedback(.error, trigger: message)
    }
}

// MARK: - Button styles

/// Defined here rather than reaching for `.borderedProminent` because the capture
/// screen sits on a live camera feed: the buttons need fixed, opaque contrast
/// instead of a material that shifts with whatever the lens is pointed at.
private struct PrimaryCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(.white.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
    }
}

private struct SecondaryCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(.white.opacity(configuration.isPressed ? 0.28 : 0.16), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
    }
}
