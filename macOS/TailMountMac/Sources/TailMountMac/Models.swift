import Foundation

enum AuthenticationMode: String, Codable, CaseIterable, Identifiable {
    case key = "SSH 密钥"
    case password = "SSH 密码"
    var id: String { rawValue }
}

struct ServerProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = "新服务器"
    var host = ""
    var port = 22
    var username = ""
    var remotePath = "/"
    var mountFolder = ""
    var authentication = AuthenticationMode.key
    var privateKeyPath = "~/.ssh/id_ed25519"
    var rememberPassword = false
    var restoreAfterLogin = false

    var destination: String { "\(username)@\(host):\(normalizedRemotePath)" }
    var normalizedRemotePath: String { remotePath.isEmpty ? "/" : remotePath }
    var resolvedMountFolder: String {
        if !mountFolder.trimmingCharacters(in: .whitespaces).isEmpty {
            return NSString(string: mountFolder).expandingTildeInPath
        }
        let safe = name.replacingOccurrences(of: "/", with: "-")
        return NSString(string: "~/TailMount/\(safe)").expandingTildeInPath
    }
}

enum ConnectionQuality: String {
    case idle = "等待连接"
    case excellent = "连接优秀"
    case good = "连接良好"
    case slow = "延时较高"
    case unstable = "连接不稳定"
    case offline = "无法连接"

    var symbol: String {
        switch self {
        case .idle: "circle.dotted"
        case .excellent, .good: "checkmark.circle.fill"
        case .slow: "exclamationmark.triangle.fill"
        case .unstable: "waveform.path.ecg"
        case .offline: "xmark.octagon.fill"
        }
    }
}

struct ProbeSample: Identifiable {
    let id = UUID()
    let date = Date()
    let latencyMS: Double?
    let succeeded: Bool
    let tailscaleLatencyMS: Double?
    let sshLatencyMS: Double?

    init(
        latencyMS: Double?,
        succeeded: Bool,
        tailscaleLatencyMS: Double? = nil,
        sshLatencyMS: Double? = nil
    ) {
        self.latencyMS = latencyMS
        self.succeeded = succeeded
        self.tailscaleLatencyMS = tailscaleLatencyMS
        self.sshLatencyMS = sshLatencyMS
    }
}

struct ActivityEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
    let level: Level
    let details: String?

    enum Level {
        case info, success, warning, error

        var label: String {
            switch self {
            case .info: "信息"
            case .success: "成功"
            case .warning: "警告"
            case .error: "错误"
            }
        }
    }
}

struct DependencyState {
    var tailscalePath: String?
    var sshfsPath: String?
    var macFUSEInstalled = false
    var isReady: Bool { sshfsPath != nil && macFUSEInstalled }
}

enum TailMountError: LocalizedError {
    case invalidProfile(String)
    case missingSSHFS
    case commandFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidProfile(let message): message
        case .missingSSHFS: "未检测到 SSHFS。请先安装 macFUSE 和 SSHFS。"
        case .commandFailed(let message): message
        case .timeout: "操作超时，请检查网络连接与服务器状态。"
        }
    }
}
