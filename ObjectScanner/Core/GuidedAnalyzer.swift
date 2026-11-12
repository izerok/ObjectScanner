import Foundation
import simd

/// Designation-guided scale analysis (v0.7).
///
/// The user designates the calibration object at framing time and its true
/// height is fixed (10 mm). A prior scale estimate (from the session's
/// depth) turns that into an expected height in model units, which turns
/// blind cube-hunting into verification: candidates are searched in a
/// height window around the expectation — as separate components, or as
/// "satellite" lobes fused onto the subject component (the eroded-stump
/// case) — fitted, and classified. A located candidate outside the accept
/// band is reported as such and yields NO scale: a wrong scale delivered
/// silently is worse than none.
enum GuidedCalibrator {

    enum Verdict: Equatable, Sendable {
        /// Fitted height inside the accept band — scale may be derived.
        case found(heightUnits: Float)
        /// Located, but far too short (eroded reconstruction remnant).
        case eroded(heightUnits: Float)
        /// Located, but far too tall to be the designated object.
        case oversized(heightUnits: Float)
        /// Nothing in the search windows.
        case notFound
    }

    struct Result: Sendable {
        var componentOfFace: [Int]
        var objectComponent: Int
        var objectDimensionsUnits: SIMD3<Float>
        var sittingLevel: Float
        var verdict: Verdict
        /// Faces belonging to a located candidate (component or satellite
        /// cluster), for export-time removal. Empty when not located.
        var calibratorFaces: Set<Int>
        /// Where the winning candidate came from: "component" / "satellite".
        var candidateSource: String?
    }

    private struct WeldKey: Hashable {
        var x: Int64
        var y: Int64
        var z: Int64
    }

    private struct Comp {
        var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var weldedIDs: [Int] = []
        var faceCount = 0
        var extents: SIMD3<Float> { maxP - minP }
    }

    static func analyze(
        positions: [SIMD3<Float>],
        indices: [UInt32],
        expectedHeightUnits: Float
    ) -> Result? {
        guard positions.count >= 8, indices.count >= 12, expectedHeightUnits > 0 else { return nil }
        let faceCount = indices.count / 3

        var boundsMin = positions[0]
        var boundsMax = positions[0]
        for p in positions {
            boundsMin = simd_min(boundsMin, p)
            boundsMax = simd_max(boundsMax, p)
        }
        let sceneDiag = simd_length(boundsMax - boundsMin)
        let sceneHeight = boundsMax.y - boundsMin.y
        guard sceneDiag > 0, sceneHeight > 0 else { return nil }

        // Weld + union-find components (same construction as ScaleCalibrator).
        let eps = max(sceneDiag * 0.001, 1e-9)
        var weldMap: [WeldKey: Int] = [:]
        var weldedOf = [Int](repeating: 0, count: positions.count)
        var welded: [SIMD3<Float>] = []
        for (i, p) in positions.enumerated() {
            let key = WeldKey(
                x: Int64((p.x / eps).rounded()),
                y: Int64((p.y / eps).rounded()),
                z: Int64((p.z / eps).rounded())
            )
            if let existing = weldMap[key] {
                weldedOf[i] = existing
            } else {
                let id = welded.count
                weldMap[key] = id
                welded.append(p)
                weldedOf[i] = id
            }
        }
        var parent = [Int](0 ..< welded.count)
        func root(_ a: Int) -> Int {
            var r = a
            while parent[r] != r { r = parent[r] }
            var n = a
            while parent[n] != r {
                let next = parent[n]
                parent[n] = r
                n = next
            }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = root(a), rb = root(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        var faces: [(Int, Int, Int)] = []
        faces.reserveCapacity(faceCount)
        for f in 0 ..< faceCount {
            let a = weldedOf[Int(indices[f * 3])]
            let b = weldedOf[Int(indices[f * 3 + 1])]
            let c = weldedOf[Int(indices[f * 3 + 2])]
            faces.append((a, b, c))
            union(a, b)
            union(b, c)
        }
        var compIndexOfRoot: [Int: Int] = [:]
        var comps: [Comp] = []
        var compOfWelded = [Int](repeating: 0, count: welded.count)
        for wid in 0 ..< welded.count {
            let r = root(wid)
            let ci: Int
            if let existing = compIndexOfRoot[r] {
                ci = existing
            } else {
                ci = comps.count
                compIndexOfRoot[r] = ci
                comps.append(Comp())
            }
            compOfWelded[wid] = ci
            comps[ci].weldedIDs.append(wid)
            comps[ci].minP = simd_min(comps[ci].minP, welded[wid])
            comps[ci].maxP = simd_max(comps[ci].maxP, welded[wid])
        }
        var componentOfFace = [Int](repeating: 0, count: faceCount)
        for (f, tri) in faces.enumerated() {
            let ci = compOfWelded[tri.0]
            componentOfFace[f] = ci
            comps[ci].faceCount += 1
        }

        func percentile(_ values: [Float], _ p: Float) -> Float {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let idx = min(max(Int((p * Float(sorted.count - 1)).rounded()), 0), sorted.count - 1)
            return sorted[idx]
        }

        // Sitting level: cluster of substantial components' bottom levels.
        var bottomLevels: [Float] = []
        for s in comps {
            let ys = s.weldedIDs.map { welded[$0].y }
            bottomLevels.append(percentile(ys, 0.05))
        }
        var sittingLevel = boundsMin.y
        do {
            let substantial = zip(comps, bottomLevels)
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
        func isOnBase(_ id: Int) -> Bool {
            bottomLevels[id] <= sittingLevel + 0.05 * sceneHeight
        }

        // Subject pick (mirrors ScaleCalibrator: presence × centrality).
        let centreX = (boundsMin.x + boundsMax.x) / 2
        let centreZ = (boundsMin.z + boundsMax.z) / 2
        let xzDiag = simd_length(SIMD2<Float>(boundsMax.x - boundsMin.x, boundsMax.z - boundsMin.z))
        func presence(_ s: Comp) -> Float {
            let e = s.extents
            return max(s.maxP.y - sittingLevel, 0) * sqrt(max(e.x * e.z, 0))
        }
        var objectID: Int?
        var objectKey: (Float, Int) = (-1, -1)
        for pass in 0 ..< 2 {
            for (id, s) in comps.enumerated() where s.faceCount >= 50 {
                guard isOnBase(id) else { continue }
                if pass == 0 {
                    let cx = (s.minP.x + s.maxP.x) / 2
                    let cz = (s.minP.z + s.maxP.z) / 2
                    let d = simd_length(SIMD2<Float>(cx - centreX, cz - centreZ))
                    if xzDiag > 0, d > 0.40 * xzDiag { continue }
                }
                let key = (presence(s), s.faceCount)
                if key > objectKey {
                    objectKey = key
                    objectID = id
                }
            }
            if objectID != nil { break }
        }
        guard let objectID else { return nil }
        let object = comps[objectID]
        let objectYs = object.weldedIDs.map { welded[$0].y }
        let objectTopRaw = percentile(objectYs, 0.995)

        // Fused-support refinement: when the subject component sprawls far
        // beyond its own top core (object fused with its support disc), the
        // cluster sitting level is the support's underside and heights read
        // tall by the support's thickness. The support's top is a dense
        // level in the component's bottom band — raise the sitting level to
        // the highest such level. Only when nothing else betrayed the seat:
        // if a separate component already sits above the subject's bottom
        // (scene E's cubes), the cluster level is right and refinement
        // would only shave real height off every measurement.
        if sittingLevel <= bottomLevels[objectID] + 0.02 * sceneHeight {
            let coreVerts = object.weldedIDs.filter { welded[$0].y >= sittingLevel + 0.5 * (objectTopRaw - sittingLevel) }
            if coreVerts.count >= 20 {
                let coreXs = coreVerts.map { welded[$0].x }
                let coreZs = coreVerts.map { welded[$0].z }
                let coreArea = max(
                    (percentile(coreXs, 0.99) - percentile(coreXs, 0.01))
                        * (percentile(coreZs, 0.99) - percentile(coreZs, 0.01)),
                    1e-12
                )
                let fullArea = max(object.extents.x * object.extents.z, 1e-12)
                if fullArea >= 1.8 * coreArea {
                    let bottom = bottomLevels[objectID]
                    let bandTop = bottom + 0.18 * (objectTopRaw - bottom)
                    let bandYs = objectYs.filter { $0 >= bottom && $0 <= bandTop }.sorted()
                    if bandYs.count >= 40 {
                        let w = max(0.025 * sceneHeight, 1e-6)
                        var bestCount = 0
                        var refined: Float?
                        var end = 0
                        for start in 0 ..< bandYs.count {
                            if end < start { end = start }
                            while end + 1 < bandYs.count, bandYs[end + 1] - bandYs[start] <= w {
                                end += 1
                            }
                            let count = end - start + 1
                            if count > bestCount { bestCount = count }
                        }
                        var end2 = 0
                        for start in 0 ..< bandYs.count {
                            if end2 < start { end2 = start }
                            while end2 + 1 < bandYs.count, bandYs[end2 + 1] - bandYs[start] <= w {
                                end2 += 1
                            }
                            let count = end2 - start + 1
                            if count >= Int(0.25 * Float(bestCount)) {
                                let level = bandYs[start ..< start + count].reduce(Float(0), +) / Float(count)
                                if level > bottom + 0.02 * sceneHeight {
                                    refined = level // keep scanning: highest wins
                                }
                            }
                        }
                        if let refined, refined > sittingLevel {
                            sittingLevel = refined
                        }
                    }
                }
            }
        }

        let objectHeight = objectTopRaw - sittingLevel
        guard objectHeight > 0 else { return nil }

        // Object dimensions (footprint above a cut level, percentile extents).
        let objectDims: SIMD3<Float>
        do {
            let cut = sittingLevel + 0.02 * sceneHeight
            var footXs: [Float] = []
            var footZs: [Float] = []
            for wid in object.weldedIDs {
                let p = welded[wid]
                guard p.y >= cut else { continue }
                footXs.append(p.x)
                footZs.append(p.z)
            }
            if footXs.count >= 10 {
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
        }
        let subjectPlanDiag = simd_length(SIMD2<Float>(objectDims.x, objectDims.z))

        // Densest-window top fit over the top half (as in ScaleCalibrator).
        func slabTop(sortedYs: [Float], approxHeight: Float) -> Float? {
            guard approxHeight > 0, sortedYs.count >= 8 else { return nil }
            let tau = max(0.08 * approxHeight, 1e-6)
            let firstTop = sortedYs.firstIndex { $0 >= sittingLevel + 0.5 * approxHeight } ?? sortedYs.count
            guard firstTop < sortedYs.count else { return nil }
            var bestStart = firstTop
            var bestCount = 0
            var end = firstTop
            for start in firstTop ..< sortedYs.count {
                if end < start { end = start }
                while end + 1 < sortedYs.count, sortedYs[end + 1] - sortedYs[start] <= 2 * tau {
                    end += 1
                }
                if end - start + 1 > bestCount {
                    bestCount = end - start + 1
                    bestStart = start
                }
            }
            guard bestCount > 0 else { return nil }
            let window = sortedYs[bestStart ..< bestStart + bestCount]
            let top = window.reduce(Float(0), +) / Float(window.count)
            let h = top - sittingLevel
            return h > 0 ? h : nil
        }

        struct Candidate {
            var fittedHeight: Float
            var faces: Set<Int>
            var source: String
            var score: Float // |ratio - 1|
        }
        var candidates: [Candidate] = []
        let searchLow = 0.25 * expectedHeightUnits
        let searchHigh = 1.8 * expectedHeightUnits

        // Path A: separate components.
        for (id, s) in comps.enumerated() where id != objectID {
            guard s.faceCount >= 30, s.weldedIDs.count >= 30 else { continue }
            guard isOnBase(id) else { continue }
            let approxH = s.maxP.y - sittingLevel
            guard approxH >= searchLow, approxH <= searchHigh else { continue }
            let ex = s.extents.x, ez = s.extents.z
            guard min(ex, ez) > 0 else { continue }
            guard max(ex, ez) / min(ex, ez) <= 2.4 else { continue }
            guard simd_length(SIMD2<Float>(ex, ez)) <= 0.65 * subjectPlanDiag else { continue }
            let ys = s.weldedIDs.map { welded[$0].y }.sorted()
            let fitted = slabTop(sortedYs: ys, approxHeight: percentile(ys, 0.99) - sittingLevel) ?? approxH
            guard fitted >= searchLow, fitted <= searchHigh else { continue }
            var faceSet = Set<Int>()
            for (f, ci) in componentOfFace.enumerated() where ci == id { faceSet.insert(f) }
            candidates.append(Candidate(
                fittedHeight: fitted,
                faces: faceSet,
                source: "component",
                score: abs(fitted / expectedHeightUnits - 1)
            ))
        }

        // Path B: satellite lobes fused onto the subject component — material
        // outside the subject's top-half core, low enough to be the
        // designated object, clustered on the ground plane.
        do {
            let coreVerts = object.weldedIDs.filter { welded[$0].y >= sittingLevel + 0.5 * objectHeight }
            if coreVerts.count >= 20 {
                let coreXs = coreVerts.map { welded[$0].x }
                let coreZs = coreVerts.map { welded[$0].z }
                let coreMinX = percentile(coreXs, 0.01), coreMaxX = percentile(coreXs, 0.99)
                let coreMinZ = percentile(coreZs, 0.01), coreMaxZ = percentile(coreZs, 0.99)
                let margin = 0.12 * expectedHeightUnits
                let cell = 0.2 * expectedHeightUnits
                let yCap = sittingLevel + searchHigh
                var satVerts: [Int] = []
                for wid in object.weldedIDs {
                    let p = welded[wid]
                    guard p.y <= yCap, p.y >= sittingLevel - 0.05 * expectedHeightUnits else { continue }
                    let outside = p.x < coreMinX - margin || p.x > coreMaxX + margin
                        || p.z < coreMinZ - margin || p.z > coreMaxZ + margin
                    if outside { satVerts.append(wid) }
                }
                if satVerts.count >= 20 {
                    // Union-find over ground-plane grid cells.
                    var sParent = [Int](0 ..< satVerts.count)
                    func sRoot(_ a: Int) -> Int {
                        var r = a
                        while sParent[r] != r { r = sParent[r] }
                        var n = a
                        while sParent[n] != r {
                            let next = sParent[n]
                            sParent[n] = r
                            n = next
                        }
                        return r
                    }
                    var cellFirst: [WeldKey: Int] = [:]
                    for (i, wid) in satVerts.enumerated() {
                        let p = welded[wid]
                        let cx = Int64(floor(p.x / cell))
                        let cz = Int64(floor(p.z / cell))
                        for dx in Int64(-1) ... Int64(1) {
                            for dz in Int64(-1) ... Int64(1) {
                                let key = WeldKey(x: cx + dx, y: 0, z: cz + dz)
                                if let other = cellFirst[key] {
                                    let ra = sRoot(i), rb = sRoot(other)
                                    if ra != rb { sParent[max(ra, rb)] = min(ra, rb) }
                                }
                            }
                        }
                        let own = WeldKey(x: cx, y: 0, z: cz)
                        if cellFirst[own] == nil { cellFirst[own] = i }
                    }
                    var clusters: [Int: [Int]] = [:]
                    for (i, wid) in satVerts.enumerated() {
                        clusters[sRoot(i), default: []].append(wid)
                    }
                    for (_, members) in clusters where members.count >= 20 {
                        let ys = members.map { welded[$0].y }
                        let approxH = percentile(ys, 0.99) - sittingLevel
                        guard approxH >= searchLow, approxH <= searchHigh else { continue }
                        let xs = members.map { welded[$0].x }
                        let zs = members.map { welded[$0].z }
                        let planX = percentile(xs, 0.99) - percentile(xs, 0.01)
                        let planZ = percentile(zs, 0.99) - percentile(zs, 0.01)
                        guard max(planX, planZ) <= 1.7 * expectedHeightUnits else { continue }
                        guard min(planX, planZ) >= 0.2 * expectedHeightUnits else { continue }
                        let sortedYs = ys.sorted()
                        let fitted = slabTop(sortedYs: sortedYs, approxHeight: approxH) ?? approxH
                        guard fitted >= searchLow, fitted <= searchHigh else { continue }
                        // Faces: subject faces whose centroid sits in the
                        // cluster's cells and below the fitted top + margin.
                        let cellSet = Set(members.map { wid -> WeldKey in
                            let p = welded[wid]
                            return WeldKey(x: Int64(floor(p.x / cell)), y: 0, z: Int64(floor(p.z / cell)))
                        })
                        var faceSet = Set<Int>()
                        for (f, tri) in faces.enumerated() where componentOfFace[f] == objectID {
                            let a = welded[tri.0], b = welded[tri.1], c = welded[tri.2]
                            let cx = (a.x + b.x + c.x) / 3
                            let cy = (a.y + b.y + c.y) / 3
                            let cz = (a.z + b.z + c.z) / 3
                            guard cy <= sittingLevel + fitted + 0.35 * expectedHeightUnits else { continue }
                            let key = WeldKey(x: Int64(floor(cx / cell)), y: 0, z: Int64(floor(cz / cell)))
                            if cellSet.contains(key) { faceSet.insert(f) }
                        }
                        candidates.append(Candidate(
                            fittedHeight: fitted,
                            faces: faceSet,
                            source: "satellite",
                            score: abs(fitted / expectedHeightUnits - 1)
                        ))
                    }
                }
            }
        }

        var verdict: Verdict = .notFound
        var winFaces: Set<Int> = []
        var winSource: String?
        if let best = candidates.min(by: { ($0.score, $0.source) < ($1.score, $1.source) }) {
            let ratio = best.fittedHeight / expectedHeightUnits
            winFaces = best.faces
            winSource = best.source
            if ratio >= 0.70, ratio <= 1.35 {
                verdict = .found(heightUnits: best.fittedHeight)
            } else if ratio < 0.70 {
                verdict = .eroded(heightUnits: best.fittedHeight)
            } else {
                verdict = .oversized(heightUnits: best.fittedHeight)
            }
        }

        return Result(
            componentOfFace: componentOfFace,
            objectComponent: objectID,
            objectDimensionsUnits: objectDims,
            sittingLevel: sittingLevel,
            verdict: verdict,
            calibratorFaces: winFaces,
            candidateSource: winSource
        )
    }
}
