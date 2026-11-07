// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit
import Foundation

struct SearchResult: Identifiable {
    var id: String { url.path }
    let url: URL
    let directory: Bool
    let size: Int64
    let modified: Date?
    var name: String { url.lastPathComponent }
}

/// Read-only, session-local metadata index. Symbolic links are never followed.
final class FileSearchIndex {
    private let lock = NSLock()
    private var entries: [SearchResult] = []
    private var generation = 0
    private var cancelled = false
    private var active = false
    private var skipped = 0
    var status: (count: Int, skipped: Int, running: Bool, cancelled: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (entries.count, skipped, active, cancelled)
    }
    func stop() { lock.lock(); cancelled = true; lock.unlock() }
    private func current(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == token && !cancelled
    }
    func build(root: URL, hidden: Bool, completion: @escaping () -> Void) {
        lock.lock(); generation += 1; let token = generation
        cancelled = false; active = true; skipped = 0; entries = []; lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            let options: FileManager.DirectoryEnumerationOptions = hidden ? [] : [.skipsHiddenFiles]
            let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: options) { _, _ in
                self.lock.lock(); if self.generation == token { self.skipped += 1 }; self.lock.unlock()
                return self.current(token)
            }
            var batch: [SearchResult] = []
            func publish() {
                self.lock.lock(); if self.generation == token { self.entries.append(contentsOf: batch) }; self.lock.unlock()
                batch.removeAll(keepingCapacity: true)
            }
            while let url = en?.nextObject() as? URL {
                if !self.current(token) { break }
                autoreleasepool {
                    guard let v = try? url.resourceValues(forKeys: keys) else {
                        self.lock.lock(); if self.generation == token { self.skipped += 1 }; self.lock.unlock(); return
                    }
                    if v.isSymbolicLink == true { en?.skipDescendants(); return }
                    guard v.isDirectory == true || v.isRegularFile == true else { return }
                    batch.append(SearchResult(url: url, directory: v.isDirectory == true,
                                              size: v.isDirectory == true ? 0 : Int64(v.fileSize ?? 0), modified: v.contentModificationDate))
                }
                if batch.count >= 512 { publish() }
            }
            publish()
            self.lock.lock(); let latest = self.generation == token
            if latest { self.active = false }; self.lock.unlock()
            if latest { DispatchQueue.main.async(execute: completion) }
        }
    }
    static func matches(_ entry: SearchResult, query: String, kind: String, minimum: Int64, since: Date?, fullPath: Bool) -> Bool {
        if (kind == "folders" && !entry.directory) || (kind == "files" && entry.directory) { return false }
        if minimum > 0 && (entry.directory || entry.size < minimum) { return false }
        if let since, (entry.modified ?? .distantPast) < since { return false }
        let text = fullPath ? entry.url.path : entry.name
        return prepared(query).allSatisfy { term in
            if let regex = term.regex { return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
            return text.range(of: term.text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
    private static func prepared(_ query: String) -> [(text: String, regex: NSRegularExpression?)] {
        query.split(whereSeparator: { $0.isWhitespace }).map { raw in
            let word = String(raw)
            let pattern = NSRegularExpression.escapedPattern(for: word).replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".")
            return (word, word.contains("*") || word.contains("?") ? try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) : nil)
        }
    }

    func search(query: String, kind: String, minimum: Int64, since: Date?, fullPath: Bool, sort: String) -> (items: [SearchResult], total: Int) {
        lock.lock(); defer { lock.unlock() }
        let terms = Self.prepared(query)
        func accepts(_ entry: SearchResult) -> Bool {
            if (kind == "folders" && !entry.directory) || (kind == "files" && entry.directory) { return false }
            if minimum > 0 && (entry.directory || entry.size < minimum) { return false }
            if let since, (entry.modified ?? .distantPast) < since { return false }
            let text = fullPath ? entry.url.path : entry.name
            return terms.allSatisfy { term in
                if let regex = term.regex { return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
                return text.range(of: term.text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        func earlier(_ lhs: SearchResult, _ rhs: SearchResult) -> Bool {
            if sort == "size" && lhs.size != rhs.size { return lhs.size > rhs.size }
            if sort == "date" && lhs.modified != rhs.modified { return (lhs.modified ?? .distantPast) > (rhs.modified ?? .distantPast) }
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return order == .orderedSame ? lhs.url.path < rhs.url.path : order == .orderedAscending
        }
        // Keep only the best 500 rows in a max heap, rather than sorting the entire index.
        var heap: [SearchResult] = []; var total = 0
        for entry in entries where accepts(entry) {
            total += 1
            if heap.count < 500 {
                heap.append(entry); var i = heap.count - 1
                while i > 0 {
                    let parent = (i - 1) / 2
                    if !earlier(heap[parent], heap[i]) { break }
                    heap.swapAt(parent, i); i = parent
                }
            } else if earlier(entry, heap[0]) {
                heap[0] = entry; var i = 0
                while 2 * i + 1 < heap.count {
                    var child = 2 * i + 1
                    if child + 1 < heap.count && earlier(heap[child], heap[child + 1]) { child += 1 }
                    if !earlier(heap[i], heap[child]) { break }
                    heap.swapAt(i, child); i = child
                }
            }
        }
        return (heap.sorted(by: earlier), total)
    }
}
