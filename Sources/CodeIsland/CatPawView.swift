import SwiftUI
import ImageIO

/// Approved cat-paw poses, animated on the same gated clock as native mascots.
/// Five tiny PNGs are decoded once; no GIF decoder or per-frame file reads.
struct CatPawView: View {
    let status: MascotAgentStatus
    var size: CGFloat = 27

    static func poseName(for status: MascotAgentStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .processing: return "processing"
        case .running: return "running"
        case .waitingApproval: return "waiting-approval"
        case .waitingQuestion: return "waiting-question"
        }
    }

    static let sprites: [String: CGImage] = {
        var result: [String: CGImage] = [:]
        for pose in ["idle", "processing", "running", "waiting-approval", "waiting-question"] {
            guard let url = Bundle.appModule.url(forResource: pose, withExtension: "png",
                                                 subdirectory: "Resources/catpaw-mascot"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            result[pose] = image
        }
        return result
    }()

    var body: some View {
        MascotTimeline(interval: 0.125) { time in
            // Match the confirmed 32-frame, four-second draft loop exactly.
            let frame = Int(floor(time * 8).truncatingRemainder(dividingBy: 32))
            let phase = Double(frame) / 32 * .pi * 2
            let bob = status == .running ? (frame.isMultiple(of: 2) ? 1.0 : -1.0) : sin(phase).rounded()
            let tilt = status == .waitingQuestion ? -sin(phase) * .pi / 60 : 0
            Group {
                if let sprite = Self.sprites[Self.poseName(for: status)] {
                    Image(decorative: sprite, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: size, height: size)
                } else {
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: size * 0.7))
                        .foregroundStyle(Color(red: 1, green: 0.57, blue: 0.52))
                }
            }
            .rotationEffect(.radians(tilt))
            .offset(y: -bob * size / 40)
            .frame(width: size, height: size)
            .clipped()
        }
        .accessibilityLabel("CatPaw")
    }
}
