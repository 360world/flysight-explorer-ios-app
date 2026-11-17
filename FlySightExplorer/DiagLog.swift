//
//  DiagLog.swift — persistent diagnostic log
//
//  The BLE log used to live only in memory and never appeared anywhere in
//  the UI: on failure all that remained was a 3-second toast ("incomplete
//  file") that revealed nothing. This class also writes every significant
//  step to a file in the Documents folder, so that it:
//    - survives an app restart,
//    - is visible in the Files app (On My iPhone),
//    - can be shared / pasted for debugging.
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
    /// The log file, also visible in the Files app.
    var fileURL: URL { docs.appendingPathComponent("flysight-diagnostics.log") }

    private lazy var stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        // On startup we load the tail of the previous log so the error
        // can still be reviewed even if the app has restarted in the meantime.
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
            let all = existing.split(separator: "\n").map(String.init)
            lines = Array(all.suffix(maxLines))
            // Rotation: if the file has outgrown what we keep in memory,
            // rewrite it with just its tail so it doesn't grow without bound.
            if all.count > maxLines {
                try? lines.joined(separator: "\n")
                    .appending("\n")
                    .write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// One line to the log. `cat` is a short tag for the source (BLE, SAVE, PARSE…).
    func log(_ message: String, _ cat: String = "") {
        let prefix = cat.isEmpty ? "" : "[\(cat)] "
        // Flatten embedded line breaks, otherwise a single entry is split across
        // several lines in the log file and becomes unreadable.
        let flat = message.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ")
        let line = "\(stamp.string(from: Date()))  \(prefix)\(flat)"
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        append(line)
    }

    /// A multi-line block (e.g. the first lines of a file) with readable indentation.
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
