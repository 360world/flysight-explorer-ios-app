//
//  DiagLog.swift — tartós diagnosztikai napló
//
//  A BLE napló eddig csak a memóriában élt, és sehol nem jelent meg a
//  felületen: hiba esetén csak egy 3 másodperces toast maradt ("hiányos
//  fájl"), ami semmit nem árult el. Ez az osztály minden lényeges lépést
//  fájlba is ír a Documents mappába, így:
//    - túléli az app újraindítását,
//    - látszik a Fájlok appban (On My iPhone),
//    - megosztható / bemásolható hibakereséshez.
//

import Foundation
import Combine      // ObservableObject, @Published

@MainActor
final class DiagLog: ObservableObject {

    static let shared = DiagLog()

    @Published private(set) var lines: [String] = []

    private let fm = FileManager.default
    private let maxLines = 4000

    private var docs: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    /// A Fájlok appban is látható naplófájl.
    var fileURL: URL { docs.appendingPathComponent("flysight-diagnostics.log") }

    private lazy var stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        // Induláskor betöltjük a korábbi napló végét, hogy a hiba
        // visszanézhető legyen akkor is, ha az app közben újraindult.
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
            let all = existing.split(separator: "\n").map(String.init)
            lines = Array(all.suffix(maxLines))
            // Forgatás: ha a fájl túlnőtte a memóriában tartott mennyiséget,
            // újraírjuk a végével, hogy ne hízzon korlátlanul.
            if all.count > maxLines {
                try? lines.joined(separator: "\n")
                    .appending("\n")
                    .write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Egy sor a naplóba. A `cat` a forrás rövid jelölése (BLE, SAVE, PARSE…).
    func log(_ message: String, _ cat: String = "") {
        let prefix = cat.isEmpty ? "" : "[\(cat)] "
        // A beágyazott sorvégeket kilapítjuk, különben egy bejegyzés több
        // sorra törik szét a naplófájlban, és nem lehet olvasni.
        let flat = message.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ")
        let line = "\(stamp.string(from: Date()))  \(prefix)\(flat)"
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        append(line)
    }

    /// Több soros blokk (pl. egy fájl első sorai) beolvasható tagolással.
    func logBlock(_ title: String, _ body: String, _ cat: String = "") {
        log(title, cat)
        for l in body.split(whereSeparator: \.isNewline).prefix(20) {
            log("    | \(l)", cat)
        }
    }

    private func append(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: fileURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    var text: String { lines.joined(separator: "\n") }

    func clear() {
        lines.removeAll()
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
        log("=== Log cleared ===", "APP")
    }
}
