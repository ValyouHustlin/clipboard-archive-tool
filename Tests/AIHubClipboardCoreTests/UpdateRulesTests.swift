import Foundation
import Testing
@testable import ClipboardArchiveUpdateRules

/// The update helper is the only part of the product that talks to a
/// network. These rules decide whether it may, and they are kept apart from
/// Sparkle so they can be tested without a feed, a key or a network.
@Suite("Update Rules")
struct UpdateRulesTests {
    /// A real 32-byte Ed25519 public key, base64. Synthetic: no private half
    /// of it exists anywhere.
    static let publicKey = Data(repeating: 7, count: 32).base64EncodedString()

    static func info(
        feed: String? = "https://example.invalid/appcast.xml",
        key: String? = publicKey,
        profiling: Any? = nil,
        signedFeed: Any? = true
    ) -> [String: Any] {
        var info: [String: Any] = ["CFBundleIdentifier": "app.clipboardarchive"]
        if let feed { info["SUFeedURL"] = feed }
        if let key { info["SUPublicEDKey"] = key }
        if let profiling { info["SUEnableSystemProfiling"] = profiling }
        if let signedFeed { info["SURequireSignedFeed"] = signedFeed }
        return info
    }

    @Test
    func testHTTPSFeedWithKeyIsReady() {
        let result = ClipboardUpdateConfiguration.evaluate(infoDictionary: Self.info())
        #expect(result == .ready(feedURL: URL(string: "https://example.invalid/appcast.xml")!))
    }

    @Test
    func testLoopbackHTTPFeedIsAllowedForLocalTesting() {
        // Sparkle's downloader refuses file: URLs, so the end-to-end test
        // serves its feed from this machine only. Nothing else may be http.
        for feed in ["http://127.0.0.1:8123/appcast.xml", "http://localhost:8123/appcast.xml"] {
            #expect(
                ClipboardUpdateConfiguration.evaluate(infoDictionary: Self.info(feed: feed))
                    == .ready(feedURL: URL(string: feed)!)
            )
        }
    }

    @Test
    func testNoFeedMeansUpdatesAreNotSetUp() {
        #expect(ClipboardUpdateConfiguration.evaluate(infoDictionary: Self.info(feed: nil)) == .notConfigured(.noFeed))
        #expect(ClipboardUpdateConfiguration.evaluate(infoDictionary: Self.info(feed: "  ")) == .notConfigured(.noFeed))
    }

    @Test
    func testNoKeyMeansUpdatesAreNotSetUp() {
        #expect(ClipboardUpdateConfiguration.evaluate(infoDictionary: Self.info(key: nil)) == .notConfigured(.noKey))
    }

    @Test
    func testPlainHTTPAndOtherSchemesAreRefused() {
        for feed in [
            "http://example.invalid/appcast.xml", "ftp://example.invalid/a.xml", "appcast.xml",
            "file:///tmp/feed/appcast.xml", "http://127.0.0.1.example.invalid/appcast.xml",
            "http://10.0.0.5/appcast.xml",
        ] {
            #expect(
                ClipboardUpdateConfiguration.evaluate(infoDictionary: Self.info(feed: feed))
                    == .refused(.insecureFeed)
            )
        }
    }

    @Test
    func testAKeyThatIsNotThirtyTwoBytesIsRefused() {
        for key in ["not base64!", Data(repeating: 1, count: 31).base64EncodedString(), Data(repeating: 1, count: 64).base64EncodedString()] {
            #expect(
                ClipboardUpdateConfiguration.evaluate(infoDictionary: Self.info(key: key))
                    == .refused(.malformedKey)
            )
        }
    }

    @Test
    func testSystemProfilingTurnedOnIsRefused() {
        // The update request must not describe the machine it comes from.
        #expect(
            ClipboardUpdateConfiguration.evaluate(infoDictionary: Self.info(profiling: true))
                == .refused(.systemProfilingEnabled)
        )
        #expect(
            ClipboardUpdateConfiguration.evaluate(infoDictionary: Self.info(profiling: "YES"))
                == .refused(.systemProfilingEnabled)
        )
        #expect(ClipboardUpdateConfiguration.evaluate(infoDictionary: Self.info(profiling: false)).isReady)
    }

    @Test
    func testAnUnsignedFeedIsRefused() {
        // A feed anyone on the path can rewrite could point at an older
        // signed build; the feed signature closes that.
        #expect(
            ClipboardUpdateConfiguration.evaluate(infoDictionary: Self.info(signedFeed: nil))
                == .refused(.unsignedFeed)
        )
        #expect(
            ClipboardUpdateConfiguration.evaluate(infoDictionary: Self.info(signedFeed: false))
                == .refused(.unsignedFeed)
        )
    }

    @Test
    func testEveryOutcomeSaysSomethingAPersonCanRead() {
        let outcomes: [ClipboardUpdateConfiguration.Outcome] = [
            .notConfigured(.noFeed), .notConfigured(.noKey),
            .refused(.insecureFeed), .refused(.malformedKey),
            .refused(.systemProfilingEnabled), .refused(.unsignedFeed),
        ]
        for outcome in outcomes {
            #expect(!outcome.sentence.isEmpty)
            #expect(outcome.sentence.hasSuffix("."))
        }
    }

    @Test
    func testHostAppIsFoundFromTheHelperInsideIt() {
        let helper = URL(fileURLWithPath: "/Applications/Clipboard Archive.app/Contents/Helpers/Clipboard Archive Updater.app")
        #expect(
            ClipboardUpdaterLayout.hostAppURL(forHelperBundle: helper)?.path
                == "/Applications/Clipboard Archive.app"
        )
        #expect(
            ClipboardUpdaterLayout.helperURL(inHostApp: URL(fileURLWithPath: "/Applications/Clipboard Archive.app")).path
                == helper.path
        )
    }

    @Test
    func testHelperIdentityFollowsTheHostIdentity() {
        #expect(ClipboardUpdaterLayout.helperBundleIdentifier(forHost: "app.clipboardarchive") == "app.clipboardarchive.updater")
        #expect(
            ClipboardUpdaterLayout.helperBundleIdentifier(forHost: "app.clipboardarchive.e2etest")
                == "app.clipboardarchive.e2etest.updater"
        )
        // Not the app's own preferences, and not the helper's own identifier
        // either: a process cannot open its own identifier as a suite.
        #expect(ClipboardUpdaterLayout.updaterDefaultsDomain(forHost: "app.clipboardarchive") == "app.clipboardarchive.updates")
        #expect(
            ClipboardUpdaterLayout.updaterDefaultsDomain(forHost: "app.clipboardarchive")
                != ClipboardUpdaterLayout.helperBundleIdentifier(forHost: "app.clipboardarchive")
        )
        #expect(
            ClipboardUpdaterLayout.checkNowNotification(forHost: "app.clipboardarchive")
                != ClipboardUpdaterLayout.checkNowNotification(forHost: "app.clipboardarchive.e2etest")
        )
    }

    @Test
    func testAHelperOutsideAnAppHasNoHost() {
        for path in [
            "/tmp/Clipboard Archive Updater.app",
            "/Applications/Clipboard Archive.app/Contents/MacOS/Clipboard Archive Updater.app",
            "/Applications/Folder/Contents/Helpers/Clipboard Archive Updater.app",
        ] {
            #expect(ClipboardUpdaterLayout.hostAppURL(forHelperBundle: URL(fileURLWithPath: path)) == nil)
        }
    }

    @Test
    func testHelperArgumentsChooseOneMode() {
        #expect(ClipboardUpdaterMode.parse([]) == .background)
        #expect(ClipboardUpdaterMode.parse(["--check-now"]) == .checkNow)
        #expect(ClipboardUpdaterMode.parse(["--unattended"]) == .unattended(verbose: false))
        #expect(ClipboardUpdaterMode.parse(["--unattended", "--verbose"]) == .unattended(verbose: true))
        // LaunchServices adds a process-serial argument to apps it opens.
        #expect(ClipboardUpdaterMode.parse(["-psn_0_12345"]) == .background)
        #expect(ClipboardUpdaterMode.parse(["--check-now", "--unattended"]) == nil)
        #expect(ClipboardUpdaterMode.parse(["--feed-url", "https://elsewhere.invalid"]) == nil)
    }

    @Test
    func testUnattendedExitCodesFollowTheCommandLineContract() {
        #expect(ClipboardUpdaterExit.installed.rawValue == 0)
        #expect(ClipboardUpdaterExit.failed.rawValue == 1)
        #expect(ClipboardUpdaterExit.usage.rawValue == 2)
        #expect(ClipboardUpdaterExit.notConfigured.rawValue == 3)
        #expect(ClipboardUpdaterExit.refused.rawValue == 4)
        #expect(ClipboardUpdaterExit.upToDate.rawValue == 5)
    }
}
