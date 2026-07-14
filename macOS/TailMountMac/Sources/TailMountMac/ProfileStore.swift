import Foundation

@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [ServerProfile] = []
    @Published var selectedID: UUID?

    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TailMount", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("profiles.json")
        load()
    }

    var selectedIndex: Int? { profiles.firstIndex { $0.id == selectedID } }
    var selected: ServerProfile? {
        get { selectedIndex.map { profiles[$0] } }
        set {
            guard let index = selectedIndex, let newValue else { return }
            profiles[index] = newValue
            save()
        }
    }

    func add() {
        let profile = ServerProfile(name: "服务器 \(profiles.count + 1)")
        profiles.append(profile)
        selectedID = profile.id
        save()
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        profiles.removeAll { $0.id == id }
        try? KeychainStore.deletePassword(profileID: id)
        if profiles.isEmpty { add() } else { selectedID = profiles.first?.id; save() }
    }

    func update(_ profile: ServerProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        save()
    }

    func save() {
        do {
            let data = try JSONEncoder.pretty.encode(profiles)
            let temporary = fileURL.appendingPathExtension("tmp")
            try data.write(to: temporary, options: [.atomic])
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            NSLog("TailMount profile save failed: \(error)")
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data),
           !decoded.isEmpty {
            profiles = decoded
        } else {
            profiles = [ServerProfile(name: "我的服务器")]
        }
        selectedID = profiles.first?.id
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
