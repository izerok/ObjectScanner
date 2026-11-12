import RoomPlan
import SwiftUI

/// Capture flow for room scanning.
///
/// Thinner than the object flows on purpose: `RoomCaptureView` already draws the
/// live wireframe and Apple's coaching hints, so there is no bounding box to
/// place, no focus to lock and no shot counter to babysit. What is left is the
/// app's own shell — setup guidance, the export choice, and the result.
struct RoomFlowView: View {
    @Environment(ScanStorage.self) private var storage
    @Environment(\.dismiss) private var dismiss

    @State private var engine: RoomCaptureEngine?
    @State private var finishedRecord: ScanRecord?
    @State private var startupError: String?
    @State private var hasSeenSetupTips = false
    /// Decided before the walk starts: stills not collected on the way cannot be
    /// recovered afterwards.
    @State private var wantsPhotographicModel = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let engine {
                content(for: engine)
            } else if let startupError {
                RoomMessageView(
                    title: String(localized: "Oda taraması başlatılamadı"),
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
    private func content(for engine: RoomCaptureEngine) -> some View {
        switch engine.phase {
        case .idle:
            ProgressView("Hazırlanıyor…").tint(.white)

        // `.preparing` is included: the session is intentionally not running yet,
        // and it must not start until the capture view below is mounted.
        case .preparing, .readyToDetect, .framing, .capturing, .reconstructing:
            if hasSeenSetupTips {
                captureStage(engine: engine)
            } else {
                RoomSetupGuide(wantsPhotographicModel: $wantsPhotographicModel) {
                    engine.capturesPhotographicModel = wantsPhotographicModel
                    hasSeenSetupTips = true
                } onCancel: {
                    engine.cancel()
                    dismiss()
                }
            }

        case .done(let record):
            RoomResultView(
                record: record,
                summary: engine.summary,
                photographicRecord: engine.photographicRecord,
                photographicNote: engine.photographicNote
            ) { dismiss() }
            .task { finishedRecord = record }

        case .failed(let message):
            RoomMessageView(
                title: String(localized: "Oda taraması başarısız"),
                message: message,
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            ) { dismiss() }

        case .cancelled:
            Color.clear.task { dismiss() }
        }
    }

    /// The capture view stays mounted through processing. RoomPlan builds the room
    /// *inside* that view, so tearing it down at the moment we ask for the result
    /// would be pulling the rug out mid-work.
    private func captureStage(engine: RoomCaptureEngine) -> some View {
        ZStack {
            // The session starts from here, not from `start()`: the callback fires
            // only once the view has a window and a size.
            RoomCaptureContainer(captureView: engine.captureView) {
                engine.beginCapture()
            }
            .ignoresSafeArea()

            if case .reconstructing = engine.phase {
                RoomProcessingOverlay(isReconstructingPhotos: engine.capturesPhotographicModel)
            } else {
                RoomOverlay(engine: engine, isCapturing: isCapturing(engine)) {
                    engine.cancel()
                    dismiss()
                }
            }
        }
    }

    private func isCapturing(_ engine: RoomCaptureEngine) -> Bool {
        if case .capturing = engine.phase { return true }
        return false
    }

    private func startIfNeeded() {
        guard engine == nil else { return }
        let engine = RoomCaptureEngine(storage: storage)
        do {
            try engine.start()
            self.engine = engine
        } catch {
            startupError = error.localizedDescription
        }
    }
}

// MARK: - Capture view

private struct RoomCaptureContainer: UIViewRepresentable {
    /// Handed in rather than created here: the engine owns it so it outlives this
    /// view's presence in the hierarchy.
    let captureView: RoomCaptureView
    /// Fired once the view is in a window and has a real size.
    let onReady: () -> Void

    func makeUIView(context: Context) -> RoomCaptureHostView {
        let host = RoomCaptureHostView()
        host.embed(captureView)
        host.onReady = onReady
        return host
    }

    func updateUIView(_ view: RoomCaptureHostView, context: Context) {}
}

/// Wrapper that exists purely to report when the capture view is genuinely on
/// screen.
///
/// `RoomCaptureView` is declared `public`, not `open`, so it cannot be subclassed
/// from here to override `layoutSubviews` directly — hence a host view around it.
/// `onAppear` is not a substitute: SwiftUI fires it around insertion, which is not
/// a promise that the UIView has a window or a non-zero size, and both are needed
/// before the session starts.
private final class RoomCaptureHostView: UIView {
    var onReady: (() -> Void)?

    private var hasReported = false

    func embed(_ view: UIView) {
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !hasReported, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        hasReported = true
        onReady?()
    }
}

// MARK: - Setup guide

private struct RoomSetupGuide: View {
    @Binding var wantsPhotographicModel: Bool
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Oda taraması")
                    .font(.title2.bold())

                // Said up front because it is the most common disappointment: this
                // mode is not a higher-resolution object scanner, it is a different
                // product entirely.
                Text("Bu mod odanın yapısını çıkarır: duvarlar, kapılar, pencereler ve mobilya. Mobilya tanınmış kutular olarak gelir — koltuğun kumaş kıvrımlarını değil. Detaylı obje modeli için Fotogrametri modunu kullan.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                photographicOption

                requirement(
                    String(localized: "Duvarlardan 1-2 metre uzakta dolaş"),
                    detail: String(localized: "LiDAR menzili yaklaşık 5 metre. Duvara yapışırsan yüzeyin tamamını göremez, çok uzaklaşırsan ölçüm zayıflar."),
                    systemImage: "figure.walk",
                    isCritical: true
                )

                requirement(
                    String(localized: "Telefonu duvara doğru tut, yavaşça süpür"),
                    detail: String(localized: "Göğüs hizasında tut ve hafifçe aşağı-yukarı çevir; taban ve tavan birleşimlerini görmesi gerekiyor. Hızlı hareket edersen 'yavaşla' uyarısı çıkar."),
                    systemImage: "iphone.gen3.radiowaves.left.and.right",
                    isCritical: true
                )

                requirement(
                    String(localized: "Bir turu tamamla"),
                    detail: String(localized: "Odanın çevresini kesintisiz dolaşıp başladığın yere dön. Yarım tur kalan duvarları eksik bırakır."),
                    systemImage: "arrow.trianglehead.clockwise"
                )

                if wantsPhotographicModel {
                    // Measured, not a hunch: a single 75-frame loop produced a torn
                    // shell with a hole where the floor was only ever seen edge-on.
                    requirement(
                        String(localized: "Fotoğraflı model için iki tur at"),
                        detail: String(localized: "Birinci turda telefonu duvarlara doğru tut. İkinci turda biraz aşağı eğ, zemini ve mobilyanın önünü gör. Tek tur yeterli kare bırakmıyor ve model yırtık çıkıyor."),
                        systemImage: "arrow.triangle.2.circlepath",
                        isCritical: true
                    )
                }

                requirement(
                    String(localized: "Işıklar açık olsun"),
                    detail: String(localized: "Duvarı LiDAR ölçer ama 'bu bir kapı' kararını kamera görüntüsü verir. Karanlıkta sınıflandırma çalışmaz."),
                    systemImage: "lightbulb"
                )

                requirement(
                    String(localized: "Ayna ve büyük camlara dikkat"),
                    detail: String(localized: "Yansıma LiDAR'ı yanıltır; aynanın arkasında olmayan bir oda çıkabilir. Mümkünse o duvarı biraz uzaktan geç."),
                    systemImage: "rectangle.on.rectangle.angled"
                )

                requirement(
                    String(localized: "Tek seferde tek oda"),
                    detail: String(localized: "RoomPlan'in sahne boyut sınırı var. Ev taramak için odaları ayrı ayrı tarayıp modelleri birlikte kullan."),
                    systemImage: "square.split.bottomrightquarter"
                )

                Button("Anladım, Başla", action: onContinue)
                    .buttonStyle(RoomPrimaryButton())
                    .padding(.top, 4)

                Button("Vazgeç", action: onCancel)
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
    }

    /// Offered here rather than at the end, because the stills have to be collected
    /// during the walk — there is nothing to reconstruct from afterwards.
    private var photographicOption: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $wantsPhotographicModel) {
                Text("Fotoğraflı model de üret")
                    .font(.subheadline.weight(.semibold))
            }

            Text("RoomPlan hiç renk üretmiyor — çıktısı tasarım gereği sadece geometri, o yüzden gri. Bu seçenek yürürken kamera kareleri de toplar ve onlardan **ikinci bir model** çıkarır: dokulu, gerçek görünümlü. Kütüphaneye iki kayıt olarak düşer.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if wantsPhotographicModel {
                Label(
                    "Deneysel. Fotogrametri geometriyi yüzey deseninden türetir; boş boyalı duvarlarda zayıf kalır, mobilyalı ve dokulu odalarda iyi çıkar. Ayrıca oda modelinden sonra birkaç dakika daha işlem sürer.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
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

// MARK: - Coverage dial

/// Shows which directions have been photographed and which have not.
///
/// RoomPlan's own wireframe answers "is the geometry there?" but says nothing about
/// the stills, so there was no way to tell a fully photographed wall from one that
/// was never pointed at. The poses already carry the answer: what a frame captured
/// is whatever the lens was facing.
///
/// Two rings because they photograph different surfaces, and a complete wall pass
/// says nothing about whether the floor was ever seen — which is exactly the second
/// loop the setup guide asks for.
private struct RoomCoverageDial: View {
    let sectorCount: Int
    let wallSectors: Set<Int>
    let floorSectors: Set<Int>
    /// World heading in radians, or nil while tracking settles.
    let heading: Double?

    private let side: CGFloat = 108

    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                draw(in: &context, centre: centre, radius: size.width * 0.42, thickness: 11, filled: wallSectors)
                draw(in: &context, centre: centre, radius: size.width * 0.27, thickness: 9, filled: floorSectors)
                drawNeedle(in: &context, centre: centre, radius: size.width * 0.48)
            }
            .frame(width: side, height: side)
            .overlay {
                VStack(spacing: 0) {
                    Text("\(wallSectors.count)/\(sectorCount)")
                        .font(.caption.weight(.bold).monospacedDigit())
                    Text("duvar")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Text("dış halka duvar · iç halka zemin")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(8)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    private func draw(
        in context: inout GraphicsContext,
        centre: CGPoint,
        radius: CGFloat,
        thickness: CGFloat,
        filled: Set<Int>
    ) {
        let sweep = 2 * Double.pi / Double(sectorCount)
        // A gap keeps neighbouring sectors readable as separate wedges.
        let gap = sweep * 0.14

        for sector in 0..<sectorCount {
            var path = Path()
            path.addArc(
                center: centre,
                radius: radius,
                startAngle: .radians(screenAngle(forSector: sector) + gap / 2),
                endAngle: .radians(screenAngle(forSector: sector) + sweep - gap / 2),
                clockwise: false
            )
            context.stroke(
                path,
                with: .color(filled.contains(sector) ? .green : .white.opacity(0.16)),
                style: StrokeStyle(lineWidth: thickness, lineCap: .butt)
            )
        }
    }

    private func drawNeedle(in context: inout GraphicsContext, centre: CGPoint, radius: CGFloat) {
        guard let heading else { return }
        // Mid-sector so the needle sits over the wedge it is filling.
        let angle = screenAngle(forRadians: heading)
        let tip = CGPoint(
            x: centre.x + cos(angle) * radius,
            y: centre.y + sin(angle) * radius
        )
        var path = Path()
        path.move(to: centre)
        path.addLine(to: tip)
        context.stroke(path, with: .color(.yellow), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    /// World yaw to Canvas angle. Canvas puts 0 at 3 o'clock and grows clockwise,
    /// so this rotates a quarter turn to put heading 0 at the top.
    private func screenAngle(forRadians yaw: Double) -> Double {
        yaw - .pi / 2
    }

    private func screenAngle(forSector sector: Int) -> Double {
        screenAngle(forRadians: 2 * .pi * Double(sector) / Double(sectorCount))
    }
}

// MARK: - Overlay

private struct RoomOverlay: View {
    let engine: RoomCaptureEngine
    /// False in the frame or two between mounting the view and the session
    /// actually running; finishing then would have nothing to finish.
    let isCapturing: Bool
    let onCancel: () -> Void

    @State private var isFinishing = false
    @State private var isConfirmingCancel = false
    @State private var isShowingStyleInfo = false
    @State private var finishError: String?

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if engine.capturesPhotographicModel {
                HStack {
                    Spacer()
                    RoomCoverageDial(
                        sectorCount: RoomKeyframeCollector.sectorCount,
                        wallSectors: engine.wallSectors,
                        floorSectors: engine.floorSectors,
                        heading: engine.heading
                    )
                }
                .padding(.top, 8)
            }

            Spacer(minLength: 0)
            if let diagnostic = engine.cameraDiagnostic {
                Label(diagnostic, systemImage: "video.slash.fill")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.9), in: Capsule())
                    .padding(.bottom, 10)
            }
            actionBar
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        // A tick per newly covered direction. The user is looking at the room while
        // walking, not at the dial, so the feedback that matters is not visual.
        .sensoryFeedback(
            .impact(weight: .light),
            trigger: engine.wallSectors.count + engine.floorSectors.count
        )
        .confirmationDialog("Taramayı iptal et?", isPresented: $isConfirmingCancel, titleVisibility: .visible) {
            Button("İptal Et ve Çık", role: .destructive, action: onCancel)
            Button("Taramaya Dön", role: .cancel) {}
        } message: {
            Text("Şu ana kadar taranan oda silinecek.")
        }
        .alert(
            "Oda modeli oluşturulamadı",
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

            // Only meaningful when stills are being collected; otherwise there is
            // no number to show and RoomPlan reports no shot count of its own.
            if engine.capturesPhotographicModel {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(engine.keyframeCount) kare")
                        .font(.footnote.weight(.semibold).monospacedDigit())
                    if let resolution = engine.frameResolution {
                        // Shown because it is the single biggest factor in how the
                        // texture turns out, and it depends on the device's formats.
                        Text("\(resolution) px")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    if engine.keyframeCount < RoomKeyframeCollector.minimumFrames {
                        Text("en az \(RoomKeyframeCollector.minimumFrames)")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.black.opacity(0.4), in: Capsule())
            }
        }
        .padding(.top, 4)
    }

    /// Says what is actually missing rather than repeating the same sentence.
    ///
    /// Once the wall ring is full the useful instruction changes completely — the
    /// second loop looking down is a different job, and telling someone to keep
    /// circling the walls at that point is wrong.
    private var guidance: String {
        guard isCapturing else { return String(localized: "Kamera başlatılıyor…") }
        guard engine.capturesPhotographicModel else {
            return String(localized: "Duvarların çevresinde yavaşça dolaş — çizgiler oluştukça o yüzey yakalanıyor")
        }

        let total = RoomKeyframeCollector.sectorCount
        let walls = engine.wallSectors.count
        if walls < total {
            return "Sarı iğneyi gri kalan yönlere çevir — \(total - walls) yön eksik"
        }
        let floors = engine.floorSectors.count
        if floors < total {
            return "Duvarlar tamam. Şimdi telefonu aşağı eğip ikinci turu at — iç halkada \(total - floors) yön eksik"
        }
        return String(localized: "Her yön çekildi. İstersen daha fazla kare topla ya da bitir.")
    }

    private var actionBar: some View {
        VStack(spacing: 12) {
            // The live wireframe is the real feedback; this only says what to do
            // with it.
            Text(guidance)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)

            Picker("Çıktı", selection: Binding(
                get: { engine.exportStyle },
                set: { engine.exportStyle = $0 }
            )) {
                ForEach(RoomExportStyle.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            Button {
                isShowingStyleInfo.toggle()
            } label: {
                Label(
                    isShowingStyleInfo ? "Gizle" : "Bu ne demek?",
                    systemImage: isShowingStyleInfo ? "chevron.up" : "info.circle"
                )
                .font(.caption)
            }
            .tint(.white.opacity(0.8))

            if isShowingStyleInfo {
                Text(engine.exportStyle.explanation)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
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
            .buttonStyle(RoomPrimaryButton())
            .disabled(isFinishing || !isCapturing)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 22))
        .animation(.easeInOut(duration: 0.18), value: isShowingStyleInfo)
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

// MARK: - Processing, result, message

private struct RoomProcessingOverlay: View {
    let isReconstructingPhotos: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 14) {
                // Indeterminate on purpose: RoomPlan reports no progress while it
                // turns the captured data into a room, and a fake bar would be a lie.
                ProgressView().tint(.white)
                Text("Oda modeli oluşturuluyor")
                    .font(.headline)
                Text(isReconstructingPhotos
                     ? "Oda modeli birkaç saniye, ardından fotoğraflı model birkaç dakika sürer. Uygulamayı arka plana almayın."
                     : "Genelde birkaç saniye sürer. Uygulamayı arka plana almayın.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

private struct RoomResultView: View {
    let record: ScanRecord
    let summary: RoomSummary?
    /// The textured model, when one was asked for and succeeded.
    let photographicRecord: ScanRecord?
    /// Why there is no textured model, or what the solver had to say about it.
    let photographicNote: String?
    let onDone: () -> Void

    @Environment(ScanStorage.self) private var storage

    var body: some View {
        // Two models can be on screen at once, so this has to scroll.
        ScrollView {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 18) {
            modelCard(
                title: String(localized: "Yapı modeli"),
                caption: String(localized: "gerçek ölçülerde · renksiz"),
                record: record,
                extra: structureCaption
            )

            if let photographicRecord {
                modelCard(
                    title: String(localized: "Fotoğraflı model"),
                    caption: String(localized: "dokulu · ölçeksiz"),
                    record: photographicRecord,
                    extra: photographicRecord.summary
                )
            }

            if let photographicNote {
                Label(photographicNote, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Bitti", action: onDone)
                .buttonStyle(RoomPrimaryButton())
                .padding(.horizontal, 40)
        }
        .padding()
        .sensoryFeedback(.success, trigger: record.id)
    }

    private var structureCaption: String? {
        var parts: [String] = []
        if let summary { parts.append(summary.text) }
        if let dimensions = record.dimensionsMillimetres, dimensions.count == 3 {
            // Metres here, not millimetres: nobody reads a room as 4180 mm.
            parts.append(Self.metres(dimensions))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private func modelCard(
        title: String,
        caption: String,
        record: ScanRecord,
        extra: String?
    ) -> some View {
        VStack(spacing: 8) {
            ModelPreviewView(url: storage.modelURL(for: record))
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 2) {
                Label(title, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let extra {
                    Text(extra)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private static func metres(_ millimetres: [Int]) -> String {
        let values = millimetres.map { String(format: "%.2f", Double($0) / 1000) }
        return "\(values[0]) × \(values[2]) m taban · \(values[1]) m yükseklik"
    }
}

private struct RoomMessageView: View {
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
                .buttonStyle(RoomPrimaryButton())
                .padding(.horizontal, 40)
        }
        .padding(32)
    }
}

private struct RoomPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(.white.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
    }
}
