//
//  Logbook.swift
//  Persistent storage on the phone for files downloaded from the FlySight.
//
//  Where they go: the app's own Documents folder, in the tracks/ subfolder.
//  index.json holds the summaries so the list appears immediately
//  without having to re-parse every CSV.
//
//  iOS includes the Documents folder in iCloud/iTunes backups, so
//  downloaded jumps survive app updates and device migration —
//  BUT NOT deleting/reinstalling the app, because that completely wipes the
//  sandbox container. This is expected iOS behavior, not a bug.
//
//  RECOMMENDED: to make the folder visible in the Files app too (Browse >
//  On My iPhone > FlySight HUD), add these to the target's Info.plist:
//
//    Application supports iTunes file sharing = YES
//      (key: UIFileSharingEnabled)
//    Supports opening documents in place = YES
//      (key: LSSupportsOpeningDocumentsInPlace)
//
//  Without this the files are there and reliably kept, the user just
//  can't view them directly from the Files app.
//

import SwiftUI
import Combine

struct LogEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var fileName: String            // name of the stored file in the tracks/ folder
    var displayName: String         // what you see in the list
    var remotePath: String          // where it came from on the FlySight
    var downloadedAt: Date
    var recordedAt: Date?
    var byteCount: Int

    // Summary, so the list is informative without re-parsing
    var exitAltitude: Double?
    var deployAltitude: Double?
    var freefallSeconds: Double?
    var maxVerticalKmh: Double?
    var avgGlide: Double?
    var jumpKind: String?           // "Wingsuit", "Tracking", "Hasas"

    var subtitle: String { subtitle("hu") }

    /// The jump type used to be shown with the stored (Hungarian) text even in
    /// English. The stored value can stay as is; we translate it here for display.
    func subtitle(_ lang: String) -> String {
        var parts: [String] = []
        if let e = exitAltitude { parts.append("\(Int(e)) m") }
        if let f = freefallSeconds { parts.append(String(format: "%.0f s", f)) }
        if let g = avgGlide { parts.append(String(format: "GR %.2f", g)) }
        if let k = jumpKind { parts.append(LogEntry.kindName(k, lang)) }
        return parts.joined(separator: " · ")
    }

    static func kindName(_ raw: String, _ lang: String) -> String {
        switch raw {
        case "Hasas", "Belly": return lang == "en" ? "Belly" : "Hasas"
        default:               return raw          // Wingsuit / Tracking
        }
    }
}

@MainActor
final class Logbook: ObservableObject {

    @Published private(set) var entries: [LogEntry] = []

    private let fm = FileManager.default

    private var docs: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var dir: URL { docs.appendingPathComponent("tracks", isDirectory: true) }
    private var indexURL: URL { dir.appendingPathComponent("index.json") }

    init() {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        loadIndex()
    }

    // MARK: index

    private func loadIndex() {
        // saveIndex writes with the `.iso8601` date strategy, so it must be READ that way too.
        // This used to be a plain `JSONDecoder()` (default: .deferredToDate,
        // which expects a number), so decoding ALWAYS failed, `entries` was emptied,
        // and the logbook "disappeared" on every app launch — even though the CSV
        // files were on disk the whole time.
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601

        if let d = try? Data(contentsOf: indexURL),
           let list = try? dec.decode([LogEntry].self, from: d) {
            entries = list.sorted { $0.downloadedAt > $1.downloadedAt }
            reattachOrphanFiles()
            return
        }

        // Missing (or corrupt) index: rebuild it from the files on disk,
        // so previously "lost" downloads get back into the logbook.
        entries = []
        reattachOrphanFiles()
        if !entries.isEmpty { saveIndex() }
    }

    /// Adds CSV files in the tracks folder that are missing from the index back
    /// to the logbook. This way a corrupt index doesn't mean data loss.
    private func reattachOrphanFiles() {
        guard let files = try? fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: [.creationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return }
        let known = Set(entries.map(\.fileName))
        var added = false
        for url in files where url.lastPathComponent != indexURL.lastPathComponent {
            let name = url.lastPathComponent
            guard !known.contains(name) else { continue }
            let attrs = try? url.resourceValues(forKeys: [.creationDateKey])
            let created = attrs?.creationDate ?? Date()
            let size = (try? Data(contentsOf: url).count) ?? 0
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let track = Track.parse(text, name: name)
            var e = LogEntry(fileName: name,
                             displayName: displayName(for: name, track: track),
                             remotePath: name,
                             downloadedAt: created,
                             recordedAt: track?.recordedAt,
                             byteCount: size)
            if let track {
                if let ex = track.exitIdx { e.exitAltitude = track.agl(ex) }
                if let dp = track.deployIdx { e.deployAltitude = track.agl(dp) }
            }
            entries.append(e)
            added = true
        }
        if added { entries.sort { $0.downloadedAt > $1.downloadedAt } }
    }

    private func saveIndex() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = .prettyPrinted
        if let d = try? enc.encode(entries) { try? d.write(to: indexURL) }
    }

    // MARK: saving and loading

    func fileURL(_ e: LogEntry) -> URL { dir.appendingPathComponent(e.fileName) }

    /// Have we already downloaded this file from the device? The device path is
    /// the identifier, because it is unique to a given recording.
    func entry(remotePath: String) -> LogEntry? {
        entries.first { $0.remotePath == remotePath }
    }
    func isDownloaded(remotePath: String) -> Bool {
        entry(remotePath: remotePath) != nil
    }

    /// Saves a downloaded file. Name collisions are resolved with a timestamp.
    ///
    /// The downloaded raw CSV is ALWAYS written to disk, regardless of whether
    /// parsing (Track.parse) succeeds. A download/save failure is practically
    /// always caused at the I/O or Bluetooth level, not by the content being
    /// "too short" — whether there is enough data to draw the track is best
    /// decided only at display time (Logbook.load). If we rejected the save
    /// here, the user would lose the file even if it was actually valid,
    /// just a short recording.
    @discardableResult
    func save(text: String, remotePath: String, suggestedName: String) -> LogEntry? {
        DiagLog.shared.log("Save started: \(remotePath) — \(text.utf8.count) bytes", "SAVE")
        DiagLog.shared.logBlock("File head:", Track.head(text), "SAVE")
        let track = Track.parse(text, name: suggestedName)
        DiagLog.shared.log(track == nil
            ? "Parse FAILED — \(Track.diagnose(text))"
            : "Parse OK — \(track!.samples.count) samples", "SAVE")

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd_HHmmss"
        let safe = sanitize(remotePath)
        let fileName = "\(stamp.string(from: Date()))_\(safe)"
        let url = dir.appendingPathComponent(fileName)

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            DiagLog.shared.log("Written to disk: \(fileName)", "SAVE")
        } catch {
            DiagLog.shared.log("DISK WRITE ERROR: \(error.localizedDescription)", "SAVE")
            return nil
        }

        var e = LogEntry(fileName: fileName,
                         displayName: displayName(for: remotePath, track: track),
                         remotePath: remotePath,
                         downloadedAt: Date(),
                         recordedAt: track?.recordedAt,
                         byteCount: text.utf8.count)

        if let track {
            if let ex = track.exitIdx { e.exitAltitude = track.agl(ex) }
            if let dp = track.deployIdx { e.deployAltitude = track.agl(dp) }
            if let ex = track.exitIdx, let dp = track.deployIdx {
                e.freefallSeconds = track.samples[dp].t - track.samples[ex].t
                let st = track.stats(ex...dp)
                e.maxVerticalKmh = st.vMax
                e.avgGlide = st.grAvg
                e.jumpKind = classify(st)
            }
        }

        // If this recording was already downloaded, we do NOT create a second
        // entry: we replace the old one. Previously the same file could end up
        // in the logbook several times and showed up selected twice in the list.
        if let old = entry(remotePath: remotePath) {
            DiagLog.shared.log("Already downloaded — replacing entry: "
                               + "\(old.fileName) → \(fileName)", "SAVE")
            try? fm.removeItem(at: fileURL(old))
            e.displayName = old.displayName      // keep the rename
            entries.removeAll { $0.id == old.id }
        }

        entries.insert(e, at: 0)
        saveIndex()
        return e
    }

    /// Only filesystem-safe characters remain — slash, space, colon and other
    /// special characters become underscores.
    /// More robust than replacing two specific characters, because it works
    /// for FlySight folders with any exotic name.
    private func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    func load(_ e: LogEntry) -> Track? {
        guard let text = try? String(contentsOf: fileURL(e), encoding: .utf8) else {
            DiagLog.shared.log("Read: file not readable from disk — "
                               + "\(e.fileName)", "READ")
            return nil
        }
        guard let t = Track.parse(text, name: e.displayName) else {
            DiagLog.shared.log("Read FAILED: \(e.fileName) — "
                               + Track.diagnose(text), "READ")
            DiagLog.shared.logBlock("File head:", Track.head(text), "READ")
            return nil
        }
        DiagLog.shared.log("Read OK: \(e.fileName) — \(t.samples.count) samples", "READ")
        return t
    }

    func rawText(_ e: LogEntry) -> String? {
        try? String(contentsOf: fileURL(e), encoding: .utf8)
    }

    /// The folder where the user can also copy CSVs in from outside. In the
    /// Files app: On My iPhone → FlySight Explorer → tracks.
    var tracksFolder: URL { dir }

    /// Rescans the folder: adds CSVs copied in from outside to the logbook.
    /// It also picks them up from the Documents root (easier to copy there)
    /// and moves them into the tracks folder.
    @discardableResult
    func rescan() -> Int {
        let before = entries.count
        adoptLooseFilesFromDocuments()
        reattachOrphanFiles()
        if entries.count != before { saveIndex() }
        DiagLog.shared.log("Folder rescanned: \(entries.count - before) new file(s)", "SCAN")
        return entries.count - before
    }

    /// Moves .csv files found in the Documents root into the tracks folder.
    private func adoptLooseFilesFromDocuments() {
        guard let files = try? fm.contentsOfDirectory(at: docs,
                                                     includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return }
        for url in files where url.pathExtension.lowercased() == "csv" {
            let target = uniqueURL(for: url.lastPathComponent)
            do {
                try fm.moveItem(at: url, to: target)
                DiagLog.shared.log("Adopted dropped file: \(url.lastPathComponent)", "SCAN")
            } catch {
                DiagLog.shared.log("Could not adopt: \(url.lastPathComponent) — "
                                   + error.localizedDescription, "SCAN")
            }
        }
    }

    /// Imports a file from the Files app (from anywhere, even iCloud).
    @discardableResult
    func importFile(at src: URL) -> LogEntry? {
        // The picker grants a security scope — it must be opened for reading.
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        guard let text = try? String(contentsOf: src, encoding: .utf8) else {
            DiagLog.shared.log("Import: not readable — \(src.lastPathComponent)", "IMPORT")
            return nil
        }
        DiagLog.shared.log("Import: \(src.lastPathComponent) — \(text.utf8.count) bytes", "IMPORT")
        // The imported file's "remote path" is its own file name, so duplicate
        // detection works the same way as for files downloaded from the device.
        return save(text: text, remotePath: "import/" + src.lastPathComponent,
                    suggestedName: src.lastPathComponent)
    }

    private func uniqueURL(for name: String) -> URL {
        var candidate = dir.appendingPathComponent(name)
        var i = 2
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)_\(i).\(ext)")
            i += 1
        }
        return candidate
    }

    /// Why couldn't it be read? This goes into the error message so we don't
    /// just see "failed".
    func diagnose(_ e: LogEntry) -> String {
        guard let text = rawText(e) else { return "file not readable from disk" }
        return Track.diagnose(text)
    }

    func delete(_ e: LogEntry) {
        try? fm.removeItem(at: fileURL(e))
        entries.removeAll { $0.id == e.id }
        saveIndex()
    }

    func rename(_ e: LogEntry, to name: String) {
        guard let i = entries.firstIndex(where: { $0.id == e.id }) else { return }
        entries[i].displayName = name
        saveIndex()
    }

    /// The older version (50-sample threshold) sometimes created phantom entries
    /// that could never be opened. This removes them.
    @discardableResult
    func removeUnreadable() -> Int {
        let bad = entries.filter { load($0) == nil }
        for e in bad { delete(e) }
        return bad.count
    }

    var totalBytes: Int { entries.reduce(0) { $0 + $1.byteCount } }

    // MARK: helpers

    /// The FlySight path has the form 26-08-09/10-10-59/TRACK.CSV — a readable
    /// date and time is built from it.
    private func displayName(for remotePath: String, track: Track?) -> String {
        let parts = remotePath.split(separator: "/").map(String.init)
        if parts.count >= 3 {
            let day = parts[parts.count - 3]      // 26-08-09
            let time = parts[parts.count - 2]     // 10-10-59
            let d = day.split(separator: "-")
            let t = time.split(separator: "-")
            if d.count == 3 && t.count >= 2 {
                return "20\(d[0]). \(d[1]). \(d[2]). \(t[0]):\(t[1])"
            }
        }
        if let r = track?.recordedAt {
            return r.formatted(date: .abbreviated, time: .shortened)
        }
        return remotePath
    }

    private func classify(_ st: Track.Stats) -> String {
        guard let gr = st.grAvg else { return "Hasas" }
        if gr > 1.2 && st.duration > 50 { return "Wingsuit" }
        if gr > 0.6 { return "Tracking" }
        return "Hasas"
    }
}
