import Foundation
import Testing
@testable import TrioMenuBar

@Suite("Local menu bar status") @MainActor struct TrioMenuBarTests {
    private let date = Date(timeIntervalSince1970: 1_600_000_000)

    @Test("Menu bar values use stored units and respect the privacy choice") func menuBarValue() throws {
        let snapshot = try TrioStatusSnapshot(glucoseMgdl: 180, glucoseDate: date, unit: .mmolL, trend: .flat)
        let presentation = TrioMenuBarPresentation(snapshot: snapshot, now: date, loadFailed: false)

        #expect(presentation.menuBarTitle(showGlucose: false) == "Trio")
        #expect(presentation.menuBarTitle(showGlucose: true, locale: Locale(identifier: "en_US_POSIX")) == "10.0 →")
    }

    @Test("Polling never refreshes source dates or merges source freshness") func sourceDates() throws {
        let snapshot = try TrioStatusSnapshot(
            glucoseMgdl: 110, glucoseDate: date, unit: .mgdL,
            iob: 1, determinationDate: date.addingTimeInterval(-200),
            reservoir: 100, pumpDate: date.addingTimeInterval(-400)
        )
        let model = TrioMenuBarStatusModel(loadSnapshot: { snapshot })
        model.reload(at: date)
        #expect(model.presentation.glucoseFreshness == .fresh)
        #expect(model.presentation.snapshot?.pumpFreshness(at: date) == .stale)

        model.reload(at: date.addingTimeInterval(360))
        #expect(model.presentation.glucoseFreshness == .stale)
        #expect(model.presentation.snapshot?.glucoseDate == date)
        #expect(model.presentation.snapshot?.determinationDate == date.addingTimeInterval(-200))
        #expect(model.presentation.menuBarTitle(showGlucose: true) != "110")
    }

    @Test("Read failure removes the previous value and does not fall back to sample data") func readFailure() throws {
        var fail = false
        let snapshot = try TrioStatusSnapshot(glucoseMgdl: 110, glucoseDate: date, unit: .mgdL)
        let model = TrioMenuBarStatusModel(loadSnapshot: {
            if fail { throw TrioStatusSnapshotError.oversizedPayload }
            return snapshot
        })
        model.reload(at: date)
        #expect(model.presentation.snapshot != nil)
        fail = true
        model.reload(at: date)
        #expect(model.presentation.snapshot == nil)
        #expect(model.presentation.loadFailed)
        #expect(model.presentation.glucoseValue() == nil)
        #expect(!model.presentation.menuBarTitle(showGlucose: true).contains("110"))
    }

    @Test("Missing and future-dated data remain unavailable") func unavailable() throws {
        let model = TrioMenuBarStatusModel(loadSnapshot: { nil })
        model.reload(at: date)
        #expect(model.presentation.snapshot == nil)
        #expect(!model.presentation.loadFailed)

        let snapshot = try TrioStatusSnapshot(glucoseMgdl: 110, glucoseDate: date.addingTimeInterval(61), unit: .mgdL)
        let presentation = TrioMenuBarPresentation(snapshot: snapshot, now: date, loadFailed: false)
        #expect(presentation.glucoseFreshness == .unavailable)
        #expect(presentation.glucoseValue() == nil)
    }
}
