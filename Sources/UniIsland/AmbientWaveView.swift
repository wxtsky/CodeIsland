import SwiftUI
import UniIslandCore

/// A beautiful, futuristic voice-assistant style neon sine wave visualizer.
/// Displays overlapping fluid waves that react dynamically to the Agent's active/idle status.
struct AmbientWaveView: View {
    let status: AgentStatus

    // Premium assistant neon gradients
    private static let cyanLt = Color(red: 0.15, green: 0.85, blue: 1.00) // Neon Cyan
    private static let pinkLt = Color(red: 1.00, green: 0.20, blue: 0.70) // Hot Pink/Magenta
    private static let violetLt = Color(red: 0.55, green: 0.25, blue: 1.00) // Bright Violet
    private static let greenLt = Color(red: 0.20, green: 0.85, blue: 0.35) // WeChat green (used in wechat state)

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { c, sz in
                // Set up parameters based on agent status
                let isThinking: Bool
                switch status {
                case .processing, .running:
                    isThinking = true
                default:
                    isThinking = false
                }

                let baseAmplitude: CGFloat = isThinking ? 9.5 : 3.5
                let baseSpeed: Double = isThinking ? 6.8 : 1.8
                let baseFrequency: CGFloat = isThinking ? 0.045 : 0.03

                // We draw 3 overlapping waves with offset phases and speeds
                drawWave(
                    context: c,
                    size: sz,
                    time: t,
                    amplitude: baseAmplitude,
                    speed: baseSpeed,
                    frequency: baseFrequency,
                    phaseOffset: 0.0,
                    gradient: Gradient(colors: [Self.cyanLt.opacity(0.8), Self.violetLt.opacity(0.4)]),
                    lineWidth: 2.0
                )

                drawWave(
                    context: c,
                    size: sz,
                    time: t,
                    amplitude: baseAmplitude * 0.75,
                    speed: baseSpeed * 1.35,
                    frequency: baseFrequency * 0.8,
                    phaseOffset: .pi * 0.5,
                    gradient: Gradient(colors: [Self.pinkLt.opacity(0.7), Self.violetLt.opacity(0.3)]),
                    lineWidth: 1.5
                )

                drawWave(
                    context: c,
                    size: sz,
                    time: t,
                    amplitude: baseAmplitude * 0.45,
                    speed: baseSpeed * 0.8,
                    frequency: baseFrequency * 1.25,
                    phaseOffset: .pi * 1.1,
                    gradient: Gradient(colors: [Self.cyanLt.opacity(0.6), Self.pinkLt.opacity(0.3)]),
                    lineWidth: 1.0
                )
            }
        }
        .frame(maxHeight: 32)
    }

    private func drawWave(
        context c: GraphicsContext,
        size sz: CGSize,
        time t: Double,
        amplitude: CGFloat,
        speed: Double,
        frequency: CGFloat,
        phaseOffset: CGFloat,
        gradient: Gradient,
        lineWidth: CGFloat
    ) {
        let midY = sz.height / 2
        let width = sz.width
        let phase = CGFloat(t * speed) + phaseOffset

        var path = Path()
        path.move(to: CGPoint(x: 0, y: midY))

        // Sample points along the width of the canvas
        let step: CGFloat = 2.0
        for x in stride(from: 0.0, through: width, by: step) {
            // Apply a nice envelope so the wave pinches down at both edges (left/right)
            // envelope ranges from 0 to 1, being 0 at edges and 1 in the middle
            let normalizedX = x / width
            let envelope = sin(normalizedX * .pi)

            let y = midY + sin(x * frequency - phase) * amplitude * envelope
            path.addLine(to: CGPoint(x: x, y: y))
        }

        // Draw a glowing shadow under the path
        c.drawLayer { shadowContext in
            shadowContext.addFilter(.blur(radius: 1.5))
            shadowContext.stroke(
                path,
                with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: width, y: 0)
                ),
                lineWidth: lineWidth * 1.8
            )
        }

        // Draw the main wave path
        c.stroke(
            path,
            with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: width, y: 0)
            ),
            lineWidth: lineWidth
        )
    }
}
