//
//  FlySightConfig.swift
//  Reading, editing and writing back CONFIG.TXT.
//
//  The parser preserves comments and ordering: the file stays readable,
//  and unknown keys pass through untouched.
//
//  IMPORTANT: the meaning of Win_Top / Win_Bottom is uncertain. According
//  to the FlySight docs, this is the altitude band where audio is ENABLED,
//  not where it is muted. Verify it by hand on the ground before relying
//  on it during a jump. The UI therefore also shows a warning.
//

import SwiftUI
import Combine

// MARK: - File representation

/// One line in CONFIG.TXT. Comment and blank lines are kept untouched.
enum ConfigLine {
    case comment(String)
    case blank
    case pair(key: String, value: String, trailingComment: String?)
}

// MARK: - Bilingual labels

/// Bilingual label. The configurator texts used to be hard-coded in Hungarian,
/// so they showed up in Hungarian even in English.
struct CfgText {
    let hu: String
    let en: String
    func t(_ lang: String) -> String { lang == "en" ? en : hu }
}

// MARK: - Schema

enum ConfigKind {
    case int(min: Int, max: Int, step: Int, unit: String)
    case options([(Int, CfgText)])
    case raw
}

struct ConfigField: Identifiable {
    let key: String
    let title: CfgText
    let help: CfgText
    let kind: ConfigKind
    var id: String { key }
}

struct ConfigGroup: Identifiable {
    let title: CfgText
    let icon: String
    let note: CfgText?
    let fields: [ConfigField]
    var id: String { title.hu }
}

/// Audio mapping and speech modes — FlySight uses the same list
/// for the Mode, Mode_2 and Sp_Mode keys.
let measurementModes: [(Int, CfgText)] = [
    (0, CfgText(hu: "Vízszintes sebesség", en: "Horizontal speed")),
    (1, CfgText(hu: "Függőleges sebesség", en: "Vertical speed")),
    (2, CfgText(hu: "Siklószám (glide ratio)", en: "Glide ratio")),
    (3, CfgText(hu: "Fordított siklószám", en: "Inverse glide ratio")),
    (4, CfgText(hu: "Teljes sebesség", en: "Total speed")),
    (11, CfgText(hu: "Merülési szög", en: "Dive angle")),
]

enum ConfigSchema {

    static let groups: [ConfigGroup] = [

        ConfigGroup(title: CfgText(hu: "GPS", en: "GPS"),
            icon: "location.fill", note: nil, fields: [
            ConfigField(key: "Model",
                title: CfgText(hu: "Mozgásmodell", en: "Dynamic model"),
                help: CfgText(
                    hu: "A GPS vevő dinamikai modellje. Ejtőernyőzéshez a nagy "
                        + "gyorsulást tűrő légi módok kellenek.",
                    en: "The dynamic model of the GPS receiver. For skydiving you "
                        + "need the airborne modes that tolerate high acceleration."),
                kind: .options([
                    (0, CfgText(hu: "Hordozható", en: "Portable")),
                    (2, CfgText(hu: "Álló", en: "Stationary")),
                    (3, CfgText(hu: "Gyalogos", en: "Pedestrian")),
                    (4, CfgText(hu: "Autó", en: "Automotive")),
                    (5, CfgText(hu: "Vízi", en: "Sea")),
                    (6, CfgText(hu: "Légi < 1 g", en: "Airborne < 1 g")),
                    (7, CfgText(hu: "Légi < 2 g", en: "Airborne < 2 g")),
                    (8, CfgText(hu: "Légi < 4 g", en: "Airborne < 4 g"))])),
            ConfigField(key: "Rate",
                title: CfgText(hu: "Mérési gyakoriság", en: "Measurement rate"),
                help: CfgText(
                    hu: "Milliszekundum két mérés között. 200 ms = 5 mérés "
                        + "másodpercenként. Kisebb érték pontosabb, de több áramot "
                        + "fogyaszt.",
                    en: "Milliseconds between two measurements. 200 ms = 5 "
                        + "measurements per second. A lower value is more accurate "
                        + "but uses more power."),
                kind: .int(min: 100, max: 1000, step: 100, unit: "ms")),
        ]),

        ConfigGroup(title: CfgText(hu: "Hangmagasság", en: "Tone pitch"),
            icon: "speaker.wave.2.fill",
            note: CfgText(
                hu: "A hang magassága a mért érték szerint változik. A Min és Max "
                    + "közötti sávot képezi le a legmélyebb és legmagasabb hangra. "
                    + "Siklószámnál az érték 100-szorosát kell megadni: 250 = 2,5:1.",
                en: "The pitch of the tone follows the measured value. The band "
                    + "between Min and Max is mapped to the lowest and highest "
                    + "pitch. For glide ratio enter 100 times the value: "
                    + "250 = 2.5:1."),
            fields: [
            ConfigField(key: "Mode",
                title: CfgText(hu: "Mit jelez a hangmagasság",
                               en: "What the pitch indicates"),
                help: CfgText(hu: "Ez az érték határozza meg a hang magasságát.",
                              en: "This value determines the pitch of the tone."),
                kind: .options(measurementModes)),
            ConfigField(key: "Min",
                title: CfgText(hu: "Alsó határ", en: "Lower limit"),
                help: CfgText(
                    hu: "Ennél az értéknél szól a legmélyebb hang. Siklószámnál "
                        + "100-szoros érték: 50 = 0,5:1.",
                    en: "The lowest tone sounds at this value. For glide ratio "
                        + "enter 100 times the value: 50 = 0.5:1."),
                kind: .int(min: 0, max: 4000, step: 10, unit: "")),
            ConfigField(key: "Max",
                title: CfgText(hu: "Felső határ", en: "Upper limit"),
                help: CfgText(
                    hu: "Ennél az értéknél szól a legmagasabb hang. "
                        + "Siklószámnál 250 = 2,5:1.",
                    en: "The highest tone sounds at this value. For glide ratio "
                        + "250 = 2.5:1."),
                kind: .int(min: 0, max: 4000, step: 10, unit: "")),
            ConfigField(key: "Limits",
                title: CfgText(hu: "Határon túl", en: "Out of range"),
                help: CfgText(
                    hu: "Mi történjék, ha a mért érték kilép a Min–Max sávból.",
                    en: "What happens when the measured value leaves the Min–Max "
                        + "band."),
                kind: .options([
                    (0, CfgText(hu: "Elnémul", en: "Mute")),
                    (1, CfgText(hu: "A szélső hangon marad",
                                en: "Hold the limit tone")),
                    (2, CfgText(hu: "Körbefordul", en: "Wrap around"))])),
            ConfigField(key: "Volume",
                title: CfgText(hu: "Hangerő", en: "Volume"),
                help: CfgText(hu: "0 = néma, 8 = maximum.",
                              en: "0 = silent, 8 = maximum."),
                kind: .int(min: 0, max: 8, step: 1, unit: "")),
        ]),

        ConfigGroup(title: CfgText(hu: "Hangismétlés", en: "Tone rate"),
            icon: "metronome.fill",
            note: CfgText(
                hu: "A második mért érték a hang ismétlési gyakoriságát szabályozza, "
                    + "így egyszerre két adat követhető. Ha nem kell, állítsd a "
                    + "sebességet fixre.",
                en: "A second measured value controls how often the tone repeats, "
                    + "so you can follow two readings at once. If you do not need "
                    + "it, set the rate to a fixed value."),
            fields: [
            ConfigField(key: "Mode_2",
                title: CfgText(hu: "Mit jelez az ismétlés",
                               en: "What the tone rate indicates"),
                help: CfgText(
                    hu: "Ez az érték szabja meg, milyen gyakran szólal meg a hang.",
                    en: "This value determines how often the tone sounds."),
                kind: .options(measurementModes)),
            ConfigField(key: "Min_Val_2",
                title: CfgText(hu: "Alsó határ", en: "Lower limit"),
                help: CfgText(hu: "Ennél az értéknél a leglassabb az ismétlés.",
                              en: "The tone repeats slowest at this value."),
                kind: .int(min: 0, max: 4000, step: 10, unit: "")),
            ConfigField(key: "Max_Val_2",
                title: CfgText(hu: "Felső határ", en: "Upper limit"),
                help: CfgText(hu: "Ennél az értéknél a leggyorsabb az ismétlés.",
                              en: "The tone repeats fastest at this value."),
                kind: .int(min: 0, max: 4000, step: 10, unit: "")),
            ConfigField(key: "Min_Rate",
                title: CfgText(hu: "Leglassabb ismétlés", en: "Slowest tone rate"),
                help: CfgText(
                    hu: "Századmásodpercenkénti hang. 50 = félmásodpercenként.",
                    en: "Tone rate in hundredths. 50 = one tone every half second."),
                kind: .int(min: 0, max: 1000, step: 10, unit: "")),
            ConfigField(key: "Max_Rate",
                title: CfgText(hu: "Leggyorsabb ismétlés", en: "Fastest tone rate"),
                help: CfgText(hu: "400 = négyszer másodpercenként.",
                              en: "400 = four tones per second."),
                kind: .int(min: 0, max: 1000, step: 10, unit: "")),
            ConfigField(key: "Flatline",
                title: CfgText(hu: "Folytonos hang", en: "Flatline tone"),
                help: CfgText(
                    hu: "Bekapcsolva a leglassabb ismétlés helyett folyamatos hang "
                        + "szól.",
                    en: "When on, a continuous tone sounds instead of the slowest "
                        + "tone rate."),
                kind: .options([(0, CfgText(hu: "Ki", en: "Off")),
                                (1, CfgText(hu: "Be", en: "On"))])),
        ]),

        ConfigGroup(title: CfgText(hu: "Bemondás", en: "Speech"),
            icon: "waveform",
            note: CfgText(
                hu: "Az eszköz szóban is bemondja a kiválasztott értéket.",
                en: "The device also announces the selected value out loud."),
            fields: [
            ConfigField(key: "Sp_Rate",
                title: CfgText(hu: "Bemondás gyakorisága", en: "Speech rate"),
                help: CfgText(
                    hu: "Másodperc két bemondás között. 0 = nincs bemondás.",
                    en: "Seconds between two announcements. 0 = no speech."),
                kind: .int(min: 0, max: 60, step: 1, unit: "s")),
            ConfigField(key: "Sp_Mode",
                title: CfgText(hu: "Mit mondjon be", en: "What to announce"),
                help: CfgText(hu: "A bemondott érték típusa.",
                              en: "The type of value announced."),
                kind: .options(measurementModes)),
            ConfigField(key: "Sp_Units",
                title: CfgText(hu: "Mértékegység", en: "Units"),
                help: CfgText(hu: "A bemondott sebesség mértékegysége.",
                              en: "Unit of the announced speed."),
                kind: .options([(0, CfgText(hu: "km/h", en: "km/h")),
                                (1, CfgText(hu: "mph", en: "mph"))])),
            ConfigField(key: "Sp_Dec",
                title: CfgText(hu: "Tizedesjegyek", en: "Decimal places"),
                help: CfgText(
                    hu: "Hány tizedesjegyet mondjon. Siklószámnál 1 hasznos.",
                    en: "How many decimal places to announce. 1 is useful for "
                        + "glide ratio."),
                kind: .int(min: 0, max: 2, step: 1, unit: "")),
            ConfigField(key: "Sp_Volume",
                title: CfgText(hu: "Bemondás hangereje", en: "Speech volume"),
                help: CfgText(hu: "0 = néma, 8 = maximum.",
                              en: "0 = silent, 8 = maximum."),
                kind: .int(min: 0, max: 8, step: 1, unit: "")),
        ]),

        ConfigGroup(title: CfgText(hu: "Küszöbök", en: "Thresholds"),
            icon: "dial.min.fill",
            note: CfgText(
                hu: "A hang csak akkor szól, ha a sebesség eléri ezeket a "
                    + "küszöböket. Így nem sípol a földön és a repülőben.",
                en: "The tone only sounds once the speed reaches these thresholds, "
                    + "so it does not beep on the ground or in the aircraft."),
            fields: [
            ConfigField(key: "V_Thresh",
                title: CfgText(hu: "Függőleges küszöb", en: "Vertical threshold"),
                help: CfgText(
                    hu: "Centiméter/másodperc. 1000 = 10 m/s = 36 km/h süllyedés.",
                    en: "Centimeters per second. 1000 = 10 m/s = 36 km/h descent."),
                kind: .int(min: 0, max: 10000, step: 100, unit: "cm/s")),
            ConfigField(key: "H_Thresh",
                title: CfgText(hu: "Vízszintes küszöb", en: "Horizontal threshold"),
                help: CfgText(
                    hu: "Centiméter/másodperc. 0 = nincs vízszintes küszöb.",
                    en: "Centimeters per second. 0 = no horizontal threshold."),
                kind: .int(min: 0, max: 10000, step: 100, unit: "cm/s")),
            ConfigField(key: "Use_SAS",
                title: CfgText(hu: "Légsűrűség-korrekció",
                               en: "Air density correction"),
                help: CfgText(
                    hu: "Bekapcsolva a sebesség a tengerszintre korrigálva jelenik "
                        + "meg (skydiver's air speed). Magasságtól függetlenül "
                        + "összehasonlítható értéket ad.",
                    en: "When on, speed is corrected to sea level (skydiver's air "
                        + "speed). This gives values that are comparable "
                        + "regardless of altitude."),
                kind: .options([(0, CfgText(hu: "Ki", en: "Off")),
                                (1, CfgText(hu: "Be", en: "On"))])),
        ]),

        ConfigGroup(title: CfgText(hu: "Magasság", en: "Altitude"),
            icon: "arrow.up.and.down", note: nil, fields: [
            ConfigField(key: "DZ_Elev",
                title: CfgText(hu: "Ugróhely magassága", en: "Dropzone elevation"),
                help: CfgText(
                    hu: "A leszállóterep tengerszint feletti magassága méterben. "
                        + "Ehhez mérve számol az eszköz minden riasztási magasságot.",
                    en: "Elevation of the landing area above sea level in meters. "
                        + "Every alarm altitude is measured relative to this."),
                kind: .int(min: -500, max: 5000, step: 5, unit: "m")),
            ConfigField(key: "Alt_Units",
                title: CfgText(hu: "Mértékegység", en: "Units"),
                help: CfgText(hu: "A bemondott magasság egysége.",
                              en: "Unit of the announced altitude."),
                kind: .options([(0, CfgText(hu: "méter", en: "meters")),
                                (1, CfgText(hu: "láb", en: "feet"))])),
            ConfigField(key: "Alt_Step",
                title: CfgText(hu: "Magasság bemondása",
                               en: "Altitude announcement step"),
                help: CfgText(
                    hu: "Ilyen lépésenként mondja be a magasságot. 0 = nincs "
                        + "bemondás.",
                    en: "Announce the altitude at these steps. 0 = no "
                        + "announcement."),
                kind: .int(min: 0, max: 1000, step: 50, unit: "")),
        ]),

        ConfigGroup(title: CfgText(hu: "Hangsáv", en: "Tone window"),
            icon: "arrow.up.arrow.down.square",
            note: CfgText(
                hu: "FIGYELEM: a FlySight dokumentációja szerint ez az a sáv, ahol a "
                    + "hang ENGEDÉLYEZETT — nem az, ahol elnémul. Ha elnémítani "
                    + "akarsz egy sávot, a sáv fölé és alá kell állítanod a "
                    + "határokat. Földön ellenőrizd, mielőtt ugrásnál számítasz rá.",
                en: "WARNING: according to the FlySight documentation this is the "
                    + "band where the tone is ENABLED — not where it is muted. If "
                    + "you want to mute a band, you have to set the limits above "
                    + "and below it. Check it on the ground before you rely on it "
                    + "on a jump."),
            fields: [
            ConfigField(key: "Win_Top",
                title: CfgText(hu: "Sáv teteje", en: "Top of window"),
                help: CfgText(hu: "Méter az ugróhely szintje felett.",
                              en: "Meters above the dropzone elevation."),
                kind: .int(min: 0, max: 10000, step: 50, unit: "m")),
            ConfigField(key: "Win_Bottom",
                title: CfgText(hu: "Sáv alja", en: "Bottom of window"),
                help: CfgText(hu: "Méter az ugróhely szintje felett.",
                              en: "Meters above the dropzone elevation."),
                kind: .int(min: 0, max: 10000, step: 50, unit: "m")),
        ]),

        ConfigGroup(title: CfgText(hu: "Riasztási ablak", en: "Alarm window"),
            icon: "bell.badge.fill",
            note: CfgText(
                hu: "Ennyivel a riasztási magasság előtt és után szólal meg a jelzés.",
                en: "The alarm sounds this far above and below the alarm altitude."),
            fields: [
            ConfigField(key: "Win_Above",
                title: CfgText(hu: "Ablak felette", en: "Window above"),
                help: CfgText(hu: "Méter.", en: "Meters."),
                kind: .int(min: 0, max: 500, step: 5, unit: "m")),
            ConfigField(key: "Win_Below",
                title: CfgText(hu: "Ablak alatta", en: "Window below"),
                help: CfgText(hu: "Méter.", en: "Meters."),
                kind: .int(min: 0, max: 500, step: 5, unit: "m")),
        ]),

        ConfigGroup(title: CfgText(hu: "Egyéb", en: "Other"),
            icon: "gearshape.fill", note: nil, fields: [
            ConfigField(key: "TZ_Offset",
                title: CfgText(hu: "Időzóna eltérés", en: "Time zone offset"),
                help: CfgText(
                    hu: "Másodperc az UTC-hez képest. Magyarországon nyáron 7200, "
                        + "télen 3600.",
                    en: "Seconds relative to UTC. For example CEST is 7200, "
                        + "CET is 3600."),
                kind: .int(min: -50400, max: 50400, step: 1800, unit: "s")),
            ConfigField(key: "Init_Mode",
                title: CfgText(hu: "Bekapcsoláskor", en: "On power-up"),
                help: CfgText(hu: "Mit tegyen az eszköz indításkor.",
                              en: "What the device does at startup."),
                kind: .options([
                    (0, CfgText(hu: "Semmit", en: "Nothing")),
                    (1, CfgText(hu: "Hangpróba", en: "Tone test")),
                    (2, CfgText(hu: "Fájl lejátszása", en: "Play file"))])),
            ConfigField(key: "Init_File",
                title: CfgText(hu: "Indító fájl száma", en: "Startup file number"),
                help: CfgText(
                    hu: "Ha a bekapcsolás fájlt játszik le, ennek a száma.",
                    en: "If power-up plays a file, this is its number."),
                kind: .int(min: 0, max: 99, step: 1, unit: "")),
        ]),
    ]

    static func field(_ key: String) -> ConfigField? {
        for g in groups { if let f = g.fields.first(where: { $0.key == key }) { return f } }
        return nil
    }
}

// MARK: - Alarm

struct AlarmEntry: Identifiable, Equatable {
    var id = UUID()
    var elevation: Int          // meters above dropzone elevation
    var type: Int               // 0..4
    var file: Int

    static let types: [(Int, CfgText)] = [
        (0, CfgText(hu: "Nincs", en: "None")),
        (1, CfgText(hu: "Sípszó", en: "Beep")),
        (2, CfgText(hu: "Emelkedő hang", en: "Rising tone")),
        (3, CfgText(hu: "Süllyedő hang", en: "Falling tone")),
        (4, CfgText(hu: "Fájl lejátszása", en: "Play file")),
    ]
    var typeName: CfgText {
        AlarmEntry.types.first { $0.0 == type }?.1 ?? CfgText(hu: "?", en: "?")
    }
    var icon: String {
        switch type {
        case 1: return "bell.fill"
        case 2: return "arrow.up.right"
        case 3: return "arrow.down.right"
        case 4: return "music.note"
        default: return "bell.slash"
        }
    }
}

// MARK: - Configuration

@MainActor
final class FlySightConfig: ObservableObject {

    @Published private(set) var lines: [ConfigLine] = []
    @Published var values: [String: Int] = [:]
    @Published var alarms: [AlarmEntry] = []
    @Published private(set) var isLoaded = false
    @Published private(set) var sourceName = ""

    /// Sentinel marking the built-in default config. Its name is NOT
    /// translated on load (otherwise it would stay in the old language after a
    /// language switch) but at display time — see `displaySourceName`.
    static let defaultSourceName = "__default__"

    func displaySourceName(_ lang: String) -> String {
        guard sourceName == Self.defaultSourceName else { return sourceName }
        return lang == "en" ? "Default" : "Alapértelmezett"
    }
    @Published var isDirty = false

    /// Unknown keys, written back unchanged
    private var unknown: [String: String] = [:]

    func load(_ text: String, name: String) {
        var out: [ConfigLine] = []
        var vals: [String: Int] = [:]
        var alarmList: [AlarmEntry] = []
        var pendingElev: Int?
        var pendingType: Int?
        unknown.removeAll()

        // CR line endings also occur in the device's files — see Track.parse.
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw).replacingOccurrences(of: "\r", with: "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { out.append(.blank); continue }
            if trimmed.hasPrefix(";") { out.append(.comment(line)); continue }

            // key: value  ; comment
            var body = trimmed
            var tail: String?
            if let semi = body.firstIndex(of: ";") {
                tail = String(body[semi...])
                body = String(body[..<semi]).trimmingCharacters(in: .whitespaces)
            }
            guard let colon = body.firstIndex(of: ":") else {
                out.append(.comment(line)); continue
            }
            let key = String(body[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(body[body.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)

            out.append(.pair(key: key, value: value, trailingComment: tail))

            // Alarms: they follow each other in groups of three
            if key == "Alarm_Elev" { pendingElev = Int(value) }
            else if key == "Alarm_Type" { pendingType = Int(value) }
            else if key == "Alarm_File" {
                if let e = pendingElev {
                    alarmList.append(AlarmEntry(elevation: e,
                                                type: pendingType ?? 0,
                                                file: Int(value) ?? 0))
                }
                pendingElev = nil; pendingType = nil
            } else if let i = Int(value) {
                vals[key] = i
            } else {
                unknown[key] = value
            }
        }

        lines = out
        values = vals
        alarms = alarmList.sorted { $0.elevation > $1.elevation }
        sourceName = name
        isLoaded = true
        isDirty = false
    }

    func set(_ key: String, _ v: Int) {
        guard values[key] != v else { return }
        values[key] = v
        isDirty = true
    }

    func value(_ key: String) -> Int { values[key] ?? 0 }

    func addAlarm() {
        alarms.append(AlarmEntry(elevation: 1000, type: 2, file: 0))
        alarms.sort { $0.elevation > $1.elevation }
        isDirty = true
    }
    func removeAlarm(_ a: AlarmEntry) {
        alarms.removeAll { $0.id == a.id }; isDirty = true
    }
    func updateAlarm(_ a: AlarmEntry) {
        guard let i = alarms.firstIndex(where: { $0.id == a.id }) else { return }
        alarms[i] = a
        alarms.sort { $0.elevation > $1.elevation }
        isDirty = true
    }

    /// Write-back: comments and ordering are preserved, only the values
    /// are replaced. The alarm block is rebuilt at the end.
    func serialize() -> String {
        var out: [String] = []
        var written = Set<String>()
        var alarmBlockDone = false

        for line in lines {
            switch line {
            case .comment(let c): out.append(c)
            case .blank: out.append("")
            case .pair(let key, let value, let tail):
                if key.hasPrefix("Alarm_") {
                    if !alarmBlockDone {
                        out.append(contentsOf: alarmBlock())
                        alarmBlockDone = true
                    }
                    continue
                }
                let newValue: String
                if let v = values[key] { newValue = String(v) }
                else { newValue = value }
                let pad = String(repeating: " ",
                                 count: max(1, 12 - key.count - 1))
                out.append("\(key):\(pad)\(newValue)" + (tail.map { "  \($0)" } ?? ""))
                written.insert(key)
            }
        }

        // If the file had no alarms so far, they now go at the end
        if !alarmBlockDone && !alarms.isEmpty {
            out.append("")
            out.append("; Riasztasok")
            out.append(contentsOf: alarmBlock())
        }

        // Known keys that weren't in the file
        let missing = ConfigSchema.groups.flatMap(\.fields).map(\.key)
            .filter { values[$0] != nil && !written.contains($0) }
        if !missing.isEmpty {
            out.append("")
            out.append("; Hozzaadott beallitasok")
            for k in missing {
                let pad = String(repeating: " ", count: max(1, 12 - k.count - 1))
                out.append("\(k):\(pad)\(values[k]!)")
            }
        }

        return out.joined(separator: "\r\n") + "\r\n"
    }

    private func alarmBlock() -> [String] {
        var out: [String] = []
        for a in alarms.sorted(by: { $0.elevation > $1.elevation }) {
            out.append("Alarm_Elev:  \(a.elevation)")
            out.append("Alarm_Type:  \(a.type)")
            out.append("Alarm_File:  \(a.file)")
        }
        return out
    }

    /// Default wingsuit setup when there is nothing to load
    static func defaultWingsuitText() -> String {
        """
        ; FlySight CONFIG.TXT
        ; GPS
        Model:      7
        Rate:       200
        ; Hangmagassag - siklaszam
        Mode:       2
        Min:        50
        Max:        250
        Limits:     1
        Volume:     6
        ; Hangismetles
        Mode_2:     2
        Min_Val_2:  50
        Max_Val_2:  250
        Min_Rate:   50
        Max_Rate:   400
        Flatline:   0
        ; Bemondas
        Sp_Rate:    8
        Sp_Volume:  6
        Sp_Mode:    2
        Sp_Units:   0
        Sp_Dec:     1
        ; Kuszobok
        V_Thresh:   1000
        H_Thresh:   0
        Use_SAS:    1
        ; Magassag
        DZ_Elev:    125
        Alt_Units:  0
        Alt_Step:   0
        ; Riasztasi ablak
        Win_Above:  50
        Win_Below:  50
        ; Hangsav
        Win_Top:    3000
        Win_Bottom: 0
        ; Egyeb
        TZ_Offset:  7200
        Init_Mode:  0
        Init_File:  0
        """
    }
}
