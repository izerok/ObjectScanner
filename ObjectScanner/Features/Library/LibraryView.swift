import SwiftUI

struct LibraryView: View {
    @Environment(ScanStorage.self) private var storage

    /// Hand-rolled rather than using `List(selection:)` plus `EditButton`.
    ///
    /// Two reasons, both found the hard way. A `selection` binding on `List` takes
    /// over row taps, so `NavigationLink` rows stop navigating and just highlight.
    /// And `EditButton` writes to the ambient `editMode` environment value, which a
    /// local `.environment(\.editMode, …)` override on the list silently
    /// disconnects — the button toggles one value while the list reads another.
    ///
    /// Owning the mode means a tap does exactly one thing, chosen here.
    @State private var isSelecting = false
    @State private var selection = Set<UUID>()
    @State private var isConfirmingBulkDelete = false

    var body: some View {
        Group {
            if storage.scans.isEmpty {
                ContentUnavailableView(
                    "Henüz tarama yok",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("Tara sekmesinden ilk taramanızı yapın.")
                )
            } else {
                List {
                    ForEach(storage.scans) { record in
                        row(for: record)
                    }
                    .onDelete { offsets in
                        delete(storage.scans.enumerated().filter { offsets.contains($0.offset) }.map(\.element))
                    }
                }
            }
        }
        // Doubles as confirmation that tapping a row actually registered.
        .navigationTitle(selectionTitle)
        .navigationDestination(for: UUID.self) { ScanDetailView(recordID: $0) }
        .toolbar {
            if !storage.scans.isEmpty {
                if isSelecting {
                    ToolbarItem(placement: .topBarLeading) { selectAllButton }
                    // Not `.bottomBar`: this screen lives inside a TabView, whose tab
                    // bar owns the bottom edge, and the item simply never drew there.
                    ToolbarItem(placement: .topBarTrailing) { deleteSelectedButton }
                }
                ToolbarItem(placement: .topBarTrailing) { selectModeButton }
            }
        }
        .confirmationDialog(
            "\(selection.count) tarama silinsin mi?",
            isPresented: $isConfirmingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Sil", role: .destructive) { deleteSelected() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Modeller ve kaynak görüntüler kalıcı olarak silinir. Bu geri alınamaz.")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for record: ScanRecord) -> some View {
        let content = ScanRow(record: record, modelURL: storage.modelURL(for: record))

        if isSelecting {
            Button {
                if selection.contains(record.id) {
                    selection.remove(record.id)
                } else {
                    selection.insert(record.id)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selection.contains(record.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selection.contains(record.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    content
                }
                .contentShape(.rect)
            }
            // Plain, or the whole row would render in the accent colour.
            .buttonStyle(.plain)
        } else {
            // Navigate by id, not by value: the detail screen renames records, and a
            // captured copy would go stale immediately.
            NavigationLink(value: record.id) { content }
        }
    }

    // MARK: - Toolbar

    private var selectionTitle: String {
        guard isSelecting else { return "Kütüphane" }
        return selection.isEmpty ? String(localized: "Seçin") : "\(selection.count) seçildi"
    }

    private var selectModeButton: some View {
        Button(isSelecting ? "Bitti" : "Seç") {
            isSelecting.toggle()
            // Ticks left behind would silently apply to the next round of selecting.
            if !isSelecting { selection.removeAll() }
        }
    }

    private var selectAllButton: some View {
        Button(selection.count == storage.scans.count ? "Seçimi Kaldır" : "Tümünü Seç") {
            if selection.count == storage.scans.count {
                selection.removeAll()
            } else {
                selection = Set(storage.scans.map(\.id))
            }
        }
    }

    private var deleteSelectedButton: some View {
        Button {
            isConfirmingBulkDelete = true
        } label: {
            Label("Sil", systemImage: "trash")
        }
        // Red rather than the accent colour, so it reads as destructive even though
        // it now sits in the navigation bar next to a harmless "Bitti".
        .tint(.red)
        .disabled(selection.isEmpty)
    }

    // MARK: - Actions

    private func deleteSelected() {
        // Resolved to records before deleting: `storage.scans` shrinks as it goes,
        // so anything holding indices would delete the wrong rows.
        delete(storage.scans.filter { selection.contains($0.id) })
        selection.removeAll()
        isSelecting = false
    }

    private func delete(_ records: [ScanRecord]) {
        for record in records {
            // The thumbnail is cached by URL, and a new scan can reuse a path.
            ThumbnailStore.shared.invalidate(storage.modelURL(for: record))
            storage.delete(record)
        }
    }
}

private struct ScanRow: View {
    let record: ScanRecord
    let modelURL: URL

    var body: some View {
        HStack(spacing: 12) {
            if record.isPreviewable {
                ModelThumbnailView(url: modelURL, side: 54)
            } else {
                // Quick Look cannot render a point cloud, so there is nothing to
                // thumbnail until the meshing pass lands.
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(width: 54, height: 54)
                    .overlay {
                        Image(systemName: "aqi.medium")
                            .foregroundStyle(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(record.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Label(record.engine.displayName, systemImage: record.engine.symbolName)
                    if let summary = record.summary {
                        Text("·")
                        Text(summary)
                    }
                    if let count = record.imageCount {
                        Text("·")
                        Text("\(count) görüntü")
                    }
                    if let count = record.pointCount {
                        Text("·")
                        Text("\(count) nokta")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

struct ScanDetailView: View {
    let recordID: UUID

    @Environment(ScanStorage.self) private var storage

    @State private var exportFormat: MeshExportFormat = .usdz
    @State private var shareableURL: URL?
    @State private var isExporting = false
    @State private var isBundling = false
    @State private var errorMessage: String?
    @State private var draftName = ""
    @State private var cubeHeightText = ""
    @State private var caliperText = ""
    @State private var isAnalyzing = false

    private var record: ScanRecord? {
        storage.scans.first { $0.id == recordID }
    }

    var body: some View {
        if let record {
            detail(for: record)
        } else {
            // Reachable if the scan is deleted while this screen is on-screen.
            ContentUnavailableView("Tarama bulunamadı", systemImage: "questionmark.folder")
        }
    }

    private func detail(for record: ScanRecord) -> some View {
        List {
            if record.isPreviewable {
                Section {
                    ModelPreviewView(url: storage.modelURL(for: record))
                        .frame(height: 320)
                        .listRowInsets(EdgeInsets())
                }
            } else {
                Section {
                    PointCloudPreviewView(url: storage.modelURL(for: record))
                        .frame(height: 320)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Döndürmek için sürükleyin, yakınlaşmak için iki parmak.")
                }
            }

            Section("Bilgi") {
                TextField("İsim", text: $draftName)
                    .onSubmit { storage.rename(record, to: draftName) }
                LabeledContent("Mod", value: record.engine.displayName)
                if let summary = record.summary {
                    LabeledContent("İçerik", value: summary)
                }
                if let detail = record.detail {
                    LabeledContent("Yoğunluk", value: detail.displayName)
                }
                LabeledContent("Ölçek", value: record.isMetricallyScaled ? String(localized: "Gerçek boyut") : String(localized: "Ölçeksiz"))
                LabeledContent("Tarih", value: record.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let count = record.imageCount {
                    LabeledContent("Görüntü", value: "\(count)")
                }
                if let count = record.pointCount {
                    LabeledContent("Nokta", value: "\(count)")
                }
                if let dimensions = record.dimensionsMillimetres, dimensions.count == 3 {
                    LabeledContent(
                        "Boyut",
                        value: "\(dimensions[0]) × \(dimensions[1]) × \(dimensions[2]) mm"
                    )
                }
            }

            if record.engine == .turntable {
                calibrationSection(for: record)
            }

            exportSection(for: record)

            if storage.hasIntermediates(for: record) {
                fullDetailSection(for: record)
            }
        }
        .navigationTitle(record.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let shareableURL {
                    ShareLink(item: shareableURL)
                }
            }
        }
        .alert(
            "İşlem başarısız",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("Tamam") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            draftName = record.name
            let stored = UserDefaults.standard.object(forKey: "calibration.cubeHeightMM") as? Double
            let cubeHeight = record.scaleCalibration?.cubeRealHeightMillimetres ?? stored ?? 10.0
            cubeHeightText = Self.trimmedNumber(cubeHeight)
        }
    }

    // MARK: - Scale calibration

    private static func trimmedNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func formatDimensions(_ dims: [Double]) -> String {
        dims.map { String(format: "%.1f", $0) }.joined(separator: " × ") + " mm"
    }

    /// Whether the mesh itself carries depth scale, as opposed to the record
    /// merely being marked metric by an earlier cube/caliper calibration.
    private func meshHasDepthScale(_ record: ScanRecord) -> Bool {
        if let calibration = record.scaleCalibration {
            return calibration.depthDimensionsMillimetres != nil
        }
        return record.isMetricallyScaled
    }

    @ViewBuilder
    private func calibrationSection(for record: ScanRecord) -> some View {
        Section {
            if let calibration = record.scaleCalibration {
                LabeledContent("Kalibrasyon yöntemi", value: calibration.method.displayName)
                if let depth = calibration.depthDimensionsMillimetres, depth.count == 3 {
                    LabeledContent("Derinlik boyutu", value: Self.formatDimensions(depth))
                }
                if let visual = calibration.visualDimensionsMillimetres, visual.count == 3 {
                    LabeledContent("Görsel boyut", value: Self.formatDimensions(visual))
                }
                if let discrepancy = calibration.discrepancyPercent {
                    LabeledContent(
                        "Ölçek uyuşmazlığı",
                        value: String(format: "%.1f%%", discrepancy)
                    )
                }
                if let fitted = calibration.cubeHeightUnits,
                   let real = calibration.cubeRealHeightMillimetres {
                    LabeledContent(
                        "Küp yüksekliği",
                        value: String(format: "%.2f → %@ mm", fitted, Self.trimmedNumber(real))
                    )
                }
                if let caliper = calibration.caliperMeasuredMillimetres {
                    LabeledContent("Kumpas değeri", value: "\(Self.trimmedNumber(caliper)) mm")
                }
            } else if record.isMetricallyScaled {
                Text("Ölçek derinlikten geliyor; kalibrasyon küpü bulunamadı.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Bu tarama ölçeksiz. Kalibrasyon küpüyle tarayın veya kumpasla kalibre edin.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Küp gerçek yüksekliği (mm)")
                Spacer()
                TextField("10", text: $cubeHeightText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
            }
            Button {
                reanalyze(record)
            } label: {
                HStack {
                    Text("Yeniden hesapla")
                    if isAnalyzing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isAnalyzing)

            HStack {
                Text("En uzun kenar (mm)")
                Spacer()
                TextField("58", text: $caliperText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
            }
            Button("Kumpasla kalibre et") { applyCaliper(record) }
                .disabled(isAnalyzing || parsedNumber(caliperText) == nil)
        } header: {
            Text("Ölçek kalibrasyonu")
        } footer: {
            Text("Küpü objenin yanına koyup birlikte tarayın; uygulama küpü mesh içinde bulup ölçeği ondan alır.")
        }
    }

    private func parsedNumber(_ text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else { return nil }
        return value
    }

    private func reanalyze(_ record: ScanRecord) {
        guard let cubeHeight = parsedNumber(cubeHeightText) else { return }
        UserDefaults.standard.set(cubeHeight, forKey: "calibration.cubeHeightMM")
        isAnalyzing = true
        let url = storage.modelURL(for: record)
        let hasDepth = meshHasDepthScale(record)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                TurntableScaleAnalyzer.analyze(
                    modelAt: url,
                    isMetricallyScaled: hasDepth,
                    cubeRealHeightMillimetres: cubeHeight
                )
            }.value
            isAnalyzing = false
            guard let outcome else {
                errorMessage = String(localized: "Model dosyası bulunamadı.")
                return
            }
            var updated = record
            if let calibration = outcome.calibration {
                updated.scaleCalibration = calibration
            }
            if let dimensions = outcome.objectDimensionsMillimetres {
                updated.dimensionsMillimetres = dimensions
            }
            updated.isMetricallyScaled = hasDepth
                || updated.scaleCalibration != nil
            storage.update(updated)
        }
    }

    private func applyCaliper(_ record: ScanRecord) {
        guard let measured = parsedNumber(caliperText) else { return }
        isAnalyzing = true
        let url = storage.modelURL(for: record)
        let hasDepth = meshHasDepthScale(record)
        let cubeHeight = parsedNumber(cubeHeightText) ?? 10.0
        Task {
            var units = record.scaleCalibration?.objectDimensionsUnits
            var baseCalibration = record.scaleCalibration
            if units == nil {
                let outcome = await Task.detached(priority: .userInitiated) {
                    TurntableScaleAnalyzer.analyze(
                        modelAt: url,
                        isMetricallyScaled: hasDepth,
                        cubeRealHeightMillimetres: cubeHeight
                    )
                }.value
                units = outcome?.objectDimensionsUnits
                if baseCalibration == nil { baseCalibration = outcome?.calibration }
            }
            isAnalyzing = false
            guard let units, units.count == 3, let longest = units.max(), longest > 0 else {
                errorMessage = String(localized: "Model dosyası bulunamadı.")
                return
            }
            let factor = measured / longest
            var calibration = baseCalibration ?? ScaleCalibration(
                method: .caliper,
                millimetresPerUnit: factor,
                objectDimensionsUnits: units,
                depthDimensionsMillimetres: nil,
                visualDimensionsMillimetres: nil,
                cubeHeightUnits: nil,
                cubeRealHeightMillimetres: nil,
                discrepancyPercent: nil,
                caliperMeasuredMillimetres: measured
            )
            calibration.method = .caliper
            calibration.millimetresPerUnit = factor
            calibration.objectDimensionsUnits = units
            calibration.caliperMeasuredMillimetres = measured
            var updated = record
            updated.scaleCalibration = calibration
            updated.dimensionsMillimetres = units.map { Int(($0 * factor).rounded()) }
            updated.isMetricallyScaled = true
            storage.update(updated)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func exportSection(for record: ScanRecord) -> some View {
        if record.isPreviewable {
            meshExportSection(for: record)
        } else {
            // `MeshExporter` runs through ModelIO, which has nothing to convert
            // here — the PLY is already the deliverable.
            Section {
                Button("PLY'yi Paylaş") { sharePointCloud(record) }
            } header: {
                Text("Dışa aktarma")
            } footer: {
                Text("Nokta bulutu PLY olarak kaydedildi. Mesh'e çevirme (marching cubes) sonraki artımda gelecek.")
            }
        }
    }

    private func meshExportSection(for record: ScanRecord) -> some View {
        Section {
            Picker("Format", selection: $exportFormat) {
                ForEach(MeshExportFormat.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(exportFormat.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if exportFormat.isGeometryOnly {
                Label("Bu format materyal/texture taşımaz — sadece geometri.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                export(record)
            } label: {
                HStack {
                    Text("Dışa Aktar")
                    if isExporting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isExporting)
        } header: {
            Text("Dışa aktarma")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hazırlanan dosya sağ üstteki paylaş düğmesinde görünür.")
                if exportMillimetresPerUnit(for: record) != nil {
                    Text("Dışa aktarma birimi: STL/OBJ/PLY milimetre, USDZ metre — ölçek gömülüdür.")
                } else {
                    Text("Kalibre edilmemiş dışa aktarma özgün birimdedir; boyutlar yanlış olabilir.")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// The factor an export must bake in: the calibration's, or the plain
    /// metres→millimetres conversion for a depth-scaled mesh.
    private func exportMillimetresPerUnit(for record: ScanRecord) -> Double? {
        record.scaleCalibration?.millimetresPerUnit
            ?? (record.isMetricallyScaled ? 1000 : nil)
    }

    private func fullDetailSection(for record: ScanRecord) -> some View {
        Section {
            LabeledContent(
                "Kaynak görüntüler",
                value: ByteCountFormatter.string(
                    fromByteCount: storage.intermediateBytes(for: record),
                    countStyle: .file
                )
            )

            Button {
                bundleImages(record)
            } label: {
                HStack {
                    Text("Görüntüleri Mac'e Aktar (.zip)")
                    if isBundling {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isBundling)

            DisclosureGroup("Mac tarafında ne yapmalı?") {
                Text(SourceImageBundle.macInstructions)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Button("Kaynak Görüntüleri Sil", role: .destructive) {
                storage.purgeIntermediates(for: record)
            }
        } header: {
            Text("Tam detay")
        } footer: {
            Text("Cihaz üstü model `reduced` seviyede. Aynı görüntüleri bir Mac'te `detail: .full` veya `.raw` ile işlerseniz belirgin şekilde yüksek poligonlu mesh alırsınız. Görüntüleri silerseniz bu yol kapanır.")
        }
    }

    // MARK: - Actions

    private func export(_ record: ScanRecord) {
        isExporting = true
        shareableURL = nil
        let factor = exportMillimetresPerUnit(for: record)
        let removeCube = record.engine == .turntable
            && record.scaleCalibration?.cubeHeightUnits != nil
        Task {
            do {
                shareableURL = try await MeshExporter.export(
                    modelAt: storage.modelURL(for: record),
                    as: exportFormat,
                    namedLike: record.name,
                    millimetresPerUnit: factor,
                    removingCubeFaces: removeCube
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }

    private func sharePointCloud(_ record: ScanRecord) {
        shareableURL = storage.modelURL(for: record)
    }

    private func bundleImages(_ record: ScanRecord) {
        isBundling = true
        shareableURL = nil
        Task {
            do {
                shareableURL = try await SourceImageBundle.makeArchive(
                    imagesDirectory: storage.directoryURL(for: record).appending(path: "images"),
                    named: record.name
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isBundling = false
        }
    }
}

#Preview {
    NavigationStack { LibraryView() }
        .environment(ScanStorage())
        .preferredColorScheme(.dark)
}
