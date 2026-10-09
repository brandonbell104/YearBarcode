import Foundation

/// A calendar day identified by year and 1-based day of the year.
public struct DayKey: Codable, Hashable, Comparable, Sendable {
    public var year: Int
    public var ordinal: Int

    public init(year: Int, ordinal: Int) {
        self.year = year
        self.ordinal = ordinal
    }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        (lhs.year, lhs.ordinal) < (rhs.year, rhs.ordinal)
    }
}

/// Gregorian calendar pinned to the time zone saved with a generation, so a
/// job partitions days the same way even if the device later travels.
public struct YearCalendar: Sendable {
    public let timeZone: TimeZone
    private let calendar: Calendar

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    public func year(of date: Date) -> Int {
        calendar.component(.year, from: date)
    }

    public func dayKey(for date: Date) -> DayKey {
        let ordinal = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        return DayKey(year: year(of: date), ordinal: ordinal)
    }

    public func startOfYear(_ year: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
    }

    public func daysInYear(_ year: Int) -> Int {
        let start = startOfYear(year)
        return calendar.range(of: .day, in: .year, for: start)?.count ?? 365
    }

    /// Every-Day slots: January 1 through December 31, or through the cutoff
    /// day when the cutoff falls inside the year.
    public func daySlots(year: Int, cutoff: Date) -> [DayKey] {
        let last: Int
        if self.year(of: cutoff) == year {
            last = dayKey(for: cutoff).ordinal
        } else {
            last = daysInYear(year)
        }
        return (1...last).map { DayKey(year: year, ordinal: $0) }
    }

    /// Month/day for display.
    public func date(for day: DayKey) -> Date {
        calendar.date(byAdding: .day, value: day.ordinal - 1, to: startOfYear(day.year))!
    }
}
