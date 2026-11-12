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

    /// Screen-space rectangle for the designated calibration object (v0.7),
    /// placed in the second framing step. Starts beside the subject frame;
    /// the user drags it onto the 10 mm reference.
    @State private var calibratorFrame = CGRect(x: 312, y: 420, width: 80, height: 80)

    /// Which framing step the capture stage is in. Designation comes before
    /// shooting: the user first says what the subject is, then what the
    /// calibration object is — identification by declaration, not by a
    /// post-hoc search guessing which blob is which.
    @State private var framingStage: FramingStage = .subject

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
                // The frames are reported back through a binding rather than read
                // from the view: converting layer coordinates to capture
                // coordinates needs the preview layer, which only this wrapper
                // owns. The calibrator frame joins the report once its step
                // starts; going back to the subject step withdraws it.
                CameraPreviewView(
                    session: session,
                    maskFrames: framingStage == .subject
                        ? [maskFrame]
                        : [maskFrame, calibratorFrame]
                ) { normalized in
                    engine.objectMaskRect = normalized.first
                    engine.calibratorMaskRect = normalized.count > 1 ? normalized[1] : nil
                }
                .ignoresSafeArea()
            }

            DualMaskOverlay(
                subjectFrame: $maskFrame,
                calibratorFrame: $calibratorFrame,
                stage: framingStage
            )

            TurntableOverlay(
                engine: engine,
                framingStage: framingStage,
                onFramingNext: { framingStage = .calibrator },
                onFramingSkip: { framingStage = .shooting },
                onFramingBack: { framingStage = .subject },
                onFramingStart: { framingStage = .shooting }
            ) {
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
                    detail: String(localized: "Bu ilk adım: sürükleyerek taşı, iki parmakla boyutlandır. Sadece çerçevelerin içi modellenir — masa, kâğıt ve arka plan tamamen dışlanır. Telefon sabit olduğu için çerçeveler bütün kareler için geçerli."),
                    systemImage: "viewfinder.rectangular",
                    isCritical: true
                )

                requirement(
                    String(localized: "İkinci adımda kalibrasyon nesnesini belirle"),
                    detail: String(localized: "Yüksekliği 10 mm olan küçük bir nesneyi (küp, blok, üst üste para) objenin yanına (1–2 cm) koy. Çekimden önce yeşil çerçeveyi onun üzerine yerleştireceksin — uygulama hangisinin obje, hangisinin kalibrasyon nesnesi olduğunu böyle bilecek; modelde o nesneyi arayıp ölçeği ondan alacak, bulamazsa söyleyecek."),
                    systemImage: "cube",
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
                        "Bu cihazda fotoğraflara derinlik gömülemiyor — ölçek ancak kalibrasyon nesnesiyle veya sonradan kumpasla gelir.",
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
    let maskFrames: [CGRect]
    let onMaskChange: ([CGRect]) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        installReporter(on: view)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        installReporter(on: view)
        view.scheduleReport()
    }

    /// Reports the mask in capture coordinates. Called on every update *and*
    /// from `layoutSubviews` — the update path alone is not enough: the
    /// first update can land before the view has bounds, and if nothing in
    /// the parent re-renders afterwards, the engine never learns the mask
    /// and every capture action dead-ends on "place the frame first"
    /// (v0.3.2: this was the pure-LiDAR mode's dead-button root cause).
    private func installReporter(on view: PreviewView) {
        let maskFrames = self.maskFrames
        let onMaskChange = self.onMaskChange
        view.reportMask = { [weak view] in
            // Only while genuinely on screen with a live session: reporting
            // during teardown (the capture stage is dismantled the moment
            // reconstruction starts) pokes a half-dead preview layer and
            // crashed the photogrammetry turntable's finish (v0.3.4).
            guard let view, view.window != nil,
                  view.bounds.width > 0, view.bounds.height > 0,
                  view.previewLayer.session != nil else { return }
            // `metadataOutputRectConverted` is the only correct way to go from
            // on-screen coordinates to the capture device's normalised space:
            // it accounts for `videoGravity` cropping and the preview's own
            // orientation, which hand-rolled arithmetic would get wrong.
            let converted = maskFrames.map {
                view.previewLayer.metadataOutputRectConverted(fromLayerRect: $0)
            }
            // Skip redundant reports: the consumer is an @Observable setter,
            // and re-reporting unchanged rects on every layout pass would
            // churn view updates for nothing.
            if let last = view.lastReportedMasks, last.count == converted.count,
               zip(last, converted).allSatisfy({ a, b in
                   abs(a.minX - b.minX) < 0.0001 && abs(a.minY - b.minY) < 0.0001
                       && abs(a.width - b.width) < 0.0001 && abs(a.height - b.height) < 0.0001
               }) {
                return
            }
            view.lastReportedMasks = converted
            onMaskChange(converted)
        }
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: ()) {
        view.reportMask = nil
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        var reportMask: (() -> Void)?
        var lastReportedMasks: [CGRect]?
        private var reportScheduled = false

        /// Reports are ALWAYS delivered on the next runloop turn, never
        /// synchronously. The consumer is an @Observable setter: calling it
        /// from inside layout (v0.3.2) let a finish-time transition — bounds
        /// oscillating while the capture stage is dismantled — feed back
        /// into layout and recurse until the app died. Coalescing here makes
        /// that loop structurally impossible (v0.4.1).
        func scheduleReport() {
            guard !reportScheduled, reportMask != nil else { return }
            reportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportScheduled = false
                self.reportMask?()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scheduleReport()
        }
    }
}

// MARK: - Overlay

private struct TurntableOverlay: View {
    let engine: TurntableCaptureEngine
    let framingStage: FramingStage
    let onFramingNext: () -> Void
    let onFramingSkip: () -> Void
    let onFramingBack: () -> Void
    let onFramingStart: () -> Void
    let onCancel: () -> Void

    @State private var isFinishing = false
    @State private var isConfirmingCancel = false
    @State private var finishError: String?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            if framingStage == .shooting, engine.shotCount == 0 {
                Label(
                    engine.calibratorMaskRect != nil
                        ? "Ölçek için: 10 mm nesne yeşil çerçevenin içinde, objenin yanında mı?"
                        : "Ölçek için: 10 mm küp çerçevenin içinde, objenin yanında mı?",
                    systemImage: "cube"
                )
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white.opacity(0.9))
                .padding(.bottom, 8)
            }
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
            if framingStage == .shooting {
                actionBar
            } else {
                framingBar
            }
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

    /// The two designation steps replace the capture controls until both
    /// rectangles are placed: first the subject, then the calibration
    /// object. Shooting controls with unplaced frames would invite exactly
    /// the unlabelled scan this flow exists to prevent.
    private var framingBar: some View {
        VStack(spacing: 12) {
            switch framingStage {
            case .subject:
                Text("Sarı çerçeveyi objenin üzerine yerleştir — sadece çerçevelerin içi modellenir, dışı kararır")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                Button("Sonraki: Kalibrasyon Nesnesini Belirle", action: onFramingNext)
                    .buttonStyle(TurntablePrimaryButton())
                Button("Kalibrasyon nesnesi yok — böyle çek", action: onFramingSkip)
                    .buttonStyle(TurntableSecondaryButton())
            case .calibrator:
                Text("Yeşil çerçeveyi, objenin yanındaki 10 mm yüksekliğindeki küçük nesnenin üzerine yerleştir")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                Button("Çekime Başla", action: onFramingStart)
                    .buttonStyle(TurntablePrimaryButton())
                Button("Geri — obje çerçevesine dön", action: onFramingBack)
                    .buttonStyle(TurntableSecondaryButton())
            case .shooting:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 22))
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
                    if record.scaleCalibration == nil {
                        Text("Kalibrasyon küpü bulunamadı — küple tekrar tarayın veya Galeri'den kumpasla kalibre edin")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                }
                if let calibration = record.scaleCalibration,
                   calibration.method == .visualCube {
                    Text("Kalibrasyon küpüyle ölçeklendi")
                        .font(.caption)
                        .foregroundStyle(.green)
                    if let discrepancy = calibration.discrepancyPercent {
                        Text("\(String(localized: "Derinlikle uyuşmazlık")): \(String(format: "%.1f%%", discrepancy))")
                            .font(.caption)
                            .foregroundStyle(discrepancy > 3 ? .orange : .secondary)
                    }
                }
                if let calibration = record.scaleCalibration,
                   calibration.method == .guidedCube {
                    switch calibration.designatedOutcome {
                    case .found:
                        Text("Belirlenen kalibrasyon nesnesiyle ölçeklendi")
                            .font(.caption)
                            .foregroundStyle(.green)
                        if let discrepancy = calibration.discrepancyPercent {
                            Text("\(String(localized: "Derinlikle uyuşmazlık")): \(String(format: "%.1f%%", discrepancy))")
                                .font(.caption)
                                .foregroundStyle(discrepancy > 3 ? .orange : .secondary)
                        }
                    case .eroded:
                        Text("Belirlenen nesne modelde aşınmış bulundu — ölçek derinlikten alındı")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                        if let located = calibration.locatedHeightMillimetres {
                            Text(String(format: String(localized: "Bulunan yükseklik: %.1f mm (gerçek 10 mm)"), located))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case .oversized:
                        Text("Belirlenen nesne beklenenden büyük bulundu — ölçek derinlikten alındı")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                        if let located = calibration.locatedHeightMillimetres {
                            Text(String(format: String(localized: "Bulunan yükseklik: %.1f mm (gerçek 10 mm)"), located))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case .notFound:
                        Text("Belirlenen kalibrasyon nesnesi modelde bulunamadı — ölçek derinlikten alındı")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    case nil:
                        EmptyView()
                    }
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

/// Which designation step the capture stage is in (v0.7).
private enum FramingStage {
    /// Placing the yellow subject rectangle.
    case subject
    /// Placing the green calibration-object rectangle.
    case calibrator
    /// Both placed (or designation skipped) — shooting.
    case shooting
}

/// The designation rectangles (v0.7): yellow for the subject, green for the
/// 10 mm calibration object, over one shared dim layer.
///
/// The dim is the union of both rectangles — what stays lit gets modelled —
/// and it tracks both rectangles' in-flight gestures, so a calibration
/// object left outside reads as excluded *before* the scan starts, not
/// after a finished model comes back without it (the v0.6.6 lesson,
/// extended to two frames). Only the current step's rectangle takes
/// gestures; while shooting both are locked.
private struct DualMaskOverlay: View {
    @Binding var subjectFrame: CGRect
    @Binding var calibratorFrame: CGRect
    let stage: FramingStage

    @State private var subjectDrag = CGSize.zero
    @State private var subjectScale: CGFloat = 1
    @State private var calibratorDrag = CGSize.zero
    @State private var calibratorScale: CGFloat = 1

    private func displayed(_ frame: CGRect, drag: CGSize, scale: CGFloat) -> CGRect {
        let width = frame.width * scale
        let height = frame.height * scale
        return CGRect(
            x: frame.midX - width / 2 + drag.width,
            y: frame.midY - height / 2 + drag.height,
            width: width,
            height: height
        )
    }

    private var displayedSubject: CGRect {
        displayed(subjectFrame, drag: subjectDrag, scale: subjectScale)
    }

    private var displayedCalibrator: CGRect {
        displayed(calibratorFrame, drag: calibratorDrag, scale: calibratorScale)
    }

    private var showsCalibrator: Bool { stage != .subject }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: proxy.size))
                    path.addRect(displayedSubject)
                    if showsCalibrator {
                        path.addRect(displayedCalibrator)
                    }
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                designationRect(
                    rect: displayedSubject,
                    color: .yellow,
                    label: String(localized: "obje"),
                    editable: stage == .subject,
                    drag: $subjectDrag,
                    scale: $subjectScale
                ) {
                    subjectFrame = displayedSubject
                    subjectDrag = .zero
                    subjectScale = 1
                }

                if showsCalibrator {
                    designationRect(
                        rect: displayedCalibrator,
                        color: .green,
                        label: "10 mm",
                        editable: stage == .calibrator,
                        drag: $calibratorDrag,
                        scale: $calibratorScale
                    ) {
                        calibratorFrame = displayedCalibrator
                        calibratorDrag = .zero
                        calibratorScale = 1
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func designationRect(
        rect: CGRect,
        color: Color,
        label: String,
        editable: Bool,
        drag: Binding<CGSize>,
        scale: Binding<CGFloat>,
        commit: @escaping () -> Void
    ) -> some View {
        Rectangle()
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            .background(color.opacity(0.06))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .overlay(alignment: .topLeading) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(color, in: Capsule())
                    .position(x: rect.minX + 22, y: rect.minY - 10)
            }
            // Gestures stay attached and no-op while locked, rather than
            // switching between a gesture and nil.
            .gesture(
                DragGesture()
                    .onChanged { if editable { drag.wrappedValue = $0.translation } }
                    .onEnded { _ in if editable { commit() } }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { if editable { scale.wrappedValue = $0.magnification } }
                    .onEnded { _ in if editable { commit() } }
            )
    }
}
