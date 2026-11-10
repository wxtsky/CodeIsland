# Riset: Waktu Salat, Kalender Hijriah, dan Jam Bertema Diorama

> Tanggal riset: 2026-11-10
> HEAD saat riset: `9d66439` (branch `feat/#3-spotify-web-browser-detection`)
> Referensi pembanding: add-on **Prayer times** milik [Oyenya Studio](https://studio.oyenza.com/) (deskripsi resmi add-on, 0.2.1–0.2.28)
> **Prinsip**: setiap angka di dokumen ini punya sumber. Yang tidak bisa diverifikasi ditandai **UNVERIFIED**.
> Dokumen ini bahan keputusan, bukan spec. Spec menyusul setelah peta wayfinder selesai.

---

## TL;DR

1. **KHGT bukan metode waktu salat.** Ia menetapkan *tanggal Hijriah*, bukan jam. Kemenag, NU, dan Muhammadiyah hanya berbeda pada **3 parameter**: sudut Subuh, ihtiyati, dan pembulatan. Jadi implementasinya satu kalkulator + tiga set parameter, bukan tiga implementasi.
2. **Jangan pakai Aladhan `method=20` lalu menyebutnya "Kemenag".** Sudah diuji: hasilnya meleset 2–3 menit dari jadwal Kemenag terbit, dan 6 menit pada Terbit. Aladhan tidak menerapkan ihtiyati Kemenag maupun koreksi ketinggiannya.
3. **Oyenya sudah menyelesaikan ini lebih dulu**, dan lebih dalam dari yang tampak: 517 tempat Kemenag, 33.000 kota dunia, tabel jadwal ter-*bundle* (bukan API), akurasi diklaim 98,2% dari 227.367 waktu persis ke menit. Fork ini tidak bisa menang dengan meniru; ia harus menang di tempat lain (lihat §9).
4. **Jam bertema diorama tidak butuh aset gambar.** Repo ini sudah punya presedennya: `ClawdView` menggambar pixel-art prosedural lewat `Canvas` + `TimelineView`. Diorama bisa ditempuh dengan cara yang sama, 0 byte aset.
5. **Sinkronisasi lokasi antar-perangkat adalah keputusan arsitektur, bukan detail.** Mac menghitung lalu mendorong lewat BLE berarti jam salat iPhone salah begitu iPhone di kota lain. Kalkulator harus berjalan **di tiap perangkat**, dari lokasi perangkat itu sendiri.

---

## 1. Pertanyaan yang dijawab dokumen ini

| # | Pertanyaan | Bagian |
|---|---|---|
| Q1 | Jam/timestamp sekarang ada di mana di CodeIsland? | §2 |
| Q2 | Template visual jam (diorama) dibuat bagaimana? | §3 |
| Q3 | Waktu salat ditentukan lewat API atau dihitung lokal? | §4 |
| Q4 | Parameter tiap metode (Kemenag / NU / Muhammadiyah)? | §5 |
| Q5 | Kalender Hijriah: KHGT vs Kemenag vs Muhammadiyah? | §6 |
| Q6 | Lokasi perangkat didapat bagaimana? | §7 |
| Q7 | Disinkronkan ke perangkat lain bagaimana? | §8 |

---

## 2. Jam di CodeIsland hari ini

**Tidak ada jam sama sekali.** Tidak ada `DateFormatter` ber-`timeStyle` yang dipakai untuk menampilkan waktu berjalan di panel; `TimelineView` yang ada semuanya untuk animasi (0,05–0,08 s) atau kuota (60 s).

Geometri pill saat istirahat ada di `Sources/CodeIsland/NotchPanelView.swift`:

| Bagian | Struct | Isi sekarang |
|---|---|---|
| Sayap kiri | `IdleIndicatorBar` (`:1874`) | maskot + status |
| **Tengah** | `Spacer(minLength: hasNotch ? notchW : 0)` (`:1912`) | **kosong** — hanya area notch |
| Sayap kanan | `IdleIndicatorBar` (`:1874`) | titik status / tombol |

Artinya **slot tengah pill kosong dan sudah berukuran notch**. Itu tempat alami untuk jam. Di mesin pengembang ini `hasNotch == false` (`ScreenDetector.screenHasNotch()`), jadi lebarnya `nil` dan jam harus punya lebar eksplisit sendiri.

Konsekuensi desain: jam di tengah berarti ia berbagi ruang dengan notch hardware pada MacBook yang punya notch. Oyenya menyelesaikannya dengan menaruh hitung mundur *di samping* kamera (bukan di bawahnya). Ini batasan nyata, bukan detail kosmetik.

---

## 3. Template visual jam: diorama

### 3.1 Yang dilakukan referensi

Dari tangkapan layar Oyenya Diorama, empat keadaan:

| Keadaan | Isi |
|---|---|
| **Day** | Matahari melintasi langit, kucing di bawah pohon, jendela rumah gelap |
| **Night** | Bulan sesuai fase, bintang, jendela menyala, lampu taman |
| **Golden hour** | Langit jingga, cahaya berubah sebelum matahari terbenam |
| **Slide** | Bola di tengah bisa ditekan dan digeser; hari berjalan menjadi malam |

Poin penting: **"Slide" itu interaksi, bukan keadaan.** Pengguna menekan bola lalu menggeser untuk memutar waktu. Itu berarti scene harus **dapat diparameterkan oleh waktu**, bukan empat gambar terpisah. Kalau empat gambar terpisah, menggeser tidak mungkin.

### 3.2 Cara membangunnya di repo ini

Preseden yang sudah ada: `Sources/CodeIsland/PixelCharacterView.swift` (`ClawdView`) — pixel-art digambar sebagai `CGRect` di dalam `Canvas`, dianimasikan lewat `TimelineView`, dengan palet warna sebagai konstanta. Tanpa sprite sheet, tanpa Metal, tanpa GIF.

Pendekatan yang sama untuk diorama:

```
waktu (0..1 dalam sehari)  ──►  parameter scene  ──►  Canvas
                               ├─ posisi matahari/bulan di busur
                               ├─ palet langit (interpolasi antar kunci)
                               ├─ fase bulan (dari tanggal Hijriah!)
                               ├─ jendela menyala/tidak
                               └─ parallax awan
```

Yang membuat ini menarik: **fase bulan bisa diambil dari tanggal Hijriah** yang sudah dihitung untuk fitur salat. Dua fitur jadi satu sumber kebenaran.

Alternatif yang ditolak:
- **Aset gambar per slot** — menambah ukuran app, dan membunuh interaksi geser.
- **Metal** — berlebihan untuk satu pill; repo tidak punya presedennya.
- **Lottie** — dependency baru untuk hal yang sudah bisa dilakukan `Canvas`.

**UNVERIFIED**: apakah Oyenya memakai sprite sheet atau prosedural. Tidak relevan untuk keputusan kita, tapi jangan mengklaim kita meniru implementasinya.

---

## 4. Waktu salat: API atau hitung lokal?

### 4.1 Pilihan yang ada

| Jalur | Sumber | Kelebihan | Kekurangan |
|---|---|---|---|
| **Aladhan API** | `api.aladhan.com` ([docs](https://aladhan.com/prayer-times-api)) | Gratis, tanpa kunci, 23 metode termasuk `KEMENAG` (id 20) dan `JAKIM` (id 17) | Butuh jaringan; **tidak akurat untuk Kemenag** (§4.3); tidak punya NU/Muhammadiyah |
| **myQuran API v2** | `api.myquran.com` ([docs](https://documenter.getpostman.com/view/841292/2s9YsGittd)) | Data Kemenag per kab/kota, gratis | Penulisnya sendiri menyatakan **tidak lagi dimaintenance**; "perubahan baru dari kemenag tidak ikut dalam pembaruan" |
| **Hitung lokal** | `adhan-swift` atau implementasi sendiri | Offline, tanpa kunci, bisa parameter apa pun | Harus diverifikasi terhadap jadwal resmi |
| **Tabel ter-bundle** | Jadwal Kemenag yang di-*scrape* | Paling akurat untuk Kemenag | Besar, harus diperbarui tiap tahun, hanya Indonesia |

### 4.2 Rekomendasi

**Hitung lokal** sebagai jalur utama, karena:
- Fitur harus jalan offline (pill selalu terlihat, jaringan tidak).
- NU dan Muhammadiyah **tidak ada** di API mana pun — hanya bisa lewat parameter sendiri.
- Tiga metode = tiga set parameter di atas satu kalkulator (§5).

`adhan-swift` ([batoulapps/adhan-swift](https://github.com/batoulapps/adhan-swift)) layak dipertimbangkan: rumusnya dari *Astronomical Algorithms* (Jean Meeus), punya `CalculationParameters` dengan `fajrAngle`/`ishaAngle`/`adjustments`/`rounding` — persis tiga parameter yang kita butuhkan. Tapi ia menambah dependency ke `Package.swift` yang sekarang hanya punya Sparkle dan Yams.

**UNVERIFIED**: apakah `adhan-swift` masih kompatibel dengan Swift 6 / toolchain repo ini. Perlu dicoba sebelum diputuskan.

### 4.3 Bukti: Aladhan `method=20` bukan Kemenag

Diuji 2026-11-10. Jakarta, 2026-01-15. Kolom "Kemenag" dari myQuran (hasil *scrape* jadwal Kemenag), kolom "Aladhan" dari `api.aladhan.com/v1/timings/2026-01-15?latitude=-6.2088&longitude=106.8456&method=20`.

| Waktu | Kemenag | Aladhan default | Selisih | Aladhan + `tune=2` | Selisih |
|---|---|---|---|---|---|
| Imsak | 04:17 | 04:15 | −2 | 04:17 | **0** |
| Subuh | 04:27 | 04:25 | −2 | 04:27 | **0** |
| Terbit | 05:45 | 05:49 | +4 | 05:51 | **+6** |
| Dzuhur | 12:05 | 12:02 | −3 | 12:04 | −1 |
| Ashar | 15:30 | 15:27 | −3 | 15:29 | −1 |
| Maghrib | 18:18 | 18:15 | −3 | 18:17 | −1 |
| Isya | 19:33 | 19:30 | −3 | 19:32 | −1 |

Kesimpulan yang bisa dipertanggungjawabkan:
- Ihtiyati Kemenag **+2 menit** menjelaskan selisih Imsak/Subuh sepenuhnya.
- Sisa −1 menit pada Dzuhur/Ashar/Maghrib/Isya **tidak** dijelaskan ihtiyati; ada koreksi tambahan (kemungkinan pembulatan ke atas + koreksi ketinggian) yang tidak diterapkan Aladhan.
- **Terbit meleset 6 menit** — Kemenag memakai definisi ketinggian Matahari yang berbeda untuk terbit.
- Mengubah koordinat ke Monas (−6,1754 / 106,8272) **tidak** mengubah hasil: jadi bukan soal koordinat.

**Catatan kejujuran**: myQuran v2 mengaku tidak dimaintenance, jadi angka "Kemenag" di atas mungkin bukan jadwal resmi 2026. Yang tetap valid adalah *adanya* selisih sistematis. Angka ini harus diuji ulang terhadap `bimasislam.kemenag.go.id` sebelum jadi patokan test.

### 4.4 Cara Oyenya menyelesaikannya

Dari deskripsi add-on-nya (sumber sekunder, klaim pihak ketiga):

> "Checked against Kemenag's 2026 schedule: 98.2% of 227,367 times to the minute, none more than a minute off."

227.367 waktu ≈ 517 tempat × 366 hari × ~1,2. Artinya mereka **membandingkan seluruh tabel setahun penuh**, bukan sampel. Dan 98,2% (bukan 100%) berarti mereka pun tidak sempurna — tapi sisa 1,8% pun tidak lebih dari 1 menit.

Untuk Muhammadiyah: *"Its times match khgt.muhammadiyah.or.id to the minute, or within one."*

Ini standar yang harus kita samai atau lewati. Dan ia menunjukkan bahwa **verifikasi terhadap jadwal terbit adalah bagian dari fiturnya**, bukan QA sekali jalan.

---

## 5. Parameter tiga metode

Sumber: [Aladhan `/v1/methods`](https://api.aladhan.com/v1/methods) (JSON mentah, untuk Kemenag), [hpt.muhammadiyah.or.id](https://hpt.muhammadiyah.or.id) (Muhammadiyah), dan keputusan LF PBNU 2025 (NU).

| Parameter | Kemenag RI | NU (LF PBNU) | Muhammadiyah (MTT) |
|---|---|---|---|
| Sudut Subuh | −20° | −20° | **−18°** |
| Sudut Isya | −18° | −18° | −18° |
| Dzuhur | istiwa + 2 mnt | istiwa + **1 mnt** | istiwa |
| Ihtiyati | **+2 mnt** semua | **0** (sejak pertengahan 2025) | 0 |
| Pembulatan | terdekat | **ke atas** | ke atas |
| Imsak | Subuh − 10 mnt | — | — |
| Dhuha | +4,5° | — | — |
| Ashar | Shafi'i | Shafi'i | Shafi'i |

Koreksi ketinggian Kemenag (hanya Maghrib & Terbit): 0–250 m: 0; 250–700 m: +1; 700–1000 m: +2; … 2000–2500 m: +6. NU memasukkan elevasi langsung ke rumus, bukan tabel.

**Implikasi teknis**: `CalculationParameters` yang dibutuhkan hanya `fajrAngle`, `ishaAngle`, `adjustments` (per waktu), dan `rounding`. Itu persis yang disediakan `adhan-swift`. Satu kalkulator, tiga preset.

**Risiko yang harus disadari**: Subuh Muhammadiyah (−18°) vs Kemenag (−20°) berselisih **±8 menit**. App yang menampilkan satu jadwal saja akan dianggap salah oleh pengguna mazhab lain. Karena itu pemilihan metode adalah fitur wajib, bukan preferensi opsional.

---

## 6. Kalender Hijriah

### 6.1 Tiga kalender, tiga kriteria

| Kalender | Kriteria | Cakupan | Sumber |
|---|---|---|---|
| **KHGT** (Muhammadiyah) | tinggi hilal ≥ 5° **dan** elongasi ≥ 8°, sebelum 24:00 UT | **global**, satu tanggal sedunia | [khgt.muhammadiyah.or.id](https://khgt.muhammadiyah.or.id/) |
| **Kemenag** | MABIMS (Neo-Mabims: 3° / 6,4°) + keputusan sidang isbat | Indonesia | bimasislam.kemenag.go.id |
| **Muhammadiyah lokal** | hisab hakiki, tanpa rukyat | Indonesia | hpt.muhammadiyah.or.id |

KHGT mengadopsi **Model Kongres Turki 2016**: seluruh dunia satu matlak; jika PKG-1 terpenuhi di mana pun sebelum 24:00 UT, besok adalah awal bulan baru bagi seluruh dunia. Ada PKG-2 untuk penyelarasan setelah 24:00 UT (Benua Amerika / sebelum fajar Selandia Baru).

### 6.2 Konsekuensi praktis

- KHGT bisa **berbeda satu hari** dari Kemenag. Ini bukan bug, ini perbedaan metode.
- Kalender bawaan Foundation (`Calendar(identifier: .islamicUmmAlQura)`) **bukan** KHGT dan **bukan** Kemenag — jangan dipakai untuk keduanya.
- Muhammadiyah menerbitkan KHGT **sampai 1451 H**; setelah itu harus dihitung dari kriteria. Oyenya menyebut hal yang sama.
- Karena itu, kalender harus **dihitung**, bukan dibaca dari `Calendar.current`.

**UNVERIFIED**: apakah `khgt.muhammadiyah.or.id` menyediakan API publik. Halaman "Jadwal salat" di sana menerima lintang/bujur, jadi kemungkinan besar dihitung di sisi klien (JavaScript), bukan endpoint. Perlu diperiksa sebelum memutuskan apakah tabel 1451 H perlu di-*bundle*.

---

## 7. Lokasi perangkat

### 7.1 macOS

`CLLocationManager` bekerja di macOS. Yang dibutuhkan:

1. `NSLocationUsageDescription` di `Info.plist` — **belum ada** di repo ini.
2. `requestLocation()` untuk satu kali baca (bukan `startUpdatingLocation()`), karena waktu salat tidak butuh stream.
3. Manager diinisialisasi di thread yang punya run loop aktif (main thread).
4. Tangani `didFailWithError` dan `authorizationStatus` sebagai keadaan runtime, bukan asumsi.

App ini **tidak sandboxed** dan bundle ID-nya stabil (`com.codeisland.app`), jadi jalurnya terbuka. **Risiko**: `build.sh` jatuh ke *ad-hoc signing* (`-`) bila tidak ada Developer ID. TCC mengikat izin ke signature, jadi dengan ad-hoc izin lokasi bisa berubah-ubah antar-build.

### 7.2 Kenapa timezone saja tidak cukup

WIB membentang 95°–120° BT. Dua kota di zona yang sama bisa berselisih hingga ±30 menit waktu salat. Timezone hanya layak sebagai *fallback* terakhir, bukan sumber utama.

Urutan fallback yang disarankan:
1. `CLLocationManager` (presisi ratusan meter — cukup)
2. Kota terakhir yang dipilih pengguna (disimpan)
3. Timezone → kota terdekat dari tabel
4. Manual: pengguna mengetik nama kota

### 7.3 Privasi

Oyenya secara eksplisit menyatakan: *"The point stays on your computer: it only picks the place."* Artinya koordinat tidak pernah dikirim; hanya dipakai untuk memilih kota dari tabel lokal.

Ini pilihan yang baik dan murah untuk ditiru: **koordinat tidak pernah meninggalkan perangkat**. Kalau kita menghitung lokal (§4.2), ini otomatis terpenuhi — tidak ada permintaan jaringan sama sekali.

---

## 8. Sinkronisasi ke perangkat lain

### 8.1 Permukaan yang ada di repo ini

| Perangkat | Teknologi | Bahasa | Lokasi sendiri? |
|---|---|---|---|
| iPhone / iPad | `CodeIslandCompanion` (BLE *central*) + Live Activity | Swift | ya |
| Apple Watch | `CodeIslandWatchApp` + `WatchConnection` | Swift | ya |
| Android Watch | `android-watch/` (Gradle) | Kotlin | ya |
| ESP32 | `hardware/hardware.ino` + `ESP32BridgeManager` | C++ | **tidak** |

### 8.2 Masalahnya

Jalur yang ada sekarang adalah **push dari Mac**: Mac → BLE → perangkat. Untuk status agent itu benar, karena agent memang berjalan di Mac.

Untuk waktu salat, itu **salah**. iPhone yang sedang di Bandung tidak boleh menampilkan jadwal Jakarta hanya karena Mac-nya di Jakarta. Waktu salat adalah fungsi dari **lokasi perangkat yang menampilkan**, bukan lokasi Mac.

### 8.3 Tiga pilihan arsitektur

| Pilihan | Cara kerja | Benar? | Biaya |
|---|---|---|---|
| **A. Mac menghitung, push ke semua** | Mac → BLE → jam salat | ✗ salah begitu perangkat berpindah kota | paling murah |
| **B. Tiap perangkat menghitung sendiri** | kalkulator di-share, tiap perangkat pakai lokasinya | ✓ | kalkulator harus ada di Swift + Kotlin + C++ |
| **C. Perangkat kirim lokasi, Mac hitung, push balik** | BLE dua arah | ✓ | koordinat meninggalkan perangkat; melanggar prinsip §7.3 |

**Rekomendasi: B**, dengan pembagian bertahap:
- **iPhone + Watch**: kalkulator Swift yang sama bisa dipakai langsung (target SwiftPM bersama). Nol duplikasi.
- **Android Watch**: port kalkulator ke Kotlin. Rumusnya ~250 baris; ini pekerjaan nyata tapi terbatas.
- **ESP32**: tidak punya lokasi. Ia menerima hasil jadi dari Mac (pilihan A) — dan itu **benar** untuk perangkat ini, karena ia memang tidak berpindah.

Jadi jawabannya bukan "pilih satu", tapi **B untuk perangkat yang berpindah, A untuk yang tidak**.

### 8.4 Yang perlu diputuskan nanti

- Apakah kalkulator masuk `CodeIslandCore` (dipakai Mac + iOS + Watch) atau package terpisah?
- Apakah jam salat ikut dikirim sebagai bagian dari frame BLE yang sudah ada, atau kanal baru?
- Bagaimana perangkat tahu zona waktu & DST-nya sendiri (iOS: `TimeZone.current`, benar; ESP32: perlu dikirim)?

---

## 9. Di mana fork ini bisa menang

Oyenya sudah punya: 517 tempat Kemenag, 33.000 kota, KHGT, adzan (CC BY-SA 4.0), busur lima waktu, hitung mundur di samping kamera, arsitektur add-on 959 KB.

Meniru itu berarti kalah, karena mereka sudah 28 versi di depan. Yang **tidak** mereka punya, dan CodeIsland punya:

- **Konteks agent.** Pill ini tahu sesi mana yang berjalan, tool apa yang sedang dipakai, dan kapan agent menunggu persetujuan. Pengingat salat yang bereaksi terhadap itu — menunda notifikasi saat agent sedang menunggu approval, atau menampilkan "Subuh 4 menit lagi" di samping status agent — adalah sesuatu yang add-on lepas tidak bisa lakukan.
- **Kanvas yang sama dengan jam.** Kalau jam diorama dan hitung mundur salat berbagi satu slot tengah, keduanya jadi satu objek, bukan dua fitur yang bersaing.
- **Perangkat keras.** ESP32 dan Android Watch tidak ada di Oyenya.

**Saran**: jangan bersaing pada cakupan (jumlah kota, jumlah metode). Bersaing pada **integrasi dengan agent**.

---

## 10. Pertanyaan yang masih terbuka

1. Apakah `adhan-swift` masih build di Swift 6 / toolchain repo ini? (**harus dicoba**)
2. Apakah `bimasislam.kemenag.go.id` punya endpoint yang bisa dipanggil untuk verifikasi otomatis?
3. Apakah `khgt.muhammadiyah.or.id` punya API, atau tabel 1451 H harus di-*bundle*?
4. Apakah ihtiyati Kemenag benar +2 menit untuk semua waktu, atau berbeda per waktu? (Data §4.3 menunjukkan +2 untuk Subuh, +3 untuk sisanya — perlu jadwal resmi untuk memastikan.)
5. Apakah jam diorama dan hitung mundur salat berbagi satu slot, atau jam pindah ke tempat lain saat salat mendekat?
6. Berapa biaya port kalkulator ke Kotlin untuk Android Watch?

---

## 11. Referensi

**Waktu salat & parameter**
- Aladhan API, daftar metode + parameter mentah: <https://api.aladhan.com/v1/methods>
- Aladhan API, dokumentasi: <https://aladhan.com/prayer-times-api>
- Penjelasan matematis: <http://praytimes.org/wiki/Prayer_Times_Calculation>
- `adhan-swift` (Batoul Apps), rumus dari *Astronomical Algorithms* (Meeus): <https://github.com/batoulapps/adhan-swift>
- `adhan-swift` panduan parameter: <https://github.com/batoulapps/adhan-swift/blob/develop/METHODS.md>
- myQuran API v2 (scrape Kemenag), peringatan tidak dimaintenance: <https://documenter.getpostman.com/view/841292/2s9YsGittd>
- myQuran, daftar kota: <https://api.myquran.com/v2/sholat/kota/semua>
- myQuran, jadwal per kota/tanggal: `https://api.myquran.com/v2/sholat/jadwal/<id>/<YYYY-MM-DD>`

**Muhammadiyah & KHGT**
- KHGT resmi (kalender, peta PKG, jadwal salat, metodologi): <https://khgt.muhammadiyah.or.id/>
- Himpunan Putusan Tarjih, waktu salat: <https://hpt.muhammadiyah.or.id>
- Kriteria PKG-1 (5°/8°) dan Model Kongres Turki 2016: halaman "Metodologi" di situs KHGT di atas

**Lokasi**
- Core Location di macOS (`requestLocation`, run loop, otorisasi): Apple Developer Documentation, Core Location

**Pembanding**
- Oyenya Studio: <https://studio.oyenza.com/>
- Deskripsi add-on Prayer times 0.2.1–0.2.28 (sumber klaim akurasi 98,2%, arsitektur add-on, adzan CC BY-SA 4.0)

**Internal repo**
- Slot tengah pill: `Sources/CodeIsland/NotchPanelView.swift:1874` (`IdleIndicatorBar`), `:1912` (`Spacer`)
- Preseden pixel-art prosedural: `Sources/CodeIsland/PixelCharacterView.swift` (`ClawdView`, `Canvas` + `TimelineView`)
- Tab: `Sources/CodeIsland/NotchPanelView.swift:113` (`ExpandedContentTab`)
- Settings: `Sources/CodeIsland/Settings.swift` (`SettingsKey`, `SettingsDefaults`)
- L10n: 7 bahasa (en, zh, zh-Hant, de, ja, ko, tr) — **tidak ada `id`**
- `Info.plist`: belum ada `NSLocationUsageDescription`
- Signing: `build.sh:123–136` (Developer ID → identity apa pun → ad-hoc)
