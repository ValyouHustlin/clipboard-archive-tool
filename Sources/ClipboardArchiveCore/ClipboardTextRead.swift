import Foundation

extension String {
    /// Reads a text file as UTF-8 with NATIVE storage, falling back to the
    /// encoding-sniffing initialiser.
    ///
    /// WHY THIS EXISTS, measured on a real 132 MB / 18,184-event archive.
    /// `String(contentsOf:)` with no encoding goes through NSString and hands
    /// back a FOREIGN (Objective-C-backed) String, so every subsequent
    /// character access crosses the bridge one `characterAtIndex:` at a time.
    /// Splitting the same lines from the same files:
    ///
    ///     String(contentsOf: url)                  4,351.8 ms
    ///     String(contentsOf: url, encoding: .utf8)   381.6 ms
    ///
    /// 11.4x, and `ClipboardArchiveHealthReporter.health()` pays it three
    /// times per call — which is most of why `status` took ~15 s on an archive
    /// this size while its own help promises "one fast read".
    ///
    /// THE FALLBACK IS NOT OPTIONAL AND MUST NOT BE TIDIED AWAY. The sniffing
    /// initialiser SUCCEEDS on files that are not valid UTF-8; demanding UTF-8
    /// outright would turn a readable legacy or imported archive file into a
    /// throw, which is a correctness regression traded for speed. With the
    /// fallback, behaviour is identical for every input and only the common
    /// path is fast.
    public static func readingClipboardText(contentsOf url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }
        return try String(contentsOf: url)
    }
}
