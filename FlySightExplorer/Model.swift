//
//  Model.swift  —  FlySight HUD + Analyzer
//  Alap adatmodell: GNSS minta, fázisdetektálás, track, élő motor, HUD beállítások
//

import SwiftUI
import Combine
import CoreLocation

// MARK: - GNSS minta

struct LiveGNSS: Equatable {
    var lat = 0.0, lon = 0.0, altM = 0.0
    var vN = 0.0, vE = 0.0, vD = 0.0
    var hAccM = 0.0
    var numSV = 0
    var t: Double = 0

    var hSpeedKmh: Double { (vN * vN + vE * vE).squareRoot() * 3.6 }
    var vSpeedKmh: Double { vD * 3.6 }
    var totalSpeedKmh: Double {
        (vN * vN + vE * vE + vD * vD).squareRoot() * 3.6
    }
    var headingDeg: Double {
        let d = atan2(vE, vN) * 180 / .pi
        return d < 0 ? d + 360 : d
    }
    var glideRatio: Double? { vSpeedKmh > 3 ? hSpeedKmh / vSpeedKmh : nil }
    var diveAngleDeg: Double {
        let h = (vN * vN + vE * vE).squareRoot()
        guard h > 0.1 || abs(vD) > 0.1 else { return 0 }
        return atan2(vD, h) * 180 / .pi
    }
    var hasFix: Bool { lat != 0 && lon != 0 }
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

    /// BLE élő csomag: első bájt bitmaszk, a mezők kötött sorrendben követik
    static func parse(_ data: Data) -> LiveGNSS? {
        guard !data.isEmpty else { return nil }
        let mask = data[0]
        var off = 1
        func u32() -> UInt32? {
            guard data.count >= off + 4 else { return nil }
            let v = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: off, as: UInt32.self).littleEndian }
            off += 4; return v
        }
        func i32() -> Int32? {
            guard data.count >= off + 4 else { return nil }
            let v = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: off, as: Int32.self).littleEndian }
            off += 4; return v
        }
        var g = LiveGNSS()
        if mask & 0x80 != 0 { g.t = Double(u32() ?? 0) / 1000 }
        if mask & 0x40 != 0 { off += 2 }
        if mask & 0x20 != 0 {
            g.lon = Double(i32() ?? 0) * 1e-7
            g.lat = Double(i32() ?? 0) * 1e-7
            g.altM = Double(i32() ?? 0) / 1000
        }
        if mask & 0x10 != 0 {
            g.vN = Double(i32() ?? 0) / 1000
            g.vE = Double(i32() ?? 0) / 1000
            g.vD = Double(i32() ?? 0) / 1000
        }
        if mask & 0x08 != 0 {
            g.hAccM = Double(u32() ?? 0) / 1000; _ = u32(); _ = u32()
        }
        if mask & 0x04 != 0, data.count >= off + 1 { g.numSV = Int(data[off]) }
        return g
    }
}

// MARK: - Repülési fázis

enum FlightPhase: String {
    case ground, climb, jumpRun, freefall, deploying, canopy, landing

    var color: Color {
        switch self {
        case .freefall:  return .blue
        case .deploying: return .yellow
        case .canopy:    return .green
        case .landing:   return .orange
        case .climb:     return .purple
        default:         return .gray
        }
    }

    /// A rawValue stabil belső azonosító marad (pl. UI állapotgép,
    /// ForEach id); a felhasználó felé mutatott szöveg mindig ezen megy.
    func name(_ lang: String) -> String { loc("phase.\(rawValue)", lang) }
}

enum Segment: String, CaseIterable, Identifiable {
    case wholeJump, freefall, opening, canopy, landing, everything
    var id: String { rawValue }
    func name(_ lang: String) -> String { loc("segment.\(rawValue == "wholeJump" ? "whole" : rawValue)", lang) }
}

struct PhaseBand: Identifiable {
    let id = UUID()
    let phase: FlightPhase
    let t0: Double, t1: Double
}

// MARK: - Track

struct Track {
    var name: String
    var samples: [LiveGNSS]
    var groundElevation = 0.0
    var exitIdx: Int?
    var deployIdx: Int?
    var landIdx: Int?
    var recordedAt: Date?

    /// Kumulatív megtett útvonal méterben, mintánként. Egyszer számoljuk ki
    /// betöltéskor, mert a kurzor-kijelző minden mozdulatnál kérné — futásidőben
    /// újraszámolva több ezer CLLocation-hívás lenne képkockánként.
    var cumDistM: [Double] = []

    var count: Int { samples.count }
    func agl(_ i: Int) -> Double { samples[i].altM - groundElevation }

    /// Megtett útvonal két index között, méterben.
    func distanceM(from a: Int, to b: Int) -> Double {
        guard !cumDistM.isEmpty else { return 0 }
        let lo = min(max(a, 0), cumDistM.count - 1)
        let hi = min(max(b, 0), cumDistM.count - 1)
        return abs(cumDistM[hi] - cumDistM[lo])
    }

    mutating func buildCumulativeDistance() {
        var acc = 0.0
        var out = [Double](repeating: 0, count: samples.count)
        for i in 1..<max(1, samples.count) {
            let a = samples[i - 1], b = samples[i]
            if a.hasFix && b.hasFix {
                let d = CLLocation(latitude: a.lat, longitude: a.lon)
                    .distance(from: CLLocation(latitude: b.lat, longitude: b.lon))
                if d.isFinite { acc += d }
            }
            out[i] = acc
        }
        cumDistM = out
    }
    var t0: Double { samples.first?.t ?? 0 }
    var tEnd: Double { samples.last?.t ?? 0 }

    func index(atTime t: Double) -> Int {
        guard !samples.isEmpty else { return 0 }
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func presetRange(_ s: Segment) -> ClosedRange<Int> {
        let n = max(0, samples.count - 1)
        let ex = exitIdx ?? 0, dp = deployIdx ?? n, ld = landIdx ?? n
        let r = 5.0
        func c(_ a: Int, _ b: Int) -> ClosedRange<Int> {
            let lo = max(0, min(a, n)), hi = max(lo, min(b, n)); return lo...hi
        }
        switch s {
        case .wholeJump:  return c(ex, ld)
        case .freefall:   return c(ex, dp)
        case .opening:    return c(dp - Int(3 * r), dp + Int(12 * r))
        case .canopy:     return c(dp, ld)
        case .landing:    return c(ld - Int(25 * r), ld)
        case .everything: return c(0, n)
        }
    }

    var bands: [PhaseBand] {
        guard let ex = exitIdx, samples.count > 1 else { return [] }
        let n = samples.count - 1
        let dp = deployIdx ?? n, ld = landIdx ?? n
        var out: [PhaseBand] = []
        if ex > 0 { out.append(.init(phase: .climb, t0: samples[0].t, t1: samples[ex].t)) }
        out.append(.init(phase: .freefall, t0: samples[ex].t, t1: samples[dp].t))
        let opEnd = min(n, dp + 50)
        out.append(.init(phase: .deploying, t0: samples[dp].t, t1: samples[opEnd].t))
        if opEnd < ld { out.append(.init(phase: .canopy, t0: samples[opEnd].t, t1: samples[ld].t)) }
        if ld < n { out.append(.init(phase: .landing, t0: samples[ld].t, t1: samples[n].t)) }
        return out
    }

    func phase(atTime t: Double) -> FlightPhase {
        bands.first { t >= $0.t0 && t <= $0.t1 }?.phase ?? .ground
    }

    /// A nyomvonal fázisonként darabolva, hogy a térképen színezhető legyen
    func phaseSegments(_ r: ClosedRange<Int>) -> [(phase: FlightPhase,
                                                   coords: [CLLocationCoordinate2D])] {
        guard !samples.isEmpty else { return [] }
        var out: [(FlightPhase, [CLLocationCoordinate2D])] = []
        var current: FlightPhase?
        var buf: [CLLocationCoordinate2D] = []
        let step = max(1, r.count / 600)
        for i in stride(from: r.lowerBound, through: r.upperBound, by: step) {
            let s = samples[i]
            guard s.hasFix else { continue }
            let p = phase(atTime: s.t)
            if p != current {
                if let c = current, buf.count > 1 { out.append((c, buf)) }
                buf = buf.isEmpty ? [] : [buf.last!]
                current = p
            }
            buf.append(s.coord)
        }
        if let c = current, buf.count > 1 { out.append((c, buf)) }
        return out
    }

    struct Stats {
        var duration = 0.0, altStart = 0.0, altEnd = 0.0
        var vMax = 0.0, vAvg = 0.0, hMax = 0.0, hAvg = 0.0
        var grAvg: Double?, grMax: Double?
        var distance = 0.0, pathLength = 0.0
    }

    func stats(_ r: ClosedRange<Int>) -> Stats {
        guard r.upperBound < samples.count, r.count > 1 else { return Stats() }
        let s = Array(samples[r])
        var st = Stats()
        st.duration = s.last!.t - s.first!.t
        st.altStart = s.first!.altM - groundElevation
        st.altEnd = s.last!.altM - groundElevation
        st.vMax = s.map(\.vSpeedKmh).max() ?? 0
        st.hMax = s.map(\.hSpeedKmh).max() ?? 0
        let d = s.filter { $0.vSpeedKmh > 5 }
        st.vAvg = d.isEmpty ? 0 : d.map(\.vSpeedKmh).reduce(0,+) / Double(d.count)
        st.hAvg = d.isEmpty ? 0 : d.map(\.hSpeedKmh).reduce(0,+) / Double(d.count)
        let g = s.compactMap(\.glideRatio).filter { $0 < 12 }
        st.grAvg = g.isEmpty ? nil : g.reduce(0,+) / Double(g.count)
        st.grMax = g.max()
        st.distance = CLLocation(latitude: s.first!.lat, longitude: s.first!.lon)
            .distance(from: CLLocation(latitude: s.last!.lat, longitude: s.last!.lon))
        var p = 0.0
        for i in 1..<s.count {
            p += CLLocation(latitude: s[i-1].lat, longitude: s[i-1].lon)
                .distance(from: CLLocation(latitude: s[i].lat, longitude: s[i].lon))
        }
        st.pathLength = p
        return st
    }

    /// A FlySight (és sok más GPS logger) a tört másodperceket néha 2
    /// tizedesjegyen írja (".00Z", ".20Z"), nem a szokásos 3 jegyen (".000Z").
    /// Az ISO8601DateFormatter `.withFractionalSeconds` szigorúan 3 jegyet vár,
    /// ezért ".00Z"-vel némán `nil`-t adna — ez minden sort elutasítana, és a
    /// fájl "túl rövidnek" tűnne. Ezért 3 jegyre igazítunk elemzés előtt.
    private static func normalizeFractionalSeconds(_ s: String) -> String {
        guard let dot = s.firstIndex(of: ".") else { return s }
        let afterDot = s.index(after: dot)
        guard let zIdx = s[afterDot...].firstIndex(where: { !$0.isNumber }) else { return s }
        var frac = String(s[afterDot..<zIdx])
        if frac.count < 3 { frac += String(repeating: "0", count: 3 - frac.count) }
        else if frac.count > 3 { frac = String(frac.prefix(3)) }
        return String(s[..<afterDot]) + frac + String(s[zIdx...])
    }

    static func isoDate(_ s: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fmtNoFrac = ISO8601DateFormatter()
        fmtNoFrac.formatOptions = [.withInternetDateTime]
        let n = normalizeFractionalSeconds(s)
        return fmt.date(from: n) ?? fmt.date(from: s)
            ?? fmtNoFrac.date(from: s) ?? fmtNoFrac.date(from: n)
    }

    /// Megmondja, MIÉRT nem sikerült elemezni egy fájlt: hány sor volt, melyik
    /// formátumra illeszkedett hány sor, és hogy néz ki az első fel nem ismert
    /// sor. Enélkül a "nem sikerült beolvasni" üzenet semmit nem árul el.
    static func diagnose(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
        var gnss = 0, iso = 0, num = 0, other = 0
        var firstOther = ""
        for l0 in lines {
            let l = l0.trimmingCharacters(in: .whitespacesAndNewlines)
            if l.isEmpty { continue }
            let p = l.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if l.hasPrefix("$GNSS,"), p.count >= 12 { gnss += 1 }
            else if p.count >= 12, isoDate(p[0]) != nil { iso += 1 }
            else if p.count >= 10, Double(p[0]) != nil { num += 1 }
            else {
                other += 1
                if firstOther.isEmpty { firstOther = String(l.prefix(70)) }
            }
        }
        var s = "\(text.utf8.count) bytes, \(lines.count) lines — "
            + "$GNSS:\(gnss) ISO:\(iso) numeric:\(num) other:\(other)"
        if !firstOther.isEmpty { s += " | unknown line: \"\(firstOther)\"" }
        let usable = gnss + iso + num
        if usable == 0 {
            s += " → NO line matches any known format "
                + "(format mismatch or corrupted download)"
        } else if usable <= 5 {
            s += " → only \(usable) usable samples, threshold is 6"
        }
        return s
    }

    /// A fájl eleje nyersen — ebből azonnal látszik a valódi formátum.
    static func head(_ text: String, lines n: Int = 8) -> String {
        text.split(whereSeparator: \.isNewline).prefix(n)
            .map { String($0.prefix(120)) }
            .joined(separator: "\n")
    }

    static func parse(_ text: String, name: String) -> Track? {
        var out: [LiveGNSS] = []
        var t0: Double?
        var firstDate: Date?

        func parseISODate(_ s: String) -> Date? { isoDate(s) }

        // FONTOS: `\.isNewline`-nel darabolunk, nem "\n"-re! A FlySight CSV
        // fájljai CR (\r) sorvéget használnak, így a "\n"-es darabolás a teljes
        // 271 kB-os fájlt EGYETLEN sornak látta, és nulla mintát talált —
        // ezért tűnt minden letöltés "hiányosnak". Az isNewline a \n, \r és
        // \r\n változatot is helyesen kezeli.
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !l.isEmpty else { continue }
            let p = l.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            var g = LiveGNSS()
            if l.hasPrefix("$GNSS,"), p.count >= 12 {
                // Régi/BLE NMEA-szerű alak: $GNSS,idő,lat,lon,hMSL,velN,velE,velD,hAcc,vAcc,sAcc,gpsFix,numSV
                guard let d = parseISODate(p[1]) else { continue }
                if t0 == nil { t0 = d.timeIntervalSince1970; firstDate = d }
                g.t = d.timeIntervalSince1970 - t0!
                g.lat = Double(p[2]) ?? 0; g.lon = Double(p[3]) ?? 0
                g.altM = Double(p[4]) ?? 0
                g.vN = Double(p[5]) ?? 0; g.vE = Double(p[6]) ?? 0; g.vD = Double(p[7]) ?? 0
                g.hAccM = Double(p[8]) ?? 0; g.numSV = Int(p[p.count - 1]) ?? 0
            } else if p.count >= 12, let d = parseISODate(p[0]) {
                // Valódi FlySight TRACK.CSV: time,lat,lon,hMSL,velN,velE,velD,hAcc,vAcc,sAcc,gpsFix,numSV
                // (nincs "$GNSS," előtag, a time oszlop ISO8601 dátum, nem másodperc-eltolás).
                if t0 == nil { t0 = d.timeIntervalSince1970; firstDate = d }
                g.t = d.timeIntervalSince1970 - t0!
                g.lat = Double(p[1]) ?? 0; g.lon = Double(p[2]) ?? 0
                g.altM = Double(p[3]) ?? 0
                g.vN = Double(p[4]) ?? 0; g.vE = Double(p[5]) ?? 0; g.vD = Double(p[6]) ?? 0
                g.hAccM = Double(p[7]) ?? 0; g.numSV = Int(p[p.count - 1]) ?? 0
            } else if p.count >= 10, let t = Double(p[0]) {
                // Régi export: másodperc-eltolással kezdődő, "$GNSS," előtag nélküli sor.
                g.t = t
                g.lat = Double(p[1]) ?? 0; g.lon = Double(p[2]) ?? 0
                g.altM = Double(p[3]) ?? 0
                g.vN = Double(p[4]) ?? 0; g.vE = Double(p[5]) ?? 0; g.vD = Double(p[6]) ?? 0
                g.hAccM = Double(p[7]) ?? 0; g.numSV = Int(p[9]) ?? 0
            } else { continue }
            out.append(g)
        }
        // Korábban 50 volt a küszöb (10+ mp 5 Hz-en). Ez néma módon
        // elutasította a rövid földi teszteket / hamis indításokat,
        // amik a legtöbb SD kártyán megtalálhatók néhány tucat sorral.
        // Az elemzés így is működik kevés mintával — exit/deploy egyszerűen
        // nil marad, ezt a UI már optional-ként kezeli.
        guard out.count > 5 else { return nil }
        var t = Track(name: name, samples: out)
        t.recordedAt = firstDate
        let sorted = out.map(\.altM).sorted()
        t.groundElevation = sorted[max(0, sorted.count / 20)]
        t.buildCumulativeDistance()
        t.detect()
        return t
    }

    /// A küszöbök a valódi FlySight adatokból: exit -> süllyedés 60 km/h fölé,
    /// nyitás -> tartósan 40 km/h alá esik.
    mutating func detect() {
        let n = samples.count
        exitIdx = samples.firstIndex { $0.vSpeedKmh > 60 }
        if let ex = exitIdx {
            var i = ex
            while i < n - 10 {
                if samples[i..<min(i+10, n)].allSatisfy({ $0.vSpeedKmh < 40 }) {
                    deployIdx = i; break
                }
                i += 1
            }
        }
        let start = deployIdx ?? exitIdx ?? 0
        landIdx = (start..<n).first {
            samples[$0].altM - groundElevation < 20 && samples[$0].hSpeedKmh < 15
        } ?? n - 1
    }
}

// MARK: - Beépített minták

enum SampleTrack: String, CaseIterable, Identifiable {
    case wingsuit = "SAMPLE_WINGSUIT", tracking = "SAMPLE_TRACKING"
    var id: String { rawValue }
    var title: String { title("hu") }
    var subtitle: String { subtitle("hu") }

    func title(_ lang: String) -> String {
        if lang == "en" {
            return self == .wingsuit ? "Wingsuit sample" : "Tracking sample"
        }
        return self == .wingsuit ? "Wingsuit minta" : "Tracking minta"
    }
    func subtitle(_ lang: String) -> String {
        if lang == "en" {
            return self == .wingsuit ? "4126 m · GR 1.2–1.5 · opening 1450 m"
                                     : "4140 m · vV 240 km/h · opening 1400 m"
        }
        return self == .wingsuit ? "4126 m · GR 1,2–1,5 · nyitás 1450 m"
                                 : "4140 m · vV 240 km/h · nyitás 1400 m"
    }
    func load(_ lang: String = "hu") -> Track? {
        guard let u = Bundle.main.url(forResource: rawValue, withExtension: "csv"),
              let t = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        return Track.parse(t, name: title(lang))
    }
}

// MARK: - Élő állapotmotor

@MainActor
final class FlightEngine: ObservableObject {
    @Published var fix: LiveGNSS?
    @Published var phase: FlightPhase = .ground
    @Published var altAGL = 0.0
    @Published var avgGlide: Double?
    @Published var trail: [CLLocationCoordinate2D] = []
    @Published var exitAlt: Double?
    @Published var deployAlt: Double?

    var groundElevation = 125.0
    private var win: [Double] = []
    private var groundSamples: [Double] = []

    func reset() {
        fix = nil; phase = .ground; altAGL = 0; avgGlide = nil
        trail.removeAll(); win.removeAll(); groundSamples.removeAll()
        exitAlt = nil; deployAlt = nil
    }

    /// Egyetlen minta megjelenítése scrub közben
    func show(_ g: LiveGNSS, phase p: FlightPhase, trail newTrail: [CLLocationCoordinate2D]) {
        fix = g
        altAGL = g.altM - groundElevation
        phase = p
        trail = newTrail
        if let gr = g.glideRatio, gr.isFinite, gr < 12 { avgGlide = gr } else { avgGlide = nil }
    }

    func ingest(_ g: LiveGNSS) {
        guard g.hasFix else { return }
        fix = g
        if g.hSpeedKmh < 8 && abs(g.vSpeedKmh) < 3 {
            groundSamples.append(g.altM)
            if groundSamples.count > 200 { groundSamples.removeFirst() }
            if groundSamples.count > 20 {
                groundElevation = groundSamples.sorted()[groundSamples.count / 2]
            }
        }
        altAGL = g.altM - groundElevation
        if trail.isEmpty || CLLocation(latitude: trail.last!.latitude,
                                       longitude: trail.last!.longitude)
            .distance(from: CLLocation(latitude: g.lat, longitude: g.lon)) > 15 {
            trail.append(g.coord)
            if trail.count > 900 { trail.removeFirst() }
        }
        if let gr = g.glideRatio, gr.isFinite, gr < 12 {
            win.append(gr); if win.count > 15 { win.removeFirst() }
            avgGlide = win.reduce(0,+) / Double(win.count)
        } else if g.vSpeedKmh < 3 { win.removeAll(); avgGlide = nil }

        let prev = phase, vv = g.vSpeedKmh
        if altAGL < 25 && g.hSpeedKmh < 15 { phase = .ground }
        else if vv < -3 { phase = .climb }
        else if vv > 70 { phase = .freefall }
        else if prev == .freefall && vv > 25 { phase = .deploying }
        else if prev == .deploying || prev == .canopy { phase = altAGL < 120 ? .landing : .canopy }
        else if abs(vv) < 5 && altAGL > 1000 { phase = .jumpRun }
        if phase == .freefall && prev != .freefall && prev != .deploying { exitAlt = g.altM }
        if phase == .deploying && prev == .freefall { deployAlt = g.altM }
    }
}

// MARK: - HUD beállítások

enum HUDLayout: String, CaseIterable, Identifiable {
    case altitudeFirst, glideFirst, edgeBar, dial
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .altitudeFirst: return "arrow.up.and.down"
        case .glideFirst:    return "chart.line.uptrend.xyaxis"
        case .edgeBar:       return "rectangle.bottomthird.inset.filled"
        case .dial:          return "gauge.medium"
        }
    }
    func name(_ lang: String) -> String {
        switch self {
        case .altitudeFirst: return loc("layout.altitude", lang)
        case .glideFirst:    return loc("layout.glide", lang)
        case .edgeBar:       return loc("layout.edgeBar", lang)
        case .dial:          return loc("layout.dial", lang)
        }
    }
}

enum HUDPalette: String, CaseIterable, Identifiable {
    case color, green, amber
    var id: String { rawValue }
    var fg: Color {
        switch self {
        case .color: return .white
        case .green: return Color(red: 0.49, green: 1, blue: 0.61)
        case .amber: return Color(red: 1, green: 0.78, blue: 0.28)
        }
    }
    var dim: Color { fg.opacity(0.5) }
    func name(_ lang: String) -> String {
        switch self {
        case .color: return loc("palette.color", lang)
        case .green: return loc("palette.green", lang)
        case .amber: return loc("palette.amber", lang)
        }
    }
    func glide(_ gr: Double) -> Color {
        guard self == .color else { return fg }
        switch gr {
        case ..<1.5: return .red
        case ..<2.0: return .orange
        case ..<2.8: return Color(red: 0.59, green: 0.77, blue: 0.35)
        default:     return .cyan
        }
    }
}

/// Talaj feletti vagy tengerszint feletti magasság
enum AltRef: String, CaseIterable, Identifiable {
    case agl, msl
    var id: String { rawValue }
    func name(_ lang: String) -> String { loc(self == .agl ? "altref.agl" : "altref.msl", lang) }
    func shortLabel(_ lang: String) -> String {
        loc(self == .agl ? "hud.altAGLshort" : "hud.altMSLshort", lang)
    }
}
