import ActivityKit
import Foundation

struct CodeIslandSessionActivityPreview: Codable, Hashable, Identifiable {
    var sessionId: String?
    var source: String
    var status: String
    var toolName: String?
    var workspaceName: String?
    var message: String?
    var updatedAt: Date

    var id: String {
        sessionId ?? "\(source)-\(workspaceName ?? "session")-\(updatedAt.timeIntervalSince1970)"
    }

    var statusLabel: String {
        switch status {
        case "processing": return "处理"
        case "running": return "运行"
        case "waitingApproval": return "待批准"
        case "waitingQuestion": return "待回答"
        default: return "空闲"
        }
    }

    var sourceLabel: String {
        source.isEmpty ? "CodeIsland" : source.uppercased()
    }
}

struct CodeIslandActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var sequence: UInt64
        var source: String
        var status: String
        var toolName: String?
        var workspaceName: String?
        var message: String?
        var pendingAction: String?
        var questionText: String?
        var questionHeader: String?
        var questionProgress: String?
        var sessions: [CodeIslandSessionActivityPreview]
        var updatedAt: Date

        var statusLabel: String {
            switch status {
            case "processing": return "处理中"
            case "running": return "运行中"
            case "waitingApproval": return "待批准"
            case "waitingQuestion": return "待回答"
            default: return "空闲"
            }
        }

        var sourceLabel: String {
            source.isEmpty ? "CodeIsland" : source.uppercased()
        }

        var compactStatusLabel: String {
            switch status {
            case "waitingApproval": return "待批"
            case "waitingQuestion": return "待答"
            case "processing": return "处理"
            case "running": return "运行"
            default: return "空闲"
            }
        }

        var activeSessionCount: Int {
            sessions.filter { $0.status != "idle" }.count
        }
    }

    var sessionId: String?
}
