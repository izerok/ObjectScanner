import SwiftUI

/// Pre-flight screen: describe the object, get a mode recommendation, pick detail,
/// then hand off to the engine's capture flow.
struct ScanSetupView: View {
    @Environment(ScanStorage.self) private var storage

    @State private var profile = ObjectProfile()
    @State private var overriddenKind: ScanEngineKind?
    @State private var isPresentingCapture = false
    @State private var permissionDenied = false

    private var availableKinds: Set<ScanEngineKind> {
        var kinds: Set<ScanEngineKind> = []
        if ObjectCaptureEngine.availability.isUsable { kinds.insert(.objectCapture) }
        if TurntableCaptureEngine.availability.isUsable { kinds.insert(.turntable) }
        if TrueDepthEngine.availability.isUsable { kinds.insert(.trueDepth) }
        if RoomCaptureEngine.availability.isUsable { kinds.insert(.roomPlan) }
        return kinds
    }

    private var recommendation: ModeRecommendation {
        profile.recommendation(availableKinds: availableKinds)
    }

    private var selectedKind: ScanEngineKind {
        overriddenKind ?? recommendation.kind
    }

    private var canStart: Bool {
        selectedKind.isImplemented && availableKinds.contains(selectedKind)
    }

    var body: some View {
        Form {
            hardwareWarningSection
            // A room is not an object, so the object questionnaire, its
            // recommendation and the photogrammetry detail note all stop applying
            // the moment room mode is picked.
            if selectedKind == .roomPlan {
                roomSection
            } else {
                objectSection
                recommendationSection
            }
            modeSection
            if selectedKind != .roomPlan {
                detailSection
            }
            diagnosticsSection
        }
        .navigationTitle("Yeni Tarama")
        .safeAreaInset(edge: .bottom) { startButton }
        .fullScreenCover(isPresented: $isPresentingCapture) {
            switch selectedKind {
            case .objectCapture: ObjectCaptureFlowView()
            case .turntable: TurntableFlowView()
            case .trueDepth: TrueDepthFlowView()
            case .roomPlan: RoomFlowView()
            }
        }
        .alert("Kamera erişimi kapalı", isPresented: $permissionDenied) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text("Tarama için Ayarlar > ObjectScanner üzerinden kamera erişimini açın.")
        }
        .onChange(of: profile) { _, _ in
            overriddenKind = nil
        }
    }

    // MARK: - Sections

    /// Only shown for conditions that actually prevent scanning.
    @ViewBuilder
    private var hardwareWarningSection: some View {
        if let warning = DeviceCapabilities.blockingHardwareWarning {
            Section {
                Label {
                    Text(warning)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "wrench.and.screwdriver.fill")
                }
                .foregroundStyle(.orange)
            } header: {
                Text("Donanım uyarısı")
            }
        }
    }

    private var objectSection: some View {
        Section {
            Picker("Boyut", selection: $profile.size) {
                ForEach(ObjectProfile.Size.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Yüzey", selection: $profile.finish) {
                ForEach(ObjectProfile.Finish.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Desen", selection: $profile.pattern) {
                ForEach(ObjectProfile.Pattern.allCases) { Text($0.displayName).tag($0) }
            }
        } header: {
            Text("Objeyi tanımlayın")
        } footer: {
            Text("Bu üç cevap hangi sensörün doğru olduğunu belirler. En kritik olan desen: fotogrametri geometriyi yüzey deseninden üretir.")
        }
    }

    /// Replaces the object questionnaire in room mode.
    ///
    /// Room mode needs no questions: RoomPlan's technique does not change with the
    /// subject the way the object modes do. What it does need is an honest
    /// statement of what comes out, because "3D oda modeli" sets expectations that
    /// a parametric floor plan does not meet.
    private var roomSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Odanın yapısını çıkarır")
                    .font(.headline)
                Text("LiDAR duvarları, kapıları, pencereleri ve mobilyayı ayrı ayrı tanır ve gerçek ölçülerle yerleştirir. Boyalı düz duvar fotogrametriyi çökertir; bu mod tam o yüzeylerde çalışır çünkü geometriyi desenden değil ölçümden alır.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Label(
                    "Mobilya tanınmış kutular olarak gelir — koltuğun detaylı mesh'i çıkmaz. Detaylı obje için Fotogrametri modu.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

                Label(
                    "Model gerçek metre cinsinden çıkar; kütüphanede oda ölçülerini görürsünüz.",
                    systemImage: "ruler"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Label(
                    "Tek seferde tek oda. Ev için odaları ayrı ayrı tarayın.",
                    systemImage: "square.split.bottomrightquarter"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Oda taraması")
        }
    }

    private var recommendationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: recommendation.kind.symbolName)
                        .font(.title2)
                        .foregroundStyle(recommendation.strength.tint)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(recommendation.kind.displayName)
                                .font(.headline)
                            if let badge = recommendation.kind.maturity.badge {
                                Text(badge)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.orange.opacity(0.16), in: Capsule())
                            }
                        }
                        Text(recommendation.strength.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(recommendation.strength.tint)
                    }

                    Spacer()

                    Image(systemName: recommendation.strength.symbolName)
                        .foregroundStyle(recommendation.strength.tint)
                }

                Text(recommendation.rationale)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !recommendation.warnings.isEmpty || !recommendation.tips.isEmpty {
                    Divider()
                }

                ForEach(recommendation.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(recommendation.tips, id: \.self) { tip in
                    Label(tip, systemImage: "lightbulb.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
            // Coloured rule keyed to how well the mode fits, so a String(localized: "geçici çözüm")
            // reads as a caveat at a glance instead of looking like a green light.
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(recommendation.strength.tint)
                    .frame(width: 3)
                    .clipShape(Capsule())
                    .offset(x: -14)
            }
            .animation(.easeInOut(duration: 0.2), value: recommendation)
        } header: {
            Text("Öneri")
        }
    }

    private var modeSection: some View {
        Section {
            ForEach(ScanEngineKind.allCases) { kind in
                ModeRow(
                    kind: kind,
                    isSelected: kind == selectedKind,
                    isRecommended: kind == recommendation.kind,
                    blockedReason: blockedReason(for: kind)
                )
                .contentShape(.rect)
                .onTapGesture {
                    guard blockedReason(for: kind) == nil else { return }
                    overriddenKind = kind
                }
            }
        } header: {
            Text("Mod")
        } footer: {
            Text("Öneriyi geçersiz kılabilirsiniz. **beta** işaretli modlar çalışır ama güvenilir değil: sonuç objeye ve ortama göre belirgin şekilde değişir.")
        }
    }

    private var detailSection: some View {
        Section {
            Label("Cihaz üstü yeniden yapılandırma: reduced", systemImage: "cpu")
                .font(.subheadline)
            Label(
                "Kaynak görüntüler saklanır; tam detay için kütüphaneden Mac'e aktarabilirsiniz.",
                systemImage: "arrow.up.forward.app"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        } header: {
            Text("Yeniden yapılandırma")
        } footer: {
            // Worth stating plainly rather than hiding behind a disabled picker:
            // the ceiling is Apple's, not this app's.
            Text("iOS SDK'sı cihaz üstü fotogrametride yalnızca `reduced` seviyesini sunuyor. `medium` / `full` / `raw` sadece macOS'ta mevcut.")
        }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        Section("Cihaz yetenekleri") {
            ForEach(DeviceCapabilities.summary, id: \.label) { item in
                HStack {
                    Text(item.label)
                    Spacer()
                    Image(systemName: item.value ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(item.value ? .green : .secondary)
                }
                .font(.subheadline)
            }
        }

        // A dead lens does not enumerate, and the virtual combination devices
        // that depend on it vanish too. Listing what the system actually hands
        // out makes two units of the same model directly comparable.
        Section {
            ForEach(Array(DeviceCapabilities.rearCaptureDevices.enumerated()), id: \.offset) { _, device in
                HStack {
                    Text(device.label)
                        .font(.footnote)
                    Spacer()
                    if device.isVirtual {
                        Text("sanal")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        } header: {
            Text("Arka kamera envanteri")
        } footer: {
            Text("\(DeviceCapabilities.physicalRearLensCount) fiziksel lens. Aynı modelin iki cihazında bu liste farklıysa eksik olan lens arızalı demektir.")
        }
    }

    private var startButton: some View {
        Button {
            Task {
                guard await DeviceCapabilities.requestCameraAccess() else {
                    permissionDenied = true
                    return
                }
                isPresentingCapture = true
            }
        } label: {
            Text(canStart ? String(localized: "Taramayı Başlat") : (blockedReason(for: selectedKind) ?? String(localized: "Kullanılamıyor")))
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canStart)
        .padding()
        .background(.bar)
    }

    private func blockedReason(for kind: ScanEngineKind) -> String? {
        guard kind.isImplemented else { return String(localized: "Henüz gelmedi") }
        switch kind {
        case .objectCapture: return ObjectCaptureEngine.availability.blockedReason
        case .turntable: return TurntableCaptureEngine.availability.blockedReason
        case .trueDepth: return TrueDepthEngine.availability.blockedReason
        case .roomPlan: return RoomCaptureEngine.availability.blockedReason
        }
    }
}

private struct ModeRow: View {
    let kind: ScanEngineKind
    let isSelected: Bool
    let isRecommended: Bool
    let blockedReason: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbolName)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(blockedReason == nil ? .primary : .tertiary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kind.displayName)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                    if let badge = kind.maturity.badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.16), in: Capsule())
                    }
                    if isRecommended {
                        Text("önerilen")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.18), in: Capsule())
                    }
                }
                Text(blockedReason ?? kind.tagline)
                    .font(.caption)
                    .foregroundStyle(blockedReason == nil ? .secondary : .tertiary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .opacity(blockedReason == nil ? 1 : 0.55)
    }
}

private extension ModeRecommendation.Strength {
    var label: String {
        switch self {
        case .strong: "iyi uyum"
        case .qualified: String(localized: "çekinceli")
        case .fallback: String(localized: "geçici çözüm")
        }
    }

    var symbolName: String {
        switch self {
        case .strong: "checkmark.seal.fill"
        case .qualified: "exclamationmark.triangle.fill"
        case .fallback: "arrow.triangle.branch"
        }
    }

    var tint: Color {
        switch self {
        case .strong: .green
        case .qualified: .orange
        case .fallback: .yellow
        }
    }
}

#Preview {
    NavigationStack { ScanSetupView() }
        .environment(ScanStorage())
        .preferredColorScheme(.dark)
}
