import Foundation

public enum TrioStatusUnit: String, Codable, CaseIterable {
    case mgdL = "mg/dL"
    case mmolL = "mmol/L"

    public func displayValue(forMgdl value: Double) -> Double {
        // Keep the conversion used by Trio's GlucoseUnits.
        self == .mgdL ? value : value * 0.0555
    }
}

public enum TrioStatusTrend: String, Codable, CaseIterable {
    case tripleUp = "TripleUp"
    case doubleUp = "DoubleUp"
    case singleUp = "SingleUp"
    case fortyFiveUp = "FortyFiveUp"
    case flat = "Flat"
    case fortyFiveDown = "FortyFiveDown"
    case singleDown = "SingleDown"
    case doubleDown = "DoubleDown"
    case tripleDown = "TripleDown"
    case none = "NONE"
    case notComputable = "NOT COMPUTABLE"
    case rateOutOfRange = "RATE OUT OF RANGE"

    public var symbol: String {
        switch self {
        case .tripleUp: return "↑↑↑"
        case .doubleUp: return "↑↑"
        case .singleUp: return "↑"
        case .fortyFiveUp: return "↗"
        case .flat: return "→"
        case .fortyFiveDown: return "↘"
        case .singleDown: return "↓"
        case .doubleDown: return "↓↓"
        case .tripleDown: return "↓↓↓"
        case .none, .notComputable, .rateOutOfRange: return ""
        }
    }
}

public enum TrioStatusFreshness: Equatable {
    case unavailable
    case fresh
    case stale

    public static let maximumAge: TimeInterval = 6 * 60
    public static let futureTolerance: TimeInterval = 60

    public static func evaluate(date: Date?, at now: Date) -> Self {
        guard let date, now.timeIntervalSince1970.isFinite,
              date.timeIntervalSince1970.isFinite,
              date.timeIntervalSince(now) <= futureTolerance
        else { return .unavailable }
        return now.timeIntervalSince(date) >= maximumAge ? .stale : .fresh
    }
}

public enum TrioStatusSnapshotError: Error, Equatable {
    case unsupportedSchema
    case invalidValue(String)
    case unavailableContainer
    case oversizedPayload
}

/// Display data only. Source dates retain their original meaning; writing or
/// reading this value never refreshes a measurement's age.
public struct TrioStatusSnapshot: Codable, Equatable {
    public let schemaVersion: Int
    /// Glucose is always stored in mg/dL, independently of the display unit.
    public let glucoseMgdl: Double?
    public let glucoseDate: Date?
    public let unit: TrioStatusUnit
    public let trend: TrioStatusTrend?
    public let iob: Double?
    public let cob: Double?
    public let determinationDate: Date?
    public let reservoir: Double?
    public let pumpStatus: String?
    public let pumpDate: Date?

    public init(
        glucoseMgdl: Double? = nil,
        glucoseDate: Date? = nil,
        unit: TrioStatusUnit,
        trend: TrioStatusTrend? = nil,
        iob: Double? = nil,
        cob: Double? = nil,
        determinationDate: Date? = nil,
        reservoir: Double? = nil,
        pumpStatus: String? = nil,
        pumpDate: Date? = nil
    ) throws {
        // These broad serialization bounds are not treatment limits or targets.
        try Self.validate(glucoseMgdl, range: 0.001 ... 1000, field: "glucoseMgdl")
        try Self.validate(iob, range: -1000 ... 1000, field: "iob")
        try Self.validate(cob, range: 0 ... 10000, field: "cob")
        try Self.validate(reservoir, range: 0 ... 10000, field: "reservoir")
        for (field, date) in [
            ("glucoseDate", glucoseDate), ("determinationDate", determinationDate), ("pumpDate", pumpDate)
        ] {
            if let date, !date.timeIntervalSince1970.isFinite || !(0 ... 4_102_444_800).contains(date.timeIntervalSince1970) {
                throw TrioStatusSnapshotError.invalidValue(field)
            }
        }
        guard (glucoseMgdl == nil) == (glucoseDate == nil), glucoseMgdl != nil || trend == nil else {
            throw TrioStatusSnapshotError.invalidValue("glucoseDate")
        }
        guard (iob == nil && cob == nil) || determinationDate != nil else {
            throw TrioStatusSnapshotError.invalidValue("determinationDate")
        }
        guard (reservoir == nil && pumpStatus == nil) || pumpDate != nil else {
            throw TrioStatusSnapshotError.invalidValue("pumpDate")
        }
        if let pumpStatus {
            guard !pumpStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  pumpStatus.count <= 80,
                  pumpStatus.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { throw TrioStatusSnapshotError.invalidValue("pumpStatus") }
        }
        schemaVersion = 1
        self.glucoseMgdl = glucoseMgdl
        self.glucoseDate = glucoseDate
        self.unit = unit
        self.trend = trend
        self.iob = iob
        self.cob = cob
        self.determinationDate = determinationDate
        self.reservoir = reservoir
        self.pumpStatus = pumpStatus
        self.pumpDate = pumpDate
    }

    private static func validate(_ value: Double?, range: ClosedRange<Double>, field: String) throws {
        if let value, !value.isFinite || !range.contains(value) {
            throw TrioStatusSnapshotError.invalidValue(field)
        }
    }

    public func glucoseFreshness(at date: Date) -> TrioStatusFreshness {
        TrioStatusFreshness.evaluate(date: glucoseDate, at: date)
    }

    public func determinationFreshness(at date: Date) -> TrioStatusFreshness {
        TrioStatusFreshness.evaluate(date: determinationDate, at: date)
    }

    public func pumpFreshness(at date: Date) -> TrioStatusFreshness {
        TrioStatusFreshness.evaluate(date: pumpDate, at: date)
    }

    public func formattedGlucose(locale: Locale = .current) -> String? {
        guard let glucoseMgdl else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = unit == .mgdL ? 0 : 1
        formatter.maximumFractionDigits = unit == .mgdL ? 0 : 1
        return formatter.string(from: NSNumber(value: unit.displayValue(forMgdl: glucoseMgdl)))
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, glucoseMgdl, glucoseDate, unit, trend, iob, cob, determinationDate, reservoir, pumpStatus, pumpDate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw TrioStatusSnapshotError.unsupportedSchema
        }
        try self.init(
            glucoseMgdl: container.decodeIfPresent(Double.self, forKey: .glucoseMgdl),
            glucoseDate: container.decodeIfPresent(Date.self, forKey: .glucoseDate),
            unit: container.decode(TrioStatusUnit.self, forKey: .unit),
            trend: container.decodeIfPresent(TrioStatusTrend.self, forKey: .trend),
            iob: container.decodeIfPresent(Double.self, forKey: .iob),
            cob: container.decodeIfPresent(Double.self, forKey: .cob),
            determinationDate: container.decodeIfPresent(Date.self, forKey: .determinationDate),
            reservoir: container.decodeIfPresent(Double.self, forKey: .reservoir),
            pumpStatus: container.decodeIfPresent(String.self, forKey: .pumpStatus),
            pumpDate: container.decodeIfPresent(Date.self, forKey: .pumpDate)
        )
    }
}

/// Pure scheduling logic shared with tests. Entries can mark existing data old;
/// they never predict a future glucose value or request treatment.
public enum TrioStatusTimeline {
    public static let reloadInterval: TimeInterval = 15 * 60

    public static func entryDates(for snapshot: TrioStatusSnapshot?, now: Date) -> [Date] {
        guard let snapshot else { return [now] }
        let sourceDates = [snapshot.glucoseDate, snapshot.determinationDate, snapshot.pumpDate].compactMap { $0 }
        let expirations = sourceDates.filter {
            TrioStatusFreshness.evaluate(date: $0, at: now) == .fresh
        }.map { $0.addingTimeInterval(TrioStatusFreshness.maximumAge) }.filter { $0 > now }
        return [now] + Array(Set(expirations)).sorted()
    }
}
