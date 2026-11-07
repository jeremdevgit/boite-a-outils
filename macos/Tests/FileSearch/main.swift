import Foundation
var passed = 0
func check(_ condition: Bool, _ message: String) { if !condition { fatalError(message) }; passed += 1 }
let root = FileManager.default.temporaryDirectory.appendingPathComponent("bao-search-\(UUID().uuidString)", isDirectory: true)
let fm = FileManager.default
try fm.createDirectory(at: root.appendingPathComponent("Reports"), withIntermediateDirectories: true)
try Data("demo".utf8).write(to: root.appendingPathComponent("Reports/Réunion.pdf"))
try Data("private".utf8).write(to: root.appendingPathComponent(".hidden"))
try fm.createSymbolicLink(at: root.appendingPathComponent("Reports/cycle"), withDestinationURL: root)
let index = FileSearchIndex(); var done = false
index.build(root: root, hidden: false) { done = true }
let deadline = Date().addingTimeInterval(10)
while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
check(done, "Index did not complete")
func find(_ q: String = "", _ kind: String = "", _ min: Int64 = 0, _ since: Date? = nil, _ path: Bool = false) -> [SearchResult] {
    index.search(query: q, kind: kind, minimum: min, since: since, fullPath: path, sort: "name").items
}
check(find("*.PDF").count == 1, "Unicode wildcard search")
check(find("reunion").count == 1, "Diacritics")
check(find("", "folders").count == 1, "Folder filter")
check(find("", "files").count == 1, "Hidden files and symlinks must be skipped")
check(find("", "", 5).isEmpty, "Minimum file size")
check(find("", "", 0, Date().addingTimeInterval(100)).isEmpty, "Modification date filter")
check(find("Reports Réunion", "", 0, nil, true).count == 1, "Full-path multiword search")
check(find("Reports Réunion").isEmpty, "Name search scope")
check(try Data(contentsOf: root.appendingPathComponent("Reports/Réunion.pdf")) == Data("demo".utf8), "Read-only behavior")
// A new generation must replace the previous scope, even if the old scan is still finishing.
let second = root.appendingPathComponent("Empty", isDirectory: true);try fm.createDirectory(at: second, withIntermediateDirectories: true)
done = false; index.build(root: root, hidden: true) {}; index.build(root: second, hidden: false) { done = true }
while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
check(done && find().isEmpty, "Rebuild generation isolation")
index.stop();check(index.status.cancelled, "Cancellation flag")
let bulk = root.appendingPathComponent("Bulk", isDirectory: true)
try fm.createDirectory(at: bulk, withIntermediateDirectories: true)
for n in 1...620 { try Data(repeating: 42, count: n).write(to: bulk.appendingPathComponent(String(format: "file%04d.dat", n))) }
done = false; index.build(root: bulk, hidden: false) { done = true }
let bulkDeadline = Date().addingTimeInterval(10)
while !done && Date() < bulkDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
let ranked = index.search(query: "*.dat", kind: "files", minimum: 0, since: nil, fullPath: false, sort: "size")
check(ranked.total == 620 && ranked.items.count == 500, "Bounded results preserve total count")
check(ranked.items.first?.size == 620 && ranked.items.last?.size == 121, "Top 500 heap ordering")
let byName = index.search(query: "*.dat", kind: "files", minimum: 0, since: nil, fullPath: false, sort: "name")
check(byName.items.first?.name == "file0001.dat" && byName.items.last?.name == "file0500.dat", "Name ordering")
try fm.removeItem(at: root)
print("PASS \(passed) native macOS search checks")
