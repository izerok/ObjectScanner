import AVFoundation
import CoreVideo
import Foundation
import simd

/// Pure computation for the LiDAR turntable engine: unprojection, turntable
/// axis calibration, one-degree-of-freedom angle registration, TSDF fusion
/// and surface-nets meshing.
///
/// Everything here works in one of two frames:
/// - camera space: the depth sensor's own frame (+X right in the buffer,
///   +Y down, +Z into the scene), and
/// - turntable space: origin on the turntable surface under the axis,
///   +Y along the rotation axis (up), defined by a calibration.
///
/// The camera never moves within a pass, so a frame's pose collapses to a
/// single number — how far the object has rotated about the axis. That is
/// the whole reason this pipeline can be simple where photogrammetry needs
/// a general solver.
enum TurntableFusion {

    // MARK: - Unprojection

    /// Turns one depth frame into camera-space points.
    ///
    /// - Parameters:
    ///   - insideMask: keep only points whose normalised image position falls
    ///     in `maskRect` (the object), or only points outside it (the
    ///     turntable/background, used for axis calibration).
    static func points(
        from depthData: AVDepthData,
        maskRect: CGRect?,
        insideMask: Bool,
        stride: Int = 2,
        minimumDepth: Float = 0.15,
        maximumDepth: Float = 1.20,
        maximumNeighbourDelta: Float = 0.03
    ) -> [SIMD3<Float>] {
        let converted = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)

        guard let calibration = converted.cameraCalibrationData else { return [] }

        let buffer = converted.depthDataMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        let reference = calibration.intrinsicMatrixReferenceDimensions
        let scaleX = Float(width) / Float(reference.width)
        let scaleY = Float(height) / Float(reference.height)
        let intrinsics = calibration.intrinsicMatrix
        let focalX = intrinsics.columns.0.x * scaleX
        let focalY = intrinsics.columns.1.y * scaleY
        let centerX = intrinsics.columns.2.x * scaleX
        let centerY = intrinsics.columns.2.y * scaleY
        guard focalX > 0, focalY > 0 else { return [] }

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(8192)

        let step = max(1, stride)
        for row in stride..<(height - stride) where row % step == 0 {
            let rowPointer = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: Float32.self)
            let nextRowPointer = base.advanced(by: (row + step) * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for column in stride..<(width - stride) where column % step == 0 {
                if let maskRect {
                    let u = Float(column) / Float(width)
                    let v = Float(row) / Float(height)
                    let inside = u >= Float(maskRect.minX) && u <= Float(maskRect.maxX)
                        && v >= Float(maskRect.minY) && v <= Float(maskRect.maxY)
                    if inside != insideMask { continue }
                }

                let depth = rowPointer[column]
                guard depth.isFinite, depth >= minimumDepth, depth <= maximumDepth else { continue }

                // Flying-pixel rejection at silhouette edges, same trick the
                // TrueDepth processor uses.
                let right = rowPointer[column + step]
                let below = nextRowPointer[column]
                if right.isFinite, abs(right - depth) > maximumNeighbourDelta { continue }
                if below.isFinite, abs(below - depth) > maximumNeighbourDelta { continue }

                points.append(SIMD3<Float>(
                    (Float(column) - centerX) * depth / focalX,
                    (Float(row) - centerY) * depth / focalY,
                    depth
                ))
            }
        }
        return points
    }

    // MARK: - Axis calibration

    struct Axis: Sendable {
        /// A point on the rotation axis (on the turntable surface).
        var point: SIMD3<Float>
        /// Unit direction of the axis, pointing from the surface toward the
        /// top of the object.
        var direction: SIMD3<Float>
    }

    /// Fits the turntable plane to background points and derives the axis.
    ///
    /// The axis point is where the object sits: the object centroid projected
    /// onto the plane. An object placed slightly off-centre makes this an
    /// approximation, which the per-frame registration partially absorbs.
    static func calibrateAxis(objectPoints: [SIMD3<Float>], backgroundPoints: [SIMD3<Float>]) -> Axis? {
        guard objectPoints.count >= 100, backgroundPoints.count >= 200 else { return nil }
        guard let plane = fitPlane(points: backgroundPoints) else { return nil }

        var centroid = SIMD3<Float>.zero
        for point in objectPoints { centroid += point }
        centroid /= Float(objectPoints.count)

        // Project the centroid onto the plane: that is the axis foot.
        let foot = centroid - plane.normal * simd_dot(centroid - plane.point, plane.normal)

        // Axis points from the surface toward the object.
        var direction = plane.normal
        if simd_dot(direction, centroid - foot) < 0 { direction = -direction }
        return Axis(point: foot, direction: simd_normalize(direction))
    }

    /// RANSAC plane fit: background points include the far wall, so a plain
    /// least-squares fit splits the difference between two planes. Sample
    /// triples (deterministic LCG, so behaviour is reproducible), keep the
    /// plane with the most inliers, then refit on the inliers.
    static func fitPlaneRANSAC(points: [SIMD3<Float>], iterations: Int = 48, inlierThreshold: Float = 0.008) -> (point: SIMD3<Float>, normal: SIMD3<Float>)? {
        guard points.count >= 100 else { return fitPlane(points: points) }
        var state: UInt64 = 0x9E3779B97F4A7C15
        func nextIndex() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(points.count))
        }

        var bestInliers: [SIMD3<Float>] = []
        for _ in 0..<iterations {
            let a = points[nextIndex()], b = points[nextIndex()], c = points[nextIndex()]
            let normal = simd_cross(b - a, c - a)
            let length = simd_length(normal)
            guard length > 1e-6 else { continue }
            let n = normal / length
            var inliers: [SIMD3<Float>] = []
            inliers.reserveCapacity(points.count / 2)
            for point in points where abs(simd_dot(point - a, n)) <= inlierThreshold {
                inliers.append(point)
            }
            if inliers.count > bestInliers.count { bestInliers = inliers }
        }
        guard bestInliers.count >= 100 else { return nil }
        return fitPlane(points: bestInliers)
    }

    /// Least-squares plane via the covariance's smallest eigenvector.
    static func fitPlane(points: [SIMD3<Float>]) -> (point: SIMD3<Float>, normal: SIMD3<Float>)? {
        guard points.count >= 3 else { return nil }
        var centroid = SIMD3<Float>.zero
        for point in points { centroid += point }
        centroid /= Float(points.count)

        var xx: Float = 0, xy: Float = 0, xz: Float = 0
        var yy: Float = 0, yz: Float = 0, zz: Float = 0
        for point in points {
            let d = point - centroid
            xx += d.x * d.x; xy += d.x * d.y; xz += d.x * d.z
            yy += d.y * d.y; yz += d.y * d.z; zz += d.z * d.z
        }
        guard let normal = smallestEigenvector(
            a: [[xx, xy, xz], [xy, yy, yz], [xz, yz, zz]]
        ) else { return nil }
        return (centroid, simd_normalize(normal))
    }

    /// Smallest eigenvector of a symmetric 3×3 matrix, by cyclic Jacobi
    /// rotations. Deterministic and more than accurate enough for a plane fit.
    static func smallestEigenvector(a input: [[Float]]) -> SIMD3<Float>? {
        var a = input
        var v: [[Float]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]

        for _ in 0..<64 {
            // Largest off-diagonal element.
            var p = 0, q = 1
            var largest = abs(a[0][1])
            if abs(a[0][2]) > largest { p = 0; q = 2; largest = abs(a[0][2]) }
            if abs(a[1][2]) > largest { p = 1; q = 2; largest = abs(a[1][2]) }
            if largest < 1e-9 { break }

            let app = a[p][p], aqq = a[q][q], apq = a[p][q]
            let theta = 0.5 * atan2(2 * apq, app - aqq)
            let c = cos(theta), s = sin(theta)

            for k in 0..<3 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp + s * akq
                a[k][q] = -s * akp + c * akq
            }
            for k in 0..<3 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk + s * aqk
                a[q][k] = -s * apk + c * aqk
            }
            for k in 0..<3 {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = c * vkp + s * vkq
                v[k][q] = -s * vkp + c * vkq
            }
        }

        var smallest = 0
        if a[1][1] < a[smallest][smallest] { smallest = 1 }
        if a[2][2] < a[smallest][smallest] { smallest = 2 }
        return SIMD3<Float>(v[0][smallest], v[1][smallest], v[2][smallest])
    }

    // MARK: - Rotations

    /// Rotation matrix about an arbitrary axis through a point is applied as
    /// `point + R * (p - point)`; this returns just R.
    static func rotationMatrix(axis: SIMD3<Float>, angleRadians: Float) -> simd_float3x3 {
        // Rodrigues' formula, written out to avoid quaternion API variance.
        let k = simd_normalize(axis)
        let c = cos(angleRadians)
        let s = sin(angleRadians)
        let t = 1 - c
        return simd_float3x3(columns: (
            SIMD3<Float>(c + k.x * k.x * t, k.y * k.x * t + k.z * s, k.z * k.x * t - k.y * s),
            SIMD3<Float>(k.x * k.y * t - k.z * s, c + k.y * k.y * t, k.z * k.y * t + k.x * s),
            SIMD3<Float>(k.x * k.z * t + k.y * s, k.y * k.z * t - k.x * s, c + k.z * k.z * t)
        ))
    }

    static func rotate(_ point: SIMD3<Float>, about axis: Axis, by angle: Float) -> SIMD3<Float> {
        let r = rotationMatrix(axis: axis.direction, angleRadians: angle)
        return axis.point + r * (point - axis.point)
    }

    /// Builds the camera→turntable frame transform from a calibration.
    ///
    /// Turntable space: origin at the axis foot, +Y along the axis. The other
    /// two axes are arbitrary but fixed: X from the camera's forward direction
    /// projected into the plane, Z completing the frame.
    static func turntableTransform(axis: Axis, cameraForward: SIMD3<Float> = SIMD3<Float>(0, 0, 1)) -> simd_float4x4 {
        let y = axis.direction
        var x = cameraForward - y * simd_dot(cameraForward, y)
        if simd_length(x) < 1e-4 { x = SIMD3<Float>(1, 0, 0) - y * y.x }
        x = simd_normalize(x)
        let z = simd_cross(x, y)
        // World = R * (camera - origin): columns are the basis images.
        var m = simd_float4x4()
        m.columns.0 = SIMD4<Float>(x.x, y.x, z.x, 0)
        m.columns.1 = SIMD4<Float>(x.y, y.y, z.y, 0)
        m.columns.2 = SIMD4<Float>(x.z, y.z, z.z, 0)
        let origin = axis.point
        m.columns.3 = SIMD4<Float>(
            -simd_dot(x, origin), -simd_dot(y, origin), -simd_dot(z, origin), 1
        )
        return m
    }

    static func apply(_ matrix: simd_float4x4, to point: SIMD3<Float>) -> SIMD3<Float> {
        let r = matrix * SIMD4<Float>(point, 1)
        return SIMD3<Float>(r.x, r.y, r.z)
    }

    // MARK: - Angle registration (1-DoF ICP)

    /// Fraction of `source` points landing within `cellSize` of a `target`
    /// point, after rotating `source` about `axis` by `angle`.
    static func hitRate(
        source: [SIMD3<Float>],
        targetVoxels: Set<SIMD3<Int32>>,
        cellSize: Float,
        axis: Axis,
        angle: Float
    ) -> Float {
        guard !source.isEmpty else { return 0 }
        let r = rotationMatrix(axis: axis.direction, angleRadians: angle)
        var hits = 0
        for point in source {
            let rotated = axis.point + r * (point - axis.point)
            let key = SIMD3<Int32>(
                Int32((rotated.x / cellSize).rounded(.down)),
                Int32((rotated.y / cellSize).rounded(.down)),
                Int32((rotated.z / cellSize).rounded(.down))
            )
            // Exact cell or any neighbour — the voxel is a tolerance, not a bin.
            var found = false
            outer: for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        let neighbor = SIMD3<Int32>(key.x + Int32(dx), key.y + Int32(dy), key.z + Int32(dz))
                        if targetVoxels.contains(neighbor) {
                            found = true
                            break outer
                        }
                    }
                }
            }
            if found { hits += 1 }
        }
        return Float(hits) / Float(source.count)
    }

    static func voxelKeys(points: [SIMD3<Float>], cellSize: Float) -> Set<SIMD3<Int32>> {
        var keys = Set<SIMD3<Int32>>()
        keys.reserveCapacity(points.count)
        for point in points {
            keys.insert(SIMD3<Int32>(
                Int32((point.x / cellSize).rounded(.down)),
                Int32((point.y / cellSize).rounded(.down)),
                Int32((point.z / cellSize).rounded(.down))
            ))
        }
        return keys
    }

    /// Estimates how far the object rotated between two camera-space clouds.
    ///
    /// Coarse-to-fine search over a single angle. When `lockedSign` is nil
    /// both directions are tried and the winner's sign is returned so the
    /// caller can lock it for the rest of the pass.
    static func estimateRotation(
        current: [SIMD3<Float>],
        previous: [SIMD3<Float>],
        axis: Axis,
        lockedSign: Float?,
        cellSize: Float = 0.008
    ) -> (deltaRadians: Float, hitRate: Float, sign: Float)? {
        let target = voxelKeys(points: previous, cellSize: cellSize)
        let sample = subsample(current, limit: 2500)
        guard sample.count >= 60 else { return nil }

        let signs: [Float] = lockedSign.map { [$0] } ?? [1, -1]
        var best: (delta: Float, rate: Float, sign: Float)?

        for sign in signs {
            var coarseBest: (delta: Float, rate: Float) = (0, -1)
            var degrees: Float = 2
            while degrees <= 30 {
                let angle = sign * degrees * .pi / 180
                let rate = hitRate(source: sample, targetVoxels: target, cellSize: cellSize, axis: axis, angle: -angle)
                if rate > coarseBest.rate { coarseBest = (angle, rate) }
                degrees += 1.5
            }
            var refined = coarseBest
            var offset: Float = -1.2
            while offset <= 1.2 {
                let angle = coarseBest.delta + sign * offset * .pi / 180
                let rate = hitRate(source: sample, targetVoxels: target, cellSize: cellSize, axis: axis, angle: -angle)
                if rate > refined.rate { refined = (angle, rate) }
                offset += 0.2
            }
            if best == nil || refined.rate > best!.rate {
                best = (refined.delta, refined.rate, sign)
            }
        }
        guard let best else { return nil }
        return (best.delta, best.rate, best.sign)
    }

    /// Yaw search over the full circle, used to register a new pass's first
    /// frame against the already-fused model (which lives in turntable
    /// space, where the only unknown left is rotation about +Y).
    static func estimateYaw(
        currentWorld: [SIMD3<Float>],
        modelPoints: [SIMD3<Float>],
        cellSize: Float = 0.008
    ) -> (yawRadians: Float, hitRate: Float)? {
        let target = voxelKeys(points: modelPoints, cellSize: cellSize)
        let sample = subsample(currentWorld, limit: 2500)
        guard sample.count >= 60 else { return nil }
        let axis = Axis(point: .zero, direction: SIMD3<Float>(0, 1, 0))

        var best: (yaw: Float, rate: Float) = (0, -1)
        var degrees: Float = 0
        while degrees < 360 {
            let angle = degrees * .pi / 180
            let rate = hitRate(source: sample, targetVoxels: target, cellSize: cellSize, axis: axis, angle: -angle)
            if rate > best.rate { best = (angle, rate) }
            degrees += 3
        }
        var refined = best
        var offset: Float = -2.4
        while offset <= 2.4 {
            let angle = best.yaw + offset * .pi / 180
            let rate = hitRate(source: sample, targetVoxels: target, cellSize: cellSize, axis: axis, angle: -angle)
            if rate > refined.rate { refined = (angle, rate) }
            offset += 0.3
        }
        return (refined.yaw, refined.rate)
    }

    static func subsample(_ points: [SIMD3<Float>], limit: Int) -> [SIMD3<Float>] {
        guard points.count > limit else { return points }
        let step = points.count / limit
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(limit)
        var index = 0
        while index < points.count {
            result.append(points[index])
            index += step
        }
        return result
    }
}

// MARK: - TSDF volume

/// A truncated signed-distance volume in turntable space.
///
/// Integration uses the cheap splat approximation: each observed point
/// writes signed distances into the few voxels along its own camera ray.
/// With a fixed camera and dozens of frames per surface patch, the weighted
/// average converges to a usable zero crossing — which is all surface nets
/// needs.
final class TSDFVolume: @unchecked Sendable {
    let dimensions: SIMD3<Int32>
    let origin: SIMD3<Float>
    let voxelSize: Float
    let truncation: Float

    private(set) var tsdf: [Float]
    private(set) var weight: [Float]

    init?(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>, voxelSize: Float, maxVoxels: Int = 3_500_000) {
        var voxel = voxelSize
        var dims = SIMD3<Int32>.zero
        // Grow the voxel until the volume fits the memory budget.
        for _ in 0..<12 {
            let span = boundsMax - boundsMin
            dims = SIMD3<Int32>(
                Int32(ceil(span.x / voxel)) + 1,
                Int32(ceil(span.y / voxel)) + 1,
                Int32(ceil(span.z / voxel)) + 1
            )
            let total = Int(dims.x) * Int(dims.y) * Int(dims.z)
            if total <= maxVoxels { break }
            voxel *= 1.25
        }
        let total = Int(dims.x) * Int(dims.y) * Int(dims.z)
        guard dims.x > 4, dims.y > 4, dims.z > 4, total <= maxVoxels * 2 else { return nil }
        self.dimensions = dims
        self.origin = boundsMin
        self.voxelSize = voxel
        self.truncation = voxel * 3
        self.tsdf = [Float](repeating: 1, count: total)
        self.weight = [Float](repeating: 0, count: total)
    }

    private func index(x: Int32, y: Int32, z: Int32) -> Int {
        (Int(z) * Int(dimensions.y) + Int(y)) * Int(dimensions.x) + Int(x)
    }

    func contains(worldPoint: SIMD3<Float>) -> Bool {
        let local = (worldPoint - origin) / voxelSize
        return local.x >= 0 && local.y >= 0 && local.z >= 0
            && local.x < Float(dimensions.x) && local.y < Float(dimensions.y) && local.z < Float(dimensions.z)
    }

    /// Integrates one frame of world-space surface points seen from
    /// `cameraOrigin` (also world space).
    func integrate(points: [SIMD3<Float>], cameraOrigin: SIMD3<Float>) {
        let halfSteps = 3
        for point in points {
            let ray = point - cameraOrigin
            let length = simd_length(ray)
            guard length > 1e-5 else { continue }
            let direction = ray / length

            for step in -halfSteps...halfSteps {
                // Positive step goes *past* the surface (inside the object):
                // signed distance there is negative by convention.
                let sdf = -Float(step) * voxelSize / truncation
                let position = point + direction * (Float(step) * voxelSize)
                let local = (position - origin) / voxelSize
                let gx = Int32(local.x.rounded(.down))
                let gy = Int32(local.y.rounded(.down))
                let gz = Int32(local.z.rounded(.down))
                guard gx >= 0, gy >= 0, gz >= 0,
                      gx < dimensions.x, gy < dimensions.y, gz < dimensions.z else { continue }
                let idx = index(x: gx, y: gy, z: gz)
                let w = weight[idx]
                let combined = w + 1
                tsdf[idx] = (tsdf[idx] * w + max(-1, min(1, sdf))) / combined
                weight[idx] = min(combined, 32)
            }
        }
    }

    func value(x: Int, y: Int, z: Int) -> Float {
        guard x >= 0, y >= 0, z >= 0,
              x < Int(dimensions.x), y < Int(dimensions.y), z < Int(dimensions.z) else { return 1 }
        return tsdf[index(x: Int32(x), y: Int32(y), z: Int32(z))]
    }

    func nodePosition(x: Int, y: Int, z: Int) -> SIMD3<Float> {
        origin + SIMD3<Float>(Float(x), Float(y), Float(z)) * voxelSize
    }
}

// MARK: - Surface nets

enum SurfaceNets {
    struct Mesh: Sendable {
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
    }

    /// Naive surface nets over the TSDF grid: one vertex per sign-changing
    /// cell, quads across sign-changing edges. No lookup tables, and the
    /// output is smooth enough for a depth-fused model.
    static func extract(from volume: TSDFVolume) -> Mesh {
        let nx = Int(volume.dimensions.x)
        let ny = Int(volume.dimensions.y)
        let nz = Int(volume.dimensions.z)
        guard nx > 2, ny > 2, nz > 2 else { return Mesh() }

        var mesh = Mesh()
        // Cell → vertex index, -1 when the cell carries no vertex.
        var cellVertex = [Int32](repeating: -1, count: (nx - 1) * (ny - 1) * (nz - 1))
        func cellIndex(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * (ny - 1) + y) * (nx - 1) + x }

        let cornerOffsets: [(Int, Int, Int)] = [
            (0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 0),
            (0, 0, 1), (1, 0, 1), (0, 1, 1), (1, 1, 1),
        ]
        // The 12 cell edges as corner pairs.
        let edges: [(Int, Int)] = [
            (0, 1), (2, 3), (4, 5), (6, 7),
            (0, 2), (1, 3), (4, 6), (5, 7),
            (0, 4), (1, 5), (2, 6), (3, 7),
        ]

        for z in 0..<(nz - 1) {
            for y in 0..<(ny - 1) {
                for x in 0..<(nx - 1) {
                    var values: [Float] = []
                    values.reserveCapacity(8)
                    var hasInside = false, hasOutside = false
                    for (dx, dy, dz) in cornerOffsets {
                        let v = volume.value(x: x + dx, y: y + dy, z: z + dz)
                        values.append(v)
                        if v < 0 { hasInside = true } else { hasOutside = true }
                    }
                    guard hasInside, hasOutside else { continue }

                    // Vertex at the average of the edge zero crossings.
                    var sum = SIMD3<Float>.zero
                    var crossings = 0
                    for (a, b) in edges {
                        let va = values[a], vb = values[b]
                        guard (va < 0) != (vb < 0) else { continue }
                        let pa = volume.nodePosition(x: x + cornerOffsets[a].0, y: y + cornerOffsets[a].1, z: z + cornerOffsets[a].2)
                        let pb = volume.nodePosition(x: x + cornerOffsets[b].0, y: y + cornerOffsets[b].1, z: z + cornerOffsets[b].2)
                        let t = va / (va - vb)
                        sum += pa + (pb - pa) * t
                        crossings += 1
                    }
                    guard crossings > 0 else { continue }

                    let vertex = sum / Float(crossings)
                    cellVertex[cellIndex(x, y, z)] = Int32(mesh.vertices.count)
                    mesh.vertices.append(vertex)
                    mesh.normals.append(gradient(volume: volume, at: vertex))
                }
            }
        }

        // Quads across interior edges whose endpoints straddle the surface.
        // An edge along X at node (x,y,z) is shared by the cells with
        // (y-1,z-1),(y-1,z),(y,z-1),(y,z); same pattern per axis.
        func quad(cells: [Int32], flip: Bool) {
            guard cells.allSatisfy({ $0 >= 0 }) else { return }
            let (a, b, c, d) = (cells[0], cells[1], cells[2], cells[3])
            if flip {
                mesh.indices += [UInt32(a), UInt32(b), UInt32(d), UInt32(a), UInt32(d), UInt32(c)]
            } else {
                mesh.indices += [UInt32(a), UInt32(d), UInt32(b), UInt32(a), UInt32(c), UInt32(d)]
            }
        }

        for z in 0..<nz {
            for y in 0..<ny {
                for x in 0..<nx {
                    let v = volume.value(x: x, y: y, z: z)
                    // X-edge to (x+1,y,z)
                    if x + 1 < nx {
                        let v2 = volume.value(x: x + 1, y: y, z: z)
                        if (v < 0) != (v2 < 0), y > 0, z > 0, y < ny - 1, z < nz - 1 {
                            let cells = [
                                cellVertex[cellIndex(x, y - 1, z - 1)],
                                cellVertex[cellIndex(x, y - 1, z)],
                                cellVertex[cellIndex(x, y, z - 1)],
                                cellVertex[cellIndex(x, y, z)],
                            ]
                            quad(cells: cells, flip: v < 0)
                        }
                    }
                    // Y-edge to (x,y+1,z)
                    if y + 1 < ny {
                        let v2 = volume.value(x: x, y: y + 1, z: z)
                        if (v < 0) != (v2 < 0), x > 0, z > 0, x < nx - 1, z < nz - 1 {
                            let cells = [
                                cellVertex[cellIndex(x - 1, y, z - 1)],
                                cellVertex[cellIndex(x - 1, y, z)],
                                cellVertex[cellIndex(x, y, z - 1)],
                                cellVertex[cellIndex(x, y, z)],
                            ]
                            quad(cells: cells, flip: v >= 0)
                        }
                    }
                    // Z-edge to (x,y,z+1)
                    if z + 1 < nz {
                        let v2 = volume.value(x: x, y: y, z: z + 1)
                        if (v < 0) != (v2 < 0), x > 0, y > 0, x < nx - 1, y < ny - 1 {
                            let cells = [
                                cellVertex[cellIndex(x - 1, y - 1, z)],
                                cellVertex[cellIndex(x, y - 1, z)],
                                cellVertex[cellIndex(x - 1, y, z)],
                                cellVertex[cellIndex(x, y, z)],
                            ]
                            quad(cells: cells, flip: v < 0)
                        }
                    }
                }
            }
        }

        orientOutward(mesh: &mesh)
        return mesh
    }

    private static func gradient(volume: TSDFVolume, at point: SIMD3<Float>) -> SIMD3<Float> {
        let local = (point - volume.origin) / volume.voxelSize
        let x = Int(local.x.rounded()), y = Int(local.y.rounded()), z = Int(local.z.rounded())
        let dx = volume.value(x: x + 1, y: y, z: z) - volume.value(x: x - 1, y: y, z: z)
        let dy = volume.value(x: x, y: y + 1, z: z) - volume.value(x: x, y: y - 1, z: z)
        let dz = volume.value(x: x, y: y, z: z + 1) - volume.value(x: x, y: y, z: z - 1)
        let g = SIMD3<Float>(dx, dy, dz)
        let length = simd_length(g)
        return length > 1e-6 ? g / length : SIMD3<Float>(0, 1, 0)
    }

    /// Signed-volume test: a closed mesh with negative volume has its
    /// triangles wound inward; flip them (and the normals) if so.
    private static func orientOutward(mesh: inout Mesh) {
        guard mesh.indices.count >= 3 else { return }
        var volume: Double = 0
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.vertices[Int(mesh.indices[i])]
            let b = mesh.vertices[Int(mesh.indices[i + 1])]
            let c = mesh.vertices[Int(mesh.indices[i + 2])]
            volume += Double(simd_dot(a, simd_cross(b, c))) / 6
            i += 3
        }
        guard volume < 0 else { return }
        var j = 0
        while j + 2 < mesh.indices.count {
            mesh.indices.swapAt(j + 1, j + 2)
            j += 3
        }
        for index in mesh.normals.indices { mesh.normals[index] = -mesh.normals[index] }
    }
}
