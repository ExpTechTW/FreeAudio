import AppKit
import Foundation
import Testing
@testable import FreeAudio

@Suite(.serialized) struct LocalizationTests {
    /// Reads a strings file from the sources, so the check doesn't depend on the built bundle.
    private func table(_ language: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FreeAudio/Resources/\(language).lproj/Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String], "\(url.path)")
    }

    private func placeholders(_ text: String) -> [String] {
        text.matches(of: #/%(?:\d+\$)?[@dfs]/#).map { String($0.output) }.sorted()
    }

    @Test func everyLanguageHasEveryStringWithTheSamePlaceholders() throws {
        let english = try table("en")
        for language in ["zh-Hant", "ja"] {
            let other = try table(language)
            #expect(Set(other.keys) == Set(english.keys), "\(language) has different keys")
            for (key, value) in english {
                #expect(placeholders(other[key] ?? "") == placeholders(value), "\(language): \(key)")
            }
        }
    }

    @Test func switchingLanguageChangesStringsImmediately() {
        defer { AppLanguage.stored.apply() }
        AppLanguage.japanese.apply()
        #expect(L("section.output") == "出力")
        AppLanguage.traditionalChinese.apply()
        #expect(L("section.output") == "輸出")
        #expect(LF("language.system", "English") == "跟隨系統（English）")
        AppLanguage.english.apply()
        #expect(L("section.output") == "Output")
        #expect(L("no.such.key") == "no.such.key")
    }

    @Test func languagesAreNamedInThemselves() {
        #expect(AppLanguage.traditionalChinese.displayName == "繁體中文")
        #expect(AppLanguage.japanese.displayName == "日本語")
        #expect(AppLanguage.english.displayName == "English")
    }
}

@Test func theMenuBarIconIsAlignedAsAWhole() {
    let on = MenuBarIcon.image(.on), muted = MenuBarIcon.image(.muted)
    // A symbol's own image aligns by a middle band only, which let the menu bar crop the microphone's top.
    #expect(on.alignmentRect == NSRect(origin: .zero, size: on.size))
    #expect(muted.alignmentRect == NSRect(origin: .zero, size: muted.size))
    #expect(on.size == muted.size && on.size.height <= NSStatusBar.system.thickness)
    #expect(on.isTemplate && !muted.isTemplate)
}
