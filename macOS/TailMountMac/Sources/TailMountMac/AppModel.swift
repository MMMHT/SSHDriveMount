import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store = ProfileStore()
    @Published var password = ""
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
        password = ""
        samples = []
        quality = .idle
        latencyMS = nil
        if let profile = selectedProfile, profile.rememberPassword {
            password = (try? KeychainStore.password(profileID: profile.id)) ?? ""
        }
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
        log("正在测试 \(profile.host):\(profile.port)…")
        let sample = await NetworkProbeService.probe(profile: profile)
        consume(sample)
        if sample.succeeded {
            log("SSH 端口可达，延时 \(formatLatency(sample.latencyMS))。", .success)
        } else {
            show(TailMountError.commandFailed("无法连接 SSH 端口。请检查 Tailscale、地址、端口及服务器防火墙。"))
        }
    }

    func mount(profile: ServerProfile, password: String) async {
        isBusy = true; defer { isBusy = false }
        do {
            if await SSHFSService.isMounted(profile) { try await SSHFSService.unmount(profile) }
            log("正在挂载 \(profile.destination)…")
            try await SSHFSService.mount(profile, password: password)
            try await Task.sleep(for: .milliseconds(400))
            isMounted = await SSHFSService.isMounted(profile)
            guard isMounted else { throw TailMountError.commandFailed("SSHFS 已返回，但 Finder 中未检测到挂载卷。") }
            log("远程磁盘已挂载到 \(profile.resolvedMountFolder)。", .success)
            SSHFSService.openInFinder(profile)
        } catch { show(error) }
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
            try await SSHFSService.mount(profile, password: savedPassword)
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

    func log(_ message: String, _ level: ActivityEntry.Level = .info) {
        activities.insert(ActivityEntry(message: message, level: level), at: 0)
        if activities.count > 100 { activities.removeLast(activities.count - 100) }
    }

    private func show(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alertMessage = message
        log(message, .error)
    }

    private func formatLatency(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded())) ms" } ?? "--"
    }
}
