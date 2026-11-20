//
//  ContentView.swift  —  FlySight HUD + Analyzer (iOS)
//  Four tabs: HUD, Analysis, Logbook, FlySight (connection + configurator)
//
//  SETUP
//    Xcode > iOS App (SwiftUI); delete the generated <Project>App.swift.
//    Target > Info: Privacy - Bluetooth Always Usage Description
//    Files in the project: Model.swift, FlySightBLE.swift, Logbook.swift,
//    FlySightConfig.swift, ContentView.swift
//    Drag into the bundle: SAMPLE_WINGSUIT.csv, SAMPLE_TRACKING.csv
//

import SwiftUI
import Combine
import MapKit
import Charts
import CoreLocation
import UIKit          // UIPasteboard — copying the log to the clipboard
import UniformTypeIdentifiers   // UTType — CSV import from Files

// MARK: - App state

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
                // We always save the raw CSV — the "too short / incomplete"
                // case is only decided at display time (Track.parse); it does not
                // block the download/save itself.
                guard let e = s.logbook.save(text: text, remotePath: remote,
                                             suggestedName: name) else {
                    // This is a real I/O error (e.g. disk full, missing write permission) —
                    // this is the actual "could not save" case.
                    s.ble.logNote("Save failed (I/O error): \(name) (\(text.utf8.count) bytes)")
                    s.toast = (s.lang == "en" ? "Couldn't save: " : "Nem sikerült elmenteni: ")
                        + name
                    return
                }
                guard let t = s.logbook.load(e) else {
                    // The file is on disk and in the logbook too — there just aren't
                    // enough GNSS samples to display (short recording or incomplete
                    // download). That only turns out here, at display time.
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
        #if DEBUG
        if let s = ScreenshotMode.secondsAfterExit, let t = track {
            let exit = t.samples[t.exitIdx ?? 0].t
            cursor = min(max(t.index(atTime: exit + s), lo), hi)
            showCursor()
        }
        #endif
    }

    /// The current language — the same key the views read with @AppStorage.
    /// AppModel is not a View, so it reads UserDefaults directly.
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
        // The `.common` run loop mode is needed: a `scheduledTimer` in the default
        // mode stops while the user is scrolling or holding a control,
        // which is why playback seemed to advance only one step per tap.
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

// MARK: - HUD elements

struct Metric: View {
    let v: String, u: String, size: CGFloat, c: Color, d: Color
    var body: some View {
        VStack(spacing: 2) {
            Text(v).font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(c)
                // Long values (e.g. 4-digit altitude) used to get truncated —
                // better to scale them down than let them run off the screen.
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

// MARK: - Map

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

    /// Without animation and only on meaningful movement, otherwise fast
    /// scrubbing triggers SwiftUI animation warnings.
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

// MARK: - Range bar

struct RangeBar: View {
    let track: Track
    @Binding var lo: Int
    @Binding var hi: Int
    @Binding var cursor: Int
    /// Called when the USER moves the cursor/handle. Playback should only be
    /// stopped in that case — `onChange(of: cursor)` is no good for this,
    /// because it also fires on playback's own stepping and stops it immediately.
    var onUserScrub: (() -> Void)? = nil
    private let h: CGFloat = 46

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let n = max(1, track.count - 1)
            // Indices clamped to 0…n so that a bad cursor/selection
            // cannot draw outside the frame.
            let xLo = CGFloat(min(max(lo, 0), n)) / CGFloat(n) * w
            let xHi = CGFloat(min(max(hi, 0), n)) / CGFloat(n) * w
            let xCur = CGFloat(min(max(cursor, 0), n)) / CGFloat(n) * w

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(track.bands) { b in
                        // For a zero-length track the denominator was ~0, so `frac`
                        // blew up and the bars pushed out the frame. Now clamped.
                        let total = track.tEnd - track.t0
                        let frac = total > 0.001
                            ? min(1, max(0, (b.t1 - b.t0) / total)) : 0
                        b.phase.color.opacity(0.4).frame(width: w * frac)
                    }
                }
                .frame(width: w, height: h, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // The altitude profile normalized to the bar's own scale. `f` MUST
                // be CLAMPED to 0…1 and the Path must be CLIPPED: for a ground
                // (no-jump) track the values ran outside the frame, and the drawing
                // spread across the whole page as long gray/white
                // lines.
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

                // With a short (few-sample) recording the ±5 could produce a negative
                // index or one past the sample count — clamped to 0…n.
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

    /// The handle's visible stripe is 5 pt, but its hit area is 30 pt — so the
    /// group is 30 wide and the stripe sits in ITS center. Because of this, with an
    /// `x - 2.5` offset the stripe ended up 12.5 pt to the right of the selection edge
    /// (that is why the yellow cursor got "ahead of" the handle, and the end
    /// could not be dragged all the way). The group must be offset by half: `x - 15`.
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
        // The gesture must measure in the BAR's coordinate space, not the handle's —
        // otherwise `location.x` is a value between 0…30, and due to the `/ w` division
        // the handle jumped to the start of the bar.
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { v in
                onUserScrub?()
                let f = max(0, min(1, v.location.x / w))
                set(Int(f * CGFloat(n)))
            })
    }
}

// MARK: - Timeline chart

struct SeriesToggles: OptionSet {
    let rawValue: Int
    static let altitude = SeriesToggles(rawValue: 1 << 0)
    static let vertical = SeriesToggles(rawValue: 1 << 1)
    static let horizontal = SeriesToggles(rawValue: 1 << 2)
    static let glide = SeriesToggles(rawValue: 1 << 3)
    static let distance = SeriesToggles(rawValue: 1 << 4)
    /// (option, localization key, color)
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
    /// Called when the user starts scrubbing the chart — playback
    /// must be stopped in that case.
    var onScrubBegan: (() -> Void)? = nil


    /// Filters out non-finite values — a bad sample (NaN/inf) would otherwise
    /// break the Swift Charts drawing.
    private func safe(_ v: Double) -> Double { v.isFinite ? v : 0 }

    /// Length of the visible time range. At least 1 s for a zero-length (ground)
    /// track, otherwise the axis degenerates and the drawing breaks down.
    private var span: Double {
        guard !track.samples.isEmpty else { return 1 }
        let s = track.samples[safeRange.upperBound].t - t0
        return s.isFinite && s > 0.5 ? s : 1
    }

    /// The given range clamped to the actual bounds of the samples — an old
    /// selection (from another, longer track) would otherwise crash with an index error.
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

    /// Cumulative distance covered in kilometers, aligned to the points of pts.
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

    /// Speed (km/h) and glide ratio (a ratio) — their natural ranges roughly
    /// coincide, so they share an axis with real values.
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

    /// Altitude (m) and distance covered (km) — in real units, each on its own axis.
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

    /// Tap = place the cursor there; drag = cursor follows, but ONLY if the
    /// movement is mostly horizontal. That way up/down drags go to the ScrollView,
    /// and the Analysis tab finally scrolls normally over the charts too.
    /// Sets the cursor to the given on-screen x position of the chart.
    private func moveCursor(_ proxy: ChartProxy, _ rect: CGRect, toX x: CGFloat) {
        guard let t: Double = proxy.value(atX: x - rect.minX) else { return }
        let idx = track.index(atTime: t + t0)
        let clamped = min(max(idx, safeRange.lowerBound), safeRange.upperBound)
        // We only write state on an actual change: unnecessary redraws are
        // what floods the console with SwiftUI animation warnings.
        guard clamped != cursor else { return }
        var tx = Transaction(); tx.disablesAnimations = true
        withTransaction(tx) { cursor = clamped }
    }

    private func dragOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            if let plot = proxy.plotFrame {
                let rect = geo[plot]
                // UIKit pan gesture (see ScrubOverlay.swift): horizontal
                // scrubbing AND preserved up/down scrolling. This can't be done
                // with SwiftUI gestures, because they capture the touch
                // on press.
                ScrubOverlay(
                    onScrub: { x in moveCursor(proxy, rect, toX: x) },
                    onBegan: { onScrubBegan?() },
                    onTap: { x in moveCursor(proxy, rect, toX: x) }
                )
            }
        }
    }
}

// MARK: - HUD tab

// MARK: - HUD tab

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
            // The top bar (phase + mini map) and the bottom control panel used to sit
            // in a ZStack ABOVE the gauges, so the panel cut off the
            // numbers. safeAreaInset, however, takes up actual space, so the
            // HUD centers itself in the remaining area — nothing overlaps.
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

// MARK: - Analysis tab

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

    /// Header bar: always visible, shows the loaded jump and opens the
    /// picker — all downloaded and sample tracks are reachable from here.
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

    /// For a recording switched on on the ground with no jump there is nothing to analyze:
    /// there is no exit, and altitude and speed are essentially constant. In that case
    /// we say so, so you don't try to figure out what happened from broken charts.
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
        // Distance covered from the start of the selection to the cursor — the same purple
        // as the "Distance" series in the picker above the chart.
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

// MARK: - Logbook tab

// MARK: - Logbook tab

struct LogbookTab: View {
    @ObservedObject var m: AppModel
    @ObservedObject var logbook: Logbook
    @AppStorage("app_language") private var appLang = AppLanguage.systemDefault.rawValue
    @State private var renaming: LogEntry?
    @State private var newName = ""
    @State private var showImporter = false

    /// Tracks brought in from outside: via the system file picker, from anywhere.
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
                        // The raw CSV can be exported to Files / shared —
                        // so even a download that can't be analyzed can be inspected,
                        // and the file doesn't get stuck inside the app.
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

// MARK: - Configurator

// MARK: - Configurator

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

    /// The fields' help text (ConfigSchema.help) is currently only available
    /// in Hungarian — it can be extended with the same loc() pattern if needed.
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

// MARK: - FlySight tab

struct FlySightTab: View {
    @ObservedObject var m: AppModel
    @ObservedObject var ble: FlySightBLE
    /// Needed for observation, so the "already downloaded" indicator updates immediately.
    @ObservedObject var logbook: Logbook
    @AppStorage("app_language") private var appLang = AppLanguage.systemDefault.rawValue
    @State private var renamingDevice: FlySightDevice?
    @State private var deviceNickname = ""

    /// There may be several FlySights nearby: all of them show up here, and you decide
    /// which one we connect to. The nickname lives only in the app — deleting it
    /// restores the factory name, since we don't change anything on the device itself.
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
                            // An already-downloaded recording is not downloaded again —
                            // so no duplicate logbook entry is created.
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

// MARK: - Diagnostic log

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

    /// Highlights the error lines so you don't have to search for them.
    private func color(for line: String) -> Color {
        let l = line.uppercased()
        if l.contains("FAILED") || l.contains("ERROR") || l.contains("INCOMPLETE")
            || l.contains("NAK") || l.contains("ABORTED") { return .red }
        if l.contains("[SAVE]") || l.contains("[READ]") { return .primary }
        return .secondary
    }
}

// MARK: - Root

// MARK: - Root

#if DEBUG
/// Launch arguments for producing App Store screenshots. Debug builds only —
/// none of this is compiled into the App Store build.
///
///   -screenshotTab 0…4             open this tab (0 = HUD … 4 = Device)
///   -screenshotSecondsAfterExit N  put the playback cursor N s after exit
///   -screenshotHideStatusBar YES   hide the status bar
///
/// Stored settings can be overridden the same way, e.g. `-app_language en`
/// or `-hud_layout <raw value>`.
enum ScreenshotMode {
    private static let d = UserDefaults.standard
    static var tab: Int { d.integer(forKey: "screenshotTab") }
    static var secondsAfterExit: Double? {
        d.object(forKey: "screenshotSecondsAfterExit") == nil
            ? nil : d.double(forKey: "screenshotSecondsAfterExit")
    }
    static var hideStatusBar: Bool { d.bool(forKey: "screenshotHideStatusBar") }
}
#endif

struct ContentView: View {
    @StateObject private var m = AppModel()
    @AppStorage("app_language") private var appLang = AppLanguage.systemDefault.rawValue
    #if DEBUG
    @State private var tab = ScreenshotMode.tab
    private let hideStatusBar = ScreenshotMode.hideStatusBar
    #else
    @State private var tab = 0
    private let hideStatusBar = false
    #endif

    var body: some View {
        TabView(selection: $tab) {
            HUDTab(m: m, ble: m.ble)
                .tabItem { Label(loc("tab.hud", appLang), systemImage: "gauge.medium") }
                .tag(0)
            AnalysisTab(m: m, logbook: m.logbook)
                .tabItem { Label(loc("tab.analysis", appLang), systemImage: "chart.xyaxis.line") }
                .tag(1)
            LogbookTab(m: m, logbook: m.logbook)
                .tabItem { Label(loc("tab.logbook", appLang), systemImage: "book.closed") }
                .tag(2)
            ConfigTab(m: m, config: m.config, ble: m.ble)
                .tabItem { Label(loc("tab.config", appLang), systemImage: "slider.horizontal.3") }
                .tag(3)
            FlySightTab(m: m, ble: m.ble, logbook: m.logbook)
                .tabItem {
                    Label(loc("tab.device", appLang),
                          systemImage: "antenna.radiowaves.left.and.right")
                }
                .tag(4)
        }
        .statusBarHidden(hideStatusBar)
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
        // We write to the log right at launch, so the Documents folder is never
        // empty — the app only shows up in the Files app
        // (On My iPhone → FlySight Explorer) if it contains a file.
        DiagLog.shared.log("=== FlySight Explorer starting ===", "APP")
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
