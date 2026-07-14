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
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
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
        guard let result = try? await CommandRunner.run("/sbin/mount", timeout: 4) else { return false }
        let marker = " on \(profile.resolvedMountFolder) ("
        return result.stdout.contains(marker)
    }

    static func mount(_ profile: ServerProfile, password: String?) async throws {
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

        let result = try await CommandRunner.run(sshfs, arguments: arguments, input: input, timeout: 30)
        guard result.exitCode == 0 else {
            let message = result.combinedOutput.isEmpty ? "SSHFS 挂载失败（代码 \(result.exitCode)）。" : result.combinedOutput
            throw TailMountError.commandFailed(message)
        }
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
}

enum NetworkProbeService {
    static func probe(profile: ServerProfile) async -> ProbeSample {
        if let tailscale = ExecutableLocator.tailscale,
           let result = try? await CommandRunner.run(
                tailscale,
                arguments: ["ping", "--c", "1", "--timeout=3s", profile.host],
                environment: [
                    "TAILSCALE_BE_CLI": "1",
                    "SHLVL": "1",
                    "TERM": "xterm-256color"
                ],
                timeout: 5
           ), result.exitCode == 0 {
            return ProbeSample(latencyMS: parseLatency(result.combinedOutput), succeeded: true)
        }
        let latency = await tcpLatency(host: profile.host, port: profile.port)
        return ProbeSample(latencyMS: latency, succeeded: latency != nil)
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
