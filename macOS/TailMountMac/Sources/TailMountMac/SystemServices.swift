import AppKit
import Foundation
import Network
import ServiceManagement
import UserNotifications

enum ExecutableLocator {
    static func first(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var sshfs: String? {
        first([
            "/usr/local/bin/sshfs",
            "/opt/homebrew/bin/sshfs",
            "/Library/Filesystems/sshfs.fs/Contents/Resources/sshfs"
        ])
    }

    static var tailscale: String? {
        first([
            // Prefer the real app executable. The GUI installer creates a
            // lowercase /usr/local/bin/tailscale symlink; on macOS 15.7 that
            // launch path can make Tailscale 1.98 mis-detect its bundle and
            // abort before producing a ping result.
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale"
        ])
    }
}

enum DependencyService {
    static func inspect() -> DependencyState {
        DependencyState(
            tailscalePath: ExecutableLocator.tailscale,
            sshfsPath: ExecutableLocator.sshfs,
            macFUSEInstalled: FileManager.default.fileExists(atPath: "/Library/Filesystems/macfuse.fs")
        )
    }

    static func openDownloads() {
        NSWorkspace.shared.open(URL(string: "https://macfuse.github.io/")!)
    }
}

enum SSHFSService {
    struct MountReport {
        let duration: TimeInterval
        let output: String
    }

    static func validate(_ profile: ServerProfile) throws {
        if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TailMountError.invalidProfile("请输入配置名称。")
        }
        if profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TailMountError.invalidProfile("请输入服务器地址或 MagicDNS 名称。")
        }
        if profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TailMountError.invalidProfile("请输入 SSH 用户名。")
        }
        if !(1...65535).contains(profile.port) {
            throw TailMountError.invalidProfile("SSH 端口必须在 1 到 65535 之间。")
        }
    }

    static func isMounted(_ profile: ServerProfile) async -> Bool {
        guard let result = try? await CommandRunner.run("/sbin/mount", timeout: 4), !result.timedOut else { return false }
        let marker = " on \(profile.resolvedMountFolder) ("
        return result.stdout.contains(marker)
    }

    static func mount(_ profile: ServerProfile, password: String?) async throws -> MountReport {
        try validate(profile)
        guard let sshfs = ExecutableLocator.sshfs else { throw TailMountError.missingSSHFS }
        try FileManager.default.createDirectory(
            atPath: profile.resolvedMountFolder,
            withIntermediateDirectories: true
        )

        var arguments = [
            profile.destination,
            profile.resolvedMountFolder,
            "-p", String(profile.port),
            "-o", "reconnect",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "defer_permissions",
            "-o", "noappledouble",
            "-o", "noapplexattr",
            "-o", "volname=\(sanitizedVolumeName(profile.name))"
        ]
        var input: Data?
        if profile.authentication == .key {
            let key = NSString(string: profile.privateKeyPath).expandingTildeInPath
            arguments += ["-o", "IdentityFile=\(key)", "-o", "BatchMode=yes"]
        } else {
            guard let password, !password.isEmpty else {
                throw TailMountError.invalidProfile("请输入 SSH 密码。")
            }
            arguments += ["-o", "password_stdin"]
            input = Data((password + "\n").utf8)
        }

        let result = try await CommandRunner.run(sshfs, arguments: arguments, input: input, timeout: 45)
        if result.timedOut {
            throw TailMountError.commandFailed(diagnosticMessage(for: result, profile: profile))
        }
        guard result.exitCode == 0 else {
            throw TailMountError.commandFailed(diagnosticMessage(for: result, profile: profile))
        }
        return MountReport(duration: result.duration, output: limitedOutput(result.combinedOutput))
    }

    static func unmount(_ profile: ServerProfile) async throws {
        var result = try await CommandRunner.run("/sbin/umount", arguments: [profile.resolvedMountFolder], timeout: 15)
        if result.exitCode != 0 {
            result = try await CommandRunner.run("/usr/sbin/diskutil", arguments: ["unmount", "force", profile.resolvedMountFolder], timeout: 20)
        }
        guard result.exitCode == 0 else {
            throw TailMountError.commandFailed(result.combinedOutput.isEmpty ? "无法卸载远程磁盘。" : result.combinedOutput)
        }
    }

    static func openInFinder(_ profile: ServerProfile) {
        NSWorkspace.shared.open(URL(fileURLWithPath: profile.resolvedMountFolder, isDirectory: true))
    }

    private static func sanitizedVolumeName(_ value: String) -> String {
        value.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: ":", with: " ")
    }

    private static func diagnosticMessage(for result: CommandResult, profile: ServerProfile) -> String {
        let output = limitedOutput(result.combinedOutput)
        let lower = output.lowercased()
        let reason: String

        if result.timedOut {
            reason = "SSHFS 在 \(Int(result.duration.rounded())) 秒后仍未结束。Tailscale ping 正常只表示设备可达，并不代表 SSH 认证、远程目录或 macFUSE 挂载一定成功。"
        } else if lower.contains("permission denied") || lower.contains("authentication failed") {
            reason = "SSH 认证被拒绝。请检查用户名、密码、密钥权限以及服务器允许的认证方式。"
        } else if lower.contains("no such file") || lower.contains("not found") {
            reason = "远程目录或本地挂载目录不存在。请确认远程目录“\(profile.normalizedRemotePath)”可被当前用户访问。"
        } else if lower.contains("host key verification failed") || lower.contains("remote host identification has changed") {
            reason = "SSH 主机密钥校验失败。服务器可能更换过系统或 SSH 密钥，请检查 ~/.ssh/known_hosts。"
        } else if lower.contains("connection refused") {
            reason = "服务器可达，但 SSH 端口拒绝连接。请检查 sshd 是否运行及端口配置。"
        } else if lower.contains("connection reset") || lower.contains("connection timed out") || lower.contains("no route to host") {
            reason = "SSH 连接在握手或传输阶段中断。请检查 Tailscale 状态、服务器防火墙和网络稳定性。"
        } else if lower.contains("macfuse") || lower.contains("fuse") || lower.contains("device not configured") || lower.contains("operation not permitted") {
            reason = "macFUSE 没有正常加载或尚未获得系统许可。请在“系统设置 → 隐私与安全性”中允许相关系统扩展后重启。"
        } else if lower.contains("mount point") && (lower.contains("not empty") || lower.contains("invalid")) {
            reason = "本地挂载目录不可用。请清空或更换挂载目录，然后重试。"
        } else {
            reason = "SSHFS 挂载失败（退出代码 \(result.exitCode)，耗时 \(String(format: "%.1f", result.duration)) 秒）。"
        }

        if output.isEmpty {
            return reason + "\nSSHFS 没有返回错误文本；这通常发生在等待认证窗口、系统扩展授权或底层进程卡住时。"
        }
        return reason + "\nSSHFS 最后输出：\n" + output
    }

    private static func limitedOutput(_ value: String) -> String {
        let sanitized = value
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = sanitized.split(separator: "\n", omittingEmptySubsequences: false).suffix(16)
        let result = lines.joined(separator: "\n")
        return result.count > 3000 ? String(result.suffix(3000)) : result
    }
}

enum NetworkProbeService {
    static func probe(profile: ServerProfile) async -> ProbeSample {
        async let tailscaleProbe = tailscaleLatency(host: profile.host)
        async let sshProbe = tcpLatency(host: profile.host, port: profile.port)
        let (tailscale, ssh) = await (tailscaleProbe, sshProbe)
        return ProbeSample(
            latencyMS: ssh ?? tailscale,
            succeeded: ssh != nil,
            tailscaleLatencyMS: tailscale,
            sshLatencyMS: ssh
        )
    }

    private static func tailscaleLatency(host: String) async -> Double? {
        if let tailscale = ExecutableLocator.tailscale,
           let result = try? await CommandRunner.run(
                tailscale,
                arguments: ["ping", "--c", "1", "--timeout=3s", host],
                environment: [
                    "TAILSCALE_BE_CLI": "1",
                    "SHLVL": "1",
                    "TERM": "xterm-256color"
                ],
                timeout: 5
           ), !result.timedOut, result.exitCode == 0 {
            return parseLatency(result.combinedOutput)
        }
        return nil
    }

    private static func parseLatency(_ output: String) -> Double? {
        let pattern = #"(?:in|time[=<])\s*([0-9.]+)\s*ms"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return Double(output[range])
    }

    private static func tcpLatency(host: String, port: Int) async -> Double? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let started = Date()
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var completed = false
            func finish(_ value: Double?) {
                lock.lock(); defer { lock.unlock() }
                guard !completed else { return }
                completed = true
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(Date().timeIntervalSince(started) * 1000)
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { finish(nil) }
        }
    }
}

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

enum LoginItemService {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
}
