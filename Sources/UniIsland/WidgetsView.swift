import SwiftUI
import UniIslandCore

// MARK: - Pomodoro Card
struct PomodoroCard: View {
    var appState: AppState
    let session: SessionSnapshot
    
    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize
    private var fontSize: CGFloat { CGFloat(contentFontSize) }
    
    private var progress: Double {
        let total = appState.pomodoroTotalDuration > 0 ? appState.pomodoroTotalDuration : 25.0 * 60.0
        return 1.0 - (appState.pomodoroRemaining / total)
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Left Mascot Column (Typing Cat!)
            MascotView(source: "pomodoro", status: session.status, size: 36)
                .frame(width: 36, height: 36)
            
            // Center Details
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    Text(appState.pomodoroLabel)
                        .font(.system(size: fontSize + 1, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.2)) // Neon Orange
                    
                    Text("• Pomodoro")
                        .font(.system(size: fontSize - 1, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                
                // Monospace Timer Readout
                Text(appState.formattedRemainingTime())
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .scaleEffect(appState.pomodoroActive && !appState.pomodoroPaused ? 1.02 : 1.0)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: appState.pomodoroActive && !appState.pomodoroPaused)
                
                // Focus progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.12))
                            .frame(height: 6)
                        
                        Capsule()
                            .fill(LinearGradient(
                                colors: [Color(red: 1.0, green: 0.4, blue: 0.1), Color(red: 1.0, green: 0.2, blue: 0.6)],
                                startPoint: .leading, endPoint: .trailing
                            ))
                            .frame(width: geo.size.width * CGFloat(min(1.0, max(0.0, progress))), height: 6)
                            .shadow(color: Color(red: 1.0, green: 0.3, blue: 0.4).opacity(0.5), radius: 3)
                    }
                }
                .frame(height: 6)
            }
            
            Spacer(minLength: 4)
            
            // Right Control Deck
            HStack(spacing: 8) {
                // Play / Pause Button
                Button {
                    appState.togglePomodoro()
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(0.08))
                            .frame(width: 26, height: 26)
                        
                        Image(systemName: appState.pomodoroActive && !appState.pomodoroPaused ? "pause.fill" : "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(appState.pomodoroActive && !appState.pomodoroPaused ? Color.orange : Color.green)
                    }
                }
                .buttonStyle(.plain)
                
                // Reset Button
                Button {
                    appState.resetPomodoro()
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(0.08))
                            .frame(width: 26, height: 26)
                        
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
    }
}

// MARK: - Stats Card
struct StatsCard: View {
    var appState: AppState
    let session: SessionSnapshot
    
    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize
    private var fontSize: CGFloat { CGFloat(contentFontSize) }
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Retro CPU Chip Core Icon
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.purple.opacity(0.15))
                    .frame(width: 32, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.purple.opacity(0.4), lineWidth: 1)
                    )
                
                Image(systemName: "cpu")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(red: 0.65, green: 0.45, blue: 1.00))
            }
            
            // Grid of Metrics
            VStack(alignment: .leading, spacing: 6) {
                // Top Line: Titles
                HStack {
                    Text("系统状态")
                        .font(.system(size: fontSize + 1, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.65, green: 0.45, blue: 1.00)) // Neon Purple
                    
                    Text("• Activity Monitor")
                        .font(.system(size: fontSize - 1, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                    
                    Spacer()
                }
                
                // CPU & Memory Gauges Row
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CPU: \(Int(appState.cpuUsage))%")
                            .font(.system(size: fontSize - 1, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                        
                        MiniProgressGauge(value: appState.cpuUsage / 100.0, color: Color.cyan)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MEM: \(Int(appState.memUsage))%")
                            .font(.system(size: fontSize - 1, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                        
                        MiniProgressGauge(value: appState.memUsage / 100.0, color: Color.purple)
                    }
                }
                
                // Network speeds row
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.green)
                    Text(formatBytes(appState.netDownloadSpeed))
                        .font(.system(size: fontSize - 1, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.green.opacity(0.85))
                    
                    Spacer().frame(width: 8)
                    
                    Image(systemName: "arrow.up")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.orange)
                    Text(formatBytes(appState.netUploadSpeed))
                        .font(.system(size: fontSize - 1, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.orange.opacity(0.85))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
    }
    
    private func formatBytes(_ speedBytes: Double) -> String {
        if speedBytes < 1024 {
            return String(format: "%.0f B/s", speedBytes)
        } else if speedBytes < 1024 * 1024 {
            return String(format: "%.1f KB/s", speedBytes / 1024.0)
        } else {
            return String(format: "%.1f MB/s", speedBytes / (1024.0 * 1024.0))
        }
    }
}

private struct MiniProgressGauge: View {
    let value: Double
    let color: Color
    
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.1))
                .frame(width: 90, height: 4)
            
            Capsule()
                .fill(color)
                .frame(width: 90 * CGFloat(min(1.0, max(0.0, value))), height: 4)
        }
    }
}

// MARK: - Media Card
struct MediaCard: View {
    var appState: AppState
    let session: SessionSnapshot
    
    @State private var diskRotation = 0.0
    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize
    private var fontSize: CGFloat { CGFloat(contentFontSize) }
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Spinning Record
            ZStack {
                Circle()
                    .fill(.black)
                    .frame(width: 34, height: 34)
                    .overlay(
                        Circle()
                            .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                    )
                
                // Record grooves
                Circle()
                    .stroke(.white.opacity(0.08), lineWidth: 3)
                    .frame(width: 24, height: 24)
                
                // Center Label
                Circle()
                    .fill(Color(red: 0.15, green: 0.85, blue: 0.35)) // Neon Green
                    .frame(width: 10, height: 10)
                
                // Spinning Note indicator
                Image(systemName: "music.note")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.black)
            }
            .rotationEffect(.degrees(diskRotation))
            .onAppear {
                if session.status == .processing {
                    withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) {
                        diskRotation = 360.0
                    }
                }
            }
            .onChange(of: session.status) {
                if session.status == .processing {
                    withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) {
                        diskRotation = 360.0
                    }
                } else {
                    diskRotation = 0.0
                }
            }
            
            // Song Details
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    Text("媒体控制器")
                        .font(.system(size: fontSize + 1, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.15, green: 0.85, blue: 0.35))
                    
                    Text("• Now Playing")
                        .font(.system(size: fontSize - 1, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                
                // Track & Artist
                VStack(alignment: .leading, spacing: 1) {
                    Text(appState.mediaTrackName)
                        .font(.system(size: fontSize, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    
                    Text(appState.mediaArtistName)
                        .font(.system(size: fontSize - 1, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            
            Spacer(minLength: 4)
            
            // Media Control Deck
            HStack(spacing: 6) {
                // Prev
                Button {
                    appState.controlMedia("previous")
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(0.08))
                            .frame(width: 24, height: 24)
                        Image(systemName: "backward.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .buttonStyle(.plain)
                
                // Play / Pause
                Button {
                    appState.controlMedia("playpause")
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(0.08))
                            .frame(width: 24, height: 24)
                        Image(systemName: session.status == .processing ? "pause.fill" : "play.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .buttonStyle(.plain)
                
                // Next
                Button {
                    appState.controlMedia("next")
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(0.08))
                            .frame(width: 24, height: 24)
                        Image(systemName: "forward.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
    }
}

// MARK: - Battery Card (SuperIsland Port)
struct BatteryCard: View {
    var appState: AppState
    let session: SessionSnapshot
    
    @State private var pulseWarning = false
    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize
    private var fontSize: CGFloat { CGFloat(contentFontSize) }
    
    private var isLowBattery: Bool {
        return appState.batteryPercent <= 20
    }
    
    private var batteryColor: Color {
        if appState.isCharging {
            return Color(red: 0.15, green: 0.85, blue: 0.35) // Neon Green
        } else if isLowBattery {
            return Color(red: 1.00, green: 0.20, blue: 0.20) // Neon Red
        } else {
            return Color(red: 0.15, green: 0.70, blue: 1.00) // Neon Blue
        }
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Neon Battery Icon
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(batteryColor.opacity(0.6), lineWidth: 1.5)
                    .frame(width: 28, height: 16)
                
                // Fill
                RoundedRectangle(cornerRadius: 2)
                    .fill(batteryColor)
                    .frame(width: CGFloat(22.0 * Double(appState.batteryPercent) / 100.0), height: 10)
                
                // Battery tip
                RoundedRectangle(cornerRadius: 1)
                    .fill(batteryColor.opacity(0.6))
                    .frame(width: 2, height: 6)
                    .offset(x: 14)
                
                if appState.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
            }
            .scaleEffect(isLowBattery && pulseWarning ? 1.08 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isLowBattery && pulseWarning)
            .onAppear {
                if isLowBattery {
                    pulseWarning = true
                }
            }
            .onChange(of: appState.batteryPercent) {
                pulseWarning = isLowBattery
            }
            
            // Battery details
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    Text("电池状态")
                        .font(.system(size: fontSize + 1, weight: .bold, design: .monospaced))
                        .foregroundStyle(batteryColor)
                    
                    Text("• Battery State")
                        .font(.system(size: fontSize - 1, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                
                HStack {
                    Text("\(appState.batteryPercent)%")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    
                    Text(appState.isCharging ? "(正在充电)" : "(\(appState.batteryTimeRemainingDescription))")
                        .font(.system(size: fontSize - 1, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(batteryColor.opacity(isLowBattery && pulseWarning ? 0.35 : 0.0), lineWidth: 1.5)
                )
        )
    }
}

// MARK: - Calendar Card (SuperIsland Port)
struct CalendarCard: View {
    var appState: AppState
    let session: SessionSnapshot
    
    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize
    private var fontSize: CGFloat { CGFloat(contentFontSize) }
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Retro 8-bit Calendar Icon
            VStack(spacing: 0) {
                // Red banner
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 30, height: 8)
                
                // White page
                ZStack {
                    Rectangle()
                        .fill(.white)
                        .frame(width: 30, height: 22)
                    
                    Text(getDayString())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.white.opacity(0.2), lineWidth: 1)
            )
            
            // Details
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    Text("日程管理")
                        .font(.system(size: fontSize + 1, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 1.00, green: 0.35, blue: 0.35)) // Neon Red
                    
                    Text("• Calendar Planner")
                        .font(.system(size: fontSize - 1, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                
                // Event Title
                Text(appState.calendarEventTitle)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                
                // Time / Countdown label
                Text(appState.calendarEventCountdown)
                    .font(.system(size: fontSize - 1, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
            }
            
            Spacer(minLength: 4)
            
            // Join Link Button
            if let link = appState.calendarJoinLink, !link.isEmpty {
                Button {
                    if let url = URL(string: link) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("一键入会")
                        .font(.system(size: fontSize - 1, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(red: 0.2, green: 0.6, blue: 1.0))
                        )
                        .shadow(color: Color(red: 0.2, green: 0.6, blue: 1.0).opacity(0.4), radius: 3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
    }
    
    private func getDayString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "dd"
        return fmt.string(from: Date())
    }
}
