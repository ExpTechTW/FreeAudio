import Foundation

/// The version this copy was built as, from the keys scripts/build-app.sh writes into Info.plist
/// (the values come from scripts/version.sh).
struct BuildInfo: Equatable, Sendable {
    /// What people see: `26.1` for a release, `26w39a` for a snapshot.
    var label: String
    /// CFBundleVersion, the only value that says which of two builds is newer. 0 for a build without a version,
    /// such as `swift run`.
    var code: Int
    /// The day its commit was made, `yy-MM-dd`.
    var date: String?
    /// Snapshots are published as pre-releases.
    var isPrerelease: Bool
    /// `owner/name` of the GitHub repository releases are published to.
    var repository: String?

    init(info: [String: Any]) {
        let label = info["FreeAudioLabel"] as? String
        self.label = label ?? "dev"
        code = label == nil ? 0 : (info["CFBundleVersion"] as? String).flatMap { Int($0) } ?? 0
        date = info["FreeAudioDate"] as? String
        isPrerelease = info["FreeAudioPrerelease"] as? Bool ?? true
        repository = (info["FreeAudioRepository"] as? String).flatMap {
            $0.wholeMatch(of: #/[A-Za-z0-9-]+/[A-Za-z0-9._-]+/#) == nil ? nil : $0
        }
    }

    static let current = BuildInfo(info: Bundle.main.infoDictionary ?? [:])
}

/// A GitHub release, as the REST API lists it.
struct Release: Decodable, Equatable, Sendable {
    let tagName: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let htmlURL: URL
    let assets: [Asset]

    struct Asset: Decodable, Equatable, Sendable {
        let name: String
        let size: Int
        /// `sha256:<hex>`, computed by GitHub when the file was uploaded.
        let digest: String?
        let downloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case downloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, draft, prerelease
        case htmlURL = "html_url"
        case assets
    }

    /// The release's title, which is the build's label.
    var label: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? tagName }

    /// The build it carries, from the `<!-- freeaudio-build: 126000042 -->` line at the end of its notes.
    var code: Int? {
        guard let body, let match = body.firstMatch(of: #/<!--\s*freeaudio-build:\s*(\d+)\s*-->/#) else { return nil }
        return Int(match.1)
    }

    /// The zipped app, `FreeAudio-<label>.zip`.
    var archive: Asset? {
        assets.first { $0.name.hasPrefix("FreeAudio-") && $0.name.hasSuffix(".zip") }
    }
}

enum UpdateChannel: String, Codable, Sendable {
    /// Releases, tagged `v26.1`.
    case release
    /// Snapshots, published as pre-releases from every push to main.
    case prerelease
}

enum UpdateCheck {
    /// The newest build in `channel` that's newer than `current`, if there is one.
    ///
    /// Builds are compared by code, never by name: a snapshot named after a later week can come before the release
    /// it led to. A channel only hears about itself, as in DPIP: someone on releases isn't moved onto snapshots, and
    /// someone on snapshots isn't offered the release built from a commit they already have. A release without a code
    /// or an app to download is skipped rather than guessed at.
    static func update(in releases: [Release], channel: UpdateChannel, current: Int) -> Release? {
        var best: (release: Release, code: Int)?
        for release in releases where !release.draft && release.prerelease == (channel == .prerelease) {
            guard let code = release.code, code > (best?.code ?? current), release.archive != nil else { continue }
            best = (release, code)
        }
        return best?.release
    }
}

struct UpdatePreferences: Codable, Equatable, Sendable {
    var checksAutomatically = true
    /// Nil follows the running build: a snapshot updates to snapshots, a release to releases.
    var channel: UpdateChannel?
    /// The newest build announced so far; each build is announced once.
    var announcedCode = 0
    var lastAnnouncement: Date?
    var lastCheck: Date?

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        checksAutomatically = try container.decodeIfPresent(Bool.self, forKey: .checksAutomatically) ?? true
        channel = try container.decodeIfPresent(UpdateChannel.self, forKey: .channel)
        announcedCode = try container.decodeIfPresent(Int.self, forKey: .announcedCode) ?? 0
        lastAnnouncement = try container.decodeIfPresent(Date.self, forKey: .lastAnnouncement)
        lastCheck = try container.decodeIfPresent(Date.self, forKey: .lastCheck)
    }

    private static let key = "FreeAudio.update.v1"

    static func load() -> UpdatePreferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let preferences = try? JSONDecoder().decode(UpdatePreferences.self, from: data) else { return UpdatePreferences() }
        return preferences
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
