import Foundation
import SwiftUI
import Combine
@preconcurrency import UserNotifications
import CodeIslandCore

public enum DayPhase: String, CaseIterable, Sendable {
    case pagi
    case siang
    case sore
    case malam

    public var displayName: String {
        switch self {
        case .pagi: return "PAGI"
        case .siang: return "SIANG"
        case .sore: return "SORE"
        case .malam: return "MALAM"
        }
    }

    public var systemImage: String {
        switch self {
        case .pagi: return "sun.and.horizon.fill"
        case .siang: return "sun.max.fill"
        case .sore: return "sun.dust.fill"
        case .malam: return "moon.stars.fill"
        }
    }

    public var accentColor: Color {
        switch self {
        case .pagi: return Color(red: 1.0, green: 0.78, blue: 0.35)
        case .siang: return Color(red: 0.35, green: 0.75, blue: 1.0)
        case .sore: return Color(red: 1.0, green: 0.55, blue: 0.25)
        case .malam: return Color(red: 0.55, green: 0.55, blue: 0.95)
        }
    }

    public var skyGradientColors: [Color] {
        switch self {
        case .pagi:
            return [
                Color(red: 0.25, green: 0.45, blue: 0.75),
                Color(red: 0.95, green: 0.70, blue: 0.45)
            ]
        case .siang:
            return [
                Color(red: 0.20, green: 0.50, blue: 0.85),
                Color(red: 0.65, green: 0.80, blue: 0.95)
            ]
        case .sore:
            return [
                Color(red: 0.40, green: 0.20, blue: 0.55),
                Color(red: 0.95, green: 0.45, blue: 0.25),
                Color(red: 0.98, green: 0.75, blue: 0.35)
            ]
        case .malam:
            return [
                Color(red: 0.05, green: 0.06, blue: 0.15),
                Color(red: 0.12, green: 0.14, blue: 0.30)
            ]
        }
    }
}

/// Central state manager for prayer calculations, living clock, day phase, and smart priority.
@MainActor
public final class PrayerTimeManager: ObservableObject {
    public static let shared = PrayerTimeManager()

    @Published public private(set) var todaySchedule: DailyPrayerSchedule?
    @Published public private(set) var tomorrowSubuh: Date?
    @Published public private(set) var currentPhase: DayPhase = .siang
    @Published public private(set) var upcomingPrayer: (prayer: PrayerType, date: Date)?
    @Published public private(set) var minutesUntilNextPrayer: Int = 0
    @Published public private(set) var currentTimeString: String = "12:00"
    @Published public private(set) var currentSecondsString: String = "12:00:00"
    @Published public private(set) var hijriDateString: String = ""
    @Published public private(set) var hijriDay: Int = 1
    @Published public private(set) var gregorianDateString: String = ""
    @Published public private(set) var currentFractionalHour: Double = 12.0
    @Published public private(set) var solarProgress: Double = 0.5
    @Published public var showMiniPeekBanner: Bool = false
    @Published public private(set) var miniPeekBannerTitle: String = ""
    @Published public private(set) var miniPeekBannerSubtitle: String = ""
    public var simulatedDate: Date? = nil

    weak var appState: AppState?

    public var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.prayerEnabled)
    }

    /// Smart Priority: Takes over the compact right wing when a prayer is within <= 15 minutes.
    public var isPrayerPrioritized: Bool {
        guard isEnabled, let next = upcomingPrayer else { return false }
        let timeRemaining = next.date.timeIntervalSince(Date())
        // Active when within 15 mins before prayer, or up to 5 mins after prayer entry
        return timeRemaining <= 15 * 60 && timeRemaining >= -5 * 60
    }

    public var formattedCountdown: String {
        let m = minutesUntilNextPrayer
        return m >= 60 ? "\(m / 60)j \(m % 60)m" : "\(m)m"
    }

    public var cityName: String {
        locationService.displayName
    }

    public var sunriseHour: Double {
        guard let s = todaySchedule else { return 5.75 }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = locationService.activeCity.timeZone
        let c = cal.dateComponents([.hour, .minute, .second], from: s.terbit)
        return Double(c.hour ?? 5) + Double(c.minute ?? 45) / 60.0 + Double(c.second ?? 0) / 3600.0
    }

    public var sunsetHour: Double {
        guard let s = todaySchedule else { return 18.3 }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = locationService.activeCity.timeZone
        let c = cal.dateComponents([.hour, .minute, .second], from: s.maghrib)
        return Double(c.hour ?? 18) + Double(c.minute ?? 18) / 60.0 + Double(c.second ?? 0) / 3600.0
    }

    public func formattedPrayerTime(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = locationService.activeCity.timeZone
        let comps = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }

    private var cancellables = Set<AnyCancellable>()
    private var timerCancellable: AnyCancellable?
    private var lastCalculatedDay: YearMonthDay?
    private let locationService = PrayerLocationService.shared
    private var triggeredAlerts = Set<String>()
    private var pendingBanner: (title: String, subtitle: String)? = nil
    private var bannerDismissTask: Task<Void, Never>? = nil

    private let gregorianDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "id_ID")
        df.dateFormat = "EEEE d MMM"
        return df
    }()
    private var cachedGregorianDay: Int = -1

    private init() {
        setupSubscriptions()
        updateTimerState()
    }

    public func forceRecalculate() {
        recalculateSchedule(force: true)
        tick()
    }

    // MARK: - Subscriptions & Lifecycle

    private func setupSubscriptions() {
        // Recalculate when city/coordinates change
        locationService.$activeCity
            .sink { [weak self] _ in
                self?.recalculateSchedule(force: true)
                self?.tick()
            }
            .store(in: &cancellables)

        locationService.$preciseCoordinates
            .sink { [weak self] _ in
                self?.recalculateSchedule(force: true)
                self?.tick()
            }
            .store(in: &cancellables)

        // Observe user settings changes in UserDefaults
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateTimerState()
            }
            .store(in: &cancellables)
    }

    private func updateTimerState() {
        if isEnabled {
            if timerCancellable == nil {
                timerCancellable = Timer.publish(every: 1.0, on: .main, in: .common)
                    .autoconnect()
                    .sink { [weak self] _ in
                        self?.tick()
                    }
            }
            recalculateSchedule(force: false)
            tick()
        } else {
            timerCancellable?.cancel()
            timerCancellable = nil
            todaySchedule = nil
            tomorrowSubuh = nil
            upcomingPrayer = nil
            dismissMiniPeekBanner()
        }
    }

    // MARK: - Daily Recalculation (Zero-allocation per second)

    private func recalculateSchedule(force: Bool) {
        guard isEnabled else { return }

        let coords = locationService.effectiveCoordinates
        let elevation = locationService.effectiveElevation
        let tz = locationService.activeCity.timeZone
        let todayYMD = YearMonthDay(date: Date(), timeZone: tz)

        if !force && lastCalculatedDay == todayYMD && todaySchedule != nil {
            return
        }

        let methodRaw = UserDefaults.standard.string(forKey: SettingsKey.prayerCalculationMethod) ?? SettingsDefaults.prayerCalculationMethod
        let method = PrayerCalculationMethod(rawValue: methodRaw) ?? .kemenag

        // 1. Calculate today's schedule with user's effective coordinates & elevation
        let schedule = PrayerTimeCalculator.calculate(
            day: todayYMD,
            coordinates: coords,
            elevationMeters: elevation,
            method: method,
            timeZone: tz
        )
        self.todaySchedule = schedule

        // 2. Calculate tomorrow's Subuh
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        if let tomorrowDate = cal.date(byAdding: .day, value: 1, to: Date()) {
            let tomorrowYMD = YearMonthDay(date: tomorrowDate, timeZone: tz)
            let tomorrowSchedule = PrayerTimeCalculator.calculate(
                day: tomorrowYMD,
                coordinates: coords,
                elevationMeters: elevation,
                method: method,
                timeZone: tz
            )
            self.tomorrowSubuh = tomorrowSchedule.subuh
        }

        // 3. Calculate Hijri date
        let hijriSourceRaw = UserDefaults.standard.string(forKey: SettingsKey.prayerHijriCalendarSource) ?? SettingsDefaults.prayerHijriCalendarSource
        let hijriSource = HijriCalendarSource(rawValue: hijriSourceRaw) ?? .neoMABIMS
        let offset = UserDefaults.standard.integer(forKey: SettingsKey.prayerHijriDayOffset)
        let hijriDate = HijriCalendarCalculator.calculate(day: todayYMD, source: hijriSource, manualOffsetDays: offset)
        self.hijriDateString = hijriDate.formattedString
        self.hijriDay = hijriDate.day

        self.lastCalculatedDay = todayYMD
    }

    // MARK: - Per-Second Tick

    internal func tick(now: Date = Date()) {
        guard isEnabled else { return }

        let now = simulatedDate ?? now
        let tz = locationService.activeCity.timeZone

        // Update formatted time
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let h = comps.hour ?? 0
        let m = comps.minute ?? 0
        let s = comps.second ?? 0

        self.currentTimeString = String(format: "%02d:%02d", h, m)
        self.currentSecondsString = String(format: "%02d:%02d:%02d", h, m, s)

        // Solar 24h progress [0..1] and fractional hour [0..24)
        let totalSeconds = Double(h * 3600 + m * 60 + s)
        self.solarProgress = totalSeconds / 86400.0
        self.currentFractionalHour = totalSeconds / 3600.0

        // Cached DateFormatter: formatted string only recalculated when calendar day changes
        let day = comps.day ?? 0
        if cachedGregorianDay != day {
            cachedGregorianDay = day
            gregorianDateFormatter.timeZone = tz
            self.gregorianDateString = gregorianDateFormatter.string(from: now)
        }

        // Auto-recalculate if midnight rolled over
        let todayYMD = YearMonthDay(year: comps.year ?? 2026, month: comps.month ?? 1, day: comps.day ?? 1)
        if lastCalculatedDay != todayYMD {
            recalculateSchedule(force: true)
        }

        guard let schedule = todaySchedule else { return }

        // Determine current phase
        if now < schedule.subuh {
            self.currentPhase = .malam
        } else if h < 11 {
            self.currentPhase = .pagi
        } else if now < schedule.ashar {
            self.currentPhase = .siang
        } else if now < schedule.maghrib {
            self.currentPhase = .sore
        } else {
            self.currentPhase = .malam
        }

        // Upcoming fardh prayer & countdown
        if let next = schedule.nextFardhPrayer(at: now, tomorrowSubuh: tomorrowSubuh) {
            self.upcomingPrayer = next
            let diff = next.date.timeIntervalSince(now)
            self.minutesUntilNextPrayer = Int(ceil(diff / 60.0))
        }

        // Evaluate mini peek banners directly in tick loop
        evaluateBannerTriggers(appState: self.appState)
    }

    // MARK: - Mini Peek Toast Banner & Agent Suppression

    public func dismissMiniPeekBanner() {
        showMiniPeekBanner = false
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
    }

    private func scheduleBannerAutoDismiss() {
        bannerDismissTask?.cancel()
        bannerDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    self.showMiniPeekBanner = false
                }
            }
        }
    }

    /// Evaluates if banner should pop up, deferring if an agent approval or question dialog is currently visible.
    func evaluateBannerTriggers(appState: AppState?) {
        guard isEnabled, let next = upcomingPrayer else { return }

        let alertBeforeMinutes = UserDefaults.standard.integer(forKey: SettingsKey.prayerAlertBeforeMinutes)
        let diffMins = minutesUntilNextPrayer

        // Trigger 1: Approaching prayer (e.g. T-10m)
        if alertBeforeMinutes > 0 && diffMins == alertBeforeMinutes {
            let key = "\(next.prayer.rawValue)-\(alertBeforeMinutes)"
            if !triggeredAlerts.contains(key) {
                triggeredAlerts.insert(key)
                let title = "\(alertBeforeMinutes) Menit Menuju \(next.prayer.displayName)"
                let subtitle = "\(currentTimeString) · \(locationService.displayName)"
                enqueueOrPresentBanner(title: title, subtitle: subtitle, appState: appState)
            }
        }

        // Trigger 2: Prayer entry (T-0m)
        if diffMins == 0 {
            let key = "\(next.prayer.rawValue)-0"
            if !triggeredAlerts.contains(key) {
                triggeredAlerts.insert(key)
                let title = "Waktu \(next.prayer.displayName) Telah Masuk"
                let subtitle = "\(currentTimeString) · \(locationService.displayName)"
                enqueueOrPresentBanner(title: title, subtitle: subtitle, appState: appState)
            }
        }

        // Check if pending banner can now be presented (after agent approval finishes)
        if pendingBanner != nil {
            checkAndFlushPendingBanner(appState: appState)
        }
    }

    func isAgentBusy(appState: AppState?) -> Bool {
        guard let state = appState else { return false }
        if state.status == .waitingApproval || state.status == .waitingQuestion {
            return true
        }
        if case .approvalCard = state.surface {
            return true
        }
        return false
    }

    private func enqueueOrPresentBanner(title: String, subtitle: String, appState: AppState?) {
        if isAgentBusy(appState: appState) {
            // Agent-Aware Suppression: hold in queue
            pendingBanner = (title, subtitle)
        } else {
            presentBanner(title: title, subtitle: subtitle)
        }
    }

    func checkAndFlushPendingBanner(appState: AppState?) {
        guard let pending = pendingBanner else { return }
        if !isAgentBusy(appState: appState) {
            pendingBanner = nil
            presentBanner(title: pending.title, subtitle: pending.subtitle)
        }
    }

    func queueBannerForTesting(title: String, subtitle: String, appState: AppState?) {
        enqueueOrPresentBanner(title: title, subtitle: subtitle, appState: appState)
    }

    private func presentBanner(title: String, subtitle: String) {
        miniPeekBannerTitle = title
        miniPeekBannerSubtitle = subtitle
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            showMiniPeekBanner = true
        }
        scheduleBannerAutoDismiss()
        playChimeIfConfigured()
        sendSystemNotificationIfConfigured(title: title, subtitle: subtitle)
    }

    private func playChimeIfConfigured() {
        guard UserDefaults.standard.bool(forKey: SettingsKey.prayerSoundEnabled) else { return }
        if UserDefaults.standard.bool(forKey: SettingsKey.quietHoursEnabled) {
            let start = UserDefaults.standard.integer(forKey: SettingsKey.quietHoursStart)
            let end = UserDefaults.standard.integer(forKey: SettingsKey.quietHoursEnd)
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
            let mins = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            if SoundManager.isInQuietHours(minutesSinceMidnight: mins, start: start, end: end) {
                return
            }
        }
        NSSound(named: "Glass")?.play()
    }

    private func sendSystemNotificationIfConfigured(title: String, subtitle: String) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.prayerSystemNotificationEnabled) else { return }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = subtitle
            if UserDefaults.standard.bool(forKey: SettingsKey.prayerSoundEnabled) {
                content.sound = .default
            }

            let request = UNNotificationRequest(
                identifier: "prayer-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("Failed to deliver prayer notification: \(error)")
                }
            }
        }
    }
}
