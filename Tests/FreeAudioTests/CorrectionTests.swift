import Foundation
import Testing
@testable import FreeAudio

@Suite struct CorrectionTests {
    @Test func readsAnAutoEqProfile() throws {
        let text = """
        Preamp: -6.2 dB
        Filter 1: ON LSC Fc 105 Hz Gain 6.5 dB Q 0.70
        Filter 2: ON PK Fc 2000 Hz Gain -3.1 dB Q 1.41
        Filter 3: OFF PK Fc 3000 Hz Gain 2.0 dB Q 1.00
        # a comment
        Filter 4: ON HSC Fc 10000 Hz Gain -4.0 dB Q 0.70
        Filter 5: ON PK Fc 500 Hz Gain 1.0 dB BW Oct 1.0
        Filter 6: ON NO Fc 100 Hz
        Filter 7: ON HP Fc 20 Hz
        """
        let profile = try #require(HeadphoneCorrection.parse(text, name: "HD 600"))
        #expect(profile.name == "HD 600" && profile.preamp == -6.2 && profile.enabled)
        #expect(profile.filters.map(\.kind) == [.lowShelf, .peak, .highShelf, .peak, .highPass])
        #expect(profile.filters[0] == Filter(kind: .lowShelf, frequency: 105, gain: 6.5, q: 0.7))
        #expect(abs(profile.filters[3].q - 2.squareRoot()) < 1e-9)
        #expect(profile.filters[4].q == 0.7071 && profile.filters[4].gain == 0)
    }

    @Test func textWithoutFiltersIsNotAProfile() {
        #expect(HeadphoneCorrection.parse("Preamp: -3 dB\nhello", name: "x") == nil)
        #expect(HeadphoneCorrection.parse("", name: "x") == nil)
    }

    @Test func keepsOnlyTheFiltersThereIsRoomFor() throws {
        let text = (1...40).map { "Filter \($0): ON PK Fc \(100 * $0) Hz Gain 1 dB Q 1" }.joined(separator: "\n")
        #expect(try #require(HeadphoneCorrection.parse(text, name: "x")).filters.count == FilterSet.correctionCapacity)
    }
}
