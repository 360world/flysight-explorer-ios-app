//
//  ContentView.swift  —  FlySight HUD + Analyzer (iOS)
//  Négy fül: HUD, Elemzés, Napló, FlySight (kapcsolat + konfigurátor)
//
//  BEÁLLÍTÁS
//    Xcode > iOS App (SwiftUI), a generált <Projekt>App.swift törlendő.
//    Target > Info: Privacy - Bluetooth Always Usage Description
//    Fájlok a projektben: Model.swift, FlySightBLE.swift, Logbook.swift,
//    FlySightConfig.swift, ContentView.swift
//    Húzd be a bundle-be: SAMPLE_WINGSUIT.csv, SAMPLE_TRACKING.csv
//

import SwiftUI
import Combine
import MapKit
import Charts
import CoreLocation
import UIKit          // UIPasteboard — napló vágólapra másolása
import UniformTypeIdentifiers   // UTType — CSV import a Fájlokból

// MARK: - Alkalmazás állapot

@MainActor
final class AppModel: ObservableObject {
    @Published var track: Track?
    @Published var sample: SampleTrack = .wingsuit
    @Published var useLive = false

    @Published var lo = 0
    @Published var hi = 0
    @Published var cursor = 0
    @Published var isPlaying = false
    @Published var speed = 1.0

    let engine = FlightEngine()
    let ble = FlySightBLE()
    let logbook = Logbook()
    let config = FlySightConfig()

    @Published var configSourceIsDevice = false
    @Published var toast: String?
    private var cancellables: [AnyCancellable] = []

    private var timer: Timer?
    private var vt = 0.0

    init() {
        ble.onLive = { [weak self] g in
            guard let s = self, s.useLive else { return }
            s.engine.ingest(g)
        }
        ble.onFileDownloaded = { [weak self] remote, name, text in
            guard let s = self else { return }
            if name.uppercased().hasPrefix("CONFIG") {
                s.config.load(text, name: remote)
                s.configSourceIsDevice = true
                s.toast = s.lang == "en" ? "CONFIG.TXT loaded from device"
                                         : "CONFIG.TXT betöltve az eszközről"
            } else {
                // A nyers CSV-t mindig elmentjük — a "túl rövid / hiányos"
                // eset csak a megjelenítésnél (Track.parse) dönt el, nem
                // blokkolja a letöltést/mentést magát.
                guard let e = s.logbook.save(text: text, remotePath: remote,
                                             suggestedName: name) else {
                    // Ez valódi I/O hiba (pl. lemez tele, írási jog hiánya) —
                    // ez a tényleges "nem sikerült elmenteni" eset.
                    s.ble.logNote("Save failed (I/O error): \(name) (\(text.utf8.count) bytes)")
                    s.toast = (s.lang == "en" ? "Couldn't save: " : "Nem sikerült elmenteni: ")
                        + name
                    return
                }
                guard let t = s.logbook.load(e) else {
                    // A fájl lemezen van és a naplóban is szerepel — csak a
                    // megjelenítéshez nincs elég GNSS minta (rövid felvétel
                    // vagy hiányos letöltés). Ez itt, megjelenítéskor derül ki.
                    s.ble.logNote("Saved, but too short/incomplete to display: \(e.displayName) (\(text.utf8.count) bytes)")
                    s.toast = (s.lang == "en"
                        ? "Saved to logbook, but too short/incomplete to open: "
                        : "Elmentve a naplóba, de túl rövid/hiányos a megnyitáshoz: ")
                        + e.displayName
                    return
                }
                s.ble.logNote("Saved to logbook: \(e.displayName) (\(text.utf8.count) bytes)")
                s.setTrack(t)
                s.toast = (s.lang == "en" ? "Saved to logbook: " : "Elmentve a naplóba: ")
                    + e.displayName
            }
        }
        ble.onUploadFinished = { [weak self] ok, name in
            let en = (self?.lang ?? AppLanguage.systemDefault.rawValue) == "en"
            self?.toast = ok ? (en ? "\(name) uploaded to device"
                                   : "\(name) feltöltve az eszközre")
                             : (en ? "Upload failed" : "A feltöltés nem sikerült")
            if ok { self?.config.isDirty = false }
        }
        cancellables.append(ble.$lastError.sink { [weak self] err in
            if let e = err { self?.toast = e }
        })
        loadSample(.wingsuit, lang)
        config.load(FlySightConfig.defaultWingsuitText(),
                    name: FlySightConfig.defaultSourceName)
    }

    /// Az aktuális nyelv — ugyanaz a kulcs, amit a nézetek @AppStorage-dzsal
    /// olvasnak. Az AppModel nem View, ezért közvetlenül a UserDefaults-ból.
    var lang: String {
        UserDefaults.standard.string(forKey: "app_language") ?? AppLanguage.systemDefault.rawValue
    }

    func loadSample(_ s: SampleTrack, _ lang: String = "hu") {
        guard let t = s.load(lang) else { return }
        sample = s; setTrack(t)
    }

    func setTrack(_ t: Track) {
        stop()
        track = t; useLive = false
        engine.reset(); engine.groundElevation = t.groundElevation
        let r = t.presetRange(.wholeJump)
        lo = r.lowerBound; hi = r.upperBound; cursor = r.lowerBound
        showCursor()
    }

    func applyPreset(_ s: Segment) {
        guard let t = track else { return }
        let r = t.presetRange(s)
        lo = r.lowerBound; hi = r.upperBound
        cursor = min(max(cursor, lo), hi)
        showCursor()
    }

    var cursorTimeLabel: String? {
        guard let t = track, t.count > 0 else { return nil }
        let i = min(max(cursor, 0), t.count - 1)
        let exit = t.exitIdx ?? 0
        let rel: Double = t.samples[i].t - t.samples[exit].t
        return String(format: "t%+.0f s", rel)
    }

    func showCursor() {
        guard let t = track, t.count > 0 else { return }
        let i = min(max(cursor, 0), t.count - 1)
        let g = t.samples[i]
        let from = max(lo, i - 400)
        let trail = stride(from: from, through: i, by: max(1, (i - from) / 120 + 1))
            .map { t.samples[$0].coord }
        engine.show(g, phase: t.phase(atTime: g.t), trail: trail)
    }

    func play() {
        guard let t = track else { return }
        if cursor >= hi { cursor = lo }
        vt = t.samples[cursor].t
        isPlaying = true
        // `.common` futásmód kell: a `scheduledTimer` alapértelmezett módú
        // időzítője megáll, amíg a felhasználó görget vagy egy vezérlőt fog,
        // ezért tűnt úgy, hogy a lejátszás csak kattintásra lép egyet.
        let tm = Timer(timeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.step() }
        }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    func stop() { timer?.invalidate(); timer = nil; isPlaying = false }

    private func step() {
        guard let t = track else { return }
        vt += 0.05 * speed
        var moved = false
        var tx = Transaction(); tx.disablesAnimations = true
        withTransaction(tx) {
            while cursor < hi && t.samples[cursor].t <= vt { cursor += 1; moved = true }
        }
        if moved { showCursor() }
        if cursor >= hi { cursor = lo; vt = t.samples[lo].t }
    }
}

// MARK: - HUD elemek

struct Metric: View {
    let v: String, u: String, size: CGFloat, c: Color, d: Color
    var body: some View {
        VStack(spacing: 2) {
            Text(v).font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(c)
                // Hosszú érték (pl. 4 jegyű magasság) eddig levágódott —
                // inkább kicsinyítjük, mint hogy kifusson a képernyőről.
                .lineLimit(1).minimumScaleFactor(0.4)
            if !u.isEmpty {
                Text(u.uppercased()).font(.system(size: max(10, size * 0.15)))
                    .tracking(1.5).foregroundStyle(d).multilineTextAlignment(.center)
            }
        }
    }
}

struct HUDView: View {
    @ObservedObject var e: FlightEngine
    let layout: HUDLayout
    let palette: HUDPalette
    let altRef: AltRef
    let lang: String

    private var gr: Double { e.avgGlide ?? 0 }
    private var grC: Color { palette.glide(gr) }
    private var grT: String { gr > 0 ? String(format: "%.2f", gr) : "—" }
    private var altValue: Int {
        Int(altRef == .agl ? e.altAGL : (e.fix?.altM ?? 0))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let f = e.fix, f.hasFix {
                switch layout {

                case .altitudeFirst:
                    VStack(spacing: 22) {
                        Metric(v: "\(altValue)", u: altRef.shortLabel(lang), size: 74,
                               c: palette.fg, d: palette.dim)
                        HStack(spacing: 0) {
                            Metric(v: "\(Int(f.hSpeedKmh))", u: loc("hud.hSpeed", lang),
                                   size: 36, c: palette.fg, d: palette.dim)
                                .frame(maxWidth: .infinity)
                            Metric(v: "\(Int(abs(f.vSpeedKmh)))", u: loc("hud.vSpeed", lang),
                                   size: 36, c: palette.fg, d: palette.dim)
                                .frame(maxWidth: .infinity)
                        }
                        Metric(v: grT, u: loc("hud.glide", lang), size: 54, c: grC, d: palette.dim)
                    }

                case .glideFirst:
                    VStack(spacing: 24) {
                        Metric(v: grT, u: loc("hud.glide", lang), size: 94, c: grC, d: palette.dim)
                        HStack(spacing: 0) {
                            Metric(v: "\(altValue)", u: altRef.shortLabel(lang), size: 34,
                                   c: palette.fg, d: palette.dim).frame(maxWidth: .infinity)
                            Metric(v: "\(Int(f.hSpeedKmh))", u: loc("hud.hSpeedShort", lang),
                                   size: 34, c: palette.fg, d: palette.dim)
                                .frame(maxWidth: .infinity)
                            Metric(v: "\(Int(abs(f.vSpeedKmh)))", u: loc("hud.vSpeedShort", lang),
                                   size: 34, c: palette.fg, d: palette.dim)
                                .frame(maxWidth: .infinity)
                        }
                    }

                case .edgeBar:
                    VStack {
                        Spacer()
                        HStack(alignment: .bottom, spacing: 0) {
                            Metric(v: "\(altValue)", u: altRef.shortLabel(lang),
                                   size: 40, c: palette.fg, d: palette.dim)
                                .frame(maxWidth: .infinity)
                            Metric(v: "\(Int(f.hSpeedKmh))", u: loc("hud.hSpeedShort", lang),
                                   size: 34, c: palette.fg, d: palette.dim)
                                .frame(maxWidth: .infinity)
                            Metric(v: grT, u: loc("hud.glide", lang), size: 50, c: grC, d: palette.dim)
                                .frame(maxWidth: .infinity)
                            Metric(v: "\(Int(abs(f.vSpeedKmh)))", u: loc("hud.vSpeedShort", lang),
                                   size: 34, c: palette.fg, d: palette.dim)
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.bottom, 28)
                    }

                case .dial:
                    ZStack {
                        Circle().trim(from: 0, to: 0.75)
                            .stroke(palette.dim.opacity(0.3),
                                    style: .init(lineWidth: 12, lineCap: .round))
                            .rotationEffect(.degrees(135)).frame(width: 235, height: 235)
                        Circle().trim(from: 0, to: 0.75 * min(max(gr / 3.5, 0), 1))
                            .stroke(grC, style: .init(lineWidth: 12, lineCap: .round))
                            .rotationEffect(.degrees(135)).frame(width: 235, height: 235)
                        VStack(spacing: 6) {
                            Metric(v: grT, u: loc("hud.glide", lang), size: 50, c: grC, d: palette.dim)
                            Metric(v: "\(altValue)", u: altRef.shortLabel(lang), size: 28,
                                   c: palette.fg, d: palette.dim)
                            HStack(spacing: 16) {
                                Metric(v: "\(Int(f.hSpeedKmh))", u: loc("hud.hSpeedShort", lang),
                                       size: 22, c: palette.fg, d: palette.dim)
                                Metric(v: "\(Int(abs(f.vSpeedKmh)))", u: loc("hud.vSpeedShort", lang),
                                       size: 22, c: palette.fg, d: palette.dim)
                            }
                        }
                    }
                }
            } else {
                Text(loc("hud.noData", lang))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.dim)
            }
        }
    }
}

// MARK: - Térkép

struct TrackMap: View {
    let track: Track?
    let range: ClosedRange<Int>
    let cursor: Int
    let liveTrail: [CLLocationCoordinate2D]
    let liveFix: LiveGNSS?
    var compact = false

    @State private var cam: MapCameraPosition = .automatic
    @State private var lastCenter: CLLocationCoordinate2D?

    var body: some View {
        Map(position: $cam, interactionModes: compact ? [] : .all) {
            if let t = track {
                ForEach(Array(t.phaseSegments(range).enumerated()), id: \.offset) { _, seg in
                    MapPolyline(coordinates: seg.coords)
                        .stroke(seg.phase.color, lineWidth: compact ? 2.5 : 4)
                }
                let i = min(max(cursor, range.lowerBound), range.upperBound)
                if i < t.count, t.samples[i].hasFix {
                    let s = t.samples[i]
                    Annotation("", coordinate: s.coord) {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: compact ? 14 : 18))
                            .foregroundStyle(.white)
                            .rotationEffect(.degrees(s.headingDeg))
                            .padding(compact ? 4 : 6)
                            .background(Circle().fill(t.phase(atTime: s.t).color))
                    }
                }
            } else {
                if liveTrail.count > 1 {
                    MapPolyline(coordinates: liveTrail).stroke(.cyan, lineWidth: 3)
                }
                if let f = liveFix, f.hasFix {
                    Annotation("", coordinate: f.coord) {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 15)).foregroundStyle(.white)
                            .rotationEffect(.degrees(f.headingDeg))
                            .padding(5).background(Circle().fill(.cyan))
                    }
                }
            }
        }
        .mapStyle(.imagery)
        .onChange(of: cursor) { _, _ in recenter() }
        .onChange(of: liveFix?.lat) { _, _ in recenter() }
        .onAppear { recenter(force: true) }
    }

    /// Animáció nélkül és csak érdemi elmozdulásnál, különben a gyors
    /// scrub SwiftUI animációs figyelmeztetéseket dob.
    private func recenter(force: Bool = false) {
        var target: CLLocationCoordinate2D?
        if let t = track {
            let i = min(max(cursor, range.lowerBound), range.upperBound)
            if i < t.count, t.samples[i].hasFix { target = t.samples[i].coord }
        } else if let f = liveFix, f.hasFix { target = f.coord }
        guard let c = target else { return }
        if !force, let l = lastCenter {
            let d = CLLocation(latitude: l.latitude, longitude: l.longitude)
                .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            if d < 25 { return }
        }
        lastCenter = c
        var tx = Transaction(); tx.disablesAnimations = true
        withTransaction(tx) {
            cam = .region(.init(center: c,
                                latitudinalMeters: compact ? 900 : 2200,
                                longitudinalMeters: compact ? 900 : 2200))
        }
    }
}

struct PhaseLegend: View {
    let lang: String
    private let items: [FlightPhase] = [.climb, .freefall, .deploying, .canopy, .landing]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(items, id: \.rawValue) { p in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(p.color).frame(width: 12, height: 4)
                    Text(p.name(lang)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Tartománysáv

struct RangeBar: View {
    let track: Track
    @Binding var lo: Int
    @Binding var hi: Int
    @Binding var cursor: Int
    /// Akkor hívjuk, ha a FELHASZNÁLÓ mozgatja a kurzort/fogantyút. A lejátszást
    /// csak ilyenkor kell leállítani — a `onChange(of: cursor)` erre nem jó,
    /// mert az a lejátszás saját léptetésénél is lefut, és azonnal megállítja.
    var onUserScrub: (() -> Void)? = nil
    private let h: CGFloat = 46

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let n = max(1, track.count - 1)
            // Az indexek 0…n közé szorítva, hogy egy hibás kurzor/kijelölés
            // ne tudjon a kereten kívülre rajzolni.
            let xLo = CGFloat(min(max(lo, 0), n)) / CGFloat(n) * w
            let xHi = CGFloat(min(max(hi, 0), n)) / CGFloat(n) * w
            let xCur = CGFloat(min(max(cursor, 0), n)) / CGFloat(n) * w

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(track.bands) { b in
                        // 0 hosszú tracknél a nevező ~0 volt, így a `frac`
                        // elszállt és a sávok kitolták a keretet. Korlátozva.
                        let total = track.tEnd - track.t0
                        let frac = total > 0.001
                            ? min(1, max(0, (b.t1 - b.t0) / total)) : 0
                        b.phase.color.opacity(0.4).frame(width: w * frac)
                    }
                }
                .frame(width: w, height: h, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // A magasságprofil a sáv saját skálájára normalizálva. A `f`-et
                // KORLÁTOZNI kell 0…1 közé, és a Path-ot VÁGNI: egy földi
                // (ugrás nélküli) track esetén ugyanis az értékek kifutottak a
                // keretből, és a rajz hosszú szürke/fehér vonalakként terült
                // szét az egész oldalon.
                Path { p in
                    let n2 = max(1, track.count - 1)
                    let alts = track.samples.map(\.altM).filter { $0.isFinite }
                    let maxA = alts.max() ?? 1
                    let minA = alts.min() ?? 0
                    let span = max(1, maxA - minA)
                    var started = false
                    for i in stride(from: 0, through: n2, by: max(1, n2 / 200)) {
                        let a = track.samples[i].altM
                        guard a.isFinite else { continue }
                        let x = CGFloat(i) / CGFloat(n2) * w
                        let f = min(1, max(0, (a - minA) / span))
                        let y = h - CGFloat(f) * (h - 6) - 3
                        guard x.isFinite, y.isFinite else { continue }
                        if started { p.addLine(to: .init(x: x, y: y)) }
                        else { p.move(to: .init(x: x, y: y)); started = true }
                    }
                }
                .stroke(.white.opacity(0.9), lineWidth: 1.5)
                .frame(height: h)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, xLo), height: h)
                Rectangle().fill(.black.opacity(0.55))
                    .frame(width: max(0, w - xHi), height: h).offset(x: xHi)

                Rectangle().fill(.yellow).frame(width: 2, height: h).offset(x: xCur - 1)
                Circle().fill(.yellow).frame(width: 11, height: 11)
                    .offset(x: xCur - 5.5, y: -h / 2 - 2)

                Color.clear.contentShape(Rectangle()).frame(height: h)
                    .gesture(DragGesture(minimumDistance: 0,
                                         coordinateSpace: .named(Self.space))
                        .onChanged { v in
                            onUserScrub?()
                            let f = max(0, min(1, v.location.x / w))
                            noAnim { cursor = min(max(Int(f * CGFloat(n)), lo), hi) }
                        })

                // Rövid (pár mintás) felvételnél a ±5 miatt negatív vagy a
                // mintaszámon túli index keletkezhetett — 0…n közé szorítva.
                handle(x: xLo, w: w) { i in
                    noAnim { lo = max(0, min(i, max(0, hi - 5))) }
                }
                handle(x: xHi, w: w) { i in
                    noAnim { hi = min(n, max(i, min(n, lo + 5))) }
                }
            }
            .frame(height: h)
            .coordinateSpace(.named(Self.space))
        }
        .frame(height: h)
    }

    private func noAnim(_ b: () -> Void) {
        var tx = Transaction(); tx.disablesAnimations = true
        withTransaction(tx, b)
    }

    /// A fogantyú látható csíkja 5 pt, de a fogási terület 30 pt — ezért a
    /// csoport szélessége 30, és a csík ANNAK a közepén áll. Emiatt `x - 2.5`
    /// eltolással a csík 12,5 pt-tal jobbra csúszott a kijelölés szélétől
    /// (innen jött, hogy a sárga kurzor a fogantyú "elé" került, és a végét
    /// nem lehetett telibe húzni). A csoportot a felére kell eltolni: `x - 15`.
    private static let hitW: CGFloat = 30
    private static let space = "rangebar"

    private func handle(x: CGFloat, w: CGFloat, set: @escaping (Int) -> Void) -> some View {
        let n = max(1, track.count - 1)
        return ZStack {
            RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 5, height: h + 10)
            Rectangle().fill(.white.opacity(0.001))
                .frame(width: Self.hitW, height: h + 16)
        }
        .offset(x: x - Self.hitW / 2)
        // A gesztus a SÁV koordinátarendszerében mérjen, ne a fogantyúéban —
        // különben `location.x` 0…30 közötti érték, és a `/ w` osztás miatt a
        // fogantyú a sáv elejére ugrott.
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { v in
                onUserScrub?()
                let f = max(0, min(1, v.location.x / w))
                set(Int(f * CGFloat(n)))
            })
    }
}

// MARK: - Idővonal görbe

struct SeriesToggles: OptionSet {
    let rawValue: Int
    static let altitude = SeriesToggles(rawValue: 1 << 0)
    static let vertical = SeriesToggles(rawValue: 1 << 1)
    static let horizontal = SeriesToggles(rawValue: 1 << 2)
    static let glide = SeriesToggles(rawValue: 1 << 3)
    static let distance = SeriesToggles(rawValue: 1 << 4)
    /// (opció, lokalizációs kulcs, szín)
    static let all: [(SeriesToggles, String, Color)] = [
        (.altitude, "series.altitude", .gray),
        (.vertical, "series.vertical", .green),
        (.horizontal, "series.horizontal", .red),
        (.glide, "series.glide", .cyan),
        (.distance, "series.distance", .purple),
    ]
}

struct TimelineChart: View {
    let track: Track
    let range: ClosedRange<Int>
    @Binding var cursor: Int
    let series: SeriesToggles
    let lang: String
    /// Akkor hívjuk, ha a felhasználó kezdi csúszkáltatni a chartot — a
    /// lejátszást ilyenkor le kell állítani.
    var onScrubBegan: (() -> Void)? = nil


    /// Nem-véges értékek kiszűrése — egy hibás minta (NaN/inf) különben
    /// szétvágja a Swift Charts rajzát.
    private func safe(_ v: Double) -> Double { v.isFinite ? v : 0 }

    /// A látható időtartomány hossza. 0 hosszú (földi) tracknél legalább 1 mp,
    /// különben a tengely elfajul és a rajz összeomlik.
    private var span: Double {
        guard !track.samples.isEmpty else { return 1 }
        let s = track.samples[safeRange.upperBound].t - t0
        return s.isFinite && s > 0.5 ? s : 1
    }

    /// A kapott tartomány a minták tényleges határai közé szorítva — egy régi
    /// kijelölés (más, hosszabb trackről) különben indexhibával elszállna.
    private var safeRange: ClosedRange<Int> {
        let last = max(0, track.count - 1)
        let lo = min(max(range.lowerBound, 0), last)
        let hi = min(max(range.upperBound, lo), last)
        return lo...hi
    }

    private var pts: [(i: Int, s: LiveGNSS)] {
        guard !track.samples.isEmpty else { return [] }
        let r = safeRange
        let step = max(1, r.count / 320)
        return stride(from: r.lowerBound, through: r.upperBound, by: step)
            .map { ($0, track.samples[$0]) }
    }
    private var t0: Double {
        guard !track.samples.isEmpty else { return 0 }
        return track.samples[safeRange.lowerBound].t
    }

    /// Kumulatív megtett távolság kilométerben, a pts pontjaihoz igazítva.
    private var distanceKm: [Double] {
        var out: [Double] = []
        var acc = 0.0
        var prev: LiveGNSS?
        for p in pts {
            if let pr = prev {
                acc += CLLocation(latitude: pr.lat, longitude: pr.lon)
                    .distance(from: CLLocation(latitude: p.s.lat, longitude: p.s.lon))
            }
            out.append(acc / 1000)
            prev = p.s
        }
        return out
    }

    private var hasSpeedSeries: Bool {
        series.contains(.vertical) || series.contains(.horizontal) || series.contains(.glide)
    }
    private var hasSpaceSeries: Bool {
        series.contains(.altitude) || series.contains(.distance)
    }

    var body: some View {
        let dist = distanceKm
        VStack(alignment: .leading, spacing: 14) {
            if hasSpeedSeries {
                speedChart
            }
            if hasSpaceSeries {
                spaceChart(dist)
            }
            if !hasSpeedSeries && !hasSpaceSeries {
                Text(lang == "hu" ? "Válassz legalább egy adatsort fent"
                                  : "Pick at least one series above")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: 60)
            }
        }
    }

    /// Sebesség (km/h) és siklószám (arányszám) — mindkettő természetes
    /// tartománya nagyjából egybeesik, ezért közös tengelyen valódi értékkel.
    private var speedChart: some View {
        Chart {
            phaseBands
            ForEach(pts, id: \.i) { p in
                if series.contains(.vertical) {
                    LineMark(x: .value("t", safe(p.s.t - t0)),
                             y: .value("km/h", safe(p.s.vSpeedKmh)),
                             series: .value("s", "v")).foregroundStyle(.green)
                }
                if series.contains(.horizontal) {
                    LineMark(x: .value("t", safe(p.s.t - t0)),
                             y: .value("km/h", safe(p.s.hSpeedKmh)),
                             series: .value("s", "h")).foregroundStyle(.red)
                }
                if series.contains(.glide) {
                    LineMark(x: .value("t", safe(p.s.t - t0)),
                             y: .value("glide", min(safe(p.s.glideRatio ?? 0), 6)),
                             series: .value("s", "gr")).foregroundStyle(.cyan)
                }
            }
            cursorRule
        }
        .chartYAxisLabel(lang == "hu" ? "km/h · siklószám" : "km/h · glide ratio")
        .chartXAxisLabel(axisLabel)
        .chartXScale(domain: 0...span)
        .frame(height: 160)
        .chartOverlay { proxy in dragOverlay(proxy) }
    }

    /// Magasság (m) és megtett táv (km) — valódi mértékegységben, saját tengelyen.
    private func spaceChart(_ dist: [Double]) -> some View {
        Chart {
            phaseBands
            ForEach(Array(pts.enumerated()), id: \.element.i) { idx, p in
                if series.contains(.altitude) {
                    LineMark(x: .value("t", safe(p.s.t - t0)),
                             y: .value("m", safe(p.s.altM - track.groundElevation)),
                             series: .value("s", "alt")).foregroundStyle(.gray)
                }
                if series.contains(.distance), idx < dist.count {
                    LineMark(x: .value("t", safe(p.s.t - t0)),
                             y: .value("km", safe(dist[idx] * 1000)),
                             series: .value("s", "d")).foregroundStyle(.purple)
                }
            }
            cursorRule
        }
        .chartYAxisLabel(lang == "hu" ? "magasság m · táv m" : "altitude m · distance m")
        .chartXAxisLabel(axisLabel)
        .chartXScale(domain: 0...span)
        .frame(height: 160)
        .chartOverlay { proxy in dragOverlay(proxy) }
    }

    private var axisLabel: String { lang == "hu" ? "mp" : "s" }

    @ChartContentBuilder
    private var phaseBands: some ChartContent {
        ForEach(track.bands) { b in
            let s = max(b.t0, t0) - t0
            let e = min(b.t1, track.samples[safeRange.upperBound].t) - t0
            if e > s {
                RectangleMark(xStart: .value("", s), xEnd: .value("", e))
                    .foregroundStyle(b.phase.color.opacity(0.14))
            }
        }
    }

    @ChartContentBuilder
    private var cursorRule: some ChartContent {
        if !track.samples.isEmpty, safeRange.contains(cursor) {
            RuleMark(x: .value("t", safe(track.samples[cursor].t - t0)))
                .foregroundStyle(.yellow).lineStyle(.init(lineWidth: 1.5))
        }
    }

    /// Koppintás = kurzor odahelyezése; húzás = kurzor követése, de CSAK ha a
    /// mozdulat inkább vízszintes. Így a fel/le húzás a ScrollView-hoz kerül,
    /// és az Elemzés fül végre normálisan görgethető a chartokon is.
    /// A kurzort a chart adott képernyő-x pozíciójára állítja.
    private func moveCursor(_ proxy: ChartProxy, _ rect: CGRect, toX x: CGFloat) {
        guard let t: Double = proxy.value(atX: x - rect.minX) else { return }
        let idx = track.index(atTime: t + t0)
        let clamped = min(max(idx, safeRange.lowerBound), safeRange.upperBound)
        // Csak tényleges változásnál írunk állapotot: a felesleges újrarajzolás
        // az, ami a konzolt teleszórja a SwiftUI animációs figyelmeztetéseivel.
        guard clamped != cursor else { return }
        var tx = Transaction(); tx.disablesAnimations = true
        withTransaction(tx) { cursor = clamped }
    }

    private func dragOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            if let plot = proxy.plotFrame {
                let rect = geo[plot]
                // UIKit pan gesztus (lásd ScrubOverlay.swift): vízszintes
                // csúszkáltatás ÉS megmaradó fel/le görgetés. SwiftUI
                // gesztusokkal ez nem megoldható, mert azok a lenyomásnál
                // lefogják az érintést.
                ScrubOverlay(
                    onScrub: { x in moveCursor(proxy, rect, toX: x) },
                    onBegan: { onScrubBegan?() },
                    onTap: { x in moveCursor(proxy, rect, toX: x) }
                )
            }
        }
    }
}

// MARK: - HUD fül

// MARK: - HUD fül

struct HUDTab: View {
    @ObservedObject var m: AppModel
    @ObservedObject var ble: FlySightBLE
    @AppStorage("hud_layout") private var layoutRaw = HUDLayout.glideFirst.rawValue
    @AppStorage("hud_palette") private var paletteRaw = HUDPalette.color.rawValue
    @AppStorage("hud_altref") private var altRefRaw = AltRef.agl.rawValue
    @AppStorage("hud_map") private var showMap = true
    @AppStorage("app_language") private var appLang = AppLanguage.systemDefault.rawValue
    @State private var showControls = true

    private var layout: HUDLayout { .init(rawValue: layoutRaw) ?? .glideFirst }
    private var palette: HUDPalette { .init(rawValue: paletteRaw) ?? .color }
    private var altRef: AltRef { .init(rawValue: altRefRaw) ?? .agl }

    var body: some View {
        HUDView(e: m.engine, layout: layout, palette: palette, altRef: altRef, lang: appLang)
            .onTapGesture { withAnimation { showControls.toggle() } }
            // A felső sáv (fázis + kistérkép) és az alsó vezérlőpanel eddig
            // ZStack-ben a mutatók FÖLÉ került, ezért a panel levágta a
            // számokat. A safeAreaInset viszont tényleges helyet foglal, így a
            // HUD a maradék területre igazodik középre — nem lóg egymásba.
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showControls {
                    controls.transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: showControls)
            .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.engine.phase.name(appLang).uppercased())
                            .font(.caption).bold().tracking(1.5)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(m.engine.phase.color.opacity(0.4)))
                            .foregroundStyle(palette.fg)
                        if !m.useLive, let l = m.cursorTimeLabel {
                            Text(l).font(.caption2).foregroundStyle(palette.dim)
                        }
                        if m.useLive, let f = m.engine.fix {
                            Text("\(f.numSV) \(loc("hud.satellite", appLang))")
                                .font(.caption2).foregroundStyle(palette.dim)
                        }
                    }
                    Spacer()
                    if showMap {
                        TrackMap(track: m.useLive ? nil : m.track,
                                 range: m.lo...max(m.lo + 1, m.hi), cursor: m.cursor,
                                 liveTrail: m.engine.trail, liveFix: m.engine.fix,
                                 compact: true)
                            .frame(width: 130, height: 130)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .allowsHitTesting(false)
                    }
                }.padding(12)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("", selection: $layoutRaw) {
                ForEach(HUDLayout.allCases) {
                    Label($0.name(appLang), systemImage: $0.icon).tag($0.rawValue)
                }
            }.pickerStyle(.segmented)

            HStack(spacing: 8) {
                Picker("", selection: $paletteRaw) {
                    ForEach(HUDPalette.allCases) { Text($0.name(appLang)).tag($0.rawValue) }
                }.pickerStyle(.segmented)
                Toggle("", isOn: $showMap).labelsHidden()
                Image(systemName: "map").font(.caption)
            }

            Picker("", selection: $altRefRaw) {
                ForEach(AltRef.allCases) { Text($0.name(appLang)).tag($0.rawValue) }
            }.pickerStyle(.segmented)

            if let t = m.track, !m.useLive {
                RangeBar(track: t, lo: $m.lo, hi: $m.hi, cursor: $m.cursor,
                         onUserScrub: { m.stop() })
                    .padding(.top, 6)
                    .onChange(of: m.cursor) { _, _ in m.showCursor() }
                    .onChange(of: m.lo) { _, _ in m.cursor = max(m.cursor, m.lo); m.showCursor() }
                    .onChange(of: m.hi) { _, _ in m.cursor = min(m.cursor, m.hi); m.showCursor() }
                PhaseLegend(lang: appLang)
            }

            HStack(spacing: 10) {
                if m.useLive {
                    Circle().frame(width: 8, height: 8)
                        .foregroundStyle(ble.state == .connected ? .green : .orange)
                    Text("\(loc("hud.live", appLang)) · \(ble.gnssPackets)").font(.caption)
                    Spacer()
                    Button(loc("hud.recording", appLang)) { m.useLive = false; m.showCursor() }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button(m.isPlaying ? loc("hud.stop", appLang) : loc("hud.play", appLang)) {
                        m.isPlaying ? m.stop() : m.play()
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                    Menu("\(Int(m.speed))x") {
                        ForEach([1.0, 2.0, 5.0, 10.0], id: \.self) { s in
                            Button("\(Int(s))x") { m.speed = s }
                        }
                    }.controlSize(.small)
                    Spacer()
                    Text(m.track?.name ?? "—").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding().background(.ultraThinMaterial)
    }
}

// MARK: - Elemzés fül

struct AnalysisTab: View {
    @ObservedObject var m: AppModel
    @ObservedObject var logbook: Logbook
    @AppStorage("app_language") private var appLang = AppLanguage.systemDefault.rawValue
    @State private var series: SeriesToggles = [.altitude, .vertical, .horizontal]
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    trackPicker

                    if let t = m.track {
                        notJumpWarning(t)

                        TrackMap(track: t, range: m.lo...max(m.lo + 1, m.hi),
                                 cursor: m.cursor, liveTrail: [], liveFix: nil)
                            .frame(height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                        PhaseLegend(lang: appLang).padding(.horizontal)

                        chips(Segment.allCases.map { $0.name(appLang) }) { i in
                            m.applyPreset(Segment.allCases[i])
                        }

                        seriesChips

                        VStack(alignment: .leading, spacing: 6) {
                            TimelineChart(track: t, range: m.lo...max(m.lo + 1, m.hi),
                                          cursor: Binding(
                                            get: { m.cursor },
                                            set: { m.cursor = $0; m.showCursor() }),
                                          series: series, lang: appLang,
                                          onScrubBegan: { m.stop() })
                            cursorReadout(t)
                        }.padding(.horizontal)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(loc("analysis.selectionHint", appLang))
                                .font(.caption2).foregroundStyle(.secondary)
                            RangeBar(track: t, lo: $m.lo, hi: $m.hi, cursor: $m.cursor,
                                     onUserScrub: { m.stop() })
                                .padding(.top, 6)
                                .onChange(of: m.cursor) { _, _ in m.showCursor() }
                                .onChange(of: m.lo) { _, _ in
                                    m.cursor = max(m.cursor, m.lo); m.showCursor() }
                                .onChange(of: m.hi) { _, _ in
                                    m.cursor = min(m.cursor, m.hi); m.showCursor() }
                            HStack { Text(rangeDuration(t)); Spacer(); Text(rangeAlt(t)) }
                                .font(.caption2).foregroundStyle(.secondary)
                        }.padding(.horizontal)

                        statsGrid(t)
                    } else {
                        Text(loc("analysis.noTrack", appLang))
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                }.padding(.vertical)
            }
            .navigationTitle(loc("nav.analysis", appLang))
            .sheet(isPresented: $showPicker) { trackPickerSheet }
        }
    }

    /// Fejlécsáv: mindig látható, mutatja a betöltött ugrást és a
    /// választóra nyit — innen érhető el az összes letöltött és minta track.
    private var trackPicker: some View {
        Button { showPicker = true } label: {
            HStack {
                Image(systemName: "chevron.down.circle.fill").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.track?.name ?? loc("analysis.pickTrack", appLang)).bold()
                        .foregroundStyle(.primary)
                    if let t = m.track {
                        Text(trackSubtitle(t)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(loc("analysis.switch", appLang)).font(.caption).foregroundStyle(.blue)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private func trackSubtitle(_ t: Track) -> String {
        var parts: [String] = []
        if let ex = t.exitIdx {
            parts.append("\(Int(t.agl(ex))) m \(loc("analysis.exit", appLang))")
        }
        parts.append("\(t.count) \(loc("analysis.samples", appLang))")
        return parts.joined(separator: " · ")
    }

    private var trackPickerSheet: some View {
        NavigationStack {
            List {
                Section(loc("analysis.builtin", appLang)) {
                    ForEach(SampleTrack.allCases) { s in
                        Button {
                            m.loadSample(s, appLang); showPicker = false
                        } label: {
                            HStack {
                                Image(systemName: "shippingbox").foregroundStyle(.secondary)
                                VStack(alignment: .leading) {
                                    Text(s.title(appLang))
                                    Text(s.subtitle(appLang)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if m.track?.name == s.title(appLang) {
                                    Image(systemName: "checkmark").foregroundStyle(.blue)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                }
                Section("\(loc("analysis.downloaded", appLang)) (\(logbook.entries.count))") {
                    if logbook.entries.isEmpty {
                        Text(loc("analysis.noDownloads", appLang))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(logbook.entries) { e in
                        Button {
                            if let t = logbook.load(e) {
                                m.setTrack(t)
                            } else {
                                let why = logbook.diagnose(e)
                                m.ble.logNote("Read failed: \(e.displayName) — \(why)")
                                m.toast = appLang == "hu"
                                    ? "Nem sikerült beolvasni: \(e.displayName) — \(why)"
                                    : "Couldn't read: \(e.displayName) — \(why)"
                            }
                            showPicker = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.displayName).bold()
                                    Text(e.subtitle(appLang)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if m.track?.name == e.displayName {
                                    Image(systemName: "checkmark").foregroundStyle(.blue)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(loc("nav.pickTrack", appLang))
            .toolbar { Button(loc("analysis.done", appLang)) { showPicker = false } }
        }
    }

    private func chips(_ titles: [String], action: @escaping (Int) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(titles.enumerated()), id: \.offset) { i, t in
                    Button(t) { action(i) }.buttonStyle(.bordered).controlSize(.small)
                }
            }.padding(.horizontal)
        }
    }

    private var seriesChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(SeriesToggles.all.enumerated()), id: \.offset) { _, item in
                    let on = series.contains(item.0)
                    Button {
                        if on { series.remove(item.0) } else { series.insert(item.0) }
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(item.2).frame(width: 8, height: 8)
                            Text(loc(item.1, appLang)).font(.caption)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(on ? item.2.opacity(0.25)
                                                      : Color.secondary.opacity(0.12)))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal)
        }
    }

    private func rangeDuration(_ t: Track) -> String {
        String(format: "%.0f \(loc("analysis.secLong", appLang))",
               t.samples[m.hi].t - t.samples[m.lo].t)
    }
    private func rangeAlt(_ t: Track) -> String {
        "\(Int(t.agl(m.lo))) → \(Int(t.agl(m.hi))) \(loc("analysis.rangeAGL", appLang))"
    }

    /// Földön bekapcsolt, ugrás nélküli felvételnél nincs mit elemezni:
    /// nincs kiugrás, a magasság és a sebesség is lényegében állandó. Ilyenkor
    /// szólunk, hogy ne a hibás grafikonokból próbáld kitalálni, mi történt.
    @ViewBuilder
    private func notJumpWarning(_ t: Track) -> some View {
        let dur = t.tEnd - t.t0
        if t.exitIdx == nil || dur < 5 {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(appLang == "hu"
                     ? "Ebben a felvételben nincs felismert ugrás "
                       + "(\(Int(dur)) mp, \(t.count) minta) — valószínűleg földi "
                       + "teszt. Az elemzés értékei ezért nem értelmesek."
                     : "No jump detected in this recording "
                       + "(\(Int(dur)) s, \(t.count) samples) — likely a ground "
                       + "test. Analysis values are not meaningful.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
        }
    }

    private func cursorReadout(_ t: Track) -> some View {
        let i: Int = min(max(m.cursor, 0), t.count - 1)
        let s: LiveGNSS = t.samples[i]
        let ph: FlightPhase = t.phase(atTime: s.t)
        let timeText: String = m.cursorTimeLabel ?? ""
        let altText: String = "\(Int(t.agl(i))) m"
        let vText: String = "\(Int(s.vSpeedKmh))"
        let hText: String = "\(Int(s.hSpeedKmh))"
        let grText: String = s.glideRatio.map { String(format: "%.2f", $0) } ?? "—"
        // Megtett táv a kijelölés kezdetétől a kurzorig — ugyanaz a lila szín,
        // mint a "Távolság" adatsoré a chart fölötti választóban.
        let dM: Double = t.distanceM(from: m.lo, to: i)
        let dText: String = dM < 1000 ? "\(Int(dM)) m"
                                      : String(format: "%.2f km", dM / 1000)
        return HStack(spacing: 10) {
            Text(timeText).bold()
            Text(ph.name(appLang)).font(.caption)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(ph.color.opacity(0.35)))
            Spacer()
            Text(altText).foregroundStyle(.gray)
            Text(vText).foregroundStyle(.green)
            Text(hText).foregroundStyle(.red)
            Text(grText).foregroundStyle(.cyan)
            Text(dText).foregroundStyle(.purple)
        }.font(.caption).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.7)
    }

    private func statsGrid(_ t: Track) -> some View {
        let st = t.stats(m.lo...max(m.lo + 1, m.hi))
        return LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
            stat(loc("stat.duration", appLang), String(format: "%.0f s", st.duration))
            stat(loc("stat.altLoss", appLang), "\(Int(st.altStart - st.altEnd)) m")
            stat(loc("stat.vMax", appLang), String(format: "%.0f km/h", st.vMax))
            stat(loc("stat.vAvg", appLang), String(format: "%.0f km/h", st.vAvg))
            stat(loc("stat.hMax", appLang), String(format: "%.0f km/h", st.hMax))
            stat(loc("stat.hAvg", appLang), String(format: "%.0f km/h", st.hAvg))
            stat(loc("stat.grAvg", appLang), st.grAvg.map { String(format: "%.2f", $0) } ?? "—")
            stat(loc("stat.grMax", appLang), st.grMax.map { String(format: "%.2f", $0) } ?? "—")
            stat(loc("stat.straightLine", appLang), String(format: "%.2f km", st.distance / 1000))
            stat(loc("stat.pathLength", appLang), String(format: "%.2f km", st.pathLength / 1000))
        }.padding(.horizontal)
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.title3).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Napló fül

// MARK: - Napló fül

struct LogbookTab: View {
    @ObservedObject var m: AppModel
    @ObservedObject var logbook: Logbook
    @AppStorage("app_language") private var appLang = AppLanguage.systemDefault.rawValue
    @State private var renaming: LogEntry?
    @State private var newName = ""
    @State private var showImporter = false

    /// Kívülről behozott trackek: a rendszer fájlválasztójával, bárhonnan.
    private var importSection: some View {
        Section {
            Button {
                showImporter = true
            } label: {
                Label(appLang == "hu" ? "CSV importálása a Fájlokból"
                                      : "Import CSV from Files",
                      systemImage: "square.and.arrow.down")
            }
        } header: {
            Text(appLang == "hu" ? "Saját fájlok" : "Your own files")
        } footer: {
            Text(appLang == "hu"
                 ? "Bárhonnan behozhatsz trackeket: iCloud Drive, Letöltések, "
                   + "másik app mappája. Egy bejegyzést hosszan nyomva a nyers "
                   + "CSV kimenthető vagy megosztható."
                 : "Import tracks from anywhere: iCloud Drive, Downloads, "
                   + "another app's folder. Long-press an entry to export or "
                   + "share its raw CSV.")
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.commaSeparatedText, .plainText, .data],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                var ok = 0
                for u in urls where logbook.importFile(at: u) != nil { ok += 1 }
                m.toast = appLang == "hu" ? "\(ok)/\(urls.count) fájl importálva"
                                          : "\(ok)/\(urls.count) file(s) imported"
            case .failure(let err):
                DiagLog.shared.log("Import error: \(err.localizedDescription)", "IMPORT")
                m.toast = appLang == "hu" ? "Az import nem sikerült"
                                          : "Import failed"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(loc("analysis.builtin", appLang)) {
                    ForEach(SampleTrack.allCases) { s in
                        Button { m.loadSample(s, appLang) } label: {
                            HStack {
                                Image(systemName: "shippingbox")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading) {
                                    Text(s.title(appLang))
                                    Text(s.subtitle(appLang)).font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if m.track?.name == s.title(appLang) {
                                    Image(systemName: "checkmark").foregroundStyle(.blue)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                }

                importSection

                Section {
                    if logbook.entries.isEmpty {
                        Text(loc("analysis.noDownloads", appLang))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(logbook.entries) { e in
                        Button {
                            if let t = logbook.load(e) {
                                m.setTrack(t)
                            } else {
                                let why = logbook.diagnose(e)
                                m.ble.logNote("Read failed: \(e.displayName) — \(why)")
                                m.toast = appLang == "hu"
                                    ? "Nem sikerült beolvasni: \(e.displayName) — \(why)"
                                    : "Couldn't read: \(e.displayName) — \(why)"
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.displayName).bold()
                                    Text(e.subtitle(appLang)).font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if m.track?.name == e.displayName {
                                    Image(systemName: "checkmark").foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { logbook.delete(e) } label: {
                                Label(loc("logbook.delete", appLang), systemImage: "trash")
                            }
                            Button {
                                renaming = e; newName = e.displayName
                            } label: {
                                Label(loc("nav.rename", appLang), systemImage: "pencil")
                            }.tint(.blue)
                        }
                        // A nyers CSV kimenthető a Fájlokba / megosztható —
                        // így egy nem elemezhető letöltés is megvizsgálható,
                        // és a fájl nem ragad bent az alkalmazásban.
                        .contextMenu {
                            ShareLink(item: logbook.fileURL(e)) {
                                Label(appLang == "hu" ? "Nyers CSV megosztása"
                                                      : "Share raw CSV",
                                      systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                } header: {
                    Text("\(loc("analysis.downloaded", appLang)) (\(logbook.entries.count))")
                } footer: {
                    if !logbook.entries.isEmpty {
                        Text("\(loc("logbook.storage", appLang)): "
                             + "\(logbook.totalBytes / 1024) kB · "
                             + loc("logbook.keptOnPhone", appLang))
                    }
                }
            }
            .navigationTitle(loc("nav.logbook", appLang))
            .alert(loc("nav.rename", appLang), isPresented: Binding(
                get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(loc("nav.rename", appLang), text: $newName)
                Button(loc("config.cancel", appLang), role: .cancel) { renaming = nil }
                Button(loc("generic.save", appLang)) {
                    if let e = renaming { logbook.rename(e, to: newName) }
                    renaming = nil
                }
            }
        }
    }
}

// MARK: - Konfigurátor

// MARK: - Konfigurátor

struct ConfigTab: View {
    @ObservedObject var m: AppModel
    @ObservedObject var config: FlySightConfig
    @ObservedObject var ble: FlySightBLE
    @AppStorage("app_language") private var appLang = AppLanguage.systemDefault.rawValue
    @State private var showRaw = false
    @State private var confirmUpload = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LanguagePicker(lang: $appLang)
                }

                Section {
                    HStack {
                        Image(systemName: m.configSourceIsDevice
                              ? "antenna.radiowaves.left.and.right" : "doc")
                        Text(config.displaySourceName(appLang))
                        Spacer()
                        if config.isDirty {
                            Text(loc("config.modified", appLang)).font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(.orange.opacity(0.3)))
                        }
                    }
                    if ble.state == .connected {
                        Button {
                            confirmUpload = true
                        } label: {
                            Label(loc("config.uploadToDevice", appLang),
                                  systemImage: "arrow.up.circle")
                        }
                        .disabled(!config.isDirty || ble.transfer.isActive)
                    } else {
                        Text(loc("config.needConnection", appLang))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(loc("config.viewRaw", appLang)) { showRaw = true }
                } header: { Text(loc("config.source", appLang)) }

                ForEach(ConfigSchema.groups) { group in
                    Section {
                        ForEach(group.fields) { f in
                            fieldRow(f)
                        }
                    } header: {
                        Label(group.title.t(appLang), systemImage: group.icon)
                    } footer: {
                        if let n = group.note {
                            Text(n.t(appLang)).font(.caption2)
                        }
                    }
                }

                alarmSection
            }
            .navigationTitle(loc("nav.config", appLang))
            .sheet(isPresented: $showRaw) {
                NavigationStack {
                    ScrollView {
                        Text(config.serialize())
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled).padding()
                    }
                    .navigationTitle(loc("nav.configRaw", appLang))
                    .toolbar { Button(loc("analysis.done", appLang)) { showRaw = false } }
                }
            }
            .alert(loc("config.uploadConfirmTitle", appLang), isPresented: $confirmUpload) {
                Button(loc("config.cancel", appLang), role: .cancel) {}
                Button(loc("config.upload", appLang)) {
                    ble.upload(text: config.serialize(),
                               toPath: ["CONFIG.TXT"], name: "CONFIG.TXT")
                }
            } message: {
                Text(loc("config.uploadConfirmMsg", appLang))
            }
        }
    }

    /// A mezők súgó szövege (ConfigSchema.help) jelenleg csak magyarul
    /// elérhető — ugyanezzel a loc()-mintával bővíthető, ha szükséges.
    @ViewBuilder
    private func fieldRow(_ f: ConfigField) -> some View {
        switch f.kind {
        case .options(let opts):
            VStack(alignment: .leading, spacing: 2) {
                Picker(f.title.t(appLang), selection: Binding(
                    get: { config.value(f.key) },
                    set: { config.set(f.key, $0) })) {
                    ForEach(opts, id: \.0) { Text($0.1.t(appLang)).tag($0.0) }
                }
                Text(f.help.t(appLang)).font(.caption2).foregroundStyle(.secondary)
            }
        case .int(let mn, let mx, let step, let unit):
            VStack(alignment: .leading, spacing: 4) {
                Stepper(value: Binding(
                    get: { config.value(f.key) },
                    set: { config.set(f.key, $0) }), in: mn...mx, step: step) {
                    HStack {
                        Text(f.title.t(appLang))
                        Spacer()
                        Text(unit.isEmpty ? "\(config.value(f.key))"
                                          : "\(config.value(f.key)) \(unit)")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text(f.help.t(appLang)).font(.caption2).foregroundStyle(.secondary)
                if f.key == "Min" || f.key == "Max", config.value("Mode") == 2 {
                    let ratio: String = String(format: "%.2f",
                                               Double(config.value(f.key)) / 100)
                    Text("\(loc("config.asGlideRatio", appLang)): \(ratio):1")
                        .font(.caption2).foregroundStyle(.blue)
                }
            }
        case .raw:
            Text(f.title.t(appLang))
        }
    }

    private var alarmSection: some View {
        Section {
            ForEach(config.alarms) { a in
                AlarmRow(alarm: a, dzElev: config.value("DZ_Elev"), lang: appLang) { updated in
                    config.updateAlarm(updated)
                }
                .swipeActions {
                    Button(role: .destructive) { config.removeAlarm(a) } label: {
                        Label(loc("logbook.delete", appLang), systemImage: "trash")
                    }
                }
            }
            Button { config.addAlarm() } label: {
                Label(loc("config.newAlarm", appLang), systemImage: "plus.circle")
            }
        } header: {
            Label(loc("config.alarms", appLang), systemImage: "bell.fill")
        } footer: {
            Text(alarmFooterText())
                .font(.caption2)
        }
    }

    private func alarmFooterText() -> String {
        let dz = config.value("DZ_Elev")
        let above1200 = dz + 1200
        if appLang == "hu" {
            return "A magasság az ugróhely szintje felett értendő. "
                + "Az ugróhelyed \(dz) méteren van, tehát "
                + "egy 1200 méteres riasztás \(above1200) m "
                + "tengerszint feletti magasságnál szól."
        } else {
            return "Altitude is measured above the drop zone. Your DZ is at "
                + "\(dz) m, so a 1200 m alarm fires at "
                + "\(above1200) m above sea level."
        }
    }
}

struct AlarmRow: View {
    let alarm: AlarmEntry
    let dzElev: Int
    let lang: String
    let onChange: (AlarmEntry) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation { expanded.toggle() } } label: {
                HStack {
                    Image(systemName: alarm.icon)
                        .foregroundStyle(alarm.type == 0 ? Color.secondary : Color.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(alarm.elevation) \(loc("analysis.rangeAGL", lang))").bold()
                        Text("\(alarm.typeName.t(lang)) · \(alarm.elevation + dzElev) "
                             + (lang == "hu" ? "m tszf" : "m MSL"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }.buttonStyle(.plain)

            if expanded {
                Stepper(value: Binding(
                    get: { alarm.elevation },
                    set: { var a = alarm; a.elevation = $0; onChange(a) }),
                        in: 0...6000, step: 50) {
                    Text("\(loc("config.altitudeLabel", lang)): \(alarm.elevation) m")
                }
                Picker(loc("config.signal", lang), selection: Binding(
                    get: { alarm.type },
                    set: { var a = alarm; a.type = $0; onChange(a) })) {
                    ForEach(AlarmEntry.types, id: \.0) { Text($0.1.t(lang)).tag($0.0) }
                }
                if alarm.type == 4 {
                    Stepper(value: Binding(
                        get: { alarm.file },
                        set: { var a = alarm; a.file = $0; onChange(a) }),
                            in: 0...99) {
                        Text("\(loc("config.fileNumber", lang)): \(alarm.file)")
                    }
                }
            }
        }
    }
}

// MARK: - FlySight fül

struct FlySightTab: View {
    @ObservedObject var m: AppModel
    @ObservedObject var ble: FlySightBLE
    /// Kell a figyeléshez, hogy a "már letöltve" jelzés azonnal frissüljön.
    @ObservedObject var logbook: Logbook
    @AppStorage("app_language") private var appLang = AppLanguage.systemDefault.rawValue
    @State private var renamingDevice: FlySightDevice?
    @State private var deviceNickname = ""

    /// Több FlySight is lehet a közelben: itt látszik mindegyik, és te döntöd
    /// el, melyikhez kapcsolódunk. A becenév csak az appban él — törölve
    /// visszaáll a gyári név, mert magán az eszközön semmit nem írunk át.
    private var devicesSection: some View {
        Section {
            if ble.devices.isEmpty {
                Text(appLang == "hu"
                     ? "Nincs eszköz a listában. Nyomd meg a Csatlakozást a kereséshez."
                     : "No devices yet. Tap Connect to start scanning.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ble.devices) { d in
                let isConnected = ble.connectedID == d.id
                Button {
                    ble.connect(to: d.id)
                } label: {
                    HStack {
                        Image(systemName: isConnected
                              ? "antenna.radiowaves.left.and.right"
                              : "dot.radiowaves.left.and.right")
                            .foregroundStyle(isConnected ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ble.displayName(d.id))
                                .fontWeight(isConnected ? .semibold : .regular)
                            HStack(spacing: 6) {
                                if ble.hasNickname(d.id) {
                                    Text(d.advertisedName)
                                }
                                if let r = d.rssi { Text("\(r) dBm") }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isConnected {
                            Image(systemName: "checkmark").foregroundStyle(.green)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isConnected || ble.transfer.isActive)
                .swipeActions {
                    Button {
                        renamingDevice = d
                        deviceNickname = ble.hasNickname(d.id) ? ble.displayName(d.id) : ""
                    } label: {
                        Label(loc("nav.rename", appLang), systemImage: "pencil")
                    }.tint(.blue)
                    if ble.hasNickname(d.id) {
                        Button {
                            ble.setNickname(nil, for: d.id)
                        } label: {
                            Label(appLang == "hu" ? "Gyári név" : "Default name",
                                  systemImage: "arrow.uturn.backward")
                        }.tint(.gray)
                    }
                    Button(role: .destructive) {
                        ble.forget(d.id)
                    } label: {
                        Label(appLang == "hu" ? "Elfelejtés" : "Forget",
                              systemImage: "trash")
                    }
                }
            }
            Button {
                ble.rescanDevices()
            } label: {
                Label(appLang == "hu" ? "Eszközök keresése újra" : "Scan again",
                      systemImage: "arrow.clockwise")
            }
        } header: {
            Text(appLang == "hu" ? "Eszközök" : "Devices")
        } footer: {
            Text(appLang == "hu"
                 ? "Automatikusan a legutóbb használt eszközhöz kapcsolódunk. "
                   + "A becenév csak ebben az appban él — a „Gyári név” "
                   + "visszaállítja a FlySight eredeti nevét."
                 : "We auto-connect to the device you used last. "
                   + "Nicknames live only in this app — “Default name” restores "
                   + "the FlySight's original name.")
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(loc("conn.title", appLang)) {
                    HStack {
                        Circle().frame(width: 9, height: 9)
                            .foregroundStyle(ble.state == .connected ? .green
                                             : (ble.state.isBusy ? .orange : .gray))
                        Text(ble.state.label(appLang))
                        Spacer()
                        if ble.state == .connected {
                            Button(loc("conn.disconnect", appLang)) { ble.stop() }
                                .buttonStyle(.bordered)
                        } else {
                            Button(loc("conn.connect", appLang)) { ble.start() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    if ble.state == .connected {
                        Toggle(loc("conn.liveToHud", appLang), isOn: $m.useLive)
                        HStack {
                            Text(loc("conn.gnssPacket", appLang)).foregroundStyle(.secondary)
                            Spacer(); Text("\(ble.gnssPackets)").monospacedDigit()
                        }
                    }
                }

                devicesSection

                if ble.transfer.isActive {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(ble.transfer.label(appLang)).font(.caption)
                            ProgressView(value: ble.progress)
                            HStack {
                                Text("\(Int(ble.progress * 100))%").font(.caption2)
                                Spacer()
                                Button(loc("conn.cancel", appLang)) { ble.cancelTransfer() }
                                    .font(.caption)
                            }
                        }
                    }
                }

                if ble.state == .connected {
                    Section(loc("conn.filesOnDevice", appLang)) {
                        HStack {
                            Button { ble.goRoot() } label: {
                                Image(systemName: "house")
                            }.disabled(ble.path.isEmpty)
                            Button { ble.goUp() } label: {
                                Image(systemName: "chevron.up")
                            }.disabled(ble.path.isEmpty)
                            Spacer()
                            Text(ble.pathString).font(.caption)
                                .foregroundStyle(.secondary).lineLimit(1)
                            Button { ble.listDirectory() } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }.buttonStyle(.bordered).controlSize(.small)

                        if ble.isListing && ble.entries.isEmpty {
                            HStack {
                                ProgressView()
                                Text(loc("conn.listing", appLang)).font(.caption)
                            }
                        }

                        ForEach(ble.entries) { e in
                            let remote = "/" + (ble.path + [e.name]).joined(separator: "/")
                            let already = !e.isDirectory
                                && logbook.isDownloaded(remotePath: remote)
                            Button {
                                e.isDirectory ? ble.enter(e) : ble.download(e)
                            } label: {
                                HStack {
                                    Image(systemName: e.icon)
                                        .foregroundStyle(e.isDirectory ? Color.blue
                                                         : (e.isConfig ? Color.orange
                                                            : Color.secondary))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(e.name)
                                        if !e.isDirectory {
                                            Text(already
                                                 ? e.subtitle + " · "
                                                   + (appLang == "hu" ? "már letöltve"
                                                                      : "already downloaded")
                                                 : e.subtitle)
                                                .font(.caption2)
                                                .foregroundStyle(already ? .green : .secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: e.isDirectory ? "chevron.right"
                                          : (already ? "checkmark.circle.fill"
                                                     : "arrow.down.circle"))
                                        .foregroundStyle(e.isDirectory ? Color.gray
                                                        : (already ? Color.green : Color.blue))
                                }
                            }
                            .buttonStyle(.plain)
                            // A már letöltött felvételt nem töltjük le újra —
                            // így nem keletkezik duplikált naplóbejegyzés.
                            .disabled(ble.transfer.isActive || already)
                        }
                    }
                }

                Section {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostic log",
                              systemImage: "doc.text.magnifyingglass")
                    }
                } footer: {
                    Text(appLang == "hu"
                         ? "A letöltés, mentés és beolvasás minden lépése ide kerül."
                         : "Every download, save and read step is logged here.")
                }
            }
            .navigationTitle(loc("nav.flysight", appLang))
            .alert(appLang == "hu" ? "Eszköz átnevezése" : "Rename device",
                   isPresented: Binding(get: { renamingDevice != nil },
                                        set: { if !$0 { renamingDevice = nil } })) {
                TextField(appLang == "hu" ? "Becenév" : "Nickname",
                          text: $deviceNickname)
                Button(loc("config.cancel", appLang), role: .cancel) {
                    renamingDevice = nil
                }
                if let d = renamingDevice, ble.hasNickname(d.id) {
                    Button(appLang == "hu" ? "Gyári név" : "Default name") {
                        ble.setNickname(nil, for: d.id)
                        renamingDevice = nil
                    }
                }
                Button(loc("generic.save", appLang)) {
                    if let d = renamingDevice {
                        ble.setNickname(deviceNickname, for: d.id)
                    }
                    renamingDevice = nil
                }
            } message: {
                Text(appLang == "hu"
                     ? "Csak ebben az appban jelenik meg. Üresen hagyva visszaáll "
                       + "a gyári név."
                     : "Shown only in this app. Leave empty to restore the "
                       + "original name.")
            }
        }
    }
}

// MARK: - Diagnosztikai napló

struct DiagnosticsView: View {
    @ObservedObject private var diag = DiagLog.shared
    @AppStorage("app_language") private var appLang = AppLanguage.systemDefault.rawValue
    @State private var copied = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(diag.lines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(color(for: line))
                            .id(i)
                    }
                }
                .padding(8)
            }
            .onAppear { proxy.scrollTo(diag.lines.count - 1, anchor: .bottom) }
            .onChange(of: diag.lines.count) { _, n in
                withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: diag.fileURL) {
                    Image(systemName: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.string = diag.text
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                Button(role: .destructive) { diag.clear() } label: {
                    Image(systemName: "trash")
                }
            }
        }
    }

    /// A hibás sorok kiemelése, hogy ne kelljen keresgélni.
    private func color(for line: String) -> Color {
        let l = line.uppercased()
        if l.contains("FAILED") || l.contains("ERROR") || l.contains("INCOMPLETE")
            || l.contains("NAK") || l.contains("ABORTED") { return .red }
        if l.contains("[SAVE]") || l.contains("[READ]") { return .primary }
        return .secondary
    }
}

// MARK: - Gyökér

// MARK: - Gyökér

struct ContentView: View {
    @StateObject private var m = AppModel()
    @AppStorage("app_language") private var appLang = AppLanguage.systemDefault.rawValue

    var body: some View {
        TabView {
            HUDTab(m: m, ble: m.ble)
                .tabItem { Label(loc("tab.hud", appLang), systemImage: "gauge.medium") }
            AnalysisTab(m: m, logbook: m.logbook)
                .tabItem { Label(loc("tab.analysis", appLang), systemImage: "chart.xyaxis.line") }
            LogbookTab(m: m, logbook: m.logbook)
                .tabItem { Label(loc("tab.logbook", appLang), systemImage: "book.closed") }
            ConfigTab(m: m, config: m.config, ble: m.ble)
                .tabItem { Label(loc("tab.config", appLang), systemImage: "slider.horizontal.3") }
            FlySightTab(m: m, ble: m.ble, logbook: m.logbook)
                .tabItem {
                    Label(loc("tab.device", appLang),
                          systemImage: "antenna.radiowaves.left.and.right")
                }
        }
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let t = m.toast {
                Text(t).font(.caption).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .padding(.top, 8)
                    .task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        m.toast = nil
                    }
            }
        }
    }
}

@main
struct FlySightApp: App {
    init() {
        // Rögtön indításkor írunk a naplóba, így a Documents mappa biztosan
        // nem üres — csak akkor jelenik meg az app a Fájlok appban
        // (Saját iPhone → FlySight Explorer), ha van benne fájl.
        DiagLog.shared.log("=== FlySight Explorer starting ===", "APP")
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
