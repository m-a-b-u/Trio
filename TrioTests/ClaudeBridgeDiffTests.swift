import Foundation
import Testing
@testable import Trio

@Suite("Claude Bridge Proposal Diff") struct ClaudeBridgeDiffTests {
    @Test("An upper-bound-only change is visible before approval") func upperBoundOnlyChange() {
        let old = [BGTargetEntry(low: 100, high: 120, start: "00:00:00", offset: 0)]
        let new = [BGTargetEntry(low: 100, high: 130, start: "00:00:00", offset: 0)]

        let lines = claudeBGTargetDiff(old: old, new: new)

        #expect(lines.count == 1)
        #expect(lines.first?.key == "Obergrenze ab 00:00")
        #expect(lines.first?.old == "120 mg/dL")
        #expect(lines.first?.new == "130 mg/dL")
    }

    @Test("Both changed bounds retain their labels and change warnings") func bothBoundsChange() {
        let old = [BGTargetEntry(low: 100, high: 120, start: "00:00:00", offset: 0)]
        let new = [BGTargetEntry(low: 140, high: 180, start: "00:00:00", offset: 0)]

        let lines = claudeBGTargetDiff(old: old, new: new)

        #expect(lines.map(\.key) == ["Untergrenze ab 00:00", "Obergrenze ab 00:00"])
        #expect(lines.map(\.old) == ["100 mg/dL", "120 mg/dL"])
        #expect(lines.map(\.new) == ["140 mg/dL", "180 mg/dL"])
        #expect(lines.map(\.warning) == ["Änderung um 40 %", "Änderung um 50 %"])
    }

    @Test("Unchanged bounds do not produce a difference") func unchangedBounds() {
        let entries = [BGTargetEntry(low: 100, high: 120, start: "00:00:00", offset: 0)]

        #expect(claudeBGTargetDiff(old: entries, new: entries).isEmpty)
    }
}
