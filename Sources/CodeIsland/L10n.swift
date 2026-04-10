import Foundation
import Combine

final class L10n: ObservableObject {
    static let shared = L10n()

    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: SettingsKey.appLanguage) }
    }

    init() {
        self.language = UserDefaults.standard.string(forKey: SettingsKey.appLanguage) ?? "system"
    }

    var effectiveLanguage: String {
        if language == "system" {
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("zh") ? "zh" : "en"
        }
        return language
    }

    subscript(_ key: String) -> String {
        Self.strings[effectiveLanguage]?[key] ?? Self.strings["en"]?[key] ?? key
    }

    // MARK: - Translations

    private static let strings: [String: [String: String]] = [
        "en": en,
        "zh": zh,
    ]

    private static let en: [String: String] = [
        // Settings pages
        "general": "General",
        "behavior": "Behavior",
        "appearance": "Appearance",
        "mascots": "Mascots",
        "sound": "Sound",
        "hooks": "Hooks",
        "about": "About",

        // Language
        "language": "Language",
        "system_language": "System",

        // General
        "launch_at_login": "Launch at Login",
        "allow_horizontal_drag": "Allow Horizontal Drag",
        "allow_horizontal_drag_desc": "Enable dragging the panel left or right along the menu bar",
        "display": "Display",
        "auto": "Auto",
        "builtin_display": "Built-in Display",
        "notch": "(Notch)",

        // Behavior
        "display_section": "Display",
        "hide_in_fullscreen": "Hide in Fullscreen",
        "hide_in_fullscreen_desc": "Automatically hide panel when any app enters fullscreen mode",
        "hide_when_no_session": "Auto-hide When No Active Session",
        "hide_when_no_session_desc": "Hide panel completely when no AI agents are running",
        "smart_suppress": "Smart Suppress",
        "smart_suppress_desc": "Don't auto-expand panel when agent's terminal tab is in foreground",
        "collapse_on_mouse_leave": "Auto-collapse on Mouse Leave",
        "collapse_on_mouse_leave_desc": "Collapse expanded panel back to notch when mouse moves away",
        "shortcuts": "Shortcuts",
        "shortcut_recording": "Recording…",
        "shortcut_none": "Not Set",
        "shortcut_togglePanel": "Toggle Panel",
        "shortcut_togglePanel_desc": "Open or close the CodeIsland panel",
        "shortcut_approve": "Approve",
        "shortcut_approve_desc": "Approve current permission request",
        "shortcut_approveAlways": "Approve Always",
        "shortcut_approveAlways_desc": "Approve and remember for this session",
        "shortcut_deny": "Deny",
        "shortcut_deny_desc": "Deny current permission request",
        "shortcut_skipQuestion": "Skip Question",
        "shortcut_skipQuestion_desc": "Skip current question prompt",
        "shortcut_jumpToTerminal": "Jump to Terminal",
        "shortcut_jumpToTerminal_desc": "Switch to the active session's terminal",
        "shortcut_conflict": "Conflicts with",
        "sessions": "Sessions",
        "session_cleanup": "Idle Session Cleanup",
        "session_cleanup_desc": "Automatically remove sessions with no activity for the set duration",
        "no_cleanup": "Never",
        "10_minutes": "10 Minutes",
        "30_minutes": "30 Minutes",
        "1_hour": "1 Hour",
        "2_hours": "2 Hours",
        "rotation_interval": "Session Rotation Interval",
        "rotation_interval_desc": "How often the collapsed bar switches between active sessions",
        "3_seconds": "3 Seconds",
        "5_seconds": "5 Seconds",
        "8_seconds": "8 Seconds",
        "10_seconds": "10 Seconds",
        "tool_history_limit": "Tool History Limit",
        "tool_history_limit_desc": "Max number of recent tool calls shown per session",

        // Appearance
        "preview": "Preview",
        "panel": "Panel",
        "max_visible_sessions": "Max Visible Sessions",
        "max_visible_sessions_desc": "Sessions beyond this limit will be scrollable",
        "default": "Default",
        "content": "Content",
        "content_font_size": "Content Font Size",
        "11pt_default": "11pt (Default)",
        "ai_reply_lines": "AI Reply Lines",
        "1_line_default": "1 Line (Default)",
        "2_lines": "2 Lines",
        "3_lines": "3 Lines",
        "5_lines": "5 Lines",
        "unlimited": "Unlimited",
        "show_agent_details": "Show Agent Activity Details",
        "show_tool_status": "Detailed Tool Activity in Compact Bar",

        // Mascots
        "preview_status": "Preview Status",
        "processing": "Processing",
        "idle": "Idle",
        "waiting_approval": "Waiting Approval",
        "mascot_speed": "Animation Speed",
        "speed_off": "Off",
        "speed_slow": "0.5× Slow",
        "speed_normal": "1× Normal",
        "speed_fast": "1.5× Fast",
        "speed_very_fast": "2× Very Fast",

        // Sound
        "enable_sound": "Enable Sound Effects",
        "volume": "Volume",
        "session_start": "Session Start",
        "new_claude_session": "New Claude Code session",
        "task_complete": "Task Complete",
        "ai_completed_reply": "AI completed this round's reply",
        "task_error": "Task Error",
        "tool_or_api_error": "Tool failure or API error",
        "system_section": "System",
        "boot_sound": "Boot Sound",
        "boot_sound_desc": "Play a jingle when CodeIsland starts",
        "interaction": "Interaction",
        "approval_needed": "Approval Needed",
        "waiting_approval_desc": "Waiting for permission approval or answer",
        "task_confirmation": "Task Confirmation",
        "you_sent_message": "You sent a message",
        "custom_sound": "Custom",
        "choose_sound_file": "Choose Sound File",
        "reset_to_default": "Reset to Default",
        "custom_sound_set": "Custom: %@",

        // Hooks
        "cli_status": "CLI Status",
        "activated": "Activated",
        "not_installed": "Not Installed",
        "not_detected": "Not Detected",
        "management": "Management",
        "reinstall": "Reinstall",
        "uninstall": "Uninstall",
        "hooks_installed": "Hooks installed successfully",
        "install_failed": "Installation failed",
        "hooks_uninstalled": "Hooks uninstalled",

        // About
        "about_desc1": "Real-time AI coding agent status panel for macOS",
        "about_desc2": "Supports 8 CLI/IDE tools via Unix socket IPC",

        // Window
        "settings_title": "CodeIsland Settings",

        // Menu
        "settings_ellipsis": "Settings...",
        "check_for_updates": "Check for Updates...",
        "export_diagnostics": "Export Diagnostics...",
        "export_diagnostics_desc": "Create a zip with logs, settings and session state for bug reports",
        "reinstall_hooks": "Reinstall Hooks",
        "remove_hooks": "Remove Hooks",
        "quit": "Quit",

        // Update
        "update_available_title": "Update Available",
        "update_available_body": "CodeIsland %@ is available (current: %@). Would you like to download it?",
        "download_update": "Download",
        "later": "Later",
        "no_update_title": "Up to Date",
        "no_update_body": "CodeIsland %@ is the latest version.",
        "ok": "OK",
        "update_now": "Update Now",
        "update_downloading": "Downloading update...",
        "update_failed_title": "Update Failed",
        "update_failed_body": "Could not install the update: %@",
        "update_manual_download": "Download Manually",
        "update_homebrew_title": "Update Available",
        "update_homebrew_body": "CodeIsland %@ is available. Since you installed via Homebrew, please run:",
        "update_homebrew_command": "brew upgrade codeisland",
        "update_copy_command": "Copy Command",

        // NotchPanel
        "mute": "Mute",
        "enable_sound_tooltip": "Enable Sound",
        "settings": "Settings",
        "deny": "DENY",
        "allow_once": "ALLOW ONCE",
        "always": "ALWAYS",
        "type_answer": "Type your answer...",
        "skip": "SKIP",
        "confirm": "CONFIRM",
        "submit": "SUBMIT",
        "open_path": "Open",
        "copy_session_id": "Copy session ID",

        // Session grouping
        "status_running": "Running",
        "status_waiting": "Waiting",
        "status_processing": "Processing",
        "status_idle": "Idle",
        "other": "Other",
        "n_sessions": "sessions",
        "scroll_for_more": "Scroll for more",
        "scroll_hidden": "more below",
        "lines": "lines",
    ]

    private static let zh: [String: String] = [
        // Settings pages
        "general": "通用",
        "behavior": "行为",
        "appearance": "外观",
        "mascots": "角色",
        "sound": "声音",
        "hooks": "Hooks",
        "about": "关于",

        // Language
        "language": "语言",
        "system_language": "跟随系统",

        // General
        "launch_at_login": "登录时打开",
        "allow_horizontal_drag": "允许水平拖动面板",
        "allow_horizontal_drag_desc": "开启后可沿菜单栏左右拖动面板位置",
        "display": "显示器",
        "auto": "自动",
        "builtin_display": "内建显示器",
        "notch": "(刘海)",

        // Behavior
        "display_section": "显示",
        "hide_in_fullscreen": "全屏时隐藏",
        "hide_in_fullscreen_desc": "当任意应用进入全屏模式时自动隐藏面板",
        "hide_when_no_session": "无活跃会话时自动隐藏",
        "hide_when_no_session_desc": "没有 AI Agent 运行时完全隐藏面板",
        "smart_suppress": "智能抑制",
        "smart_suppress_desc": "Agent 所在终端标签页在前台时不自动展开面板",
        "collapse_on_mouse_leave": "鼠标离开时自动收起",
        "collapse_on_mouse_leave_desc": "鼠标移出展开的面板后自动收回到刘海状态",
        "shortcuts": "快捷键",
        "shortcut_recording": "请按下快捷键…",
        "shortcut_none": "未设置",
        "shortcut_togglePanel": "切换面板",
        "shortcut_togglePanel_desc": "展开或收起 CodeIsland 面板",
        "shortcut_approve": "批准",
        "shortcut_approve_desc": "批准当前权限请求",
        "shortcut_approveAlways": "始终批准",
        "shortcut_approveAlways_desc": "批准并记住本次会话",
        "shortcut_deny": "拒绝",
        "shortcut_deny_desc": "拒绝当前权限请求",
        "shortcut_skipQuestion": "跳过问题",
        "shortcut_skipQuestion_desc": "跳过当前问答提示",
        "shortcut_jumpToTerminal": "跳转终端",
        "shortcut_jumpToTerminal_desc": "切换到当前活跃会话的终端",
        "shortcut_conflict": "与以下快捷键冲突:",
        "sessions": "会话",
        "session_cleanup": "空闲会话清理",
        "session_cleanup_desc": "自动移除超过指定时间没有活动的会话",
        "no_cleanup": "不清理",
        "10_minutes": "10 分钟",
        "30_minutes": "30 分钟",
        "1_hour": "1 小时",
        "2_hours": "2 小时",
        "rotation_interval": "会话轮转间隔",
        "rotation_interval_desc": "收缩状态下多个活跃会话之间的切换频率",
        "3_seconds": "3 秒",
        "5_seconds": "5 秒",
        "8_seconds": "8 秒",
        "10_seconds": "10 秒",
        "tool_history_limit": "工具历史上限",
        "tool_history_limit_desc": "每个会话显示的最近工具调用数量上限",

        // Appearance
        "preview": "预览",
        "panel": "面板",
        "max_visible_sessions": "最大显示会话数",
        "max_visible_sessions_desc": "超出数量的会话将通过滚动查看",
        "default": "默认",
        "content": "内容",
        "content_font_size": "内容字体大小",
        "11pt_default": "11pt (默认)",
        "ai_reply_lines": "AI 回复行数",
        "1_line_default": "1 行 (默认)",
        "2_lines": "2 行",
        "3_lines": "3 行",
        "5_lines": "5 行",
        "unlimited": "不限制",
        "show_agent_details": "显示代理活动详情",
        "show_tool_status": "紧凑栏显示工具调用详情",

        // Mascots
        "preview_status": "预览状态",
        "processing": "工作中",
        "idle": "空闲",
        "waiting_approval": "等待审批",
        "mascot_speed": "动画速度",
        "speed_off": "关闭",
        "speed_slow": "0.5× 慢速",
        "speed_normal": "1× 正常",
        "speed_fast": "1.5× 快速",
        "speed_very_fast": "2× 极速",

        // Sound
        "enable_sound": "启用音效",
        "volume": "音量",
        "session_start": "会话开始",
        "new_claude_session": "新的 Claude Code 会话",
        "task_complete": "任务完成",
        "ai_completed_reply": "AI 完成了本轮回复",
        "task_error": "任务错误",
        "tool_or_api_error": "工具失败或 API 错误",
        "system_section": "系统",
        "boot_sound": "启动音效",
        "boot_sound_desc": "CodeIsland 启动时播放提示音",
        "interaction": "交互",
        "approval_needed": "需要审批",
        "waiting_approval_desc": "等待权限审批或回答问题",
        "task_confirmation": "任务确认",
        "you_sent_message": "你发送了一条消息",
        "custom_sound": "自定义",
        "choose_sound_file": "选择音效文件",
        "reset_to_default": "恢复默认",
        "custom_sound_set": "自定义: %@",

        // Hooks
        "cli_status": "CLI 状态",
        "activated": "已激活",
        "not_installed": "未安装",
        "not_detected": "未检测到",
        "management": "管理",
        "reinstall": "重新安装",
        "uninstall": "卸载",
        "hooks_installed": "Hooks 安装成功",
        "install_failed": "安装失败",
        "hooks_uninstalled": "Hooks 已卸载",

        // About
        "about_desc1": "macOS 实时 AI 编码 Agent 状态面板",
        "about_desc2": "通过 Unix socket IPC 支持 8 种 CLI/IDE 工具",

        // Window
        "settings_title": "CodeIsland 设置",

        // Menu
        "settings_ellipsis": "设置...",
        "check_for_updates": "检查更新...",
        "export_diagnostics": "导出诊断信息...",
        "export_diagnostics_desc": "创建包含日志、设置和会话状态的 zip 文件，用于反馈 Bug",
        "reinstall_hooks": "重新安装 Hooks",
        "remove_hooks": "卸载 Hooks",
        "quit": "退出",

        // Update
        "update_available_title": "发现新版本",
        "update_available_body": "CodeIsland %@ 已发布（当前版本：%@），是否前往下载？",
        "download_update": "前往下载",
        "later": "稍后",
        "no_update_title": "已是最新版本",
        "no_update_body": "CodeIsland %@ 已是最新版本。",
        "ok": "好",
        "update_now": "立即更新",
        "update_downloading": "正在下载更新...",
        "update_failed_title": "更新失败",
        "update_failed_body": "无法安装更新：%@",
        "update_manual_download": "手动下载",
        "update_homebrew_title": "发现新版本",
        "update_homebrew_body": "CodeIsland %@ 已发布。由于您通过 Homebrew 安装，请运行：",
        "update_homebrew_command": "brew upgrade codeisland",
        "update_copy_command": "复制命令",

        // NotchPanel
        "mute": "静音",
        "enable_sound_tooltip": "开启音效",
        "settings": "设置",
        "deny": "拒绝",
        "allow_once": "允许一次",
        "always": "始终允许",
        "type_answer": "输入回答…",
        "skip": "跳过",
        "confirm": "确认",
        "submit": "提交",
        "open_path": "打开",
        "copy_session_id": "复制会话 ID",

        // Session grouping
        "status_running": "运行中",
        "status_waiting": "等待中",
        "status_processing": "处理中",
        "status_idle": "空闲",
        "other": "其他",
        "n_sessions": "个会话",
        "scroll_for_more": "向下滚动查看更多",
        "scroll_hidden": "个未显示",
        "lines": "行",
    ]
}
