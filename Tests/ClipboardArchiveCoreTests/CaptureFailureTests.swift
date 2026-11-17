import Foundation
import Testing
@testable import ClipboardArchiveCore

@Suite("Capture failure classification")
struct CaptureFailureTests {
    private func posix(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    @Test("POSIX write errors map to their class")
    func posixCodesMapToClasses() {
        #expect(ClipboardCaptureFailure.classify(posix(28)) == .diskFull)
        #expect(ClipboardCaptureFailure.classify(posix(13)) == .permissionDenied)
        #expect(ClipboardCaptureFailure.classify(posix(1)) == .permissionDenied)
        #expect(ClipboardCaptureFailure.classify(posix(30)) == .readOnlyVolume)
        #expect(ClipboardCaptureFailure.classify(posix(2)) == .archiveMissing)
    }

    @Test("An unrecognized error is classified as other")
    func unknownErrorIsOther() {
        let unknown = NSError(domain: "com.example.synthetic", code: 42)
        #expect(ClipboardCaptureFailure.classify(unknown) == .other)
        // A POSIX code with no mapping stays generic too.
        #expect(ClipboardCaptureFailure.classify(posix(EIO)) == .other)
    }

    @Test("A Cocoa error wrapping a POSIX code is classified by the POSIX code")
    func cocoaErrorWrappingPOSIXCode() {
        let wrapped = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: posix(28)]
        )
        #expect(ClipboardCaptureFailure.classify(wrapped) == .diskFull)

        let permission = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: posix(13)]
        )
        #expect(ClipboardCaptureFailure.classify(permission) == .permissionDenied)

        // Cocoa code alone, with no underlying POSIX error, still classifies.
        let readOnly = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError)
        #expect(ClipboardCaptureFailure.classify(readOnly) == .readOnlyVolume)
    }

    @Test("Labels are short and carry no paths or error text")
    func labelsAreContentFree() {
        let labels = ClipboardCaptureFailure.allCases.map(\.label)
        #expect(labels.count == Set(labels).count)
        for label in labels {
            #expect(!label.contains("/"))
            #expect(!label.contains("Error"))
            #expect(label.count <= 24)
        }
        #expect(ClipboardCaptureFailure.diskFull.label == "Disk full")
        #expect(ClipboardCaptureFailure.permissionDenied.label == "Permission denied")
    }

    @Test("An out-of-range POSIX code does not crash classification")
    func outOfRangePOSIXCodeIsSafe() {
        let huge = NSError(domain: NSPOSIXErrorDomain, code: Int(Int32.max) + 1)
        #expect(ClipboardCaptureFailure.classify(huge) == .other)
        let negative = NSError(domain: NSPOSIXErrorDomain, code: Int(Int32.min) - 1)
        #expect(ClipboardCaptureFailure.classify(negative) == .other)
        // An out-of-range outer code still lets an inner code classify.
        let wrapped = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(Int32.max) + 1,
            userInfo: [NSUnderlyingErrorKey: posix(28)]
        )
        #expect(ClipboardCaptureFailure.classify(wrapped) == .diskFull)
    }

    @Test("A cyclic underlying-error chain terminates")
    func cyclicChainTerminates() {
        let inner = NSError(domain: "com.example.synthetic", code: 1)
        let outer = NSError(
            domain: "com.example.synthetic",
            code: 2,
            userInfo: [NSUnderlyingErrorKey: inner]
        )
        #expect(ClipboardCaptureFailure.classify(outer) == .other)
    }
}
