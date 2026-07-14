import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store = ProfileStore()
    @Published var dependencyState = DependencyService.inspect()
    @Published var isMounted = false
    @Published var isBusy = false
    @Published var quality = ConnectionQuality.idle
    @Published var latencyMS: Double?
    @Published var successRate = 100.0
    @Published var samples: [ProbeSample] = []
    @Published var activities: [ActivityEntry] = []
    @Published var alertMessage: String?
    @Published var launchAtLogin = LoginItemService.enabled

    private var monitorTask: Task<Void, Never>?
    private var lastNotifiedQuality = ConnectionQuality.idle

    private init() {
        NotificationService.requestAuthorization()
        log("TailMount for macOS 已启动。")
        startMonitoring()
        Task { await restoreSelectedMountIfNeeded() }
    }

    var selectedProfile: ServerProfile? { store.selected }

    func profileSelectionChanged() {
        samples = []
        quality = .idle
        latencyMS = nil
        Task { await refreshMountState() }
    }

    func save(profile: ServerProfile, password: String) {
        store.update(profile)
        do {
            if profile.authentication == .password && profile.rememberPassword && !password.isEmpty {
                try KeychainStore.savePassword(password, profileID: profile.id)
            } else {
                try KeychainStore.deletePassword(profileID: profile.id)
            }
            log("配置“\(profile.name)”已保存，密码未写入配置文件。", .success)
        } catch {
            show(error)
        }
    }

    func testConnection(profile: ServerProfile) async {
        do { try SSHFSService.validate(profile) } catch { show(error); return }
        isBusy = true; defer { isBusy = false }
        log("正在分别测试 Tailscale 与 SSH TCP 端口 \(profile.host):\(profile.port)…")
        let sample = await NetworkProbeService.probe(profile: profile)
        consume(sample)
        if sample.succeeded {
            log(
                "SSH TCP 端口可达，延时 \(formatLatency(sample.sshLatencyMS))。",
                .success,
                details: probeDetails(sample, profile: profile) + "\n注意：该测试不验证 SSH 密码、密钥或远程目录权限；这些项目会在实际挂载时验证。"
            )
        } else if sample.tailscaleLatencyMS != nil {
            show(TailMountError.commandFailed(
                "Tailscale 可以 ping 通，但 SSH TCP 端口 \(profile.port) 无法连接。\n" + probeDetails(sample, profile: profile)
            ))
        } else {
            show(TailMountError.commandFailed(
                "Tailscale 与 SSH TCP 端口均无法连接。\n" + probeDetails(sample, profile: profile)
            ))
        }
    }

    func mount(profile: ServerProfile, password: String) async {
        do { try SSHFSService.validate(profile) } catch { show(error); return }
        isBusy = true; defer { isBusy = false }
        let attempt = String(UUID().uuidString.prefix(6)).uppercased()
        let started = Date()
        log("[\(attempt)] 开始挂载 \(profile.destination)。")
        do {
            guard dependencyState.macFUSEInstalled, let sshfs = dependencyState.sshfsPath else {
                throw TailMountError.missingSSHFS
            }
            log(
                "[\(attempt)] 1/6 运行环境检查通过。",
                .success,
                details: "SSHFS：\(sshfs)\nmacFUSE：已安装\n本地目录：\(profile.resolvedMountFolder)"
            )

            if await SSHFSService.isMounted(profile) {
                log("[\(attempt)] 检测到旧挂载，正在先卸载。", .warning)
                try await SSHFSService.unmount(profile)
            }

            log("[\(attempt)] 2/6 正在检查 Tailscale 和 SSH TCP 端口…")
            let sample = await NetworkProbeService.probe(profile: profile)
            consume(sample)
            guard sample.succeeded else {
                let summary = sample.tailscaleLatencyMS == nil
                    ? "Tailscale 与 SSH 端口均不可达。"
                    : "Tailscale 可达，但 SSH 端口 \(profile.port) 不可达。"
                throw TailMountError.commandFailed(summary + "\n" + probeDetails(sample, profile: profile))
            }
            log(
                "[\(attempt)] 2/6 SSH TCP 端口可达（\(formatLatency(sample.sshLatencyMS))）。",
                .success,
                details: probeDetails(sample, profile: profile) + "\n网络可达不等于认证或远程目录验证成功。"
            )

            let authDetail: String
            if profile.authentication == .key {
                let key = NSString(string: profile.privateKeyPath).expandingTildeInPath
                authDetail = "认证：SSH 密钥\n密钥文件可读：\(FileManager.default.isReadableFile(atPath: key) ? "是" : "否")"
            } else {
                authDetail = "认证：SSH 密码\n密码已提供：\(!password.isEmpty ? "是" : "否")\n密码不会写入活动记录或命令参数。"
            }
            log("[\(attempt)] 3/6 认证参数已准备。", details: authDetail)
            log("[\(attempt)] 4/6 正在启动 SSHFS；最长等待 45 秒…")
            let report = try await SSHFSService.mount(profile, password: password)
            log(
                "[\(attempt)] 4/6 SSHFS 已返回（耗时 \(String(format: "%.1f", report.duration)) 秒）。",
                .success,
                details: report.output.isEmpty ? "SSHFS 未输出额外信息。" : report.output
            )

            log("[\(attempt)] 5/6 正在等待 macOS 注册挂载卷…")
            isMounted = await waitForMount(profile, timeout: 8)
            guard isMounted else {
                throw TailMountError.commandFailed(
                    "SSHFS 已正常返回，但 8 秒内没有在系统挂载表中发现该卷。\n本地目录：\(profile.resolvedMountFolder)\n请检查 macFUSE 系统扩展是否已获允许，或该目录是否被其他进程占用。"
                )
            }
            log("[\(attempt)] 6/6 挂载确认完成，总耗时 \(String(format: "%.1f", Date().timeIntervalSince(started))) 秒。", .success)
            log("远程磁盘已挂载到 \(profile.resolvedMountFolder)。", .success)
            SSHFSService.openInFinder(profile)
        } catch { show(error, context: "[\(attempt)]") }
    }

    func unmount(profile: ServerProfile) async {
        isBusy = true; defer { isBusy = false }
        do {
            try await SSHFSService.unmount(profile)
            isMounted = false
            log("远程磁盘已安全卸载。", .success)
        } catch { show(error) }
    }

    func refreshMountState() async {
        guard let profile = selectedProfile else { isMounted = false; return }
        isMounted = await SSHFSService.isMounted(profile)
    }

    private func restoreSelectedMountIfNeeded() async {
        try? await Task.sleep(for: .seconds(2))
        guard let profile = selectedProfile, profile.restoreAfterLogin,
              dependencyState.isReady, !(await SSHFSService.isMounted(profile)) else { return }
        let savedPassword = profile.authentication == .password
            ? ((try? KeychainStore.password(profileID: profile.id)) ?? nil)
            : nil
        log("正在恢复“\(profile.name)”的登录挂载…")
        do {
            _ = try await SSHFSService.mount(profile, password: savedPassword)
            isMounted = await SSHFSService.isMounted(profile)
            if isMounted { log("登录挂载已恢复。", .success) }
        } catch {
            show(error)
            NotificationService.post(title: "TailMount：恢复挂载失败", body: error.localizedDescription)
        }
    }

    func refreshDependencies() {
        dependencyState = DependencyService.inspect()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemService.setEnabled(enabled)
            launchAtLogin = enabled
            log(enabled ? "已设置登录时启动。" : "已取消登录时启动。", .success)
        } catch { show(error); launchAtLogin = LoginItemService.enabled }
    }

    func clearActivities() { activities.removeAll() }

    func copyActivities() {
        let formatter = ISO8601DateFormatter()
        let text = activities.reversed().map { entry in
            let header = "[\(formatter.string(from: entry.date))] [\(entry.level.label)] \(entry.message)"
            return entry.details.map { header + "\n" + $0 } ?? header
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        log("活动记录已复制到剪贴板。", .success)
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let profile = self.selectedProfile, !profile.host.isEmpty {
                    let sample = await NetworkProbeService.probe(profile: profile)
                    self.consume(sample)
                    await self.refreshMountState()
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func consume(_ sample: ProbeSample) {
        samples.append(sample)
        if samples.count > 30 { samples.removeFirst(samples.count - 30) }
        latencyMS = sample.latencyMS
        successRate = Double(samples.filter(\.succeeded).count) / Double(max(samples.count, 1)) * 100
        let previous = quality
        if !sample.succeeded {
            quality = successRate < 70 ? .offline : .unstable
        } else if successRate < 90 {
            quality = .unstable
        } else if let latency = sample.latencyMS, latency >= 250 {
            quality = .slow
        } else if let latency = sample.latencyMS, latency < 80 {
            quality = .excellent
        } else {
            quality = .good
        }
        if quality != previous && quality != lastNotifiedQuality && [.slow, .unstable, .offline].contains(quality) {
            lastNotifiedQuality = quality
            NotificationService.post(title: "TailMount：\(quality.rawValue)", body: statusDetail)
        }
    }

    var statusDetail: String {
        if quality == .offline { return "服务器当前无法访问，请检查 Tailscale 与网络。" }
        return "当前延时 \(formatLatency(latencyMS))，近期成功率 \(Int(successRate))%。"
    }

    func log(_ message: String, _ level: ActivityEntry.Level = .info, details: String? = nil) {
        activities.insert(ActivityEntry(message: message, level: level, details: details), at: 0)
        if activities.count > 200 { activities.removeLast(activities.count - 200) }
    }

    private func show(_ error: Error, context: String? = nil) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let summary = String(parts.first ?? "未知错误")
        let details = parts.count > 1 ? String(parts[1]) : nil
        alertMessage = details == nil ? summary : summary + "\n详细诊断已写入活动记录。"
        log([context, summary].compactMap { $0 }.joined(separator: " "), .error, details: details)
    }

    private func formatLatency(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded())) ms" } ?? "--"
    }

    private func probeDetails(_ sample: ProbeSample, profile: ServerProfile) -> String {
        let tailscale = sample.tailscaleLatencyMS.map { "可达（\(formatLatency($0))）" } ?? "不可达或命令不可用"
        let ssh = sample.sshLatencyMS.map { "可达（\(formatLatency($0))）" } ?? "不可达"
        return "Tailscale ping：\(tailscale)\nSSH TCP \(profile.host):\(profile.port)：\(ssh)"
    }

    private func waitForMount(_ profile: ServerProfile, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if await SSHFSService.isMounted(profile) { return true }
            try? await Task.sleep(for: .milliseconds(500))
        } while Date() < deadline
        return false
    }
}
