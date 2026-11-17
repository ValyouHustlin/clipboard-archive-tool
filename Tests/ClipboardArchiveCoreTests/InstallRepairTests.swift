import Foundation
import Testing
@testable import ClipboardArchiveCore

/// One working copy of the app after a newer one is installed beside an
/// older one. These are the decisions; the app only carries them out.
@Suite("Install repair")
struct InstallRepairTests {
    private typealias Copy = ClipboardInstallRepair.Copy
    private let folders = ["/Applications", "/Users/someone/Applications"]
    private let identifier = "app.clipboardarchive"

    private var newCopy: Copy {
        Copy(path: "/Applications/Clipboard Archive.app", bundleIdentifier: identifier, build: 13)
    }

    private var oldCopy: Copy {
        Copy(path: "/Users/someone/Applications/ClipboardArchive.app", bundleIdentifier: identifier, build: 3)
    }

    private func loginItem(arguments: [String], extra: [String: Any] = [:]) throws -> Data {
        var root: [String: Any] = [
            "Label": "app.clipboardarchive",
            "ProgramArguments": arguments,
            "RunAtLoad": true,
            "KeepAlive": false
        ]
        for (key, value) in extra {
            root[key] = value
        }
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    private func read(_ data: Data) throws -> [String: Any] {
        try #require(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
    }

    private func describe(_ copies: [Copy]) -> (String) -> Copy? {
        { path in copies.first { $0.path == path } }
    }

    // MARK: Installed or not

    @Test func onlyABundleDirectlyInAnInstallFolderCountsAsInstalled() {
        #expect(ClipboardInstallRepair.isInstalled("/Applications/Clipboard Archive.app", installFolders: folders))
        #expect(ClipboardInstallRepair.isInstalled("/Users/someone/Applications/ClipboardArchive.app", installFolders: folders))
        #expect(!ClipboardInstallRepair.isInstalled("/Volumes/Clipboard Archive/Clipboard Archive.app", installFolders: folders))
        #expect(!ClipboardInstallRepair.isInstalled("/Users/someone/Downloads/Clipboard Archive.app", installFolders: folders))
        #expect(!ClipboardInstallRepair.isInstalled("/Applications/Utilities/Clipboard Archive.app", installFolders: folders))
        #expect(!ClipboardInstallRepair.isInstalled(
            "/private/var/folders/ab/cd/T/AppTranslocation/1234/d/Clipboard Archive.app",
            installFolders: folders
        ))
        #expect(!ClipboardInstallRepair.isInstalled("/Users/someone/src/.build/debug", installFolders: folders))
    }

    // MARK: Taking over from the copy that holds the lock

    @Test func aNewerInstalledCopyTakesOverFromAnOlderOne() {
        #expect(ClipboardInstallRepair.shouldTakeOver(own: newCopy, holder: oldCopy, installFolders: folders))
    }

    @Test func nothingElseTakesOver() {
        // The same copy opened twice: an ordinary second instance.
        #expect(!ClipboardInstallRepair.shouldTakeOver(own: newCopy, holder: newCopy, installFolders: folders))
        // The same build in another folder.
        var sameBuildElsewhere = oldCopy
        sameBuildElsewhere.build = 13
        #expect(!ClipboardInstallRepair.shouldTakeOver(own: newCopy, holder: sameBuildElsewhere, installFolders: folders))
        // An older copy never displaces a newer one.
        #expect(!ClipboardInstallRepair.shouldTakeOver(own: oldCopy, holder: newCopy, installFolders: folders))
        // A copy run from a disk image or a build folder never displaces anything.
        var fromDiskImage = newCopy
        fromDiskImage.path = "/Volumes/Clipboard Archive/Clipboard Archive.app"
        #expect(!ClipboardInstallRepair.shouldTakeOver(own: fromDiskImage, holder: oldCopy, installFolders: folders))
        // Some other app holding a lock file with this name.
        var anotherApp = oldCopy
        anotherApp.bundleIdentifier = "com.example.other"
        #expect(!ClipboardInstallRepair.shouldTakeOver(own: newCopy, holder: anotherApp, installFolders: folders))
        // Anything that cannot be identified.
        #expect(!ClipboardInstallRepair.shouldTakeOver(own: newCopy, holder: nil, installFolders: folders))
        var noBuild = oldCopy
        noBuild.build = nil
        #expect(!ClipboardInstallRepair.shouldTakeOver(own: newCopy, holder: noBuild, installFolders: folders))
        var unbundled = newCopy
        unbundled.bundleIdentifier = nil
        #expect(!ClipboardInstallRepair.shouldTakeOver(own: unbundled, holder: oldCopy, installFolders: folders))
    }

    // MARK: The login item

    @Test func aLoginItemNamingAnOlderCopyIsPointedAtThisOneAndKeepsEverythingElse() throws {
        let pins = [
            "CLIPBOARD_ARCHIVE_ARCHIVE_ROOT": "/Users/someone/Documents/My Clips & More",
            "CLIPBOARD_ARCHIVE_INDEX_PATH": "/Users/someone/Documents/index.sqlite"
        ]
        let before = try loginItem(
            arguments: ["/usr/bin/open", oldCopy.path],
            extra: ["EnvironmentVariables": pins, "StandardOutPath": "/Users/someone/Library/Logs/x.log"]
        )
        let repair = try #require(ClipboardInstallRepair.repairedLaunchAgent(
            plist: before, own: newCopy, installFolders: folders, describe: describe([oldCopy, newCopy])
        ))
        #expect(repair.replacedTarget == oldCopy.path)

        let after = try read(repair.data)
        #expect(after["ProgramArguments"] as? [String] == ["/usr/bin/open", newCopy.path])
        #expect(after["EnvironmentVariables"] as? [String: String] == pins)
        #expect(after["Label"] as? String == "app.clipboardarchive")
        #expect(after["RunAtLoad"] as? Bool == true)
        #expect(after["KeepAlive"] as? Bool == false)
        #expect(after["StandardOutPath"] as? String == "/Users/someone/Library/Logs/x.log")
        #expect(Set(after.keys) == Set(try read(before).keys))
    }

    @Test func aLoginItemNamingACopyThatIsGoneIsPointedAtThisOne() throws {
        let before = try loginItem(arguments: ["/usr/bin/open", oldCopy.path])
        let repair = try #require(ClipboardInstallRepair.repairedLaunchAgent(
            plist: before, own: newCopy, installFolders: folders, describe: describe([newCopy])
        ))
        #expect(try read(repair.data)["ProgramArguments"] as? [String] == ["/usr/bin/open", newCopy.path])
    }

    @Test func optionsBeforeTheAppPathSurvive() throws {
        let before = try loginItem(arguments: ["/usr/bin/open", "--env", "A=/x/y", "-g", oldCopy.path])
        let repair = try #require(ClipboardInstallRepair.repairedLaunchAgent(
            plist: before, own: newCopy, installFolders: folders, describe: describe([oldCopy])
        ))
        #expect(try read(repair.data)["ProgramArguments"] as? [String]
            == ["/usr/bin/open", "--env", "A=/x/y", "-g", newCopy.path])
    }

    @Test func aLoginItemThatIsAlreadyRightOrNotOursToTouchIsLeftAlone() throws {
        func repaired(_ data: Data, own: Copy? = nil, known: [Copy]? = nil) -> ClipboardInstallRepair.LaunchAgentRepair? {
            ClipboardInstallRepair.repairedLaunchAgent(
                plist: data,
                own: own ?? newCopy,
                installFolders: folders,
                describe: describe(known ?? [oldCopy, newCopy])
            )
        }
        // Already names this copy.
        #expect(repaired(try loginItem(arguments: ["/usr/bin/open", newCopy.path])) == nil)
        // Names a NEWER copy elsewhere: never repoint backwards.
        #expect(repaired(try loginItem(arguments: ["/usr/bin/open", newCopy.path]), own: oldCopy) == nil)
        // Names another app entirely.
        let other = Copy(path: "/Applications/Other.app", bundleIdentifier: "com.example.other", build: 1)
        #expect(repaired(try loginItem(arguments: ["/usr/bin/open", other.path]), known: [other]) == nil)
        // Names something that is gone and was never one of ours.
        #expect(repaired(try loginItem(arguments: ["/usr/bin/open", "/Applications/Gone.app"]), known: []) == nil)
        // Starts two apps: not a shape to guess at.
        #expect(repaired(try loginItem(arguments: ["/usr/bin/open", oldCopy.path, newCopy.path])) == nil)
        // Names the app by name or bundle id, which already follows the newest copy.
        #expect(repaired(try loginItem(arguments: ["/usr/bin/open", "-a", "Clipboard Archive"])) == nil)
        #expect(repaired(try loginItem(arguments: ["/usr/bin/open", "-b", identifier])) == nil)
        // Runs the executable directly, or something that is not `open`.
        #expect(repaired(try loginItem(arguments: [oldCopy.path + "/Contents/MacOS/ClipboardArchive"])) == nil)
        #expect(repaired(try loginItem(arguments: ["/usr/bin/open", oldCopy.path], extra: ["Program": "/bin/sh"])) == nil)
        // This copy is not installed (opened from the disk image).
        var fromDiskImage = newCopy
        fromDiskImage.path = "/Volumes/Clipboard Archive/Clipboard Archive.app"
        #expect(repaired(try loginItem(arguments: ["/usr/bin/open", oldCopy.path]), own: fromDiskImage) == nil)
        // Not a property list at all.
        #expect(repaired(Data("previous login item".utf8)) == nil)
    }
}
