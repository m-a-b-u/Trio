import Combine
import Foundation

struct TrioMenuBarPresentation {
    let snapshot: TrioStatusSnapshot?
    let now: Date
    let loadFailed: Bool

    var glucoseFreshness: TrioStatusFreshness {
        snapshot?.glucoseFreshness(at: now) ?? .unavailable
    }

    func glucoseValue(locale: Locale = .current) -> String? {
        guard glucoseFreshness != .unavailable else { return nil }
        return snapshot?.formattedGlucose(locale: locale)
    }

    func menuBarTitle(showGlucose: Bool, locale: Locale = .current) -> String {
        guard showGlucose else { return "Trio" }
        guard let glucose = glucoseValue(locale: locale) else { return "Trio —" }
        if glucoseFreshness == .stale {
            return glucose + " · " + String(localized: "alt")
        }
        let trend = snapshot?.trend?.symbol ?? ""
        return trend.isEmpty ? glucose : glucose + " " + trend
    }
}

@MainActor final class TrioMenuBarStatusModel: ObservableObject {
    @Published private(set) var presentation: TrioMenuBarPresentation
    private let loadSnapshot: () throws -> TrioStatusSnapshot?

    init(loadSnapshot: @escaping () throws -> TrioStatusSnapshot? = {
        guard let store = TrioStatusSnapshotStore.configured() else {
            throw TrioStatusSnapshotError.unavailableContainer
        }
        return try store.load()
    }) {
        self.loadSnapshot = loadSnapshot
        presentation = TrioMenuBarPresentation(snapshot: nil, now: Date(), loadFailed: false)
    }

    func reload(at now: Date = Date()) {
        do {
            presentation = TrioMenuBarPresentation(snapshot: try loadSnapshot(), now: now, loadFailed: false)
        } catch {
            // Never leave a previously loaded value visible when the local snapshot cannot be read.
            presentation = TrioMenuBarPresentation(snapshot: nil, now: now, loadFailed: true)
        }
    }

    func observeLocalSnapshot() async {
        while !Task.isCancelled {
            reload()
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
        }
    }
}
