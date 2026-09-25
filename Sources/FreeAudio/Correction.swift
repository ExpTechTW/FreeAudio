import Foundation

/// A headphone correction profile: the parametric equalizer AutoEq publishes for a headphone model, in Equalizer APO's
/// format (the `ParametricEQ.txt` of each model on github.com/jaakkopasanen/AutoEq).
struct HeadphoneCorrection: Codable, Equatable, Sendable {
    var name: String
    var preamp: Double
    var filters: [Filter]
    var enabled = true

    init(name: String, preamp: Double, filters: [Filter]) {
        self.name = name
        self.preamp = preamp
        self.filters = filters
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        preamp = try container.decode(Double.self, forKey: .preamp)
        filters = try container.decode([Filter].self, forKey: .filters)
        try container.update(&enabled, .enabled)
    }

    /// Reads lines such as
    ///
    ///     Preamp: -6.2 dB
    ///     Filter 1: ON LSC Fc 105 Hz Gain 6.5 dB Q 0.70
    ///     Filter 2: ON PK Fc 2000 Hz Gain -3.1 dB BW Oct 1.0
    ///
    /// Filters that are OFF, of a kind FreeAudio doesn't have, or past the ones it can hold are left out, as are
    /// comments and other commands. `nil` when no filter is left.
    static func parse(_ text: String, name: String) -> HeadphoneCorrection? {
        var preamp = 0.0
        var filters: [Filter] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
            guard let command = words.first else { continue }
            if command == "preamp:", let gain = number(after: "preamp:", in: words) {
                preamp += gain
            } else if command.hasPrefix("filter"), let filter = filter(words), filters.count < FilterSet.correctionCapacity {
                filters.append(filter)
            }
        }
        return filters.isEmpty ? nil : HeadphoneCorrection(name: name, preamp: preamp, filters: filters)
    }

    private static func filter(_ words: [String]) -> Filter? {
        guard let state = words.firstIndex(where: { $0 == "on" || $0 == "off" }), words[state] == "on",
              state + 1 < words.count, let frequency = number(after: "fc", in: words) else { return nil }
        let kind: FilterKind
        switch words[state + 1] {
        case "pk", "peq", "peak": kind = .peak
        case "lsc", "ls", "lsq": kind = .lowShelf
        case "hsc", "hs", "hsq": kind = .highShelf
        case "lp", "lpq": kind = .lowPass
        case "hp", "hpq": kind = .highPass
        default: return nil
        }
        var q = number(after: "q", in: words) ?? 0.7071
        if let octaves = number(after: "oct", in: words) {
            // Bandwidth in octaves, as Equalizer APO converts it.
            let ratio = pow(2, octaves)
            q = ratio.squareRoot() / (ratio - 1)
        }
        return Filter(kind: kind, frequency: frequency, gain: number(after: "gain", in: words) ?? 0, q: q)
    }

    private static func number(after key: String, in words: [String]) -> Double? {
        guard let index = words.firstIndex(of: key), index + 1 < words.count else { return nil }
        return Double(words[index + 1])
    }
}
