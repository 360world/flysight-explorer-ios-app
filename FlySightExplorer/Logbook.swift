//
//  Logbook.swift
//  A FlySightról letöltött fájlok tartós tárolása a telefonon.
//
//  Hova kerül: az app saját Documents mappájába, tracks/ alkönyvtárba.
//  Az index.json tartalmazza az összefoglalókat, hogy a lista azonnal
//  megjelenjen anélkül, hogy minden CSV-t újra kellene parsolni.
//
//  Az iOS a Documents mappát az iCloud/iTunes mentésbe is beleveszi, tehát
//  a letöltött ugrások túlélik az app frissítését és az eszközcserét —
//  DE NEM az app törlését/újratelepítését, mert az teljesen kiüríti a
//  sandbox konténert. Ez elvárt iOS-viselkedés, nem hiba.
//
//  AJÁNLOTT: hogy a mappa a Fájlok appban is látható legyen (Böngészés >
//  Ezen az iPhone-on > FlySight HUD), a target Info.plist-jébe vedd fel:
//
//    Application supports iTunes file sharing = YES
//      (kulcs: UIFileSharingEnabled)
//    Supports opening documents in place = YES
//      (kulcs: LSSupportsOpeningDocumentsInPlace)
//
//  Enélkül a fájlok megvannak és megbízhatóan megmaradnak, csak a
//  felhasználó nem tudja őket a Fájlok appból közvetlenül megnézni.
//

import SwiftUI
import Combine

struct LogEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var fileName: String            // a tárolt fájl neve a tracks/ mappában
    var displayName: String         // amit a listában látsz
    var remotePath: String          // honnan jött a FlySightról
    var downloadedAt: Date
    var recordedAt: Date?
    var byteCount: Int

    // Összefoglaló, hogy a lista informatív legyen újraparsolás nélkül
    var exitAltitude: Double?
    var deployAltitude: Double?
    var freefallSeconds: Double?
    var maxVerticalKmh: Double?
    var avgGlide: Double?
    var jumpKind: String?           // "Wingsuit", "Tracking", "Hasas"

    var subtitle: String { subtitle("hu") }

    /// Az ugrás típusa eddig a mentett (magyar) szöveggel jelent meg angol
    /// nyelven is. A tárolt érték maradhat a régi, itt fordítjuk megjelenítéskor.
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
        // A saveIndex `.iso8601` dátumformátummal ír, ezért OLVASNI is úgy kell.
        // Korábban itt sima `JSONDecoder()` állt (alapértelmezés: .deferredToDate,
        // ami számot vár), így a dekódolás MINDIG elhasalt, az `entries` kiürült,
        // és a napló minden appindításkor "eltűnt" — pedig a CSV fájlok végig
        // ott voltak a lemezen.
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601

        if let d = try? Data(contentsOf: indexURL),
           let list = try? dec.decode([LogEntry].self, from: d) {
            entries = list.sorted { $0.downloadedAt > $1.downloadedAt }
            reattachOrphanFiles()
            return
        }

        // Nincs (vagy sérült) index: a lemezen lévő fájlokból építjük újra,
        // hogy a korábban "elveszett" letöltések visszakerüljenek a naplóba.
        entries = []
        reattachOrphanFiles()
        if !entries.isEmpty { saveIndex() }
    }

    /// A tracks mappában lévő, indexben nem szereplő CSV fájlokat visszaveszi
    /// a naplóba. Így egy sérült index nem jelent adatvesztést.
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

    // MARK: mentés és betöltés

    func fileURL(_ e: LogEntry) -> URL { dir.appendingPathComponent(e.fileName) }

    /// Már letöltöttük ezt az eszközön lévő fájlt? A készülék útvonala az
    /// azonosító, mert az egy adott felvételre egyedi.
    func entry(remotePath: String) -> LogEntry? {
        entries.first { $0.remotePath == remotePath }
    }
    func isDownloaded(remotePath: String) -> Bool {
        entry(remotePath: remotePath) != nil
    }

    /// Letöltött fájl elmentése. A név ütközését időbélyeggel oldjuk fel.
    ///
    /// A letöltött nyers CSV-t MINDIG lemezre írjuk, függetlenül attól, hogy
    /// az elemzés (Track.parse) sikeres-e. Egy letöltési/mentési hiba oka
    /// gyakorlatilag mindig I/O vagy Bluetooth-szintű, nem a tartalom
    /// "rövidsége" — azt csak a megjelenítésnél (Logbook.load) érdemes
    /// eldönteni, hogy elég adat van-e a track megrajzolásához. Ha itt
    /// visszautasítanánk a mentést, a felhasználó elveszítené a fájlt
    /// akkor is, ha az valójában érvényes, csak rövid felvétel volt.
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

        // Ha ezt a felvételt már letöltöttük, NEM hozunk létre második
        // bejegyzést: lecseréljük a régit. Eddig ugyanaz a fájl többször is
        // bekerült a naplóba, és a listában duplán jelent meg kijelölve.
        if let old = entry(remotePath: remotePath) {
            DiagLog.shared.log("Already downloaded — replacing entry: "
                               + "\(old.fileName) → \(fileName)", "SAVE")
            try? fm.removeItem(at: fileURL(old))
            e.displayName = old.displayName      // megtartjuk az átnevezést
            entries.removeAll { $0.id == old.id }
        }

        entries.insert(e, at: 0)
        saveIndex()
        return e
    }

    /// Csak a fájlrendszer számára biztonságos karakterek maradnak — perjel,
    /// szóköz, kettőspont és egyéb speciális karakter aláhúzásra vált.
    /// Robusztusabb, mint két konkrét karakter lecserélése, mert bármilyen
    /// egzotikus elnevezésű FlySight mappára is működik.
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

    /// A mappa, ahová a felhasználó kívülről is bemásolhat CSV-t. Ez a
    /// Fájlok appban: Saját iPhone → FlySight Explorer → tracks.
    var tracksFolder: URL { dir }

    /// Újraolvassa a mappát: a kívülről bemásolt CSV-ket felveszi a naplóba.
    /// A Documents gyökeréből is beszedi őket (oda egyszerűbb bemásolni),
    /// és átmozgatja a tracks mappába.
    @discardableResult
    func rescan() -> Int {
        let before = entries.count
        adoptLooseFilesFromDocuments()
        reattachOrphanFiles()
        if entries.count != before { saveIndex() }
        DiagLog.shared.log("Folder rescanned: \(entries.count - before) new file(s)", "SCAN")
        return entries.count - before
    }

    /// A Documents gyökerében talált .csv fájlokat áthelyezi a tracks mappába.
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

    /// Fájl importálása a Fájlok appból (bárhonnan, akár iCloud-ból).
    @discardableResult
    func importFile(at src: URL) -> LogEntry? {
        // A picker biztonsági hatókört ad — meg kell nyitni az olvasáshoz.
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        guard let text = try? String(contentsOf: src, encoding: .utf8) else {
            DiagLog.shared.log("Import: not readable — \(src.lastPathComponent)", "IMPORT")
            return nil
        }
        DiagLog.shared.log("Import: \(src.lastPathComponent) — \(text.utf8.count) bytes", "IMPORT")
        // Az importált fájl "távoli útvonala" a saját fájlneve, így a
        // duplikátumszűrés ugyanúgy működik, mint az eszközről letöltötteknél.
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

    /// Miért nem sikerült beolvasni? Ez kerül a hibaüzenetbe, hogy ne csak
    /// annyit lássunk: "nem sikerült".
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

    /// A régebbi verzió (50 mintás küszöb) néha fantom bejegyzést hozott
    /// létre, amit soha nem lehetett megnyitni. Ez törli az ilyeneket.
    @discardableResult
    func removeUnreadable() -> Int {
        let bad = entries.filter { load($0) == nil }
        for e in bad { delete(e) }
        return bad.count
    }

    var totalBytes: Int { entries.reduce(0) { $0 + $1.byteCount } }

    // MARK: segédek

    /// A FlySight útvonala 26-08-09/10-10-59/TRACK.CSV alakú — ebből
    /// olvasható dátum és időpont készül.
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
