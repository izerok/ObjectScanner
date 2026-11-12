import Foundation
import ModelIO
import simd

/// Minimal ModelIO geometry access shared by the scale analyzer and the
/// exporter: flatten an asset into world-space triangles, and scale an
/// asset's vertex positions in place.
enum MeshGeometry {

    struct PositionAttribute {
        var bufferIndex: Int
        var offset: Int
        var stride: Int
    }

    static func positionAttribute(of mesh: MDLMesh) -> PositionAttribute? {
        for case let attribute as MDLVertexAttribute in mesh.vertexDescriptor.attributes {
            guard attribute.name == MDLVertexAttributePosition, attribute.format == .float3 else { continue }
            let layout = mesh.vertexDescriptor.layouts[attribute.bufferIndex] as? MDLVertexBufferLayout
            guard let stride = layout?.stride, stride >= 12 else { return nil }
            return PositionAttribute(
                bufferIndex: attribute.bufferIndex,
                offset: attribute.offset,
                stride: stride
            )
        }
        return nil
    }

    /// All triangles of all meshes, positions transformed to world space.
    static func load(from url: URL) -> (positions: [SIMD3<Float>], indices: [UInt32])? {
        let asset = MDLAsset(url: url)
        let meshes = asset.childObjects(of: MDLMesh.self) as? [MDLMesh] ?? []
        guard !meshes.isEmpty else { return nil }

        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for mesh in meshes {
            guard let attribute = positionAttribute(of: mesh) else { continue }
            let buffer = mesh.vertexBuffers[attribute.bufferIndex]
            let map = buffer.map()
            let transform = mesh.transform?.matrix ?? matrix_identity_float4x4
            let vertexOffset = UInt32(positions.count)
            for i in 0 ..< mesh.vertexCount {
                let pointer = map.bytes
                    .advanced(by: attribute.offset + i * attribute.stride)
                    .assumingMemoryBound(to: Float.self)
                let local = SIMD4<Float>(pointer[0], pointer[1], pointer[2], 1)
                let world = transform * local
                positions.append(SIMD3<Float>(world.x, world.y, world.z))
            }
            for rawSubmesh in mesh.submeshes ?? [] {
                guard let submesh = rawSubmesh as? MDLSubmesh else { continue }
                let indexMap = submesh.indexBuffer.map()
                switch submesh.indexType {
                case .uInt32:
                    let pointer = indexMap.bytes.assumingMemoryBound(to: UInt32.self)
                    for i in 0 ..< submesh.indexCount {
                        indices.append(vertexOffset + pointer[i])
                    }
                case .uInt16:
                    let pointer = indexMap.bytes.assumingMemoryBound(to: UInt16.self)
                    for i in 0 ..< submesh.indexCount {
                        indices.append(vertexOffset + UInt32(pointer[i]))
                    }
                default:
                    continue
                }
            }
        }
        guard positions.count >= 3, indices.count >= 3 else { return nil }
        return (positions, indices)
    }

    /// Multiplies every position in the asset by `factor`, in place. Buffer
    /// layout, UVs, normals and materials are untouched (a uniform scale
    /// does not change normal directions). Returns false when no mesh had a
    /// writable float3 position buffer.
    static func scalePositions(in asset: MDLAsset, by factor: Float) -> Bool {
        let meshes = asset.childObjects(of: MDLMesh.self) as? [MDLMesh] ?? []
        var didScale = false
        for mesh in meshes {
            guard let attribute = positionAttribute(of: mesh) else { continue }
            let buffer = mesh.vertexBuffers[attribute.bufferIndex]
            let map = buffer.map()
            for i in 0 ..< mesh.vertexCount {
                let pointer = map.bytes
                    .advanced(by: attribute.offset + i * attribute.stride)
                    .assumingMemoryBound(to: Float.self)
                pointer[0] *= factor
                pointer[1] *= factor
                pointer[2] *= factor
            }
            didScale = true
        }
        return didScale
    }
}
