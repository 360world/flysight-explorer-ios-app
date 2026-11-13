# FlySight Explorer

iOS alkalmazás a FlySight 2 GPS-loggerhez: ugrásadatok letöltése Bluetooth-on,
elemzés, HUD-megjelenítés és az eszköz konfigurálása — mindezt a telefonról,
kártyaolvasó és számítógép nélkül.

Részletes technikai leírás: [ARCHITEKTURA.md](ARCHITEKTURA.md)

---

## Futtatás másik Macen

1. Nyisd meg a `FlysightExplorer_ios.xcodeproj`-ot Xcode-ban.
2. A target **Signing & Capabilities** fülén válaszd ki a saját Apple Developer
   Team-edet (a projekt szándékosan nem tartalmaz team ID-t).
3. Bundle ID jelenleg: `com.example.flysightexplorer` — ha ütközik, írd át
   sajátodra.
4. Build & Run fizikai iPhone-ra (BLE-hez szimulátor nem elég).
