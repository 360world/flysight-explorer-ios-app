//
//  FlySightBLE.swift
//  Kapcsolat, kapcsolattartás, fájlböngészés, letöltés és feltöltés.
//
//  IGAZOLT PROTOKOLL (a hivatalos flysight-ios-core forrásából és méréssel):
//    0xFE  ping, 15 mp-enként az FT_Packet_In-re, enélkül 30 mp után bont
//    0xF1  ACK + eredeti parancs      0xF0  NAK + eredeti parancs
//    0x05  könyvtárlistázás, utána útvonal PERJELLEL és lezáró 0x00
//    0x11  könyvtárbejegyzés válasz, 22 bájt: méret, FAT dátum/idő, attribútum, név
//    0x03  fájl megnyitása írásra
//    0xFF  átvitel megszakítása
//    A párosítást az FT_Packet_In OLVASÁSA váltja ki, nem írás.
//
//  ELLENŐRIZENDŐ: readFile / fileData / ackFileData értékei. Ezek a
//  ConstantsAndTypes.swift-ben vannak, amit nem láttunk. A letöltés
//  automatikusan próbálja mindkét útvonalformát, mielőtt feladná.
//

import SwiftUI
import Combine
import CoreBluetooth

enum FS {
    static let ftPacketOut = CBUUID(string: "00000001-8E22-4541-9D4C-21EDAE82ED19")
    static let ftPacketIn  = CBUUID(string: "00000002-8E22-4541-9D4C-21EDAE82ED19")
    static let sdGNSS      = CBUUID(string: "00000000-8E22-4541-9D4C-21EDAE82ED19")
    static let companyID: UInt16 = 0x09DB
    static let savedKey = "flysight_peripheral_uuid"
    /// UUID → becenév. Csak az appon belüli elnevezés; magán az eszközön
    /// semmit nem írunk át, ezért a becenév törlésével visszaáll a gyári név.
    static let nicknamesKey = "flysight_nicknames"
}

/// Egy felderített (vagy korábban már használt) FlySight.
struct FlySightDevice: Identifiable, Equatable {
    let id: UUID
    var advertisedName: String
    var rssi: Int?
    var lastSeen: Date
}

extension UInt32 {
    /// Kis-végű 4 bájt — a readFile parancs offset mezőihez
    var littleEndianData: Data {
        var v = self.littleEndian
        return Data(bytes: &v, count: 4)
    }
}

enum FT {
    static let listDirectory: UInt8 = 0x05
    static let dirEntry:      UInt8 = 0x11
    static let writeFileOpen: UInt8 = 0x03
    static let nak:           UInt8 = 0xF0
    static let ack:           UInt8 = 0xF1
    static let cancel:        UInt8 = 0xFF
    static let ping:          UInt8 = 0xFE

    static let readFile:      UInt8 = 0x02
    static let fileData:      UInt8 = 0x10
    static let ackFileData:   UInt8 = 0x12
}

struct RemoteEntry: Identifiable {
    let id = UUID()
    let name: String
    let size: UInt32
    let date: Date
    let isDirectory: Bool

    var subtitle: String {
        let kb = Int(size / 1024)
        let when = date.formatted(date: .abbreviated, time: .shortened)
        return "\(kb) kB · \(when)"
    }
    var icon: String {
        if isDirectory { return "folder.fill" }
        let u = name.uppercased()
        if u.hasPrefix("TRACK") { return "chart.xyaxis.line" }
        if u.hasPrefix("CONFIG") { return "slider.horizontal.3" }
        return "doc"
    }
    var isTrack: Bool { name.uppercased().hasPrefix("TRACK") }
    var isConfig: Bool { name.uppercased().hasPrefix("CONFIG") }
}

@MainActor
final class FlySightBLE: NSObject, ObservableObject {

    enum State: Equatable {
        case idle, searching, connecting, connected, unavailable(String)
        func label(_ lang: String) -> String {
            switch self {
            case .idle: return loc("conn.idle", lang)
            case .searching: return loc("conn.searching", lang)
            case .connecting: return loc("conn.connecting", lang)
            case .connected: return loc("conn.connected", lang)
            case .unavailable(let m): return m
            }
        }
        var isBusy: Bool { self == .searching || self == .connecting }
    }

    enum Transfer: Equatable {
        case none
        case downloading(String)
        case uploading(String)
        var isActive: Bool { self != .none }
        func label(_ lang: String) -> String {
            switch self {
            case .none: return ""
            case .downloading(let n): return "\(loc("conn.downloading", lang)): \(n)"
            case .uploading(let n): return "\(loc("conn.uploading", lang)): \(n)"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var entries: [RemoteEntry] = []
    @Published private(set) var path: [String] = []
    @Published private(set) var isListing = false
    @Published private(set) var transfer: Transfer = .none
    @Published private(set) var progress = 0.0
    @Published private(set) var gnssPackets = 0
    @Published private(set) var log: [String] = []
    @Published var lastError: String?

    /// A felderített eszközök, legutóbb látott sorrendben.
    @Published private(set) var devices: [FlySightDevice] = []
    /// Az éppen kapcsolódott eszköz, ha van.
    @Published private(set) var connectedID: UUID?
    /// UUID → becenév.
    @Published private(set) var nicknames: [String: String] = [:]

    var onLive: ((LiveGNSS) -> Void)?
    /// (távoli útvonal, fájlnév, tartalom)
    var onFileDownloaded: ((String, String, String) -> Void)?
    var onUploadFinished: ((Bool, String) -> Void)?

    private var central: CBCentralManager!
    private var target: CBPeripheral?
    private var chIn: CBCharacteristic?
    private var pingTimer: Timer?
    /// Amelyik eszközhöz automatikusan kapcsolódunk, és amelyikhez
    /// újrakapcsolódunk bontás után.
    private var preferredID: UUID?
    /// A felderített peripheral objektumok, hogy később is tudjunk kapcsolódni.
    private var seen: [UUID: CBPeripheral] = [:]
    private var want = false

    // letöltés
    private var buf = Data()
    private var expected: UInt8 = 0
    private var pktCount = 0
    private var dlName: String?
    private var dlSize: UInt32 = 0
    private var dlComponents: [String] = []

    // feltöltés
    private var upData = Data()
    private var upOffset = 0
    private var upSeq: UInt8 = 0
    private var upComponents: String = ""
    private var upName = ""

    override init() {
        super.init()
        if let s = UserDefaults.standard.string(forKey: FS.savedKey) {
            preferredID = UUID(uuidString: s)
        }
        nicknames = UserDefaults.standard
            .dictionary(forKey: FS.nicknamesKey) as? [String: String] ?? [:]
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: eszközök és becenevek

    /// Amit a listában látsz: a becenév, ha adtál, különben a gyári (hirdetett) név.
    func displayName(_ id: UUID) -> String {
        if let n = nicknames[id.uuidString], !n.isEmpty { return n }
        return advertisedName(id)
    }

    /// A gyári, BLE-ben hirdetett név.
    func advertisedName(_ id: UUID) -> String {
        devices.first { $0.id == id }?.advertisedName
            ?? seen[id]?.name
            ?? "FlySight"
    }

    func hasNickname(_ id: UUID) -> Bool {
        !(nicknames[id.uuidString] ?? "").isEmpty
    }

    /// Becenév beállítása. `nil` vagy üres szöveg TÖRLI, tehát visszaáll a
    /// gyári név — az eszközön semmit nem módosítottunk, így ez veszteségmentes.
    func setNickname(_ name: String?, for id: UUID) {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            nicknames.removeValue(forKey: id.uuidString)
            note("Nickname cleared for \(id.uuidString) → \(advertisedName(id))")
        } else {
            nicknames[id.uuidString] = trimmed
            note("Nickname set: \(trimmed)")
        }
        UserDefaults.standard.set(nicknames, forKey: FS.nicknamesKey)
    }

    /// Kapcsolódás egy konkrét eszközhöz a listából.
    func connect(to id: UUID) {
        guard let p = seen[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        else { note("Cannot connect: peripheral \(id.uuidString) not found"); return }
        want = true
        preferredID = id
        UserDefaults.standard.set(id.uuidString, forKey: FS.savedKey)
        seen[id] = p
        if let t = target, t.identifier != id, t.state == .connected {
            central.cancelPeripheralConnection(t)
        }
        central.stopScan()
        target = p; p.delegate = self
        state = .connecting
        note("Connecting to \(displayName(id))")
        central.connect(p, options: nil)
    }

    /// Elfelejtjük az eszközt: becenév és automatikus kapcsolódás törlése.
    func forget(_ id: UUID) {
        setNickname(nil, for: id)
        if preferredID == id {
            preferredID = nil
            UserDefaults.standard.removeObject(forKey: FS.savedKey)
        }
        devices.removeAll { $0.id == id }
        seen.removeValue(forKey: id)
        note("Device forgotten")
    }

    private func remember(_ p: CBPeripheral, name: String, rssi: Int?) {
        seen[p.identifier] = p
        let dev = FlySightDevice(id: p.identifier, advertisedName: name,
                                 rssi: rssi, lastSeen: Date())
        if let i = devices.firstIndex(where: { $0.id == p.identifier }) {
            devices[i] = dev
        } else {
            devices.append(dev)
        }
        devices.sort { $0.lastSeen > $1.lastSeen }
    }

    /// Kétnyelvű felhasználói szöveg. A NAPLÓ mindig angol, ez csak a
    /// felhasználónak megjelenő hibaüzenetekre és állapotokra kell.
    private var lang: String {
        UserDefaults.standard.string(forKey: "app_language") ?? "hu"
    }
    private func L(_ hu: String, _ en: String) -> String { lang == "en" ? en : hu }

    private func note(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(s)")
        if log.count > 400 { log.removeFirst(100) }
        // Tartós naplóba is — hogy újraindítás után is visszanézhető legyen.
        DiagLog.shared.log(s, "BLE")
    }

    /// Publikus belépési pont a naplóba, más komponensek (pl. Logbook mentés
    /// eredménye) számára — hogy a mentés sikere/hibája is megjelenjen a
    /// BLE naplóban, nem csak egy eltűnő toast-ban.
    func logNote(_ s: String) { note(s) }
    var logText: String { log.joined(separator: "\n") }
    var pathString: String { "/" + path.joined(separator: "/") }

    // MARK: kapcsolat

    private func bluetoothProblem(_ s: CBManagerState) -> String {
        switch s {
        case .unknown:      return L("Bluetooth még indul, próbáld újra",
                                     "Bluetooth is starting up, try again")
        case .resetting:    return L("Bluetooth újraindul", "Bluetooth is resetting")
        case .unsupported:  return L("Az eszköz nem támogat BLE-t",
                                     "This device does not support BLE")
        case .unauthorized: return L("Nincs Bluetooth engedély — Beállítások",
                                     "No Bluetooth permission — check Settings")
        case .poweredOff:   return L("Kapcsold be a Bluetooth-t", "Turn on Bluetooth")
        case .poweredOn:    return L("kész", "ready")
        @unknown default:   return L("Ismeretlen Bluetooth állapot",
                                     "Unknown Bluetooth state")
        }
    }

    func start() {
        want = true
        guard central.state == .poweredOn else {
            #if targetEnvironment(simulator)
            state = .unavailable(L("A szimulátor nem támogat Bluetooth-t",
                                   "The simulator does not support Bluetooth"))
            #else
            state = .unavailable(bluetoothProblem(central.state))
            #endif
            note("Cannot start: state \(central.state.rawValue)")
            return
        }
        state = .searching; note("Scanning started")
        // A korábban használt eszköz azonnal jelenjen meg a listában, még a
        // felderítés előtt — és ha megvan, kapcsolódjunk hozzá automatikusan.
        if let u = preferredID,
           let p = central.retrievePeripherals(withIdentifiers: [u]).first {
            remember(p, name: p.name ?? "FlySight", rssi: nil)
            target = p; p.delegate = self; state = .connecting
            note("Reconnecting to \(displayName(u))")
            central.connect(p, options: nil)
        }
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    /// Újrakeresés: a lista frissítése kapcsolódás nélkül.
    func rescanDevices() {
        guard central.state == .poweredOn else { return }
        central.stopScan()
        devices.removeAll { $0.id != connectedID }
        want = true
        if state != .connected { state = .searching }
        note("Rescanning for devices")
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func stop() {
        want = false; central.stopScan()
        pingTimer?.invalidate(); pingTimer = nil
        if let t = target { central.cancelPeripheralConnection(t) }
        state = .idle
    }

    private func send(_ d: Data) {
        guard let p = target, let c = chIn, p.state == .connected else { return }
        p.writeValue(d, for: c, type: .withoutResponse)
    }

    private func startPing() {
        pingTimer?.invalidate(); send(Data([FT.ping]))
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let s = self else { return }
                // Átvitel közben a forgalom maga tartja életben a kapcsolatot
                if !s.transfer.isActive { s.send(Data([FT.ping])) }
            }
        }
    }

    private var chunkSize: Int {
        guard let p = target else { return 18 }
        return max(16, min(p.maximumWriteValueLength(for: .withoutResponse) - 2, 240))
    }

    // MARK: böngészés

    func listDirectory() {
        entries.removeAll(); isListing = true
        var c = Data([FT.listDirectory])
        c.append(pathString.data(using: .utf8) ?? Data()); c.append(0x00)
        note("Listing \(pathString)"); send(c)
    }
    func enter(_ e: RemoteEntry) {
        guard e.isDirectory else { return }
        path.append(e.name); listDirectory()
    }
    func goUp() {
        guard !path.isEmpty else { return }
        path.removeLast(); listDirectory()
    }
    func goRoot() { path.removeAll(); listDirectory() }

    // MARK: letöltés

    func download(_ e: RemoteEntry) {
        guard !transfer.isActive else { return }
        buf.removeAll(); expected = 0; pktCount = 0
        dlName = e.name; dlSize = e.size
        // A listázás perjellel kezdi az útvonalat — ugyanezt használjuk itt is.
        dlComponents = ["/" + (path + [e.name]).joined(separator: "/")]
        transfer = .downloading(e.name); progress = 0
        note("Download \(e.name) (\(e.size) bytes)")
        sendReadFile()
    }

    /// A readFile payload: [0x02][offsetMultiplier u32 LE][strideMinusOneMultiplier
    /// u32 LE][útvonal][0x00]. Teljes fájl letöltésénél mindkét szám 0.
    private func sendReadFile() {
        let p = dlComponents[0]
        var c = Data([FT.readFile])
        c.append(UInt32(0).littleEndianData)   // offsetMultiplier
        c.append(UInt32(0).littleEndianData)   // strideMinusOneMultiplier
        c.append(p.data(using: .utf8) ?? Data())
        c.append(0x00)
        note("readFile: \"\(p)\"")
        send(c)
    }

    func cancelTransfer() {
        send(Data([FT.cancel]))
        transfer = .none; progress = 0
        note("Cancelled")
    }

    // MARK: feltöltés

    func upload(text: String, toPath components: [String], name: String) {
        guard !transfer.isActive, state == .connected else { return }
        upData = Data(text.utf8)
        upOffset = 0; upSeq = 0
        upComponents = "/" + components.joined(separator: "/")
        upName = name
        transfer = .uploading(name); progress = 0
        note("Upload \(name) (\(upData.count) bytes)")
        sendWriteOpen()
    }

    private func sendWriteOpen() {
        var c = Data([FT.writeFileOpen])
        c.append(upComponents.data(using: .utf8) ?? Data())
        c.append(0x00)
        note("writeFileOpen: \"\(upComponents)\"")
        send(c)
    }

    private func sendNextUploadChunk() {
        let size = chunkSize
        if upOffset >= upData.count {
            send(Data([FT.fileData, upSeq]))        // üres csomag = vége
            note("Upload finalized")
            return
        }
        let end = min(upOffset + size, upData.count)
        var pkt = Data([FT.fileData, upSeq])
        pkt.append(upData.subdata(in: upOffset..<end))
        send(pkt)
        upOffset = end
        upSeq = upSeq &+ 1
        progress = Double(upOffset) / Double(max(1, upData.count))
    }

    // MARK: bejövő FT csomagok

    private func handleFT(_ d: Data) {
        guard let op = d.first else { return }
        switch op {

        case FT.dirEntry:
            guard d.count >= 24 else { return }
            let p = d.subdata(in: 2..<d.count)
            let size = p.subdata(in: 0..<4).withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).littleEndian }
            let fd = p.subdata(in: 4..<6).withUnsafeBytes {
                $0.loadUnaligned(as: UInt16.self).littleEndian }
            let ftm = p.subdata(in: 6..<8).withUnsafeBytes {
                $0.loadUnaligned(as: UInt16.self).littleEndian }
            let attr = p[8]
            let nb = p.subdata(in: 9..<min(22, p.count))
            if nb.first == 0 { isListing = false; return }
            let cut = nb.firstIndex(of: 0) ?? nb.endIndex
            guard let name = String(data: nb.subdata(in: nb.startIndex..<cut),
                                    encoding: .utf8), !name.isEmpty else { return }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: 0)!
            let date = cal.date(from: DateComponents(
                year: Int((fd >> 9) & 0x7F) + 1980, month: Int((fd >> 5) & 0x0F),
                day: Int(fd & 0x1F), hour: Int((ftm >> 11) & 0x1F),
                minute: Int((ftm >> 5) & 0x3F), second: Int((ftm & 0x1F) * 2))) ?? Date()
            entries.append(.init(name: name, size: size, date: date,
                                 isDirectory: (attr & 0x10) != 0))
            entries.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name > $1.name          // legfrissebb mappa elöl
            }

        case FT.fileData:
            guard d.count >= 2 else { return }
            // Letöltés adatcsomagja
            if case .downloading = transfer {
                if buf.isEmpty && d[1] == 0 { note("Data stream starting") }
                if d[1] != expected {
                    // Ismételt küldés (elveszett ACK): újra nyugtázzuk, de NEM
                    // fűzzük hozzá még egyszer az adatot.
                    if d[1] == expected &- 1 {
                        send(Data([FT.ackFileData, d[1]]))
                        return
                    }
                    // Valódi lyuk a sorszámozásban: innentől a fájl biztosan
                    // hiányos lenne. Korábban ezt némán eldobtuk, és a végén
                    // csonka CSV-t mentettünk — inkább egyértelmű hibát adunk.
                    note("Packet sequence error: got \(d[1]), expected \(expected) — download aborted")
                    send(Data([FT.cancel]))
                    transfer = .none; progress = 0
                    lastError = L("A letöltés megszakadt (csomagvesztés a Bluetooth "
                                  + "kapcsolatban). Vidd közelebb az eszközt és próbáld újra.",
                                  "Download aborted (packet loss on the Bluetooth "
                                  + "link). Move closer to the device and retry.")
                    return
                }
                let payload = d.count > 2 ? d.subdata(in: 2..<d.count) : Data()
                send(Data([FT.ackFileData, d[1]]))
                if payload.isEmpty {
                    // String(data:encoding:.utf8) NIL-t ad vissza akár egyetlen
                    // hibás bájtnál is, és akkor a fájl csendben üresként mentődik.
                    // A veszteséges dekódolás sosem hibázik: legfeljebb a hibás
                    // bájtokat cseréli le, a többi sor épen marad.
                    let text = String(decoding: buf, as: UTF8.self)
                    let remote = dlComponents.first ?? (dlName ?? "file")
                    // A listázásból ismerjük a fájl méretét — ha kevesebb bájt
                    // érkezett, a letöltés valóban hiányos. Ez az EGYETLEN hely,
                    // ahol a "hiányos letöltés" megállapítása értelmes.
                    if dlSize > 0 && buf.count < Int(dlSize) {
                        note("Incomplete download: \(buf.count)/\(dlSize) bytes")
                        transfer = .none; progress = 0
                        lastError = L("A letöltés hiányos (\(buf.count)/\(dlSize) bájt). "
                                      + "Próbáld újra, közelebb az eszközhöz.",
                                      "Download is incomplete (\(buf.count)/\(dlSize) bytes). "
                                      + "Retry, closer to the device.")
                        return
                    }
                    note("Done: \(buf.count) bytes")
                    transfer = .none; progress = 1
                    onFileDownloaded?(remote, dlName ?? "file", text)
                } else {
                    buf.append(payload); expected = expected &+ 1
                    if dlSize > 0 { progress = min(1, Double(buf.count) / Double(dlSize)) }
                    // Minden 50. csomagnál jelzünk, hogy elakadás esetén
                    // látszódjon, hol állt meg az átvitel. Külön Int számláló,
                    // mert az `expected` UInt8 és 256-onként visszafordul.
                    pktCount += 1
                    if pktCount % 50 == 0 {
                        DiagLog.shared.log("… \(buf.count)/\(dlSize) bytes "
                                           + "(packet \(pktCount))", "DL")
                    }
                }
            }

        case FT.ackFileData:
            // Feltöltés nyugtája: jöhet a következő darab
            if case .uploading = transfer {
                if upOffset >= upData.count {
                    transfer = .none; progress = 1
                    note("Upload complete")
                    onUploadFinished?(true, upName)
                } else {
                    sendNextUploadChunk()
                }
            }

        case FT.ack:
            let orig: UInt8 = d.count > 1 ? d[1] : 0
            if orig == FT.writeFileOpen, case .uploading = transfer {
                note("File opened for writing, sending data")
                sendNextUploadChunk()
            }

        case FT.nak:
            let orig: UInt8 = d.count > 1 ? d[1] : 0
            note("NAK for command 0x\(String(format: "%02X", orig))")
            if orig == FT.readFile, case .downloading = transfer {
                transfer = .none
                lastError = L("A letöltést az eszköz elutasította (0x02 NAK). "
                              + "Ellenőrizd, hogy a fájl valóban létezik ezen az útvonalon.",
                              "The device rejected the download (0x02 NAK). "
                              + "Check that the file exists at this path.")
            } else if orig == FT.writeFileOpen, case .uploading = transfer {
                transfer = .none
                lastError = L("A feltöltést az eszköz elutasította (0x03 NAK).",
                              "The device rejected the upload (0x03 NAK).")
                onUploadFinished?(false, upName)
            } else {
                isListing = false
                if case .downloading = transfer {
                    transfer = .none
                    lastError = L("A letöltést az eszköz elutasította. Ha mindkét "
                                  + "útvonalforma NAK-ot kap, az FT.readFile opcode rossz.",
                                  "The device rejected the download. If both path "
                                  + "forms get a NAK, the FT.readFile opcode is wrong.")
                } else if case .uploading = transfer {
                    transfer = .none
                    lastError = L("A feltöltést az eszköz elutasította.",
                                  "The device rejected the upload.")
                    onUploadFinished?(false, upName)
                }
            }

        default:
            let hex = d.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
            note("Unknown FT opcode 0x\(String(format: "%02X", op)) — \(hex)")
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension FlySightBLE: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let s = c.state
        Task { @MainActor in
            note("System state: \(s.rawValue) — \(bluetoothProblem(s))")
            if s == .poweredOn {
                if want { start() } else { state = .idle }
            } else {
                #if targetEnvironment(simulator)
                state = .unavailable(L("A szimulátor nem támogat Bluetooth-t",
                                   "The simulator does not support Bluetooth"))
                #else
                state = .unavailable(bluetoothProblem(s))
                #endif
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData adv: [String: Any], rssi: NSNumber) {
        Task { @MainActor in
            let advName = (adv[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
            var ok = false
            if p.identifier == preferredID { ok = true }
            if nicknames[p.identifier.uuidString] != nil { ok = true }
            if let md = adv[CBAdvertisementDataManufacturerDataKey] as? Data, md.count >= 2,
               UInt16(md[0]) | (UInt16(md[1]) << 8) == FS.companyID { ok = true }
            if advName.lowercased().contains("flysight") { ok = true }
            guard ok else { return }

            let isNew = !devices.contains { $0.id == p.identifier }
            remember(p, name: advName.isEmpty ? "FlySight" : advName,
                     rssi: rssi.intValue)
            if isNew {
                note("Found \(displayName(p.identifier)) \(rssi.intValue) dBm")
            }

            // Több eszköz is lehet a közelben, ezért NEM kapcsolódunk vakon az
            // elsőre: csak ahhoz, amit korábban használtál. A többi a listában
            // várja, hogy kiválaszd.
            guard want, state == .searching, p.identifier == preferredID else { return }
            target = p; p.delegate = self; state = .connecting
            c.connect(p, options: nil)
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        Task { @MainActor in
            c.stopScan()
            state = .connected
            connectedID = p.identifier
            remember(p, name: p.name ?? advertisedName(p.identifier), rssi: nil)
            note("Connected to \(displayName(p.identifier))")
            p.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            note("Failed: \(error?.localizedDescription ?? "?")")
            if want { c.connect(p, options: nil) }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager,
                                    didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        Task { @MainActor in
            pingTimer?.invalidate(); chIn = nil
            entries.removeAll(); isListing = false
            if p.identifier == connectedID { connectedID = nil }
            if transfer.isActive {
                lastError = L("A kapcsolat megszakadt átvitel közben",
                              "The connection dropped during the transfer")
                transfer = .none
            }
            note("Disconnected from \(displayName(p.identifier))")
            // Csak a kiválasztott eszközhöz kapcsolódunk vissza automatikusan.
            guard want, p.identifier == preferredID else { state = .idle; return }
            state = .connecting
            c.connect(p, options: nil)      // iOS-en függőben marad
        }
    }
}

// MARK: - CBPeripheralDelegate

extension FlySightBLE: CBPeripheralDelegate {

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral,
                                didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        // Szinkron feldolgozás, hogy a `chIn` és a notify-beállítás biztosan
        // kész legyen, mielőtt az első FT csomag megérkezik.
        MainActor.assumeIsolated {
            for ch in s.characteristics ?? [] {
                switch ch.uuid {
                case FS.ftPacketIn:
                    chIn = ch
                    p.readValue(for: ch)      // ez váltja ki a párosítást
                    startPing()
                case FS.ftPacketOut, FS.sdGNSS:
                    p.setNotifyValue(true, for: ch)
                default:
                    if ch.properties.contains(.notify) { p.setNotifyValue(true, for: ch) }
                }
            }
            listDirectory()
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral,
                                didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        let uuid = ch.uuid, d = ch.value ?? Data()
        // FONTOS: itt NEM indíthatunk `Task { @MainActor in ... }`-ot!
        // Külön Task-ok futási SORRENDJE nem garantált, a letöltésnél viszont
        // másodpercenként több száz csomag érkezik, és ezek sorrendje kritikus:
        // az átrendeződő csomagokat a `d[1] == expected` ellenőrzés némán
        // eldobta, így a fájl közepéből hiányoztak darabok, a végén pedig
        // csonka CSV-t mentettünk el ("hiányos letöltés").
        //
        // A CBCentralManager delegate queue-ja `.main`, tehát ez a callback
        // már a fő szálon fut — így szinkronban, ÉRKEZÉSI SORRENDBEN tudjuk
        // feldolgozni a csomagokat.
        MainActor.assumeIsolated {
            guard error == nil else { return }
            if uuid == FS.sdGNSS {
                gnssPackets += 1
                if let g = LiveGNSS.parse(d) { onLive?(g) }
            } else if uuid == FS.ftPacketOut {
                handleFT(d)
            }
        }
    }
}
