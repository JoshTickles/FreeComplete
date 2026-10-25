import Foundation

func instant(_ value: String) -> Date {
    guard let date = ISO8601DateFormatter().date(from: value) else {
        fatalError("Invalid test instant: \(value)")
    }
    return date
}

let utc = TimeZone(secondsFromGMT: 0)!
let now = instant("2026-01-01T12:00:00Z")
var statistics = SavingsStatistics(timeZone: utc)
try statistics.record(inserted: "ing", replacingSelection: false, at: now)
try statistics.record(inserted: " ", replacingSelection: false, at: now)
try statistics.record(inserted: "é👨‍👩‍👧‍👦e\u{301}", replacingSelection: false, at: now)
try statistics.record(inserted: "replacement", replacingSelection: true, at: now)
try statistics.record(inserted: "", replacingSelection: false, at: now)
try statistics.record(inserted: "", replacingSelection: true, at: now)
let initial = statistics.snapshot(period: .today, now: now)
precondition(initial.insertedCharacters == 7 && initial.acceptedCompletions == 3,
             "Partial words, spaces, composed/decomposed Unicode and emoji count characters, not invented words or bytes")
precondition(initial.rewrittenCharacters == 11 && initial.acceptedRewrites == 1,
             "Selection replacements must be separate from completion savings")
precondition(abs(initial.estimatedSeconds(wordsPerMinute: 40) - 2.1) < 0.000001,
             "Typing estimate uses nominal five-character words and excludes rewrites")
precondition(abs(initial.estimatedSeconds(wordsPerMinute: 80) - 1.05) < 0.000001,
             "An adjusted typing speed updates the estimate without changing counts")
for speed in [0, -1, Double.nan, .infinity, -.infinity] {
    precondition(initial.estimatedSeconds(wordsPerMinute: speed) == 0,
                 "Invalid typing speed must never produce NaN or infinity")
}

// Today and last seven calendar days cross both month and year boundaries.
var boundaries = SavingsStatistics(timeZone: utc)
try boundaries.record(inserted: "a", replacingSelection: false, at: instant("2025-12-25T23:59:59Z"))
try boundaries.record(inserted: "bb", replacingSelection: false, at: instant("2025-12-26T00:00:00Z"))
try boundaries.record(inserted: "ccc", replacingSelection: false, at: instant("2025-12-31T23:59:59Z"))
try boundaries.record(inserted: "dddd", replacingSelection: false, at: instant("2026-01-01T00:00:00Z"))
try boundaries.record(inserted: "eeeee", replacingSelection: false, at: instant("2026-01-02T00:00:00Z"))
precondition(boundaries.snapshot(period: .today, now: now).insertedCharacters == 4,
             "A midnight insertion belongs to the new day, not the previous day")
precondition(boundaries.snapshot(period: .last7Days, now: now).insertedCharacters == 9,
             "The rolling week includes today plus six days, excluding the eighth and future day")
precondition(boundaries.snapshot(period: .allTime, now: now).insertedCharacters == 15,
             "Clock changes must not silently delete future buckets from lifetime history")
precondition(boundaries.snapshot(period: .today, now: instant("2026-01-02T00:00:00Z")).insertedCharacters == 5,
             "Snapshots roll over without requiring another insertion")
precondition(boundaries.snapshot(period: .allTime, now: instant("2036-01-01T00:00:00Z")).insertedCharacters == 15,
             "Old buckets must remain retained indefinitely")

// New York has 23-hour and 25-hour days: calendar arithmetic must not use 86,400-second offsets.
let newYork = TimeZone(identifier: "America/New_York")!
var spring = SavingsStatistics(timeZone: newYork)
try spring.record(inserted: "a", replacingSelection: false, at: instant("2026-03-07T04:59:59Z")) // March 6
try spring.record(inserted: "bb", replacingSelection: false, at: instant("2026-03-07T05:00:00Z")) // March 7
try spring.record(inserted: "ccc", replacingSelection: false, at: instant("2026-03-13T03:59:59Z")) // March 12
try spring.record(inserted: "dddd", replacingSelection: false, at: instant("2026-03-13T04:00:00Z")) // March 13
let springNow = instant("2026-03-13T12:00:00Z")
precondition(spring.snapshot(period: .last7Days, now: springNow).insertedCharacters == 9,
             "Spring daylight-saving week includes March 7 through March 13")
precondition(spring.snapshot(period: .today, now: springNow).insertedCharacters == 4,
             "Day boundaries follow the saved time zone, not UTC")
var autumn = SavingsStatistics(timeZone: newYork)
try autumn.record(inserted: "a", replacingSelection: false, at: instant("2026-11-01T05:30:00Z"))
try autumn.record(inserted: "b", replacingSelection: false, at: instant("2026-11-01T06:30:00Z"))
try autumn.record(inserted: "ccc", replacingSelection: false, at: instant("2026-11-02T04:59:59Z"))
try autumn.record(inserted: "dddd", replacingSelection: false, at: instant("2026-11-02T05:00:00Z"))
precondition(autumn.snapshot(period: .today, now: instant("2026-11-01T18:00:00Z")).insertedCharacters == 5,
             "Both repeated local hours and the late hour belong to the same 25-hour day")

// Leap days and empty windows are part of ordinary calendar behavior.
var leap = SavingsStatistics(timeZone: utc)
try leap.record(inserted: "leap", replacingSelection: false, at: instant("2028-02-29T23:59:59Z"))
precondition(leap.snapshot(period: .last7Days, now: instant("2028-03-06T12:00:00Z")).insertedCharacters == 4)
precondition(leap.snapshot(period: .last7Days, now: instant("2028-03-07T12:00:00Z")).insertedCharacters == 0)

let encoded = try JSONEncoder().encode(statistics)
let payload = String(decoding: encoded, as: UTF8.self)
precondition(!payload.contains("replacement") && !payload.contains("👨‍👩‍👧‍👦"),
             "Persistence contains aggregate counts, never accepted content")
let restored = try JSONDecoder().decode(SavingsStatistics.self, from: encoded)
precondition(restored == statistics && restored.snapshot(period: .today, now: now) == initial,
             "Codable roundtrip preserves all aggregates")
let restoredSpring = try JSONDecoder().decode(SavingsStatistics.self, from: JSONEncoder().encode(spring))
precondition(restoredSpring.timeZoneIdentifier == newYork.identifier &&
             restoredSpring.snapshot(period: .last7Days, now: springNow) == spring.snapshot(period: .last7Days, now: springNow),
             "Persistence preserves the original day-boundary time zone")

let originalDefaultZone = NSTimeZone.default
NSTimeZone.default = TimeZone(identifier: "Pacific/Auckland")!
let afterTravel = restoredSpring.snapshot(period: .last7Days, now: springNow)
NSTimeZone.default = originalDefaultZone
precondition(afterTravel == spring.snapshot(period: .last7Days, now: springNow),
             "Changing the system time zone never reassigns saved event days")

var rewritesOnly = SavingsStatistics(timeZone: utc)
try rewritesOnly.record(inserted: "better phrasing", replacingSelection: true, at: now)
let replacementTotals = rewritesOnly.snapshot(period: .allTime, now: now)
precondition(replacementTotals.acceptedRewrites == 1 && replacementTotals.rewrittenCharacters == 15 &&
             replacementTotals.acceptedCompletions == 0 && replacementTotals.insertedCharacters == 0 &&
             replacementTotals.estimatedSeconds(wordsPerMinute: 40) == 0,
             "A rewrite alone cannot claim any saved typing")

// Aggregate model is value-semantic: reading/copying does not mutate the original.
var copy = restored
try copy.record(inserted: "ing", replacingSelection: false, at: now)
precondition(copy.snapshot(period: .today, now: now).acceptedCompletions == 4 &&
             restored.snapshot(period: .today, now: now).acceptedCompletions == 3,
             "Distinct successful accepts count separately; snapshots and copies do not double-count")
copy.reset()
let resetRestored = try JSONDecoder().decode(SavingsStatistics.self, from: JSONEncoder().encode(copy))
for period in SavingsStatistics.Period.allCases {
    let empty = resetRestored.snapshot(period: period, now: now)
    precondition(empty.insertedCharacters == 0 && empty.acceptedCompletions == 0 &&
                 empty.rewrittenCharacters == 0 && empty.acceptedRewrites == 0 &&
                 empty.estimatedSeconds(wordsPerMinute: 40) == 0,
                 "Explicit reset clears every counter and survives relaunch")
}
precondition(resetRestored.timeZoneIdentifier == statistics.timeZoneIdentifier,
             "Reset clears counts, not the calendar convention")

func savedData(_ days: [String: [String: Int]], zone: String = "GMT") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["timeZoneIdentifier": zone, "days": days], options: [.sortedKeys])
}

func rejectsSavedData(_ data: Data, _ reason: String) {
    do {
        _ = try JSONDecoder().decode(SavingsStatistics.self, from: data)
        fatalError("Corrupted statistics were accepted: \(reason)")
    } catch is DecodingError {
        // The owner can preserve the original blob and surface its existing recovery UI.
    } catch {
        fatalError("Unexpected decoding error for \(reason): \(error)")
    }
}

let zeroCounters = ["insertedCharacters": 0, "acceptedCompletions": 0,
                    "rewrittenCharacters": 0, "acceptedRewrites": 0]
for field in zeroCounters.keys {
    var negative = zeroCounters
    negative[field] = -1
    rejectsSavedData(try savedData(["1-2026-1-1": negative]), "negative \(field)")

    var maximum = zeroCounters
    maximum[field] = Int.max
    var one = zeroCounters
    one[field] = 1
    rejectsSavedData(try savedData(["1-2026-1-1": maximum, "1-2026-1-2": one]),
                     "cross-day \(field) overflow")

    // A representable maximum is legitimate data and must remain lossless.
    let maximumData = try savedData(["1-2026-1-1": maximum])
    var full = try JSONDecoder().decode(SavingsStatistics.self, from: maximumData)
    let beforeOverflow = full
    let fullRoundtrip = try JSONDecoder().decode(SavingsStatistics.self, from: JSONEncoder().encode(full))
    precondition(fullRoundtrip == beforeOverflow, "Maximum representable counters survive persistence")
    let replacement = field == "rewrittenCharacters" || field == "acceptedRewrites"
    for date in [now, instant("2026-01-02T12:00:00Z")] {
        do {
            try full.record(inserted: "a", replacingSelection: replacement, at: date)
            fatalError("Recording should reject \(field) overflow")
        } catch SavingsStatistics.StatisticsError.counterOverflow {
            precondition(full == beforeOverflow,
                         "Same-day and cross-day overflow must leave every counter unchanged")
        }
    }
    try full.record(inserted: "", replacingSelection: replacement, at: now)
    precondition(full == beforeOverflow, "Empty insertions do not overflow or mutate full counters")
    full.reset()
    try full.record(inserted: "a", replacingSelection: false, at: now)
    precondition(full.snapshot(period: .allTime, now: now).insertedCharacters == 1,
                 "Explicit reset makes an overflowed store usable again")
}
rejectsSavedData(try savedData([:], zone: "not-a-time-zone"), "invalid saved time zone")
for key in ["", "2026-1-1", "1-2026-0-1", "1-2026-13-1", "1-2026-1-0",
            "1-2026-1-32", "1-2026-2-29", "1-2026-2-30", "1-0-1-1",
            "2-2026-1-1", "1-02026-1-1", "1-2026-01-1", "1-2026-1-1-extra",
            "1-\(Int.max)-1-1"] {
    rejectsSavedData(try savedData([key: zeroCounters]), "invalid or aliased day key \(key)")
}
rejectsSavedData(Data("{\"timeZoneIdentifier\":\"GMT\",\"days\":".utf8), "truncated JSON")
rejectsSavedData(Data("{\"timeZoneIdentifier\":\"GMT\",\"days\":{\"1-2026-1-1\":{}}}".utf8),
                 "missing counter fields")
let validLeapData = try savedData(["1-2028-2-29": zeroCounters])
_ = try JSONDecoder().decode(SavingsStatistics.self, from: validLeapData)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let encodedValidated = try encoder.encode(restored)
precondition(!String(decoding: encodedValidated, as: UTF8.self).contains("lifetime"),
             "The derived lifetime cache is not a competing persisted source of truth")

print("Savings statistics regressions passed")
