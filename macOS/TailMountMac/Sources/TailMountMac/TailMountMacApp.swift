import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var closeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow, window.title == "TailMount" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if !NSApp.windows.contains(where: { $0.title == "TailMount" && $0.isVisible }) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }
}

@main
struct TailMountMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("TailMount", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1040, minHeight: 700)
        }
        .defaultSize(width: 1180, height: 790)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("TailMount", systemImage: model.isMounted ? "externaldrive.fill.badge.checkmark" : "externaldrive") {
            MenuBarContent(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开 TailMount") { showWindow() }
            .keyboardShortcut("o")
        Divider()
        Label(model.quality.rawValue, systemImage: model.quality.symbol)
        if let profile = model.selectedProfile {
            Button(model.isMounted ? "在 Finder 中打开“\(profile.name)”" : "远程磁盘尚未挂载") {
                SSHFSService.openInFinder(profile)
            }
            .disabled(!model.isMounted)
            if model.isMounted {
                Button("卸载远程磁盘") { Task { await model.unmount(profile: profile) } }
            }
        }
        Divider()
        Button("退出 TailMount") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.title == "TailMount" })?.makeKeyAndOrderFront(nil)
        }
    }
}
