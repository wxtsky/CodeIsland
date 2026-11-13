import SwiftUI
import AppKit

// MARK: - MagSafe Charging Dynamic Island Banner

public struct MagSafeChargingBanner: View {
    let batteryLevel: Int
    @State private var pulseRing = false

    public init(batteryLevel: Int) {
        self.batteryLevel = batteryLevel
    }

    private var chargingGreen: Color {
        Color(red: 0.19, green: 0.82, blue: 0.35) // Apple MagSafe Emerald (#30D158)
    }

    public var body: some View {
        HStack(spacing: 11) {
            // Glowing MagSafe Energy Puck
            ZStack {
                // Background Track
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 2.6)
                    .frame(width: 26, height: 26)

                // Dynamic Charge Progress Arc
                Circle()
                    .trim(from: 0.0, to: max(0.06, CGFloat(batteryLevel) / 100.0))
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                chargingGreen.opacity(0.7),
                                chargingGreen
                            ]),
                            center: .center,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(270)
                        ),
                        style: StrokeStyle(lineWidth: 2.6, lineCap: .round)
                    )
                    .frame(width: 26, height: 26)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: chargingGreen.opacity(0.45), radius: 3)

                // Center Pulsing Bolt
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(chargingGreen)
                    .scaleEffect(pulseRing ? 1.12 : 0.92)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    pulseRing = true
                }
            }

            // Power Details
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4.5) {
                    Text("MAGSAFE")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .tracking(0.6)

                    Text("•")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.28))

                    Text("CHARGING")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(chargingGreen)
                        .tracking(0.5)
                }

                Text(batteryLevel >= 100 ? "Battery Fully Charged" : "Fast Power Delivery Connected")
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.55))
            }

            Spacer(minLength: 8)

            // Battery Percentage & Hardware Capsule
            HStack(spacing: 5.5) {
                Text("\(batteryLevel)%")
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)

                // Mini Hardware Battery Indicator
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.9)
                        .frame(width: 19, height: 9.5)

                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(chargingGreen)
                        .frame(width: max(2, 15 * CGFloat(batteryLevel) / 100.0), height: 5.5)
                        .padding(.leading, 2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                )
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 5)
    }
}

// MARK: - Compact Cyber System Telemetry Gauge Bar

public struct CyberSystemGaugeBar: View {
    @ObservedObject private var sys = SystemMonitorManager.shared

    public init() {}

    public var body: some View {
        let m = sys.metrics
        HStack(spacing: 8) {
            // CPU
            HStack(spacing: 3) {
                Image(systemName: "cpu")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(m.cpuUsagePercent > 75 ? Color(red: 1.0, green: 0.16, blue: 0.53) : Color(red: 0.0, green: 0.96, blue: 0.83))
                Text(String(format: "%.0f%%", m.cpuUsagePercent))
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)
            }

            // RAM
            HStack(spacing: 3) {
                Image(systemName: "memorychip")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color(red: 0.0, green: 0.90, blue: 0.46))
                Text(String(format: "%.1fG", m.memoryUsedGB))
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.9))
            }

            // Network Speed
            HStack(spacing: 3) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.6))
                Text(SystemMonitorManager.formatSpeed(m.downloadBytesPerSec))
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.0, green: 0.96, blue: 0.83))
            }

            // Battery
            HStack(spacing: 2) {
                Image(systemName: m.isCharging ? "battery.100.bolt" : "battery.75")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(m.isCharging ? Color(red: 0.0, green: 0.90, blue: 0.46) : Color.white.opacity(0.8))
                Text("\(m.batteryLevel)%")
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(
            RoundedRectangle(cornerRadius: 3.5)
                .fill(Color(white: 0.08))
                .overlay(RoundedRectangle(cornerRadius: 3.5).stroke(Color(white: 0.16), lineWidth: 0.6))
        )
    }
}
