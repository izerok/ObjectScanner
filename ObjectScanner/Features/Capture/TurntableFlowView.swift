import AVFoundation
import SwiftUI

/// Capture flow for turntable photogrammetry: device fixed, object rotating.
struct TurntableFlowView: View {
    @Environment(ScanStorage.self) private var storage
    @Environment(\.dismiss) private var dismiss

    @State private var engine: TurntableCaptureEngine?
    @State private var finishedRecord: ScanRecord?
    @State private var startupError: String?
    @State private var hasSeenSetupTips = false

    /// Screen-space rectangle the user places over the object.
    @State private var maskFrame = CGRect(x: 80, y: 240, width: 220, height: 260)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let engine {
                content(for: engine)
            } else if let startupError {
                TurntableMessageView(
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
    private func content(for engine: TurntableCaptureEngine) -> some View {
        switch engine.phase {
        case .idle, .preparing:
            ProgressView("Kamera hazırlanıyor…").tint(.white)

        case .readyToDetect, .framing, .capturing:
            if hasSeenSetupTips {
                captureStage(engine: engine)
            } else {
                // The turntable setup has one make-or-break requirement, and showing
                // it after a failed 40-shot session would be too late.
                TurntableSetupGuide(deliversDepth: engine.deliversDepth) {
                    hasSeenSetupTips = true
                } onCancel: {
                    engine.cancel()
                    dismiss()
                }
            }

        case .reconstructing(let progress):
            TurntableReconstructionView(progress: progress)

        case .done(let record):
            TurntableResultView(record: record, warnings: engine.warnings) { dismiss() }
                .task { finishedRecord = record }

        case .failed(let message):
            TurntableMessageView(
                title: String(localized: "Tarama başarısız"),
                message: message,
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            ) { dismiss() }

        case .cancelled:
            Color.clear.task { dismiss() }
        }
    }

    private func captureStage(engine: TurntableCaptureEngine) -> some View {
        ZStack {
            if let session = engine.session {
                // The frame is reported back through a binding rather than read from
                // the view: converting layer coordinates to capture coordinates needs
                // the preview layer, which only this wrapper owns.
                CameraPreviewView(session: session, maskFrame: maskFrame) { normalized in
                    engine.objectMaskRect = normalized
                }
                .ignoresSafeArea()
            }

            ObjectMaskRectangle(frame: $maskFrame)

            TurntableOverlay(engine: engine) {
                engine.cancel()
                dismiss()
            }
        }
    }

    private func startIfNeeded() {
        guard engine == nil else { return }
        let engine = TurntableCaptureEngine(storage: storage)
        do {
            try engine.start()
            self.engine = engine
        } catch {
            startupError = error.localizedDescription
        }
    }
}

// MARK: - Setup guide

private struct TurntableSetupGuide: View {
    let deliversDepth: Bool
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Döner tabla kurulumu")
                    .font(.title2.bold())

                // Now that a mask is supplied, the backdrop is no longer the thing
                // that makes or breaks the capture — so it is demoted and the mask
                // takes the top slot instead. Overstating a requirement the app has
                // since solved just trains people to ignore the guide.
                requirement(
                    String(localized: "Sarı çerçeveyi objenin üzerine yerleştir"),
                    detail: String(localized: "Sürükleyerek taşı, iki parmakla boyutlandır. Sadece çerçevenin içi modellenir — masa, kâğıt ve arka plan tamamen dışlanır. Telefon sabit olduğu için tek çerçeve bütün kareler için geçerli."),
                    systemImage: "viewfinder.rectangular",
                    isCritical: true
                )

                requirement(
                    String(localized: "Arka plan sade olursa yine iyi olur"),
                    detail: String(localized: "Çerçeve işi çözüyor ama kenarları objeye çok yakınsa yardımcı olur: mümkünse arka planı biraz geriye al, yan yana kâğıt yerine tek parça bir fon kullan."),
                    systemImage: "square.dashed"
                )

                requirement(
                    String(localized: "Telefon sabit dursun"),
                    detail: String(localized: "Tripod veya bir desteğe yasla. Çekim sırasında telefona dokunma."),
                    systemImage: "iphone.gen3"
                )

                requirement(
                    String(localized: "Objeyi adım adım döndür"),
                    detail: String(localized: "Her karede ~10° çevir, kısa bir an bekle. Sürekli döndürmek hareket bulanıklığı yapar ve eşleşmeyi bozar."),
                    systemImage: "arrow.trianglehead.clockwise"
                )

                // Promoted to critical: this is the one thing that makes turntable
                // capture structurally harder than orbiting, not just different.
                // Walking around a lit object keeps every surface point's shading
                // constant between frames. Rotating the object slides the shading
                // across the surface, so the solver sees a different-looking patch
                // each time and stops matching it.
                requirement(
                    String(localized: "Işık her yönden yumuşak olsun — yoksa hizalama düşer"),
                    detail: String(localized: "Etrafında dönerken ışık objeye göre sabit kalır. Objeyi çevirdiğinde gölge yüzeyin üzerinde kayar ve çözücü aynı noktayı iki karede tanıyamaz. Tek lamba yerine dağınık ışık kullan; mümkünse lambayı objeyle birlikte döndür."),
                    systemImage: "lightbulb.fill",
                    isCritical: true
                )

                requirement(
                    String(localized: "Bir tur yetmez — yüksekliği değiştir"),
                    detail: String(localized: "Tek yükseklikten çekilen kareler tek bir halka oluşturur ve dikey paralaks vermez; üst yüzeyler bu yüzden yumuşar. Bir turu bitirince telefonun yüksekliğini/açısını değiştirip bir tur daha çek. Alt yüz için objeyi ters çevirip tekrarla."),
                    systemImage: "arrow.up.and.down",
                    isCritical: true
                )

                if !deliversDepth {
                    Label(
                        "Bu cihazda fotoğraflara derinlik gömülemiyor — model gerçek boyutta olmayacak, ölçeksiz çıkacak.",
                        systemImage: "ruler"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }

                Button("Anladım, Başla", action: onContinue)
                    .buttonStyle(TurntablePrimaryButton())
                    .padding(.top, 4)

                Button("Vazgeç", action: onCancel)
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
    }

    private func requirement(
        _ title: String,
        detail: String,
        systemImage: String,
        isCritical: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 26)
                .foregroundStyle(isCritical ? .orange : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isCritical ? .orange : .primary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Preview layer

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let maskFrame: CGRect
    let onMaskChange: (CGRect) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        // `metadataOutputRectConverted` is the only correct way to go from on-screen
        // coordinates to the capture device's normalised space: it accounts for
        // `videoGravity` cropping and the preview's own orientation, which hand-rolled
        // arithmetic would get wrong.
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        let converted = view.previewLayer.metadataOutputRectConverted(fromLayerRect: maskFrame)
        onMaskChange(converted)
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - Overlay

private struct TurntableOverlay: View {
    let engine: TurntableCaptureEngine
    let onCancel: () -> Void

    @State private var isFinishing = false
    @State private var isConfirmingCancel = false
    @State private var finishError: String?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            if let reason = engine.lastRejectionReason, engine.rejectedShots > 0 {
                Label(reason, systemImage: "camera.metering.none")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.85), in: Capsule())
                    .padding(.bottom, 8)
            }
            if let error = engine.captureError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.9), in: Capsule())
                    .padding(.bottom, 10)
            }
            actionBar
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .confirmationDialog("Taramayı iptal et?", isPresented: $isConfirmingCancel, titleVisibility: .visible) {
            Button("İptal Et ve Çık", role: .destructive, action: onCancel)
            Button("Taramaya Dön", role: .cancel) {}
        } message: {
            Text("\(engine.shotCount) fotoğraf silinecek.")
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

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(engine.shotCount) fotoğraf")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                HStack(spacing: 5) {
                    if engine.megapixels > 0 {
                        Text("\(engine.megapixels) MP")
                    }
                    if engine.isLocked {
                        Image(systemName: "lock.fill")
                    }
                    if engine.rejectedShots > 0 {
                        Text("· \(engine.rejectedShots) bulanık")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                if !engine.canFinish {
                    Text("en az \(TurntableCaptureEngine.minimumShots)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.4), in: Capsule())
        }
        .padding(.top, 4)
    }

    private var actionBar: some View {
        VStack(spacing: 12) {
            // Prompted at the moment it becomes actionable rather than buried in the
            // setup guide: a single ring of camera positions is the measured cause
            // of soft top and bottom surfaces.
            if engine.shouldChangeElevation {
                Label(
                    "Bir tur doldu — telefonun yüksekliğini veya açısını değiştirip bir tur daha çek",
                    systemImage: "arrow.up.and.down.circle.fill"
                )
                .font(.footnote.weight(.medium))
                .foregroundStyle(.yellow)
                .multilineTextAlignment(.center)
            } else {
                Text(engine.isAutoCapturing
                     ? "Otomatik çekim açık — objeyi yavaşça döndürmeye devam edin"
                     : "Objeyi ~10° çevirip çekin")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button {
                    engine.lockCameraSettings()
                } label: {
                    switch engine.lockState {
                    case .unlocked: Text("Odağı Kilitle")
                    // Locking waits for focus and exposure to converge, which takes a
                    // moment — without this the button looked like it did nothing.
                    case .locking: Label("Kilitleniyor…", systemImage: "circle.dotted")
                    case .locked: Label("Odak Kilitli", systemImage: "lock.fill")
                    case .failed: Label("Kilitlenemedi", systemImage: "lock.slash")
                    }
                }
                .buttonStyle(TurntableSecondaryButton())
                .disabled(engine.lockState == .locking || engine.lockState == .locked)

                Button(engine.isAutoCapturing ? "Otomatiği Durdur" : "Otomatik Çekim") {
                    engine.toggleAutoCapture()
                }
                .buttonStyle(TurntableSecondaryButton())

                Button {
                    engine.captureNow()
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.title3)
                        .frame(width: 56, height: 44)
                }
                .buttonStyle(TurntableSecondaryButton())
                .disabled(engine.isAutoCapturing)
            }

            Button {
                finish()
            } label: {
                if isFinishing {
                    ProgressView().tint(.black)
                } else {
                    Text("Bitir ve Modeli Oluştur")
                }
            }
            .buttonStyle(TurntablePrimaryButton())
            .disabled(isFinishing || !engine.canFinish)

            if !engine.canFinish {
                Text("Çözücünün turu kapatabilmesi için en az \(TurntableCaptureEngine.minimumShots) fotoğraf gerekiyor.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 22))
        // The device is on a tripod and the user is looking at the object, so a tick
        // per saved shot is the confirmation that matters.
        .sensoryFeedback(.impact(weight: .light), trigger: engine.shotCount)
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

// MARK: - Reconstruction, result, message

private struct TurntableReconstructionView: View {
    let progress: ReconstructionProgress

    var body: some View {
        VStack(spacing: 18) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 240)
            Text(progress.stage?.displayName ?? String(localized: "Model oluşturuluyor"))
                .font(.headline)
            if let remaining = progress.remainingText {
                Text("\(remaining) kaldı")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("Uygulamayı arka plana almayın.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

private struct TurntableResultView: View {
    let record: ScanRecord
    /// Surfaced next to the result rather than only logged: if masking was skipped
    /// the model will contain background, and that is worth knowing while looking
    /// at it.
    let warnings: [String]
    let onDone: () -> Void

    @Environment(ScanStorage.self) private var storage

    var body: some View {
        // Scrollable because the pose diagnosis can run to three paragraphs, and a
        // clipped explanation is worse than no explanation.
        ScrollView {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 18) {
            ModelPreviewView(url: storage.modelURL(for: record))
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 4) {
                Label("Tarama hazır", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                if let count = record.imageCount {
                    Text("\(count) fotoğraf işlendi")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                // The three numbers that explain the mesh: how many frames actually
                // got aligned, and how the cameras were spread around the object.
                if let summary = record.summary {
                    Text(summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if !record.isMetricallyScaled {
                    Text("Ölçeksiz — derinlik verisi yoktu")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "lightbulb.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Bitti", action: onDone)
                .buttonStyle(TurntablePrimaryButton())
                .padding(.horizontal, 40)
        }
        .padding()
        .sensoryFeedback(.success, trigger: record.id)
    }
}

private struct TurntableMessageView: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(tint)
            Text(title).font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Kapat", action: onDismiss)
                .buttonStyle(TurntablePrimaryButton())
                .padding(.horizontal, 40)
        }
        .padding(32)
    }
}

private struct TurntablePrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(.white.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
    }
}

private struct TurntableSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(.white.opacity(configuration.isPressed ? 0.28 : 0.16), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
    }
}

/// Draggable, pinchable rectangle marking the object.
private struct ObjectMaskRectangle: View {
    @Binding var frame: CGRect

    @State private var dragOffset = CGSize.zero
    @State private var scale: CGFloat = 1

    private var displayed: CGRect {
        let width = frame.width * scale
        let height = frame.height * scale
        return CGRect(
            x: frame.midX - width / 2 + dragOffset.width,
            y: frame.midY - height / 2 + dragOffset.height,
            width: width,
            height: height
        )
    }

    var body: some View {
        GeometryReader { _ in
            Rectangle()
                .stroke(.yellow, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                .background(Color.yellow.opacity(0.06))
                .frame(width: displayed.width, height: displayed.height)
                .position(x: displayed.midX, y: displayed.midY)
                .overlay(alignment: .topLeading) {
                    Text("obje")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.yellow, in: Capsule())
                        .position(x: displayed.minX + 22, y: displayed.minY - 10)
                }
                .gesture(
                    DragGesture()
                        .onChanged { dragOffset = $0.translation }
                        .onEnded { _ in
                            frame = displayed
                            dragOffset = .zero
                            scale = 1
                        }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { scale = $0.magnification }
                        .onEnded { _ in
                            frame = displayed
                            dragOffset = .zero
                            scale = 1
                        }
                )
        }
        .allowsHitTesting(true)
    }
}
