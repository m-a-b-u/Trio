import Foundation
@testable import TrioStatusWidgetCore
import XCTest

final class TrioStatusWidgetCoreTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testGlucoseUnitAndNativeTrendMapping() throws {
        let snapshot = try TrioStatusSnapshot(glucoseMgdl: 180, glucoseDate: date, unit: .mmolL, trend: .doubleUp)
        XCTAssertEqual(snapshot.formattedGlucose(locale: Locale(identifier: "en_US_POSIX")), "10.0")
        XCTAssertEqual(TrioStatusTrend(rawValue: "DoubleUp")?.symbol, "↑↑")
        XCTAssertEqual(TrioStatusTrend(rawValue: "NOT COMPUTABLE")?.symbol, "")
        XCTAssertNil(TrioStatusTrend(rawValue: "arbitrary text"))
    }

    func testSourceTimesAreRequiredAndIndependent() throws {
        XCTAssertThrowsError(try TrioStatusSnapshot(glucoseMgdl: 110, unit: .mgdL))
        XCTAssertThrowsError(try TrioStatusSnapshot(unit: .mgdL, iob: 1))
        XCTAssertThrowsError(try TrioStatusSnapshot(unit: .mgdL, reservoir: 100))
        let snapshot = try TrioStatusSnapshot(
            glucoseMgdl: 110, glucoseDate: date.addingTimeInterval(-400), unit: .mgdL,
            iob: -0.2, cob: 12, determinationDate: date, reservoir: 90, pumpDate: date.addingTimeInterval(-500)
        )
        XCTAssertEqual(snapshot.glucoseFreshness(at: date), .stale)
        XCTAssertEqual(snapshot.determinationFreshness(at: date), .fresh)
        XCTAssertEqual(snapshot.pumpFreshness(at: date), .stale)
    }

    func testStalenessBoundaryAndFutureClockAreExplicit() {
        XCTAssertEqual(TrioStatusFreshness.evaluate(date: date, at: date.addingTimeInterval(359)), .fresh)
        XCTAssertEqual(TrioStatusFreshness.evaluate(date: date, at: date.addingTimeInterval(360)), .stale)
        XCTAssertEqual(TrioStatusFreshness.evaluate(date: date.addingTimeInterval(61), at: date), .unavailable)
        XCTAssertEqual(TrioStatusFreshness.evaluate(date: nil, at: date), .unavailable)
    }

    func testTimelineSchedulesEachSourceExpiryWithoutRejuvenatingData() throws {
        let snapshot = try TrioStatusSnapshot(
            glucoseMgdl: 110, glucoseDate: date.addingTimeInterval(-300), unit: .mgdL,
            iob: 1, determinationDate: date, reservoir: 100, pumpDate: date
        )
        XCTAssertEqual(TrioStatusTimeline.entryDates(for: snapshot, now: date), [
            date, date.addingTimeInterval(60), date.addingTimeInterval(360)
        ])
        XCTAssertEqual(TrioStatusTimeline.entryDates(for: snapshot, now: date.addingTimeInterval(360)), [
            date.addingTimeInterval(360)
        ])
        XCTAssertEqual(snapshot.glucoseDate, date.addingTimeInterval(-300))
    }

    func testNonfiniteBoundsAndUnboundedStringsAreRejected() {
        for value in [Double.nan, .infinity, -.infinity, 0, -1, 1001] {
            XCTAssertThrowsError(try TrioStatusSnapshot(glucoseMgdl: value, glucoseDate: date, unit: .mgdL))
        }
        XCTAssertThrowsError(try TrioStatusSnapshot(unit: .mgdL, cob: -1, determinationDate: date))
        XCTAssertThrowsError(try TrioStatusSnapshot(unit: .mgdL, iob: 1001, determinationDate: date))
        XCTAssertThrowsError(try TrioStatusSnapshot(unit: .mgdL, reservoir: 10001, pumpDate: date))
        for text in ["", String(repeating: "x", count: 81), "Connected\nInjected row"] {
            XCTAssertThrowsError(try TrioStatusSnapshot(unit: .mgdL, pumpStatus: text, pumpDate: date))
        }
    }

    func testDecodeEnforcesSchemaTypesBoundsAndOriginalDates() throws {
        let valid = try TrioStatusSnapshot(glucoseMgdl: 110, glucoseDate: date, unit: .mgdL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(valid)
        XCTAssertEqual(try decoder.decode(TrioStatusSnapshot.self, from: data), valid)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value) in [
            ("schemaVersion", 2 as Any), ("glucoseMgdl", -5 as Any), ("glucoseMgdl", "110" as Any),
            ("glucoseDate", 9e15 as Any), ("unit", "unrecognized" as Any), ("trend", "unrecognized" as Any)
        ] {
            var changed = original
            changed[key] = value
            XCTAssertThrowsError(try decoder.decode(TrioStatusSnapshot.self, from: JSONSerialization.data(withJSONObject: changed)))
        }
    }

    func testStoreRoundTripReplacementRemovalAndPayloadLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TrioWidgetTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrioStatusSnapshotStore(directoryURL: directory)
        XCTAssertNil(try store.load())
        let first = try TrioStatusSnapshot(glucoseMgdl: 110, glucoseDate: date, unit: .mgdL)
        try store.save(first)
        XCTAssertEqual(try store.load(), first)
        let replacement = try TrioStatusSnapshot(unit: .mmolL)
        try store.save(replacement)
        XCTAssertEqual(try store.load(), replacement)
        let path = directory.appendingPathComponent(TrioStatusSnapshotStore.fileName)
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try Data(repeating: 32, count: TrioStatusSnapshotStore.maximumPayloadSize + 1).write(to: path)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? TrioStatusSnapshotError, .oversizedPayload) }
        try Data("{broken".utf8).write(to: path)
        XCTAssertThrowsError(try store.load())
        try store.remove()
        XCTAssertNil(try store.load())
    }
}
