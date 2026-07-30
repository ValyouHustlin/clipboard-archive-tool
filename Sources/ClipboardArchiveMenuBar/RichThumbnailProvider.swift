import ClipboardArchiveCore
import AppKit
import Foundation
import ImageIO

/// Transfers a value the compiler cannot prove Sendable across the one
/// background→main hop below. Safe because the thumbnail is created on the
/// generation queue and never touched there again after the transfer.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

/// Bounded thumbnail provider for image clips (Slice 6 design):
/// - thumbnails come from `CGImageSourceCreateThumbnailAtIndex` capped at
///   1024 px — NEVER a full `NSImage(data:)` decode of the stored bytes,
/// - results live in an NSCache bounded to ~32 MB, keyed by event id,
/// - generation happens off the main thread; callers guard staleness with
///   their own generation counters.
@MainActor
final class RichThumbnailProvider {
    static let shared = RichThumbnailProvider()

    static let maximumThumbnailPixelSize = 1024

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(
        label: "app.clipboardarchive.rich-thumbnails",
        qos: .userInitiated
    )

    private init() {
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func cachedThumbnail(forEventID eventID: String) -> NSImage? {
        cache.object(forKey: eventID as NSString)
    }

    /// Loads (or generates) the thumbnail for an image event. The
    /// completion always runs on the main actor; it receives nil when the
    /// body is unreadable or not a decodable image.
    func thumbnail(
        for event: StoredClipboardEvent,
        reader: ClipboardArchiveReader,
        completion: @escaping @MainActor (NSImage?) -> Void
    ) {
        if let cached = cachedThumbnail(forEventID: event.id) {
            completion(cached)
            return
        }
        let eventID = event.id
        queue.async { @Sendable in
            var thumbnail: NSImage?
            var cost = 0
            if let data = try? reader.richBody(for: event),
               let source = CGImageSourceCreateWithData(
                   data as CFData,
                   [kCGImageSourceShouldCache: false] as CFDictionary
               ) {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: Self.maximumThumbnailPixelSize
                ]
                if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    thumbnail = NSImage(
                        cgImage: cgImage,
                        size: NSSize(width: cgImage.width, height: cgImage.height)
                    )
                    cost = cgImage.width * cgImage.height * 4
                }
            }
            let box = UncheckedSendableBox(value: thumbnail)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let image = box.value {
                        RichThumbnailProvider.shared.cache.setObject(
                            image,
                            forKey: eventID as NSString,
                            cost: cost
                        )
                    }
                    completion(box.value)
                }
            }
        }
    }

    /// Solid-color swatch with the hex + color-space caption drawn in a
    /// contrasting color (Slice 6 color detail). Pure drawing — no decode.
    static func colorSwatch(hex: String, colorSpace: String, fill: NSColor) -> NSImage {
        let size = NSSize(width: 320, height: 160)
        let image = NSImage(size: size)
        image.lockFocus()
        fill.setFill()
        NSRect(origin: .zero, size: size).fill()
        let luminance = 0.299 * fill.redComponent
            + 0.587 * fill.greenComponent
            + 0.114 * fill.blueComponent
        let textColor: NSColor = luminance > 0.6 ? .black : .white
        let caption = "\(hex) · \(colorSpace)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: textColor
        ]
        let textSize = caption.size(withAttributes: attributes)
        caption.draw(
            at: NSPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
            withAttributes: attributes
        )
        image.unlockFocus()
        return image
    }
}
