import CoreVideo
import Foundation
import RealityKit
import os

/// Streams `PhotogrammetrySample`s from disk, attaching an object mask to each.
///
/// A `Sequence` rather than an array on purpose. Each sample carries a
/// full-resolution `CVPixelBuffer`; at 48 MP that is roughly 190 MB apiece, so
/// materialising eighty of them at once is not an option. The iterator loads one,
/// hands it over, and lets it go.
///
/// The mask is built from the first image's actual dimensions rather than from the
/// capture settings — the file is the authority on how big it really is.
struct MaskedSampleSequence: Sequence {
    let imageURLs: [URL]
    /// Regions to keep, in 0…1 image coordinates (subject rectangle plus,
    /// since v0.7, the designated calibration object's). Empty means no
    /// masking.
    let normalizedRects: [CGRect]

    func makeIterator() -> Iterator {
        Iterator(imageURLs: imageURLs, normalizedRects: normalizedRects)
    }

    struct Iterator: IteratorProtocol {
        private static let logger = Logger(subsystem: "com.example.ObjectScanner", category: "samples")

        let imageURLs: [URL]
        let normalizedRects: [CGRect]

        private var index = 0
        private var cachedMask: CVPixelBuffer?
        private var cachedMaskSize: (width: Int, height: Int)?

        init(imageURLs: [URL], normalizedRects: [CGRect]) {
            self.imageURLs = imageURLs
            self.normalizedRects = normalizedRects
        }

        mutating func next() -> PhotogrammetrySample? {
            while index < imageURLs.count {
                let url = imageURLs[index]
                index += 1

                guard var sample = try? PhotogrammetrySample(contentsOf: url) else {
                    // A single unreadable file should not abort the whole
                    // reconstruction; the remaining images still carry the object.
                    Self.logger.error("Örnek okunamadı: \(url.lastPathComponent, privacy: .public)")
                    continue
                }

                if !normalizedRects.isEmpty {
                    let width = CVPixelBufferGetWidth(sample.image)
                    let height = CVPixelBufferGetHeight(sample.image)

                    // Every frame is the same size, so the mask is built once and
                    // shared — regenerating it eighty times would be pure waste.
                    if cachedMaskSize?.width != width || cachedMaskSize?.height != height {
                        cachedMask = ObjectMaskBuilder.makeMask(
                            width: width,
                            height: height,
                            normalizedRects: normalizedRects
                        )
                        cachedMaskSize = (width, height)
                    }
                    sample.objectMask = cachedMask
                }

                return sample
            }
            return nil
        }
    }
}
