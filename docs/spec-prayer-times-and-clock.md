# Specification: Prayer Times & Living Diorama Clock (Kemenag, NU, Muhammadiyah, KHGT)

**Status:** `ready-for-agent`  
**Branch:** `feat/prayer-times-and-clock`

---

## Problem Statement

Muslim developers and power users on macOS who use CodeIsland throughout their workday currently have no ambient prayer time awareness or Islamic calendar reference in the Dynamic Island / notch:

1. **Lack of Ambient Awareness**: Developers frequently miss prayer times while focused on coding sessions because existing prayer apps require separate menu bar icons, intrusive dock apps, or external mobile phone reminders that break developer flow.
2. **Method & Madhhab Conflicts**: Prayer calculation in Indonesia is sensitive to organization and methodology differences. Muhammadiyah uses a $-18^\circ$ Fajr angle, while Kemenag RI and LF PBNU use $-20^\circ$ (resulting in an $\approx 8$-minute difference for Subuh). Furthermore, Kemenag applies a $+2$-minute *ihtiyati* safety buffer (and $-2$ minutes on sunrise) with altitude corrections, while LF PBNU uses direct spherical dip elevation without static ihtiyati, and Muhammadiyah applies neither. Existing third-party APIs (like Aladhan default) miss Kemenag's published schedule by up to 6 minutes because they fail to model Indonesian ihtiyati and altitude dip rules accurately.
3. **Hijri Calendar Divergence**: Muhammadiyah officially adopted the Global Unified Hijri Calendar (**KHGT**) with global *Ittihad al-Matali'* criteria ($5^\circ$ altitude / $8^\circ$ elongation before 24:00 UT), which can differ by $\pm 1$ day from the Indonesian government's MABIMS criteria ($3^\circ / 6.4^\circ$) and moon sighting (*rukyatul hilal*). Apple's built-in `islamicUmmAlQura` calendar matches neither.
4. **Visual Disconnect**: Existing prayer apps display sterile text lists. Users desire an ambient, living diorama background (reflecting Morning, Afternoon, Golden Hour, and Night) that synchronizes dynamically with real solar and lunar positions (including Hijri-accurate moon phases).
5. **Conflict with Developer Workflow**: Standard desktop notifications can pop up right when an AI coding agent is waiting for critical permission approvals (e.g. bash commands or file edits), obscuring approval buttons or causing notification fatigue.

---

## Solution

Integrate an offline, zero-allocation **Prayer Time & Living Diorama Clock** into CodeIsland's notch panel:

1. **Autonomous Offline Meeus Engine in Core**:
   - Implement an offline astronomical calculation engine in `CodeIslandCore` with **zero external dependencies**, computing exact solar coordinates, equation of time, solar declination, and prayer times according to Jean Meeus's *Astronomical Algorithms*.
   - Provide three first-class preset methodologies:
     - **Kemenag RI**: Fajr $-20^\circ$, Isha $-18^\circ$, Dhuhr $+2\text{m}$ (*istiwa*), Ihtiyati $+2\text{m}$ for prayer times and $-2\text{m}$ on Sunrise, altitude elevation lookup.
     - **NU (LF PBNU)**: Fajr $-20^\circ$, Isha $-18^\circ$, Dhuhr $+1\text{m}$ (*istiwa*), true spherical horizon dip elevation correction, ceiling rounding.
     - **Muhammadiyah (MTT)**: Fajr $-18^\circ$, Isha $-18^\circ$, Dhuhr $+0\text{m}$, zero ihtiyati, ceiling rounding.
2. **Dual-Criteria Hijri Calendar Source**:
   - Bundle a lightweight ($<1\text{ KB}$) verified table of the first 60 lunar months (1447 H – 1451 H) covering both **KHGT** and **Takwim Standar Indonesia (Neo-MABIMS)** for zero-network instantaneous accuracy.
   - Fall back to an astronomical criterion solver for years beyond 1451 H.
   - Provide an instant user adjustment offset ($-2$ to $+2$ days) in Settings to match governmental Sidang Isbat or PBNU *Ikhbar Rukyatul Hilal* announcements.
3. **Privacy-Preserving On-Device Location Acquisition**:
   - Acquire coordinates via `CLLocationManager` using coarse kilometer accuracy (`kCLLocationAccuracyKilometer`) once on startup or when the machine wakes after $>6$ hours, caching coordinates rounded to 2 decimal places ($\approx 1.1\text{ km}$). Coordinates never leave the device.
   - Resolve city names locally using an offline Haversine distance lookup against bundled Indonesian regencies and global capitals.
   - Maintain a 4-tier fallback chain: Manual City $\to$ CoreLocation $\to$ Last Saved Location $\to$ System TimeZone estimate.
4. **Adaptive Visual Surfaces (Pill & Living Diorama Tab)**:
   - **Compact Pill Right Wing**: 38pt tall frameless pill displaying the current time-of-day phase icon (tinted with the active phase color), `HH:mm` timestamp, upcoming prayer name with countdown (e.g., `Ashar -6m`), and a subtle 2.5pt dynamic horizon strip tracing solar progress.
   - **Smart Priority**: During idle periods, the prayer timestamp sits in the right wing. When music or active agent tasks are running, the wing prioritizes music/agent status until prayer time is within $\le 15$ minutes, at which point the prayer countdown takes active priority.
   - **Prayer Mini Peek Toast Banner**: A gentle ~6-second banner appearing under the notch at $T-10\text{m}$ (customizable) and upon prayer entry, automatically delayed if an Agent Approval or Question prompt is currently active.
   - **Expanded `SLT` Tab**: Displays a 138pt living procedural diorama canvas (sky gradient interpolated across 4 phases, sun and Hijri-driven moon arc, drifting clouds, stars, and subtle grounded skyline with glowing windows at dusk/night), a 34pt digital clock, centered city/date subtitle, and 5 interactive prayer capsules, with a 24pt bottom margin for generous breathing room.
5. **Feature Gating & Settings Integration**:
   - Keep the feature entirely hidden by default (disabled toggle under a dedicated **Prayer** page in Settings) so non-interested global users experience no changes to their notch.

---

## User Stories

1. As a developer observing daily prayers, I want CodeIsland to accurately display upcoming prayer times in the notch, so that I can manage my work schedule without missing prayers.
2. As a follower of Muhammadiyah, I want prayer times calculated with the $-18^\circ$ Subuh angle and dates following the global KHGT calendar, so that my notch matches official Muhammadiyah schedules.
3. As a follower of Nahdlatul Ulama or the Ministry of Religious Affairs (Kemenag), I want Subuh calculated at $-20^\circ$ with Kemenag ihtiyati and Neo-MABIMS calendar criteria, so that the timings match local mosque announcements.
4. As a user working offline or without internet access, I want prayer times and Hijri dates computed entirely on-device, so that the feature works reliably in airplanes, trains, or offline development environments.
5. As a privacy-conscious user, I want my location data kept strictly on my local Mac, so that my geographical coordinates are never uploaded to any server.
6. As a developer with multiple apps running, I want the compact notch pill to show current time and prayer countdown without visual clutter or heavy borders.
7. As a user listening to music or running agent tools, I want the right wing of the pill to show music/agent info normally, but automatically shift to prayer countdown when a prayer is $\le 15$ minutes away.
8. As a user reviewing code changes, I want prayer popups to never cover or intercept the Agent Approval or Question dialog, so that critical workflow actions are never interrupted.
9. As a user looking at the expanded notch panel, I want to see an ambient diorama reflecting whether it is Pagi, Siang, Sore, or Malam with accurate moon phases, so that I have a calming visual connection to the outdoor sky.
10. As a user in a quiet office or meeting, I want prayer arrival alerts to be visual-first by default with an optional chime, so that my audio is never interrupted unexpectedly.
11. As a user whose local religious authority announces a moon sighting that differs by 1 day from astronomical calculations, I want a quick $\pm 1..2$ day manual Hijri adjustment in Settings, so that my calendar stays in sync with my community.
12. As a user who does not require Islamic prayer times, I want the feature completely invisible and zero-overhead until explicitly turned on in Settings.

---

## Implementation Decisions

### 1. Astronomical Calculation Engine (`CodeIslandCore`)
- Implement a pure, stateless value-type calculator:
  ```swift
  public enum PrayerCalculationMethod: String, CaseIterable, Sendable {
      case kemenag
      case nuLFPBNU
      case muhammadiyah
  }

  public struct DailyPrayerSchedule: Equatable, Sendable {
      public let imsak: Date
      public let subuh: Date
      public let terbit: Date
      public let dhuha: Date
      public let dzuhur: Date
      public let ashar: Date
      public let maghrib: Date
      public let isya: Date
  }

  public enum PrayerTimeCalculator {
      public static func calculate(
          day: YearMonthDay,
          coordinates: Coordinates,
          elevationMeters: Double,
          method: PrayerCalculationMethod,
          timeZone: TimeZone
      ) -> DailyPrayerSchedule
  }
  ```
- Astronomical formulas follow Meeus's *Astronomical Algorithms*:
  - Julian Day calculation from calendar date.
  - Sun's mean anomaly, mean longitude, ecliptic longitude, obliquity of ecliptic.
  - Right ascension and solar declination ($\delta$).
  - Equation of time ($EoT$).
  - Transit time ($T = 12 + TimeZoneOffset - (Longitude / 15) - (EoT / 60)$).
  - Sun angle hour angle: $\cos(H) = \frac{\sin(\alpha) - \sin(\phi)\sin(\delta)}{\cos(\phi)\cos(\delta)}$.
  - Asr altitude via shadow multiplier ($m = 1$ for Shafi'i/standard): $\text{alt} = \operatorname{arccot}(m + \tan(|\phi - \delta|))$.
  - Dhuha angle: $+4.5^\circ$ above horizon.
  - Imsak: Subuh $- 10$ minutes.
  - Sunrise (Terbit) applies negative ihtiyati ($-2$ minutes) and horizon dip, avoiding Aladhan's positive buffer error.

### 2. Dual Hijri Calendar Engine & Tabular Constant
- Support two distinct calculation schemes:
  ```swift
  public enum HijriCalendarSource: String, CaseIterable, Sendable {
      case khgt          // Global Unified (5° / 8° before 24:00 UT)
      case neoMABIMS     // Regional Southeast Asia (3° / 6.4°)
  }

  public struct HijriDate: Equatable, Sendable {
      public let day: Int
      public let month: Int
      public let year: Int
      public let monthName: String
  }
  ```
- Store the verified table of 60 month boundaries (1447 H to 1451 H) as fixed static arrays in `CodeIslandCore`, requiring $<1\text{ KB}$ of memory.
- For dates past 1451 H, dynamically compute conjunction time and moon-sun altitude/elongation.
- Apply user-configured day offset ($-2 ... +2$) on the resulting Hijri date.

### 3. Location Manager & Offline City Resolution
- Add `NSLocationUsageDescription` to application `Info.plist`.
- Request `kCLLocationAccuracyKilometer` to minimize battery drain.
- Trigger single updates via `requestLocation()` upon app startup and `NSWorkspace.didWakeNotification` if more than 6 hours have elapsed or local date changed.
- Round coordinates stored in `UserDefaults` to 2 decimal places ($\approx 1.1\text{ km}$).
- Match city names against an internal catalog of 514 Indonesian cities/regencies plus global capitals via Haversine distance:
  $$d = 2r \arcsin\left(\sqrt{\sin^2\left(\frac{\Delta \phi}{2}\right) + \cos(\phi_1)\cos(\phi_2)\sin^2\left(\frac{\Delta \lambda}{2}\right)}\right)$$
- If location permissions are denied, silently fallback to time zone default without modal alerts.

### 4. UI Geometry & Living Diorama Integration (`NotchPanelView`)
- **Compact Pill (Idle State)**:
  - Height set to **38pt** with `cornerRadius: 19`, matching hardware notch proportions.
  - Placed in the right wing of the bar, leading the chevron expand button.
  - Displays phase icon, formatted timestamp, next prayer countdown, and a 2.5pt linear gradient horizon strip with a sun/moon indicator dot.
- **Living Diorama (Expanded Tab)**:
  - Add tab identifier `.prayer` to `ExpandedContentTab`.
  - In `RightWingPixelTabs`, display `SALAT` (collapsing to `SLT` when width $<265$).
  - Tab highlight color dynamically reflects the current day phase (Pagi: light amber, Siang: sky blue, Sore: golden amber, Malam: soft indigo).
  - Banner height set to **138pt** with `cornerRadius: 16`.
  - Skyline silhouette rendered at the base (`baseSkylineY = 0.92`, `skylineHeight: 0.12`) with procedural window lights at night.
  - Subtitle text (*City · Day Date · Hijri Date*) centered between clock numbers and banner bottom.
  - Notch container card features a **24pt bottom margin** (`cornerRadius: 24`), giving generous separation between the 5 prayer capsules and the bottom rounded border.
- **Prayer Mini Peek Toast Banner**:
  - Emitted at $T-10\text{m}$ (user-adjustable: Off, 5m, 10m, 15m) and on entry ($T-0\text{m}$).
  - Automatically suppressed and queued while an agent approval or question is pending (`waitingApproval` or `waitingQuestion`).

### 5. Settings Configuration Schema
- Add dedicated `prayer` page to `SettingsPage` under group "CodeIsland".
- Settings keys:
  - `prayerEnabled`: Bool (default `false`)
  - `prayerCalculationMethod`: String (`"kemenag"`, `"nuLFPBNU"`, `"muhammadiyah"`)
  - `prayerHijriCalendarSource`: String (`"khgt"`, `"neoMABIMS"`)
  - `prayerHijriDayOffset`: Int (`-2...2`, default `0`)
  - `prayerLocationMode`: String (`"automatic"`, `"manual"`)
  - `prayerManualCityId`: String
  - `prayerAlertBeforeMinutes`: Int (`10`)
  - `prayerSoundEnabled`: Bool (`false`)
  - `prayerSystemNotificationEnabled`: Bool (`false`)

---

## Testing Decisions

### Test Principles
1. **Zero Network Dependence**: All unit tests must pass completely offline without making external HTTP requests or reverse-geocoding calls.
2. **Deterministic Seam Testing**: Solar and lunar coordinate outputs must be tested against verified reference tables across geographical and seasonal extremes.
3. **No Flaky Timing**: Time-dependent calculations must take explicit `Date` arguments rather than referencing system clock `Date()`.

### Modules Under Test
1. **`CodeIslandCoreTests/PrayerTimeCalculatorTests.swift`**:
   - Golden fixture testing for 6 reference cities:
     - Banda Aceh ($5.55^\circ\text{ N}, 95.32^\circ\text{ E}$)
     - Jakarta ($-6.21^\circ\text{ S}, 106.85^\circ\text{ E}$)
     - Surabaya ($-7.25^\circ\text{ S}, 112.75^\circ\text{ E}$)
     - Pontianak ($0.00^\circ\text{ N}, 109.34^\circ\text{ E}$)
     - Makassar ($-5.15^\circ\text{ S}, 119.43^\circ\text{ E}$)
     - Jayapura ($-2.54^\circ\text{ S}, 140.72^\circ\text{ E}$)
   - Evaluated across 4 key astronomical points: Vernal Equinox (March 20), Summer Solstice (June 21), Autumnal Equinox (September 22), Winter Solstice (December 21), plus validation test date `2026-01-15`.
   - Tolerance assertion: $100\%$ of calculated prayer times within $\le 1$ minute of official Kemenag and KHGT tables ($\ge 90\%$ exact 0-minute matches).
2. **`CodeIslandCoreTests/HijriCalendarTests.swift`**:
   - Boundary tests for KHGT and Neo-MABIMS month transitions for 1447 H through 1451 H.
   - Verification of manual day offset arithmetic ($-2 ... +2$).
3. **`CodeIslandTests/PrayerManagerLifecycleTests.swift`**:
   - Smart priority switching between idle, music playback, and active agent states.
   - Verification that Mini Peek Banner is delayed when `appState.status == .waitingApproval`.

### Prior Art in Codebase
- `SpotifyWebDetectionTests.swift`: Pure function parser verification against static HTML and title fixtures.
- `NowPlayingLyricSyncTests.swift`: Deterministic mock timestamp and tolerance testing.
- `FloatingLyricPresetTests.swift`: Value-type layout and setting serialization coverage.

---

## Out of Scope

1. **Full Adhan Audio Files**: Bundling full recitations of the Adhan is out of scope due to asset licensing restrictions. Only lightweight procedural chimes / 8-bit tones are provided.
2. **Global City Database Expansion**: Bundling tens of thousands of global villages (like Oyenza's 33,000 cities) is out of scope. City resolution focuses on Indonesia's 514 regencies and major global capitals.
3. **Companion Push (iOS/Watch/ESP32 v1)**: Pushing prayer times from Mac to mobile or wearable devices over BLE is explicitly deferred. Calculators reside in `CodeIslandCore` for future client-side execution on those devices.
4. **Third-Party Plugin Architecture**: Building a generalized dynamic plugin loader for the prayer feature is out of scope; direct integration behind a Settings toggle provides complete isolation.

---

## Further Notes

- Once this specification is implemented, the throwaway visual prototype file `Sources/CodeIsland/PrayerPrototype.swift` and the temporary `--prayer-prototype` entry hook in `AppDelegate.swift` will be deleted.
- The procedural diorama canvas consumes 0 bytes of raster image assets, ensuring that application bundle size remains lightweight.
