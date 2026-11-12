import Foundation
import simd

/// Pure mesh analysis behind turntable scale calibration: split a
/// reconstructed mesh into connected components, identify the scanned object
/// and a calibration cube sitting next to it, and measure both.
///
/// Deliberately free of ModelIO so the geometry logic can be exercised
/// offline on synthetic scenes. Assumes a Y-up mesh (USD/ModelIO convention).
enum ScaleCalibrator {

    struct Segmentation: Sendable {
        /// Compact component id per face, parallel to the input triangles.
        var componentOfFace: [Int]
        var objectComponent: Int
        var cubeComponent: Int?
        /// Bounding box of the object component, in model units.
        var objectDimensionsUnits: SIMD3<Float>
        /// Fitted height of the calibration cube in model units:
        /// its top plane level minus the level the object sits on.
        var cubeHeightUnits: Float?
    }

    private struct WeldKey: Hashable {
        var x: Int64
        var y: Int64
        var z: Int64
    }

    private struct ComponentStats {
        var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var vertexCount = 0
        var faceCount = 0
        var weldedIDs: [Int] = []

        var extents: SIMD3<Float> { maxP - minP }
    }

    static func analyze(positions: [SIMD3<Float>], indices: [UInt32]) -> Segmentation? {
        let faceCount = indices.count / 3
        guard positions.count >= 100, faceCount >= 100 else { return nil }

        var boundsMin = positions[0]
        var boundsMax = positions[0]
        for p in positions {
            boundsMin = simd_min(boundsMin, p)
            boundsMax = simd_max(boundsMax, p)
        }
        let diag = simd_length(boundsMax - boundsMin)
        guard diag > 0 else { return nil }

        // Weld duplicated vertices (ModelIO soup repeats shared corners).
        let eps = max(diag * 0.001, 1e-9)
        var weldMap: [WeldKey: Int] = [:]
        weldMap.reserveCapacity(positions.count)
        var weldedOf = [Int](repeating: 0, count: positions.count)
        var weldedPositions: [SIMD3<Float>] = []
        for (i, p) in positions.enumerated() {
            let key = WeldKey(
                x: Int64((p.x / eps).rounded()),
                y: Int64((p.y / eps).rounded()),
                z: Int64((p.z / eps).rounded())
            )
            if let existing = weldMap[key] {
                weldedOf[i] = existing
            } else {
                let id = weldedPositions.count
                weldMap[key] = id
                weldedPositions.append(p)
                weldedOf[i] = id
            }
        }

        // Union-find over welded vertices, joined by triangles.
        var parent = [Int](0 ..< weldedPositions.count)
        func find(_ a: Int) -> Int {
            var root = a
            while parent[root] != root { root = parent[root] }
            var node = a
            while parent[node] != root {
                let next = parent[node]
                parent[node] = root
                node = next
            }
            return root
        }

        // Kept parallel to the caller's triangle list (original slot kept in
        // .3) so component ids can be mapped back onto the source indices —
        // the exporter relies on that alignment to drop the cube's faces.
        var faces: [(Int, Int, Int, Int)] = []
        faces.reserveCapacity(faceCount)
        for f in 0 ..< faceCount {
            let a = weldedOf[Int(indices[f * 3])]
            let b = weldedOf[Int(indices[f * 3 + 1])]
            let c = weldedOf[Int(indices[f * 3 + 2])]
            guard a != b, b != c, a != c else { continue }
            faces.append((a, b, c, f))
            // Union all three roots onto one. Each root must be re-found:
            // chaining parent[ra]=rb; parent[rb]=rc without re-finding
            // creates a cycle when a and c already share a root.
            let root = find(a)
            for other in [b, c] {
                let r = find(other)
                if r != root { parent[r] = root }
            }
        }
        guard faces.count >= 100 else { return nil }

        // Component statistics.
        var stats: [Int: ComponentStats] = [:]
        for (wid, p) in weldedPositions.enumerated() {
            let root = find(wid)
            var s = stats[root] ?? ComponentStats()
            s.minP = simd_min(s.minP, p)
            s.maxP = simd_max(s.maxP, p)
            s.vertexCount += 1
            s.weldedIDs.append(wid)
            stats[root] = s
        }
        var componentOfFace = [Int](repeating: -1, count: faceCount)
        for face in faces {
            let root = find(face.0)
            componentOfFace[face.3] = root
            stats[root]?.faceCount += 1
        }

        // Compact component ids (union-find roots are sparse).
        var compact: [Int: Int] = [:]
        var compactStats: [ComponentStats] = []
        for (root, s) in stats where s.faceCount > 0 {
            compact[root] = compactStats.count
            compactStats.append(s)
        }
        for fi in componentOfFace.indices where componentOfFace[fi] >= 0 {
            componentOfFace[fi] = compact[componentOfFace[fi]] ?? -1
        }
        guard !compactStats.isEmpty else { return nil }

        func percentile(_ values: [Float], _ p: Float) -> Float {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let idx = min(sorted.count - 1, max(0, Int(p * Float(sorted.count))))
            return sorted[idx]
        }

        let sceneHeight = boundsMax.y - boundsMin.y
        guard sceneHeight > 0 else { return nil }

        // Each component's bottom level: a low percentile of its heights,
        // not the raw minimum — the minimum is one noise excursion below
        // the surface the component actually rests on.
        var bottomLevels: [Float] = []
        bottomLevels.reserveCapacity(compactStats.count)
        for s in compactStats {
            let ys = s.weldedIDs.map { weldedPositions[$0].y }
            bottomLevels.append(percentile(ys, 0.05))
        }

        // The level everything sits on (the support surface's top). Separate
        // components resting on it share the same bottom level, so cluster
        // the substantial components' bottom levels: the cluster with the
        // most members wins (object + cube outvote the support slab, whose
        // bottom is its own underside). Ties go to the higher cluster.
        // When object and support are fused into one component, the cube
        // still betrays the level; with no cube either, we fall back to the
        // fused component's bottom and heights read slightly tall.
        var sittingLevel = boundsMin.y
        do {
            let substantial = zip(compactStats, bottomLevels)
                .filter { $0.0.faceCount >= 100 }
                .map { $0.1 }
                .sorted()
            if !substantial.isEmpty {
                var best: (count: Int, level: Float) = (0, boundsMin.y)
                var i = 0
                while i < substantial.count {
                    var j = i
                    while j + 1 < substantial.count, substantial[j + 1] - substantial[i] <= 0.02 * sceneHeight {
                        j += 1
                    }
                    let level = substantial[(i + j) / 2]
                    let count = j - i + 1
                    if count > best.count || (count == best.count && level > best.level) {
                        best = (count, level)
                    }
                    i = j + 1
                }
                sittingLevel = best.level
            }
        }

        // "On base" tolerates a few percent of scene height — reconstruction
        // skirts sink slightly into the support surface.
        func isOnBase(_ id: Int, _ s: ComponentStats) -> Bool {
            bottomLevels[id] <= sittingLevel + 0.05 * sceneHeight
        }

        // The object: the on-base component near the scene centre with the
        // most presence, scored as height-above-the-support × √footprint.
        // The support surface itself scores ~zero (it does not rise above
        // its own top), a wide flat subject still beats a small tall cube,
        // and centrality helps because the subject sat in the middle of the
        // capture mask while the cube stands off to one side.
        let sceneCentreX = (boundsMin.x + boundsMax.x) / 2
        let sceneCentreZ = (boundsMin.z + boundsMax.z) / 2
        let sceneXZDiag = simd_length(SIMD2<Float>(boundsMax.x - boundsMin.x, boundsMax.z - boundsMin.z))
        func centralityOK(_ s: ComponentStats) -> Bool {
            let cx = (s.minP.x + s.maxP.x) / 2
            let cz = (s.minP.z + s.maxP.z) / 2
            let d = simd_length(SIMD2<Float>(cx - sceneCentreX, cz - sceneCentreZ))
            return sceneXZDiag == 0 || d <= 0.40 * sceneXZDiag
        }
        func presence(_ s: ComponentStats) -> Float {
            let e = s.extents
            let heightAbove = max(s.maxP.y - sittingLevel, 0)
            return heightAbove * sqrt(max(e.x * e.z, 0))
        }

        var objectID: Int?
        var objectKey: (Float, Int) = (-1, -1) // (presence, faceCount)
        for pass in 0 ..< 2 {
            for (id, s) in compactStats.enumerated() where s.faceCount >= 50 {
                guard isOnBase(id, s) else { continue }
                if pass == 0, !centralityOK(s) { continue }
                let key = (presence(s), s.faceCount)
                if key > objectKey {
                    objectKey = key
                    objectID = id
                }
            }
            if objectID != nil { break }
        }
        guard let objectID else { return nil }
        let object = compactStats[objectID]
        // Percentile, not the raw maximum: a single noise spike must not
        // stretch the reported height.
        let objectYs = object.weldedIDs.map { weldedPositions[$0].y }
        let objectHeight = percentile(objectYs, 0.995) - sittingLevel
        guard objectHeight > 0 else { return nil }

        // Object dimensions. Height is measured from the sitting level.
        // The footprint ignores the lowest sliver of vertices: when object
        // and support are fused, that sliver is partly support surface and
        // would inflate the footprint to the whole patch.
        let cutLevel = sittingLevel + 0.02 * sceneHeight
        var footXs: [Float] = []
        var footZs: [Float] = []
        for wid in object.weldedIDs {
            let p = weldedPositions[wid]
            guard p.y >= cutLevel else { continue }
            footXs.append(p.x)
            footZs.append(p.z)
        }
        let objectDims: SIMD3<Float>
        if footXs.count >= 10 {
            // Percentile extents: a few stray support vertices above the cut
            // must not stretch the footprint to the whole patch.
            objectDims = SIMD3<Float>(
                percentile(footXs, 0.99) - percentile(footXs, 0.01),
                objectHeight,
                percentile(footZs, 0.99) - percentile(footZs, 0.01)
            )
        } else {
            var e = object.extents
            e.y = objectHeight
            objectDims = e
        }

        // The cube: a small, near-cubic, on-base component that is not the
        // object. Flat or sprawling components (support fragments, debris)
        // fail the cubic test.
        var cubeID: Int?
        var cubeScore: Float = .greatestFiniteMagnitude
        for (id, s) in compactStats.enumerated() where id != objectID {
            guard s.faceCount >= 30, s.vertexCount >= 30 else { continue }
            guard isOnBase(id, s) else { continue }
            let e = s.extents
            let sortedExtents = [e.x, e.y, e.z].sorted()
            guard sortedExtents[0] > 0 else { continue }
            let ratio = sortedExtents[2] / sortedExtents[0]
            guard ratio <= 1.9 else { continue }
            let heightAbove = s.maxP.y - sittingLevel
            guard heightAbove >= 0.02 * sceneHeight, heightAbove <= 2.5 * objectHeight else { continue }
            // Small in plan view — a second subject-sized object is not a cube.
            guard e.x * e.z <= 0.5 * objectDims.x * objectDims.z else { continue }
            // Squarer is better; break ties toward the denser component.
            let score = ratio - Float(s.faceCount) * 0.0001
            if score < cubeScore {
                cubeScore = score
                cubeID = id
            }
        }

        var cubeHeight: Float?
        if let cubeID {
            // The cube's top is a flat face: find the height level with the
            // densest sliding window of vertices and average that window.
            // A percentile rides the noise tail and inflates the height
            // (hence deflates the scale); a window mean over the face's own
            // samples is unbiased.
            let cubeYs = compactStats[cubeID].weldedIDs.map { weldedPositions[$0].y }.sorted()
            let approxHeight = percentile(cubeYs, 0.99) - sittingLevel
            if approxHeight > 0, cubeYs.count >= 8 {
                let tau = max(0.08 * approxHeight, 1e-6)
                // Search only the top half: the bottom face is exactly as
                // dense as the top face and would otherwise win the tie.
                let firstTop = cubeYs.firstIndex { $0 >= sittingLevel + 0.5 * approxHeight } ?? cubeYs.count
                var bestStart = firstTop
                var bestCount = 0
                var end = firstTop
                for start in firstTop ..< cubeYs.count {
                    if end < start { end = start }
                    while end + 1 < cubeYs.count, cubeYs[end + 1] - cubeYs[start] <= 2 * tau {
                        end += 1
                    }
                    if end - start + 1 > bestCount {
                        bestCount = end - start + 1
                        bestStart = start
                    }
                }
                if bestCount > 0 {
                    let window = cubeYs[bestStart ..< bestStart + bestCount]
                    let topLevel = window.reduce(Float(0), +) / Float(window.count)
                    let height = topLevel - sittingLevel
                    if height > 0 { cubeHeight = height }
                }
            }
        }

        return Segmentation(
            componentOfFace: componentOfFace,
            objectComponent: objectID,
            cubeComponent: cubeID,
            objectDimensionsUnits: objectDims,
            cubeHeightUnits: cubeHeight
        )
    }
}
