import SwiftUI

/// A week as a row of days, each with a bar for its value and the value underneath; clicking a day picks it, and the
/// arrows move a week. Days still to come are dimmed.
struct WeekStrip: View {
    @Environment(\.locale) private var locale
    @Binding var selected: Date
    /// How much the day had; the bars are scaled to the week's largest.
    let value: (Date) -> Double
    /// What's written under the day.
    let caption: (Date) -> String
    /// The bar's colour for a day.
    var tint: (Date) -> Color = { _ in .accentColor }

    var body: some View {
        let calendar = Calendar.current
        let days = Day.week(of: selected, calendar: calendar)
        let values = days.map(value)
        let largest = max(values.max() ?? 0, 1e-9)
        let today = calendar.startOfDay(for: Date())
        HStack(spacing: 6) {
            arrow("chevron.left", help: L("stats.previous_week")) { move(-7) }
            ForEach(Array(zip(days, values)), id: \.0) { date, amount in
                let future = date > today
                Button {
                    selected = date
                } label: {
                    VStack(spacing: 4) {
                        Text(date.formatted(.dateTime.weekday(.abbreviated).locale(locale)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(date.formatted(.dateTime.day().locale(locale)))
                            .font(.callout.weight(calendar.isDate(date, inSameDayAs: today) ? .bold : .regular))
                            .foregroundStyle(calendar.isDate(date, inSameDayAs: today) ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        Capsule()
                            .fill(.fill.tertiary)
                            .frame(width: 6, height: 28)
                            .overlay(alignment: .bottom) {
                                Capsule().fill(tint(date)).frame(width: 6, height: amount > 0 ? max(28 * amount / largest, 4) : 0)
                            }
                        Text(future ? " " : caption(date))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(calendar.isDate(date, inSameDayAs: selected) ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.clear))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(future)
                .opacity(future ? 0.4 : 1)
                .accessibilityLabel(date.formatted(.dateTime.month().day().weekday(.wide).locale(locale)))
                .accessibilityValue(caption(date))
                .accessibilityAddTraits(calendar.isDate(date, inSameDayAs: selected) ? .isSelected : [])
            }
            arrow("chevron.right", help: L("stats.next_week")) { move(7) }
                .disabled(days.last.map { $0 >= today } ?? true)
        }
    }

    private func arrow(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.callout.weight(.semibold)).frame(width: 20, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Keeps to days that have been.
    private func move(_ days: Int) {
        let calendar = Calendar.current
        guard let date = calendar.date(byAdding: .day, value: days, to: selected) else { return }
        selected = min(date, calendar.startOfDay(for: Date()))
    }
}

/// The one number a view leads with, what it is, and a line of what goes with it.
struct Headline: View {
    let value: String
    let title: String
    var facts: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 34, weight: .semibold, design: .rounded))
            if !facts.isEmpty {
                Text(facts.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A share of something, on a track of the same colour.
struct Meter: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        Capsule()
            .fill(tint.opacity(0.18))
            .frame(height: 8)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule().fill(tint).frame(width: fraction > 0 ? max(geometry.size.width * min(fraction, 1), 8) : 0)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Minutes and hours as they read best: "45 min" under an hour, "4.7 hr" above it.
func shortDuration(_ seconds: Double) -> String {
    guard seconds >= 60 else { return seconds > 0 ? "<1m" : "—" }
    if seconds < 3_600 { return "\(Int((seconds / 60).rounded()))m" }
    return String(format: "%.1fh", seconds / 3_600)
}
