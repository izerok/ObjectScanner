import CoreVideo
import Foundation

/// Builds the single-channel mask that tells `PhotogrammetrySession` which pixels
/// belong to the object.
///
/// This is the reliable way to exclude a background, and it is only practical in
/// turntable mode: the device does not move, so the object stays in the same part
/// of every frame and one rectangle covers the whole set. In orbit mode the object
/// moves across the frame constantly and a fixed rectangle would be meaningless —
/// which is why that mode relies on ARKit's bounding box instead.
enum ObjectMaskBuilder {

    /// - Parameter normalizedRects: regions to keep, in 0…1 image coordinates
    ///   with the origin at the top-left. More than one since v0.7: the
    ///   subject rectangle plus the designated calibration object's — the
    ///   mask is their union, each region modelled, everything else not.
    /// - Returns: a `kCVPixelFormatType_OneComponent8` buffer, 255 inside any
    ///   of the regions and 0 outside.
    static func makeMask(width: Int, height: Int, normalizedRects: [CGRect]) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: false,
            kCVPixelBufferCGBitmapContextCompatibilityKey: false,
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            attributes as CFDictionary,
            &buffer
        )

        guard status == kCVReturnSuccess, let mask = buffer else { return nil }

        CVPixelBufferLockBaseAddress(mask, [])
        defer { CVPixelBufferUnlockBaseAddress(mask, []) }

        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)

        // Clamped so a rectangle dragged past the edge still produces a valid
        // mask rather than writing outside the buffer.
        let spans: [(left: Int, right: Int, top: Int, bottom: Int)] = normalizedRects.map { rect in
            (
                left: max(0, Int((rect.minX * CGFloat(width)).rounded())),
                right: min(width, Int((rect.maxX * CGFloat(width)).rounded())),
                top: max(0, Int((rect.minY * CGFloat(height)).rounded())),
                bottom: min(height, Int((rect.maxY * CGFloat(height)).rounded()))
            )
        }

        let pointer = base.assumingMemoryBound(to: UInt8.self)

        for row in 0..<height {
            let rowStart = pointer.advanced(by: row * bytesPerRow)
            rowStart.update(repeating: 0, count: width)
            for span in spans where row >= span.top && row < span.bottom && span.right > span.left {
                rowStart.advanced(by: span.left).update(repeating: 255, count: span.right - span.left)
            }
        }

        return mask
    }
}
