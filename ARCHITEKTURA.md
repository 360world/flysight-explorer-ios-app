# FlySight Explorer — technikai dokumentáció

iOS alkalmazás a FlySight 2 GPS-loggerhez: fájlletöltés BLE-n, ugráselemzés,
HUD-megjelenítés és az eszköz konfigurálása.

Platform: iOS 26.5+, SwiftUI. Külső függőség nincs (CoreBluetooth, MapKit,
Swift Charts a rendszerből).

---

## 1. BLE kapcsolat és párosítás

Ez a szakasz a legfontosabb: a FlySight BLE-viselkedése több ponton
dokumentálatlan, és a rosszul kezelt párosítás olyan tüneteket ad, amiket
könnyű más okra fogni.

### Karakterisztikák

| UUID | Irány | Szerep |
|---|---|---|
| `00000001-8E22-…-ED19` | eszköz → telefon | értesítések (`ftPacketOut`) |
| `00000002-8E22-…-ED19` | telefon → eszköz | parancsok (`ftPacketIn`) |
| `00000000-8E22-…-ED19` | eszköz → telefon | élő GNSS stream |

### ⚠ A párosítást a `ftPacketIn` OLVASÁSA váltja ki, nem az írás

**Ez nem dokumentált, méréssel derült ki.** Ha a kliens csak *írni* próbál a
karakterisztikára, a párosítási folyamat nem indul el. A kapcsolat ilyenkor
látszólag létrejön — a kapcsolódás lefut, a szolgáltatások felderíthetők —, de
biztonságos kötés (bond) nélkül.

A helyes sorrend tehát: kapcsolódás → szolgáltatás-felderítés → **a parancs-
karakterisztika olvasása** → keepalive indítása.

### ⚠ Keepalive: `0xFE` ping 15 másodpercenként

**Ping nélkül az eszköz 30 másodperc után bont.** Ez saját, eszközoldali
időtúllépés, nem BLE-szintű hiba.

A pinget a párosítás kiváltása után azonnal el kell indítani. Fájlátvitel
közben szünetelhet, mert akkor a csomagonkénti `0x12` nyugták tartják életben a
kapcsolatot.

### Ha a kapcsolat létrejön, de a párosítás nem

- a kapcsolat **~30 másodperc után bont** (a hiányzó keepalive miatt)
- az eszköz **újrakereséskor más MAC-en látszik**
- a védett műveletek (fájlolvasás, konfigírás) **`0xF0` NAK-ot** kapnak
- ezért tűnik úgy, hogy minden művelet előtt „reset" vagy újbóli
  konfigfeltöltés kell

**A MAC-változás itt nem a hiba oka, hanem következménye.** A BLE
szabvány szerint az eszköz *random resolvable private address*-t használ, amit
kb. 15 percenként rotál — ez adatvédelmi funkció. Párosítás során a felek
kicserélik az **IRK**-t (Identity Resolving Key), amivel a central a változó
címet feloldja és felismeri az eszközt. Bond nélkül nincs IRK, tehát a
rotáló cím tényleg azonosíthatatlanná válik.

> Megjegyzés: a fenti tünetsort a BLE-szabvány és a megfigyelt eszközoldali
> időtúllépés alapján vezettük le, nem közvetlen méréssel bontottuk szét
> tünetenként.

### Eszközazonosítás

Az eszközt **nem a hirdetett címmel** kell azonosítani, mert az rotál. iOS-en a
rendszer nem is ad MAC-et, hanem eszközönként stabil azonosítót; Androidon a
bondolt eszközök listája a helyes kiindulás.

### Több eszköz

Az alkalmazás nyilvántartja a felderített eszközöket, mindegyikhez tartozhat
felhasználói becenév. A becenév csak az alkalmazáson belül él — törlésével
visszaáll a hirdetett gyári név, az eszközre semmit nem írunk.

Egy eszköz megjelölhető előnyben részesítettként: ehhez kapcsolódik
automatikusan az alkalmazás, és bontás után **csak ehhez** próbál
visszakapcsolódni. Több eszköz jelenlétében így nem kapcsolódik vaktában az
elsőre.

---

## 2. Fájlátviteli protokoll

| Kód | Név | | Kód | Név |
|---|---|---|---|---|
| `0x02` | readFile | | `0x11` | dirEntry |
| `0x03` | writeFileOpen | | `0x12` | ackFileData |
| `0x05` | listDirectory | | `0xF0` / `0xF1` | NAK / ACK |
| `0x10` | fileData | | `0xFE` / `0xFF` | ping / cancel |

Letöltés menete:

1. `[0x05][útvonal][0x00]` → listázás; `0x11` válaszok, üres név = vége
2. `[0x02][offset u32 LE][stride u32 LE][útvonal][0x00]` → fájl kérése
3. `[0x10][seq][adat]` csomagok, mindegyikre `[0x12][seq]` nyugta
4. üres adatú `0x10` = adatfolyam vége
5. **a kapott bájtszám összevetése a listázásból ismert mérettel**

A `seq` egy bájt, 256-onként körbefordul. Csomagméret az MTU-tól függ, iOS-en
mérve ~242 bájt. Egy 464 kB-os TRACK.CSV ~1920 csomag, ~17 másodperc.

---

## 3. Kezdeti hibák a feldolgozási láncban

Négy, egymástól független hiba adta ugyanazt a tünetet: *„nem sikerült
elmenteni — túl rövid felvétel vagy hiányos letöltés"* egy érvényes fájlra. Az
üzenet a lánc végén keletkezik, a kiváltó ok korábban van.

**1. Csomagsorrend.** A beérkező BLE-értesítések feldolgozása aszinkron
feladatokba került, amelyek sorrendje nem garantált. Az átrendeződött
csomagokat a sorszám-ellenőrzés eldobta — nyugta és naplóbejegyzés nélkül.
Javítás: a csomagok szinkron, érkezési sorrendben dolgozódnak fel; ismételt
csomag újranyugtázva, valódi sorszám-lyuk esetén megszakítás, a végén
méretellenőrzés.

**2. Az elemzés blokkolta a mentést.** A mentés előbb értelmezte a CSV-t, és
annak hibája esetén a nyers fájl sem került lemezre. Javítás: a nyers CSV
mindig kiíródik, az értelmezés csak metaadatot szolgáltat.

**3. CR sorvég.** A FlySight `\r`-t használ; a `\n`-re darabolás a 271 kB-os
fájlt egyetlen sornak látta → nulla minta → „túl rövid". Javítás: mindhárom
sorvégfajta (`\n`, `\r`, `\r\n`) kezelése. Ugyanez a hiba a CONFIG.TXT
olvasásában is megvolt.

**4. Index szerializáció.** Az index dátumai eltérő formátummal íródtak és
olvasódtak, így a dekódolás minden indításkor elhasalt és a napló kiürült.
Javítás: azonos formátum mindkét irányban; sérült index esetén a napló a
lemezen lévő fájlokból újraépül.

A beazonosítást az nehezítette, hogy a hibaüzenet nem tartalmazott
diagnosztikai adatot, a BLE-napló pedig nem volt elérhető a felületről. A
tartós napló bevezetése után az ok egyetlen bejegyzésből látszott:

```
[SAVE] Parse FAILED — 271615 bytes, 1 lines — $GNSS:0 ISO:0 numeric:0 other:1
```

---

## 4. Diagnosztikai napló

Fájlba ír (`Documents/flysight-diagnostics.log`), túléli az alkalmazás
újraindítását, 4000 sor után forgat, a felületről megosztható. Nyelve mindig
angol.

Kategóriák: `BLE`, `DL`, `SAVE`, `READ`, `SCAN`, `IMPORT`, `APP`. A mentési és
beolvasási bejegyzések kiírják a fájl első 8 sorát — ebből azonnal látszik a
valódi formátum.

---

## 5. Adatmodell

Egy track a GNSS-minták sorozata (idő, pozíció, magasság, sebességvektor,
pontosság, műholdszám), plusz a származtatott adatok: a talajszint becslése (a
magasságok 5. percentilise), az exit/nyitás/leszállás indexe, és a mintánkénti
kumulatív úthossz. Ez utóbbi betöltéskor egyszer készül el, mert futásidőben
újraszámolva képkockánként több ezer távolságszámítás lenne.

**Támogatott CSV-formátumok:** FlySight 2 (`$FLYS`/`$VAR`/`$COL`/`$UNIT`/`$DATA`
fejléc + `$GNSS,<ISO idő>,…`), FlySight 1 (előtag nélküli, 12 oszlop, ISO idő),
és régi export (10 oszlop, másodperc-eltolás). A tört másodperc lehet 2 jegyű
(`.00Z`), ezért elemzés előtt 3 jegyre igazítjuk.

Küszöb: 6 használható minta. Ez alatt nincs elemzés, de a fájl mentve van.

**Fázisdetektálás:** exit = első minta 60 km/h fölötti süllyedéssel; nyitás =
utána tartósan 40 km/h alá esik; leszállás = 20 m talaj felett, 15 km/h alatt.

---

## 6. Tárolás

```
Documents/
├── tracks/
│   ├── index.json
│   └── 20260812_090828__26-08-02_11-10-24_TRACK.CSV
└── flysight-diagnostics.log
```

Duplikátumszűrés a felvétel eszközön belüli útvonala alapján: ugyanaz a
felvétel nem kerül be kétszer. Import a rendszer fájlválasztójával. `UIFileSharingEnabled` +
`LSSupportsOpeningDocumentsInPlace` beállítva.

---

## 7. UI-megoldások, amik nem triviálisak

**Görgetés vs. chart-csúszkáltatás.** SwiftUI-ban bármilyen folytonos gesztus
a charton már a lenyomásnál lefogja az érintést, és onnantól a görgetés nem
működik — ez a natív gesztus-API mindhárom változatára igaz. Megoldás egy
UIKit-alapú pan-felismerő, amely nem zárja ki a görgetés gesztusát: néhány
pixel elmozdulás után eldönti az irányt, függőlegesnél átengedi a görgetésnek,
vízszintesnél pedig a mozdulat végéig letiltja a görgetést. Így a két mozdulat
kizárólagos.

**Csúszka-eltolás.** A kijelölés-fogantyú látható csíkja 5 pt, de a fogási
területe 30 pt; a csík a fogási terület közepén áll, ezért a korábbi eltolás
12,5 pt-tal jobbra csúsztatta a jelölést a kijelölés valódi szélétől. Emellett
a gesztus a fogantyú saját koordinátarendszerében mért a sáv helyett, ezért a
két végállás nem volt elérhető. Mindkettő javítva.

**Védelem hibás adat ellen.** Ugrás nélküli, földi felvételnél a magasságprofil
normalizálás és vágás nélkül rajzolt, és a rajz kifutott a keretből. Javítva:
az értékek 0…1 közé szorítva, a rajz vágva, nem-véges értékek kiszűrve, a
grafikon időtengelye legalább 1 mp széles, és minden index a minták tényleges
határai közé szorítva.

**Lejátszás.** A kurzor változását figyelő kód a lejátszás saját léptetésénél is
leállította a lejátszást. Javítás: a leállítás csak valódi felhasználói
mozdulatra fut. Emellett az időzítő olyan futásmódba került, amely interakció
közben sem áll meg.

---

## 8. Lokalizáció

112 kulcsos szótár, magyar és angol. A konfigurátor szövegei (9 csoport, 31
mező, súgók, legördülők) nem kulcsalapúak, hanem kétnyelvű értékként a sémában
élnek, és megjelenítéskor oldódnak fel. A `CONFIG.TXT` kulcsai bájtazonosak, a
fájlformátumhoz nem nyúlunk.

---

## 9. Nyitott kérdések

Rövid méréssel eldönthetők, még nem történtek meg:

- kínál-e a FlySight szabványos Battery Service-t (`0x180F`)?
- van-e hasznos adat a hirdetési csomagban (akku, logolási állapot)?
- pontosan hány párhuzamos BLE kapcsolatot engedélyez?
- kiolvasható-e a szabad tárhely? (a felhasznált a listázásból számolható)

Mindegyikhez a szolgáltatás- és karakterisztika-lista naplóba írása kell.

---

## 10. Flutter migráció — mérési eredmény

A `flutter_spike/` egy eldobható próba: kiszolgálja-e a `flutter_blue_plus`
hibátlanul ezt a protokollt.

**iOS, 464 548 bájt, 3 futás:** mindhárom bájtra pontos (1920 csomag,
17,0–18,1 s), sorrendhiba 0, parse 4640 minta. ~242 bájt/csomag, ~26 kB/s —
megegyezik a natív teljesítménnyel. A parser 12 egységtesztje átment Dartban,
beleértve a CR sorvéget.

**Android mérés: még nincs meg.** A döntést nem lehet egy platformról
meghozni; az Android BLE stackje a másik gyakori bukási pont (MTU-tárgyalás,
write-without-response torlódás, gyártói eltérések).

A `flutter_blue_plus` 2.x licence személyes, nonprofit és oktatási használatra
ingyenes, kereskedelmi használatra fizetős.
