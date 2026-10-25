import AppKit
import ApplicationServices

func snapshot(before: String, after: String = "", selection: String = "", location: Int? = nil,
              elementPID: pid_t = 123, x: CGFloat = 10) -> TextSnapshot {
    TextSnapshot(element: AXUIElementCreateApplication(elementPID), pid: 123, appID: "fixture",
                 appName: "Fixture", siteDomains: [], siteDomain: nil, isWebContent: false,
                 before: before, after: after, selected: selection,
                 range: CFRange(location: location ?? before.utf16.count, length: selection.utf16.count),
                 caret: CGRect(x: x, y: 20, width: 0, height: 18))
}
func require(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
}
let now = Date(timeIntervalSince1970: 1_000)
let source = snapshot(before: "Hello")
require(!source.matchesContent(snapshot(before: "Hello", elementPID: 124)), "Different fields must not share suggestion identity")
require(source.matchesContent(snapshot(before: "Hello", x: 200)), "Geometry is separate from content identity")
let receipt = InsertionReceipt(source: source, text: " world", expiresAt: now.addingTimeInterval(2))
require(receipt.matches(snapshot(before: "Hello world"), now: now), "Confirmed continuation counts")
require(!receipt.matches(source, now: now), "AX success without changed text must not count")
require(!receipt.matches(snapshot(before: "Hello worl"), now: now), "Partial event delivery must not count")
require(!receipt.matches(snapshot(before: "Hello world", elementPID: 124), now: now), "Another field cannot confirm an insertion")
require(!receipt.matches(snapshot(before: "Hello world", after: "changed"), now: now), "Changed suffix rejects confirmation")
require(!receipt.matches(snapshot(before: "Hello world"), now: now.addingTimeInterval(3)), "Expired receipts cannot count later edits")
let replacement = InsertionReceipt(source: snapshot(before: "A ", after: ".", selection: "bad"),
                                   text: "better", expiresAt: now.addingTimeInterval(2))
require(replacement.matches(snapshot(before: "A better", after: "."), now: now), "Replacement confirms selected-text removal")
let unicode = InsertionReceipt(source: source, text: " 👩🏽‍💻", expiresAt: now.addingTimeInterval(2))
require(unicode.matches(snapshot(before: "Hello 👩🏽‍💻"), now: now), "Caret verification uses UTF-16 without splitting Unicode")
let longBefore = String(repeating: "a", count: 1200)
let long = InsertionReceipt(source: snapshot(before: longBefore, location: 3000), text: " end", expiresAt: now.addingTimeInterval(2))
require(long.matches(snapshot(before: String((longBefore + " end").suffix(1200)), location: 3004), now: now), "Bounded context can confirm insertion in a long document")
print("Accessibility identity and insertion confirmation checks passed")
