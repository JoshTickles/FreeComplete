import AppKit
import ApplicationServices

let identity = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
let otherIdentity = AXUIElementCreateSystemWide()
let key = ScreenContextKey(pid: 42, window: identity, title: "Conversation A", column: 100...400)
let capturedAt = Date(timeIntervalSince1970: 1_000)
let cache = ScreenTranscriptCache(key: key, date: capturedAt, text: "Reference text")
precondition(cache.isFresh(for: key, now: capturedAt), "A newly captured matching transcript is usable")
precondition(cache.isFresh(for: key, now: capturedAt.addingTimeInterval(2.999)),
             "A matching transcript remains usable strictly within its freshness interval")
for age in [-1.0, 3.0, 10.0, 29.0, 30.0] {
    precondition(!cache.isFresh(for: key, now: capturedAt.addingTimeInterval(age)),
                 "A stale or future-dated transcript must never be reused while refreshing")
}
let changedKeys = [
    ScreenContextKey(pid: 42, window: identity, title: "Conversation B", column: 100...400),
    ScreenContextKey(pid: 42, window: otherIdentity, title: "Conversation A", column: 100...400),
    ScreenContextKey(pid: 43, window: identity, title: "Conversation A", column: 100...400),
    ScreenContextKey(pid: 42, window: identity, title: "Conversation A", column: 200...500)
]
for changed in changedKeys {
    precondition(!cache.isFresh(for: changed, now: capturedAt.addingTimeInterval(1)),
                 "Window identity, title, process or column changes invalidate even a fresh transcript")
}
print("Screen context cache behavior checks passed")
