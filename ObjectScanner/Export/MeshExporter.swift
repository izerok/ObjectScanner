import Foundation
import ModelIO
import os

enum MeshExportFormat: String, CaseIterable, Identifiable, Sendable {
    /// The reconstructor's native output — geometry plus material, no conversion.
    case usdz
    case obj
    case ply
    case stl

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .usdz: "USDZ"
        case .obj: "OBJ"
        case .ply: "PLY"
        case .stl: "STL"
        }
    }

    var explanation: String {
        switch self {
        case .usdz: String(localized: "Apple ekosistemi, AR Quick Look. Kaynak format — dönüşüm yok.")
        case .obj: String(localized: "Yaygın değişim formatı. Blender, MeshLab, ZBrush.")
        case .ply: String(localized: "Nokta bulutu / mesh, geometri odaklı araçlar.")
        case .stl: String(localized: "3B baskı. Sadece geometri, materyal taşımaz.")
        }
    }

    /// Whether the conversion drops surface appearance. Worth surfacing in the UI
    /// even for a geometry-first workflow, so nobody is surprised later.
    var isGeometryOnly: Bool {
        switch self {
        case .usdz, .obj: false
        case .ply, .stl: true
        }
    }
}

enum MeshExportError: LocalizedError {
    case sourceMissing
    case formatUnsupported(MeshExportFormat)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            String(localized: "Model dosyası bulunamadı.")
        case .formatUnsupported(let format):
            "\(format.displayName) bu cihazda desteklenmiyor."
        case .conversionFailed(let detail):
            "Dönüştürme başarısız: \(detail)"
        }
    }
}

enum MeshExporter {
    private static let logger = Logger(subsystem: "com.example.ObjectScanner", category: "export")

    /// Converts a reconstructed USDZ into `format`, returning a temporary file
    /// ready to hand to a share sheet.
    ///
    /// Conversion runs off the main actor — a full-detail mesh is large enough
    /// that ModelIO will visibly hitch the UI otherwise.
    ///
    /// When `millimetresPerUnit` is given, the calibration is baked into the
    /// geometry: STL/OBJ/PLY are written in millimetres (what slicers and CAD
    /// expect) and USDZ stays in metres (the USD convention), so a file
    /// dropped into a slicer measures what the real object measures.
    /// `removingCubeFaces` drops the calibration cube's triangles from the
    /// geometry-only formats, where the cube would otherwise end up printed.
    /// `guidedCubeHeightMillimetres` (v0.7) switches the removal to the
    /// designation-guided search: for a guided scan the cube may be fused
    /// onto the subject (an eroded remnant), which the blind component
    /// search cannot see at all. The mesh is metric in that flow, so the
    /// expected height in units is the real height over 1000.
    static func export(
        modelAt sourceURL: URL,
        as format: MeshExportFormat,
        namedLike baseName: String,
        millimetresPerUnit: Double? = nil,
        removingCubeFaces: Bool = false,
        guidedCubeHeightMillimetres: Double? = nil
    ) async throws -> URL {

        guard FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
            throw MeshExportError.sourceMissing
        }

        let safeName = baseName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let fileName = safeName.isEmpty ? "model" : safeName

        let destination = FileManager.default.temporaryDirectory
            .appending(path: "\(fileName).\(format.rawValue)", directoryHint: .notDirectory)
        try? FileManager.default.removeItem(at: destination)

        // Native format at native scale: copying keeps the share sheet's
        // filename consistent with the other formats.
        if format == .usdz, millimetresPerUnit == nil || millimetresPerUnit == 1000 {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return destination
        }

        guard MDLAsset.canExportFileExtension(format.rawValue) else {
            throw MeshExportError.formatUnsupported(format)
        }

        // Geometry-only formats with a scale to bake (or a cube to remove)
        // are written directly: full control over units and triangles, and
        // no dependence on ModelIO's unit assumptions.
        if format == .stl || format == .ply,
           millimetresPerUnit != nil || removingCubeFaces || guidedCubeHeightMillimetres != nil {
            let written = await Task.detached(priority: .userInitiated) {
                writeGeometryOnly(
                    sourceURL: sourceURL,
                    format: format,
                    millimetresPerUnit: millimetresPerUnit,
                    removingCubeFaces: removingCubeFaces,
                    guidedCubeHeightMillimetres: guidedCubeHeightMillimetres,
                    destination: destination
                )
            }.value
            if written { return destination }
            // Fall through to the ModelIO path below.
            try? FileManager.default.removeItem(at: destination)
        }

        try await Task.detached(priority: .userInitiated) {
            let asset = MDLAsset(url: sourceURL)
            guard asset.count > 0 else {
                throw MeshExportError.conversionFailed("Kaynak modelde geometri yok.")
            }
            // Bake the calibration into the remaining formats: OBJ goes to
            // millimetres, USDZ keeps metres and only takes the correction.
            if let millimetresPerUnit {
                let factor = format == .usdz ? millimetresPerUnit / 1000 : millimetresPerUnit
                if abs(factor - 1) > 1e-9 {
                    _ = MeshGeometry.scalePositions(in: asset, by: Float(factor))
                }
            }
            do {
                try asset.export(to: destination)
            } catch {
                throw MeshExportError.conversionFailed(error.localizedDescription)
            }
        }.value

        logger.info("Dışa aktarıldı: \(format.rawValue, privacy: .public)")
        return destination
    }

    // MARK: - Direct writers (STL / PLY)

    /// Writes STL (binary) or PLY (ASCII) from flattened geometry with the
    /// scale baked in and, optionally, the calibration cube removed.
    /// Returns false when the geometry could not be read, so the caller can
    /// fall back to ModelIO.
    private static func writeGeometryOnly(
        sourceURL: URL,
        format: MeshExportFormat,
        millimetresPerUnit: Double?,
        removingCubeFaces: Bool,
        guidedCubeHeightMillimetres: Double?,
        destination: URL
    ) -> Bool {
        guard let geometry = MeshGeometry.load(from: sourceURL) else { return false }

        var faces: [(UInt32, UInt32, UInt32)] = []
        faces.reserveCapacity(geometry.indices.count / 3)
        var dropFaces: Set<Int> = []
        if removingCubeFaces {
            if let guidedCubeHeightMillimetres,
               let guided = GuidedCalibrator.analyze(
                positions: geometry.positions,
                indices: geometry.indices,
                expectedHeightUnits: Float(guidedCubeHeightMillimetres / 1000.0)
               ) {
                // Located (found or eroded): exactly the faces the guided
                // search attributed to the designated object.
                dropFaces = guided.calibratorFaces
            } else if let segmentation = ScaleCalibrator.analyze(
                positions: geometry.positions,
                indices: geometry.indices
            ), let cubeComponent = segmentation.cubeComponent {
                for (f, ci) in segmentation.componentOfFace.enumerated() where ci == cubeComponent {
                    dropFaces.insert(f)
                }
            }
        }
        for f in 0 ..< geometry.indices.count / 3 {
            if dropFaces.contains(f) {
                continue
            }
            faces.append((
                geometry.indices[f * 3],
                geometry.indices[f * 3 + 1],
                geometry.indices[f * 3 + 2]
            ))
        }
        guard !faces.isEmpty else { return false }

        let scale = Float(millimetresPerUnit ?? 1)
        let positions = geometry.positions.map {
            SIMD3<Float>($0.x * scale, $0.y * scale, $0.z * scale)
        }

        do {
            switch format {
            case .stl:
                try writeBinarySTL(positions: positions, faces: faces, to: destination)
            case .ply:
                try writeASCIIPLY(positions: positions, faces: faces, to: destination)
            default:
                return false
            }
        } catch {
            return false
        }
        return true
    }

    private static func writeBinarySTL(
        positions: [SIMD3<Float>],
        faces: [(UInt32, UInt32, UInt32)],
        to url: URL
    ) throws {
        var data = Data(count: 80)
        var count = UInt32(faces.count)
        data.append(Data(bytes: &count, count: 4))
        data.reserveCapacity(84 + faces.count * 50)
        for face in faces {
            let a = positions[Int(face.0)]
            let b = positions[Int(face.1)]
            let c = positions[Int(face.2)]
            var normal = simd_cross(b - a, c - a)
            let length = simd_length(normal)
            normal = length > 0 ? normal / length : SIMD3<Float>(0, 0, 0)
            for value in [normal.x, normal.y, normal.z, a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z] {
                var v = value
                data.append(Data(bytes: &v, count: 4))
            }
            var attribute = UInt16(0)
            data.append(Data(bytes: &attribute, count: 2))
        }
        try data.write(to: url, options: .atomic)
    }

    private static func writeASCIIPLY(
        positions: [SIMD3<Float>],
        faces: [(UInt32, UInt32, UInt32)],
        to url: URL
    ) throws {
        var text = "ply\nformat ascii 1.0\n"
            + "element vertex \(positions.count)\n"
            + "property float x\nproperty float y\nproperty float z\n"
            + "element face \(faces.count)\n"
            + "property list uchar int vertex_indices\nend_header\n"
        text.reserveCapacity(positions.count * 24 + faces.count * 12)
        for p in positions {
            text += "\(p.x) \(p.y) \(p.z)\n"
        }
        for face in faces {
            text += "3 \(face.0) \(face.1) \(face.2)\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
