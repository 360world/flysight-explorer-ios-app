//
//  Localization.swift
//  Egyszerű, kézzel karbantartott fordítási réteg magyar/angol nyelvhez.
//
//  Használat: @AppStorage("app_language") private var appLang = AppLanguage.systemDefault.rawValue
//             Text(loc("tab.hud", appLang))
//
//  Miért nem Xcode String Catalog: a projekt egyfájlos/kevés-fájlos, kézzel
//  szerkesztett forrásból nő — egy .xcstrings katalógust Xcode string-
//  extraction nélkül nehéz karban tartani. Ez a szótár ugyanazt az elvet
//  követi (kulcs -> nyelvenkénti szöveg), csak egyszerű Swift kódban.
//
//  LEFEDETTSÉG: a fő navigáció, gombok, HUD felirat, szegmens- és
//  sorozatválasztó, statisztika címkék le vannak fordítva. A konfigurátor
//  mezőinek részletes súgó szövegei (ConfigSchema) még csak magyarul
//  vannak — ha kell, ugyanezzel a mintával bővíthető.
//

import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case hu, en
    var id: String { rawValue }
    var label: String { self == .hu ? "Magyar" : "English" }
    var flag: String { self == .hu ? "🇭🇺" : "🇬🇧" }

    /// Language used until the user picks one in Settings: Hungarian if it is
    /// the phone's preferred language, English otherwise.
    static var systemDefault: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("hu") == true ? .hu : .en
    }
}

/// Kulcs -> [nyelv: szöveg]. Ha egy kulcs vagy nyelv hiányzik, a kulcs
/// szövege jelenik meg — így sosem tűnik el felirat, csak nem fordított.
private let translations: [String: [String: String]] = [

    // Fülek / navigáció
    "tab.hud":      ["hu": "HUD",       "en": "HUD"],
    "tab.analysis": ["hu": "Elemzés",   "en": "Analysis"],
    "tab.logbook":  ["hu": "Napló",     "en": "Logbook"],
    "tab.config":   ["hu": "Beállítás", "en": "Settings"],
    "tab.device":   ["hu": "Eszköz",    "en": "Device"],

    "nav.analysis": ["hu": "Elemzés",              "en": "Analysis"],
    "nav.logbook":  ["hu": "Napló",                "en": "Logbook"],
    "nav.config":   ["hu": "Konfiguráció",         "en": "Configuration"],
    "nav.flysight":  ["hu": "FlySight",             "en": "FlySight"],
    "nav.pickTrack": ["hu": "Ugrás kiválasztása",   "en": "Choose a jump"],
    "nav.configRaw": ["hu": "CONFIG.TXT",           "en": "CONFIG.TXT"],
    "nav.rename":    ["hu": "Átnevezés",            "en": "Rename"],

    // Kapcsolat
    "conn.title":       ["hu": "Kapcsolat",              "en": "Connection"],
    "conn.connect":     ["hu": "Csatlakozás",            "en": "Connect"],
    "conn.disconnect":  ["hu": "Bontás",                 "en": "Disconnect"],
    "conn.idle":        ["hu": "Készenlét",              "en": "Idle"],
    "conn.searching":   ["hu": "Keresés…",               "en": "Searching…"],
    "conn.connecting":  ["hu": "Csatlakozás…",           "en": "Connecting…"],
    "conn.connected":   ["hu": "Kapcsolódva",            "en": "Connected"],
    "conn.liveToHud":   ["hu": "Élő adat a HUD-ra",      "en": "Live data on HUD"],
    "conn.gnssPacket":  ["hu": "GNSS csomag",            "en": "GNSS packets"],
    "conn.filesOnDevice": ["hu": "Fájlok az eszközön",   "en": "Files on device"],
    "conn.listing":     ["hu": "Listázás…",              "en": "Listing…"],
    "conn.cancel":      ["hu": "Megszakít",              "en": "Cancel"],
    "conn.downloading": ["hu": "Letöltés",               "en": "Downloading"],
    "conn.uploading":   ["hu": "Feltöltés",               "en": "Uploading"],

    // HUD
    "hud.noData":       ["hu": "NINCS ADAT",             "en": "NO DATA"],
    "hud.recording":    ["hu": "Felvétel",               "en": "Recording"],
    "hud.live":         ["hu": "Élő",                    "en": "Live"],
    "hud.play":         ["hu": "Lejátszás",              "en": "Play"],
    "hud.stop":         ["hu": "Stop",                   "en": "Stop"],
    "hud.satellite":    ["hu": "műhold",                 "en": "satellites"],
    "hud.altAGL":       ["hu": "talaj felett m",         "en": "above ground m"],
    "hud.altMSL":       ["hu": "tengerszint m",          "en": "sea level m"],
    "hud.altAGLshort":  ["hu": "m talaj",                "en": "m AGL"],
    "hud.altMSLshort":  ["hu": "m tszf",                 "en": "m MSL"],
    "hud.hSpeed":       ["hu": "km/h vízszintes",        "en": "km/h horizontal"],
    "hud.vSpeed":       ["hu": "km/h függőleges",        "en": "km/h vertical"],
    "hud.hSpeedShort":  ["hu": "vízsz",                  "en": "horiz"],
    "hud.vSpeedShort":  ["hu": "függ",                   "en": "vert"],
    "hud.glide":        ["hu": "siklószám",              "en": "glide ratio"],

    "layout.altitude":  ["hu": "Magasság",  "en": "Altitude"],
    "layout.glide":     ["hu": "Glide",     "en": "Glide"],
    "layout.edgeBar":   ["hu": "Peremsáv",  "en": "Edge bar"],
    "layout.dial":      ["hu": "Ív",        "en": "Dial"],

    "palette.color":    ["hu": "Színes",       "en": "Color"],
    "palette.green":    ["hu": "Zöld mono",    "en": "Green mono"],
    "palette.amber":    ["hu": "Sárga mono",   "en": "Amber mono"],

    "altref.agl":       ["hu": "Talaj felett",  "en": "Above ground"],
    "altref.msl":       ["hu": "Tengerszint",   "en": "Sea level"],

    // Fázisok
    "phase.ground":     ["hu": "Földön",        "en": "Ground"],
    "phase.climb":      ["hu": "Emelkedés",     "en": "Climb"],
    "phase.jumpRun":     ["hu": "Jump run",      "en": "Jump run"],
    "phase.freefall":   ["hu": "Esés",          "en": "Freefall"],
    "phase.deploying":  ["hu": "Nyitás",        "en": "Deploying"],
    "phase.canopy":     ["hu": "Ernyő alatt",   "en": "Under canopy"],
    "phase.landing":    ["hu": "Leszállás",     "en": "Landing"],

    // Szegmensek (gyorsválasztó chipek)
    "segment.whole":       ["hu": "Ugrás",     "en": "Jump"],
    "segment.freefall":    ["hu": "Esés",      "en": "Freefall"],
    "segment.opening":     ["hu": "Nyitás",    "en": "Opening"],
    "segment.canopy":      ["hu": "Ernyő",     "en": "Canopy"],
    "segment.landing":     ["hu": "Leszállás", "en": "Landing"],
    "segment.everything":  ["hu": "Minden",    "en": "Everything"],

    // Sorozatválasztó (a görbén megjelenő adatok)
    "series.altitude":   ["hu": "Magasság",       "en": "Altitude"],
    "series.vertical":   ["hu": "Függőleges",      "en": "Vertical"],
    "series.horizontal": ["hu": "Vízszintes",      "en": "Horizontal"],
    "series.glide":      ["hu": "Siklószám",       "en": "Glide ratio"],
    "series.distance":   ["hu": "Táv",             "en": "Distance"],

    // Elemzés fül
    "analysis.pickTrack":     ["hu": "Válassz ugrást",           "en": "Choose a jump"],
    "analysis.switch":        ["hu": "Váltás",                    "en": "Switch"],
    "analysis.noTrack":       ["hu": "Nincs betöltött ugrás — válassz fent egyet.",
                                "en": "No jump loaded — pick one above."],
    "analysis.samples":       ["hu": "minta",                     "en": "samples"],
    "analysis.exit":          ["hu": "exit",                      "en": "exit"],
    "analysis.builtin":       ["hu": "Beépített minták",          "en": "Built-in samples"],
    "analysis.downloaded":    ["hu": "Letöltött ugrások",         "en": "Downloaded jumps"],
    "analysis.noDownloads":   ["hu": "Még nincs letöltött ugrás. A FlySight fülön "
                                    + "csatlakozva tölts le egy TRACK.CSV-t.",
                                "en": "No downloads yet. Connect on the FlySight tab "
                                    + "and download a TRACK.CSV."],
    "analysis.selectionHint": ["hu": "Kijelölés — fogantyúk a széleken, kurzor bárhol",
                                "en": "Selection — handles at the edges, cursor anywhere"],
    "analysis.rangeAGL":      ["hu": "m talaj felett",  "en": "m above ground"],
    "analysis.secLong":       ["hu": "s hosszú",         "en": "s long"],
    "analysis.done":          ["hu": "Kész",             "en": "Done"],

    "stat.duration":      ["hu": "Időtartam",         "en": "Duration"],
    "stat.altLoss":       ["hu": "Magasságvesztés",   "en": "Altitude lost"],
    "stat.vMax":          ["hu": "Függ. max",         "en": "Vert. max"],
    "stat.vAvg":          ["hu": "Függ. átlag",       "en": "Vert. avg"],
    "stat.hMax":          ["hu": "Vízsz. max",        "en": "Horiz. max"],
    "stat.hAvg":          ["hu": "Vízsz. átlag",      "en": "Horiz. avg"],
    "stat.grAvg":         ["hu": "Siklószám átlag",   "en": "Glide avg"],
    "stat.grMax":         ["hu": "Siklószám max",     "en": "Glide max"],
    "stat.straightLine":  ["hu": "Légvonal",          "en": "Straight line"],
    "stat.pathLength":    ["hu": "Útvonal",           "en": "Path length"],

    // Napló fül
    "logbook.title":     ["hu": "Napló",                                 "en": "Logbook"],
    "logbook.storage":   ["hu": "Tárhely",                               "en": "Storage"],
    "logbook.keptOnPhone": ["hu": "a fájlok a telefon memóriájában maradnak",
                             "en": "files stay on this phone"],
    "logbook.delete":    ["hu": "Törlés",                                "en": "Delete"],

    // Konfigurátor
    "config.title":         ["hu": "Konfiguráció",                       "en": "Configuration"],
    "config.source":        ["hu": "Forrás",                             "en": "Source"],
    "config.modified":      ["hu": "módosítva",                          "en": "modified"],
    "config.uploadToDevice": ["hu": "Feltöltés a FlySightra",            "en": "Upload to FlySight"],
    "config.needConnection": ["hu": "Csatlakozz a FlySight fülön a betöltéshez és feltöltéshez.",
                               "en": "Connect on the FlySight tab to load and upload."],
    "config.viewRaw":       ["hu": "Nyers fájl megtekintése",            "en": "View raw file"],
    "config.uploadConfirmTitle": ["hu": "Feltöltés a FlySightra",        "en": "Upload to FlySight"],
    "config.uploadConfirmMsg":   ["hu": "Ez felülírja az eszközön lévő CONFIG.TXT-t. "
                                       + "Az eredetit előtte töltsd le és mentsd el.",
                                   "en": "This overwrites CONFIG.TXT on the device. "
                                       + "Download and keep the original first."],
    "config.cancel":       ["hu": "Mégse",   "en": "Cancel"],
    "config.upload":       ["hu": "Feltöltés", "en": "Upload"],
    "config.alarms":       ["hu": "Riasztási magasságok", "en": "Alarm altitudes"],
    "config.newAlarm":     ["hu": "Új riasztás", "en": "New alarm"],
    "config.asGlideRatio": ["hu": "Siklószámként", "en": "As glide ratio"],
    "config.altitudeLabel": ["hu": "Magasság", "en": "Altitude"],
    "config.fileNumber":   ["hu": "Fájl száma", "en": "File number"],
    "config.signal":       ["hu": "Jelzés", "en": "Signal"],

    // Általános
    "generic.save": ["hu": "Mentés", "en": "Save"],

    // Nyelv
    "settings.language":   ["hu": "Nyelv", "en": "Language"],
]

func loc(_ key: String, _ lang: String) -> String {
    translations[key]?[lang] ?? translations[key]?["en"] ?? key
}

/// Kényelmi nézet: nyelvválasztó szegmentált vezérlő. Bárhová beilleszthető,
/// ahol @AppStorage("app_language") elérhető.
struct LanguagePicker: View {
    @Binding var lang: String
    var body: some View {
        Picker(loc("settings.language", lang), selection: $lang) {
            ForEach(AppLanguage.allCases) { l in
                Text("\(l.flag) \(l.label)").tag(l.rawValue)
            }
        }
        .pickerStyle(.segmented)
    }
}
