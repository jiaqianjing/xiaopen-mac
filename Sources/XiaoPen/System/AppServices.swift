import Foundation
import AppKit
import ServiceManagement
import OSLog
import Observation

/// Login item registration through the system's own Login Items list.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status == .enabled else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
    static let repository = "jiaqianjing/xiaopen-mac"
    static let homepage = URL(string: "https://github.com/jiaqianjing/xiaopen-mac")!
    static let privacyURL = URL(string: "https://github.com/jiaqianjing/xiaopen-mac/blob/main/docs/PRIVACY.md")!
    static let issuesURL = URL(string: "https://github.com/jiaqianjing/xiaopen-mac/issues")!
}

/// Collects this run's app logs plus non-sensitive configuration into a text file
/// the user can attach to a bug report. Logs never contain transcripts, replies or keys.
@MainActor
enum DiagnosticsExporter {
    static func report() -> String {
        let prefs = AppPreferences.shared
        var lines = ["小喷诊断报告", "生成时间：\(Date().formatted(date: .numeric, time: .standard))",
                     "版本：\(AppInfo.version) (\(AppInfo.build))",
                     "系统：\(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "内存：\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB", ""]
        lines.append("模型：\(prefs.providerType.rawValue) / \(prefs.providerType == .openAI ? prefs.openAIVendor.rawValue : "-") / \(currentModel(prefs))")
        lines.append("朗读：\(prefs.ttsEngine.rawValue)，唤醒词启用：\(prefs.isWakeWordEnabled)，继续倾听：\(prefs.isFollowUpEnabled)")
        lines.append("状态：\(AppState.shared.statusText)；\(AppState.shared.deviceStatus)；\(AppState.shared.recognitionStatus)")
        lines.append("")
        lines.append("—— 本次运行日志（不含对话内容与密钥）——")
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(matching: NSPredicate(format: "subsystem == %@", "com.jiaqianjing.XiaoPen"))
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            for case let entry as OSLogEntryLog in entries {
                lines.append("\(formatter.string(from: entry.date)) [\(entry.category)] \(entry.composedMessage)")
            }
        } catch {
            lines.append("日志读取失败：\(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }

    static func exportWithSavePanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "XiaoPen-诊断-\(Int(Date().timeIntervalSince1970)).txt"
        panel.allowedContentTypes = [.plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report().write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func currentModel(_ prefs: AppPreferences) -> String {
        switch prefs.providerType {
        case .ollama: return prefs.ollamaModel
        case .anthropic: return prefs.anthropicModel
        case .openAI: return prefs.openAIModel
        }
    }
}

/// Checks GitHub Releases at most once a day. It only informs; nothing is downloaded automatically.
@Observable
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        let version: String
        let url: URL
    }

    private(set) var available: Release?
    private(set) var lastResult: String?
    @ObservationIgnored private let defaults = UserDefaults.standard

    func checkIfDue() {
        let last = defaults.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        Task { await check() }
    }

    func check() async {
        defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        lastResult = "正在检查..."
        guard let url = URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                lastResult = "暂时无法获取版本信息"
                return
            }
            let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            if Self.isNewer(version, than: AppInfo.version) {
                available = Release(version: version, url: page)
                lastResult = "发现新版本 \(version)"
            } else {
                available = nil
                lastResult = "已是最新版本"
            }
        } catch {
            lastResult = "检查失败：\(error.localizedDescription)"
        }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parse: (String) -> [Int] = { $0.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parse(candidate), b = parse(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
