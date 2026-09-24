import Combine
import Foundation
import os

/// Languages the interface can be shown in. FreeAudio follows the system unless one is chosen in the app.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case english = "en"

    var id: Self { self }

    private static let storageKey = "language"

    /// The saved choice. A per-app language picked in System Settings counts as one until FreeAudio saves its own.
    static var stored: AppLanguage {
        if let saved = UserDefaults.standard.string(forKey: storageKey) {
            return AppLanguage(rawValue: saved) ?? .system
        }
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let override = UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] as? [String]
        return override.flatMap(bestMatch(for:)) ?? .system
    }

    /// The language the system settings pick among the ones FreeAudio has.
    static var systemChoice: AppLanguage {
        let languages = CFPreferencesCopyAppValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication) as? [String]
        return bestMatch(for: languages ?? Locale.preferredLanguages) ?? .english
    }

    private static func bestMatch(for preferences: [String]) -> AppLanguage? {
        let available = [traditionalChinese, japanese, english].map(\.rawValue)
        guard let match = Bundle.preferredLocalizations(from: available, forPreferences: preferences).first,
              let language = AppLanguage(rawValue: match) else { return nil }
        // The lookup falls back to its first candidate when nothing matches; only accept a real match.
        let code = match.prefix { $0 != "-" }
        return preferences.contains { $0.prefix { $0 != "-" } == code } ? language : nil
    }

    /// Each language is named in itself, so it can be found from any other.
    var displayName: String {
        switch self {
        case .system: LF("language.system", Self.systemChoice.displayName)
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .english: "English"
        }
    }

    var locale: Locale {
        self == .system ? .autoupdatingCurrent : Locale(identifier: rawValue)
    }

    /// Uses this language for every FreeAudio string from now on.
    func apply() {
        let table = StringTable(self)
        activeTable.withLock { $0 = table }
    }

    /// Remembers the choice and hands it to macOS, so text the system draws for FreeAudio
    /// (such as the permission prompt) follows it from the next launch.
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(rawValue, forKey: Self.storageKey)
        if self == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

/// Publishes the interface language so open windows redraw when it changes.
@MainActor
final class LanguageSettings: ObservableObject {
    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            language.apply()
            language.save()
        }
    }

    init() {
        language = AppLanguage.stored
    }
}

/// One language's strings, with English for anything it lacks.
private struct StringTable: Sendable {
    let strings: [String: String]
    let fallback: [String: String]

    init(_ language: AppLanguage) {
        let resolved = language == .system ? AppLanguage.systemChoice : language
        fallback = Self.load(.english)
        strings = resolved == .english ? fallback : Self.load(resolved)
    }

    private static func load(_ language: AppLanguage) -> [String: String] {
        guard let url = resources.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language.rawValue),
              let table = NSDictionary(contentsOf: url) as? [String: String] else { return [:] }
        return table
    }
}

/// The package's resources. In the app they're in Contents/Resources, where SwiftPM's own lookup doesn't look: it
/// tries beside the executable, then the absolute build path, which only exists on the Mac that built it.
private let resources = Bundle.main.resourceURL
    .flatMap { Bundle(url: $0.appendingPathComponent("FreeAudio_FreeAudio.bundle")) } ?? .module

private let activeTable = OSAllocatedUnfairLock(initialState: StringTable(AppLanguage.stored))

func L(_ key: String) -> String {
    activeTable.withLock { $0.strings[key] ?? $0.fallback[key] } ?? key
}

func LF(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: arguments)
}
