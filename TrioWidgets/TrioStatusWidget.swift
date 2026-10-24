import Foundation
import SwiftUI
import WidgetKit

struct TrioStatusWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: TrioStatusSnapshot?
}

struct TrioStatusWidgetProvider: TimelineProvider {
    func placeholder(in _: Context) -> TrioStatusWidgetEntry {
        previewEntry()
    }

    func getSnapshot(in context: Context, completion: @escaping (TrioStatusWidgetEntry) -> Void) {
        completion(context.isPreview ? previewEntry() : TrioStatusWidgetEntry(date: Date(), snapshot: load()))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<TrioStatusWidgetEntry>) -> Void) {
        let now = Date()
        let snapshot = load()
        let entries = TrioStatusTimeline.entryDates(for: snapshot, now: now).map {
            TrioStatusWidgetEntry(date: $0, snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(TrioStatusTimeline.reloadInterval))))
    }

    private func load() -> TrioStatusSnapshot? {
        // Missing permissions, corrupt files and absent data produce an empty
        // state, never demonstration values in a live widget.
        guard let store = TrioStatusSnapshotStore.configured() else { return nil }
        return try? store.load()
    }

    private func previewEntry() -> TrioStatusWidgetEntry {
        let date = Date()
        // Synthetic gallery/placeholder data only. No app group is read here.
        let snapshot = try? TrioStatusSnapshot(
            glucoseMgdl: 110, glucoseDate: date, unit: .mgdL, trend: .flat,
            iob: 1.2, cob: 15, determinationDate: date, reservoir: 100,
            pumpStatus: "Beispiel", pumpDate: date
        )
        return TrioStatusWidgetEntry(date: date, snapshot: snapshot)
    }
}

struct TrioStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TrioStatusSnapshotStore.widgetKind, provider: TrioStatusWidgetProvider()) { entry in
            TrioStatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Trio Status")
        .description("Glukose und Pumpenstatus aus Trio auf diesem Gerät.")
        .supportedFamilies(families)
    }

    private var families: [WidgetFamily] {
        #if os(iOS) && !targetEnvironment(macCatalyst)
            return [.systemSmall, .systemMedium, .accessoryRectangular]
        #else
            return [.systemSmall, .systemMedium]
        #endif
    }
}

private struct TrioStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redactionReasons
    let entry: TrioStatusWidgetEntry

    var body: some View {
        content
            .privacySensitive()
            .widgetURL(appURL)
            .modifier(TrioStatusWidgetBackground())
    }

    private var appURL: URL? {
        #if os(macOS) || targetEnvironment(macCatalyst)
            return URL(string: "trio-mac://")
        #else
            return URL(string: "Trio://")
        #endif
    }

    private var isAccessory: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
            return family == .accessoryRectangular
        #else
            return false
        #endif
    }

    @ViewBuilder private var content: some View {
        if redactionReasons.contains(.privacy) {
            Label("Trio", systemImage: "lock.fill")
        } else if let snapshot = entry.snapshot {
            if isAccessory {
                accessory(snapshot)
            } else if family == .systemMedium {
                HStack(alignment: .top, spacing: 16) {
                    glucose(snapshot)
                    VStack(alignment: .leading, spacing: 6) {
                        metric("IOB", value: snapshot.iob, unit: "U", fresh: snapshot.determinationFreshness(at: entry.date))
                        metric("COB", value: snapshot.cob, unit: "g", fresh: snapshot.determinationFreshness(at: entry.date))
                        metric("Reservoir", value: snapshot.reservoir, unit: "U", fresh: snapshot.pumpFreshness(at: entry.date))
                        if let status = snapshot.pumpStatus {
                            Text(snapshot.pumpFreshness(at: entry.date) == .fresh ? status : "Pumpenstatus veraltet")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                glucose(snapshot)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Trio", systemImage: "drop.fill")
                Text("Keine Daten")
                    .font(.headline)
                Text("Trio auf diesem Gerät öffnen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func accessory(_ snapshot: TrioStatusSnapshot) -> some View {
        let freshness = snapshot.glucoseFreshness(at: entry.date)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(freshness == .unavailable ? "—" : snapshot.formattedGlucose() ?? "—")
                    .font(.headline)
                    .monospacedDigit()
                    .strikethrough(freshness == .stale)
                if freshness == .fresh, let trend = snapshot.trend { Text(trend.symbol) }
                Text(snapshot.unit.rawValue)
                    .font(.caption2)
            }
            HStack(spacing: 4) {
                Text(freshness == .stale ? "Veraltet" : "Trio")
                if freshness != .unavailable, let date = snapshot.glucoseDate {
                    Text(date, style: .time)
                } else {
                    Text("Keine Daten")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func glucose(_ snapshot: TrioStatusSnapshot) -> some View {
        let freshness = snapshot.glucoseFreshness(at: entry.date)
        let hasReading = freshness != .unavailable
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Trio")
                if freshness == .stale { Text("· Veraltet") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(hasReading ? (snapshot.formattedGlucose() ?? "—") : "—")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .strikethrough(freshness == .stale)
                if freshness == .fresh, let trend = snapshot.trend {
                    Text(trend.symbol)
                        .font(.headline)
                }
            }
            .foregroundStyle(freshness == .stale ? .secondary : .primary)
            Text(snapshot.unit.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if hasReading, let date = snapshot.glucoseDate {
                HStack(spacing: 3) {
                    Text(date, style: .time)
                    Text("·")
                    Text(date, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            } else {
                Text("Keine aktuelle Messung")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ title: String, value: Double?, unit: String, fresh: TrioStatusFreshness) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 4)
            if let value, fresh == .fresh {
                Text("\(value.formatted(.number.precision(.fractionLength(0 ... 1)))) \(unit)")
                    .monospacedDigit()
            } else {
                Text(fresh == .stale ? "Veraltet" : "—")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }
}

private struct TrioStatusWidgetBackground: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            content.containerBackground(for: .widget) { Color.clear }
        } else {
            content.background(Color.clear)
        }
    }
}
