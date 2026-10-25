import Foundation

/// Local aggregate counters only: no inserted text, application identity, or event log.
/// Days use the Gregorian calendar and the time zone captured when tracking starts.
/// Keeping that zone across travel and relaunch avoids reassigning existing days.
/// Every daily bucket is retained until an explicit reset; legacy counters are separate.
struct SavingsStatistics: Codable, Equatable {
    enum StatisticsError: LocalizedError {
        case counterOverflow

        var errorDescription: String? {
            "Savings counters have reached their supported limit. Existing statistics are preserved; reset statistics to resume counting."
        }
    }

    private enum CodingKeys: String, CodingKey {
        case timeZoneIdentifier, days
    }

    enum Period: String, CaseIterable, Identifiable {
        case today, last7Days, allTime

        var id: Self { self }
        var title: String {
            switch self {
            case .today: return "Today"
            case .last7Days: return "Last 7 Days"
            case .allTime: return "All Time"
            }
        }
    }

    struct Snapshot: Codable, Equatable {
        fileprivate(set) var insertedCharacters = 0
        fileprivate(set) var acceptedCompletions = 0
        fileprivate(set) var rewrittenCharacters = 0
        fileprivate(set) var acceptedRewrites = 0

        /// Nominal five-character words, not inferred linguistic word counts.
        /// This is gross typing time, not measured net time saved; review time is unknown.
        func estimatedSeconds(wordsPerMinute: Double) -> Double {
            guard wordsPerMinute.isFinite, wordsPerMinute > 0 else { return 0 }
            return Double(insertedCharacters) / 5 / wordsPerMinute * 60
        }

        fileprivate func addingChecked(_ other: Self) throws -> Self {
            let characters = insertedCharacters.addingReportingOverflow(other.insertedCharacters)
            let completions = acceptedCompletions.addingReportingOverflow(other.acceptedCompletions)
            let replacementCharacters = rewrittenCharacters.addingReportingOverflow(other.rewrittenCharacters)
            let rewrites = acceptedRewrites.addingReportingOverflow(other.acceptedRewrites)
            guard !characters.overflow, !completions.overflow,
                  !replacementCharacters.overflow, !rewrites.overflow else {
                throw StatisticsError.counterOverflow
            }
            return Self(insertedCharacters: characters.partialValue,
                        acceptedCompletions: completions.partialValue,
                        rewrittenCharacters: replacementCharacters.partialValue,
                        acceptedRewrites: rewrites.partialValue)
        }

        fileprivate mutating func add(_ other: Self) {
            insertedCharacters += other.insertedCharacters
            acceptedCompletions += other.acceptedCompletions
            rewrittenCharacters += other.rewrittenCharacters
            acceptedRewrites += other.acceptedRewrites
        }
    }

    let timeZoneIdentifier: String
    private var days: [String: Snapshot] = [:]
    /// Derived cache, not a second persisted source of truth.
    private var lifetime = Snapshot()

    init(timeZone: TimeZone = .current) {
        timeZoneIdentifier = timeZone.identifier
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        timeZoneIdentifier = try values.decode(String.self, forKey: .timeZoneIdentifier)
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .timeZoneIdentifier, in: values,
                                                  debugDescription: "Unknown statistics time zone")
        }
        days = try values.decode([String: Snapshot].self, forKey: .days)
        let calendar = calendar
        for (key, totals) in days {
            guard isValidDayKey(key, calendar: calendar),
                  totals.insertedCharacters >= 0, totals.acceptedCompletions >= 0,
                  totals.rewrittenCharacters >= 0, totals.acceptedRewrites >= 0 else {
                throw DecodingError.dataCorruptedError(forKey: .days, in: values,
                                                      debugDescription: "Invalid statistics day or negative counter")
            }
            do {
                lifetime = try lifetime.addingChecked(totals)
            } catch {
                throw DecodingError.dataCorruptedError(forKey: .days, in: values,
                                                      debugDescription: "Statistics lifetime counters overflow")
            }
        }
    }

    /// Call exactly once after a successful native insertion, never on display or rejection.
    /// Characters are Swift extended grapheme clusters, including inserted whitespace.
    /// Selection replacements are kept separate and never contribute to typing estimates.
    /// Overflow leaves both in-memory counters and the caller's persisted data unchanged.
    mutating func record(inserted: String, replacingSelection: Bool, at date: Date = Date()) throws {
        guard !inserted.isEmpty else { return }
        let key = dayKey(date, calendar: calendar)
        let increment = replacingSelection
            ? Snapshot(rewrittenCharacters: inserted.count, acceptedRewrites: 1)
            : Snapshot(insertedCharacters: inserted.count, acceptedCompletions: 1)
        let nextLifetime = try lifetime.addingChecked(increment)
        let nextDay = try days[key, default: Snapshot()].addingChecked(increment)
        days[key] = nextDay
        lifetime = nextLifetime
    }

    mutating func reset() {
        days.removeAll()
        lifetime = Snapshot()
    }

    /// Last 7 Days means today and the six preceding calendar days, not 168 hours.
    /// All Time includes every retained bucket, including dates ahead of a changed clock.
    func snapshot(period: Period, now: Date = Date()) -> Snapshot {
        if period == .allTime {
            return lifetime
        }
        let calendar = calendar
        let start = calendar.startOfDay(for: now)
        let count = period == .today ? 1 : 7
        var result = Snapshot()
        for offset in 0..<count {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: start),
                  let day = days[dayKey(date, calendar: calendar)] else { continue }
            result.add(day)
        }
        return result
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // Both constructors establish a valid time zone.
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar
    }

    private func isValidDayKey(_ key: String, calendar: Calendar) -> Bool {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4, let era = Int(parts[0]), (0...1).contains(era),
              let year = Int(parts[1]), year > 0,
              let yearRange = calendar.maximumRange(of: .year), yearRange.contains(year),
              let month = Int(parts[2]), (1...12).contains(month),
              let day = Int(parts[3]), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(era: era, year: year, month: month, day: day, hour: 12)) else {
            return false
        }
        // Roundtripping rejects impossible dates and noncanonical aliases of a bucket.
        return dayKey(date, calendar: calendar) == key
    }

    private func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return "\(parts.era!)-\(parts.year!)-\(parts.month!)-\(parts.day!)"
    }
}
