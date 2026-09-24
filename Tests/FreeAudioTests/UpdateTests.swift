import CryptoKit
import Foundation
import Testing
@testable import FreeAudio

@Suite struct UpdateCheckTests {
    private func release(
        _ label: String, code: Int?, prerelease: Bool, draft: Bool = false, archive: Bool = true
    ) -> Release {
        let marker = code.map { "\n\n<!-- freeaudio-build: \($0) -->\n" } ?? ""
        let assets = archive ? [Release.Asset(
            name: "FreeAudio-\(label).zip", size: 1, digest: nil,
            downloadURL: URL(string: "https://example.com/FreeAudio-\(label).zip")!
        )] : []
        return Release(
            tagName: prerelease ? label : "v\(label)", name: label, body: "### 🌟 新功能\(marker)", draft: draft,
            prerelease: prerelease, htmlURL: URL(string: "https://example.com/\(label)")!, assets: assets
        )
    }

    @Test func offersTheNewestBuildInTheChannel() {
        let releases = [
            release("26w40b", code: 126000060, prerelease: true),
            release("26w40a", code: 126000055, prerelease: true),
            release("26.2", code: 126000050, prerelease: false),
            release("26.1", code: 126000030, prerelease: false),
        ]
        #expect(UpdateCheck.update(in: releases, channel: .prerelease, current: 126000050)?.label == "26w40b")
        #expect(UpdateCheck.update(in: releases, channel: .release, current: 126000030)?.label == "26.2")
    }

    @Test func aChannelOnlyHearsAboutItself() {
        let releases = [
            release("26w40a", code: 126000060, prerelease: true),
            release("26.2", code: 126000058, prerelease: false),
        ]
        // Someone on releases isn't moved onto snapshots, however new.
        #expect(UpdateCheck.update(in: releases, channel: .release, current: 126000058) == nil)
        // Someone on snapshots isn't offered a release built from a commit they already have.
        #expect(UpdateCheck.update(in: releases, channel: .prerelease, current: 126000060) == nil)
    }

    @Test func buildsAreComparedByCodeNotName() {
        // A snapshot named after a later week can come before a release.
        let releases = [release("26w45a", code: 126000050, prerelease: true)]
        #expect(UpdateCheck.update(in: releases, channel: .prerelease, current: 126000100) == nil)
    }

    @Test func skipsWhatCannotBeInstalledOrCompared() {
        let releases = [
            release("26w41a", code: 126000090, prerelease: true, draft: true),
            release("26w40c", code: nil, prerelease: true),
            release("26w40b", code: 126000080, prerelease: true, archive: false),
            release("26w40a", code: 126000070, prerelease: true),
        ]
        #expect(UpdateCheck.update(in: releases, channel: .prerelease, current: 126000060)?.label == "26w40a")
    }

    @Test func nothingWhenAlreadyCurrent() {
        let releases = [release("26.1", code: 126000030, prerelease: false)]
        #expect(UpdateCheck.update(in: releases, channel: .release, current: 126000030) == nil)
        #expect(UpdateCheck.update(in: [], channel: .release, current: 126000030) == nil)
    }

    @Test func decodesTheGitHubReleaseList() throws {
        let json = #"""
        [{
          "tag_name": "26w39a", "name": "26w39a", "draft": false, "prerelease": true,
          "html_url": "https://github.com/ExpTechTW/FreeAudio/releases/tag/26w39a",
          "body": "_快照_\r\n\r\n<!--  freeaudio-build:126000042  -->\r\n",
          "assets": [
            {"name": "FreeAudio-26w39a.zip", "size": 1234,
             "digest": "sha256:2151b604e3429bff440b9fbc03eb3617bc2603cda96c95b9bb05277f9ddba255",
             "browser_download_url": "https://github.com/ExpTechTW/FreeAudio/releases/download/26w39a/FreeAudio-26w39a.zip"},
            {"name": "notes.txt", "size": 1, "digest": null, "browser_download_url": "https://example.com/notes.txt"}
          ]
        }, {
          "tag_name": "v26.1", "name": null, "draft": false, "prerelease": false, "body": null,
          "html_url": "https://github.com/ExpTechTW/FreeAudio/releases/tag/v26.1", "assets": []
        }]
        """#
        let releases = try JSONDecoder().decode([Release].self, from: Data(json.utf8))
        #expect(releases[0].code == 126000042)
        #expect(releases[0].archive?.size == 1234)
        #expect(releases[0].archive?.digest?.hasPrefix("sha256:") == true)
        #expect(releases[1].label == "v26.1")
        #expect(releases[1].code == nil)
        #expect(releases[1].archive == nil)
    }

    @Test func readsTheBuildFromInfoPlist() {
        let build = BuildInfo(info: [
            "CFBundleVersion": "126000042", "FreeAudioLabel": "26.1", "FreeAudioDate": "26-09-24",
            "FreeAudioPrerelease": false, "FreeAudioRepository": "ExpTechTW/FreeAudio",
        ])
        #expect(build == BuildInfo(info: build.infoForTest))
        #expect(build.code == 126000042)
        #expect(build.label == "26.1")
        #expect(!build.isPrerelease)
        #expect(build.repository == "ExpTechTW/FreeAudio")
    }

    @Test func aBuildWithoutAVersionDoesNotUpdate() {
        // Built before versions were stamped: only a number from the old script.
        let old = BuildInfo(info: ["CFBundleVersion": "1"])
        #expect(old.code == 0)
        #expect(old.label == "dev")
        let odd = BuildInfo(info: ["FreeAudioLabel": "26w39a", "CFBundleVersion": "126000001", "FreeAudioRepository": "a/b/../c"])
        #expect(odd.repository == nil)
    }

    @Test func preferencesKeepDefaultsForMissingFields() throws {
        let preferences = try JSONDecoder().decode(UpdatePreferences.self, from: Data(#"{"announcedCode": 5}"#.utf8))
        #expect(preferences.checksAutomatically)
        #expect(preferences.channel == nil)
        #expect(preferences.announcedCode == 5)
    }
}

private extension BuildInfo {
    var infoForTest: [String: Any] {
        var info: [String: Any] = ["CFBundleVersion": String(code), "FreeAudioLabel": label, "FreeAudioPrerelease": isPrerelease]
        info["FreeAudioDate"] = date
        info["FreeAudioRepository"] = repository
        return info
    }
}

@Suite struct UpdateInstallerTests {
    private let identifier = "io.github.yuyu1015.FreeAudio"

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FreeAudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A minimal app bundle, signed with `identity` when given.
    private func makeApp(in folder: URL, version: String = "126000042", identity: String? = nil) throws -> URL {
        let app = folder.appendingPathComponent("FreeAudio.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("FreeAudio"))
        let info: NSDictionary = [
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "FreeAudio", "CFBundleVersion": version,
            "CFBundlePackageType": "APPL",
        ]
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        if let identity { try run("/usr/bin/codesign", "--force", "--sign", identity, "--timestamp=none", app.path) }
        return app
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: String...) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: text]) }
        return text
    }

    private func asset(for file: URL, digest: String?) throws -> Release.Asset {
        let size = try #require(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        return Release.Asset(name: "FreeAudio-26w39a.zip", size: size, digest: digest, downloadURL: file)
    }

    @Test func acceptsOnlyTheDownloadGitHubDescribed() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("FreeAudio.zip")
        try Data("FreeAudio".utf8).write(to: file)
        let hex = SHA256.hash(data: Data("FreeAudio".utf8)).map { String(format: "%02x", $0) }.joined()

        try UpdateInstaller.checkDigest(of: file, against: asset(for: file, digest: "sha256:\(hex)"))
        try UpdateInstaller.checkDigest(of: file, against: asset(for: file, digest: "SHA256:\(hex.uppercased())"))
        // No digest (uploaded before GitHub computed them): the size still has to match.
        try UpdateInstaller.checkDigest(of: file, against: asset(for: file, digest: nil))
        #expect(throws: UpdateFailure.damaged) {
            try UpdateInstaller.checkDigest(of: file, against: asset(for: file, digest: "sha256:\(String(repeating: "0", count: 64))"))
        }
        #expect(throws: UpdateFailure.damaged) {
            let wrongSize = Release.Asset(name: "FreeAudio.zip", size: 1, digest: nil, downloadURL: file)
            try UpdateInstaller.checkDigest(of: file, against: wrongSize)
        }
    }

    @Test func unpacksTheApp() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try makeApp(in: folder.appendingPathComponent("source"))
        let archive = folder.appendingPathComponent("FreeAudio.zip")
        try run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app.path, archive.path)
        let unpacked = try UpdateInstaller.unpack(archive, into: folder.appendingPathComponent("unpacked"))
        #expect(unpacked.lastPathComponent == "FreeAudio.app")
        #expect(FileManager.default.fileExists(atPath: unpacked.appendingPathComponent("Contents/Info.plist").path))

        #expect(throws: UpdateFailure.damaged) {
            let junk = folder.appendingPathComponent("junk.zip")
            try Data("not a zip".utf8).write(to: junk)
            try UpdateInstaller.unpack(junk, into: folder.appendingPathComponent("junk"))
        }
    }

    @Test func refusesAnAppWithoutTheTeamsSignature() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let unsigned = try makeApp(in: folder.appendingPathComponent("unsigned"))
        #expect(throws: UpdateFailure.untrusted) {
            try UpdateInstaller.verify(unsigned, code: 126000042, bundleIdentifier: identifier, team: "98Q7JARYZF")
        }
        // Anyone can sign ad hoc.
        let adHoc = try makeApp(in: folder.appendingPathComponent("adhoc"), identity: "-")
        #expect(throws: UpdateFailure.untrusted) {
            try UpdateInstaller.verify(adHoc, code: 126000042, bundleIdentifier: identifier, team: "98Q7JARYZF")
        }
    }

    /// Needs a signing certificate, so only runs where there is one.
    @Test(.enabled(if: UpdateInstallerTests.developmentIdentity != nil))
    func acceptsTheTeamsSignatureForTheAdvertisedBuild() throws {
        let identity = try #require(Self.developmentIdentity)
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try makeApp(in: folder, identity: identity.name)
        try UpdateInstaller.verify(app, code: 126000042, bundleIdentifier: identifier, team: identity.team)
        // Signed by the team, but not the build the release said it was.
        #expect(throws: UpdateFailure.damaged) {
            try UpdateInstaller.verify(app, code: 126000043, bundleIdentifier: identifier, team: identity.team)
        }
        // Another team's signature.
        #expect(throws: UpdateFailure.untrusted) {
            try UpdateInstaller.verify(app, code: 126000042, bundleIdentifier: identifier, team: "AAAAAAAAAA")
        }
        // Changed after signing.
        try Data("tampered".utf8).write(to: app.appendingPathComponent("Contents/Resources-extra"))
        #expect(throws: UpdateFailure.untrusted) {
            try UpdateInstaller.verify(app, code: 126000042, bundleIdentifier: identifier, team: identity.team)
        }
    }

    /// The first Apple Development identity in the keychain and its team, read from the certificate.
    static let developmentIdentity: (name: String, team: String)? = {
        let find = Process()
        let output = Pipe()
        find.executableURL = URL(fileURLWithPath: "/bin/sh")
        find.arguments = ["-c", """
            name=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')
            [ -n "$name" ] || exit 1
            team=$(security find-certificate -c "$name" -p | openssl x509 -noout -subject -nameopt multiline \
              | awk -F' = ' '/organizationalUnitName/ { print $2; exit }')
            printf '%s\\n%s' "$name" "$team"
            """]
        find.standardOutput = output
        find.standardError = FileHandle.nullDevice
        guard (try? find.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        find.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        guard find.terminationStatus == 0, lines.count == 2, !lines[1].isEmpty else { return nil }
        return (lines[0], lines[1])
    }()
}
