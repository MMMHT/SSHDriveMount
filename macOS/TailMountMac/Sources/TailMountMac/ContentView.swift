import Charts
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: ProfileStore

    init(model: AppModel) {
        self.model = model
        self.store = model.store
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model, store: store)
                .navigationSplitViewColumnWidth(min: 270, ideal: 290, max: 320)
        } detail: {
            if let profile = store.selected {
                ProfileDetail(model: model, profile: profile)
                    .id(profile.id)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "externaldrive.badge.plus").font(.system(size: 44)).foregroundStyle(TailTheme.accent)
                    Text("创建一个服务器配置").font(.title2.bold())
                    Button("新建配置") { store.add() }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("TailMount", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) { Button("确定", role: .cancel) {} } message: { Text(model.alertMessage ?? "") }
        .onChange(of: store.selectedID) { _ in model.profileSelectionChanged() }
        .task { model.profileSelectionChanged(); model.refreshDependencies() }
    }
}

private struct Sidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: ProfileStore

    var body: some View {
        ZStack {
            TailTheme.sidebar.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(TailTheme.accent)
                        Text("T").font(.title2.bold()).foregroundStyle(.white)
                    }.frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TailMount").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                        Text("macOS · SFTP Drive").font(.caption).foregroundStyle(.white.opacity(0.48))
                    }
                }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 26)

                HStack {
                    Text("连接配置").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.52))
                    Spacer()
                    Button { store.add() } label: { Label("新建", systemImage: "plus") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.86))
                }.padding(.horizontal, 22).padding(.bottom, 10)

                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(store.profiles) { profile in
                            Button {
                                store.selectedID = profile.id
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: model.isMounted && store.selectedID == profile.id ? "externaldrive.fill.badge.checkmark" : "server.rack")
                                        .font(.system(size: 17)).foregroundStyle(.mint)
                                        .frame(width: 36, height: 36)
                                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                        Text(profile.host.isEmpty ? "尚未配置" : profile.host).font(.caption).opacity(0.62).lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 13).padding(.vertical, 10)
                                .background(store.selectedID == profile.id ? TailTheme.accent : .clear, in: RoundedRectangle(cornerRadius: 13))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 13)
                }

                Spacer(minLength: 14)
                VStack(alignment: .leading, spacing: 11) {
                    Text("运行环境").font(.caption.weight(.semibold)).foregroundStyle(.white)
                    DependencyRow(name: "Tailscale", installed: model.dependencyState.tailscalePath != nil)
                    DependencyRow(name: "macFUSE", installed: model.dependencyState.macFUSEInstalled)
                    DependencyRow(name: "SSHFS", installed: model.dependencyState.sshfsPath != nil)
                    if !model.dependencyState.isReady {
                        Button("安装缺少的组件") { DependencyService.openDownloads() }
                            .buttonStyle(.plain).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                .padding(17).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                .padding(16)
            }
        }
    }
}

private struct ProfileDetail: View {
    @ObservedObject var model: AppModel
    @State private var draft: ServerProfile
    @State private var password = ""
    @State private var showDeleteConfirmation = false

    init(model: AppModel, profile: ServerProfile) {
        self.model = model
        _draft = State(initialValue: profile)
        let savedPassword = profile.rememberPassword
            ? ((try? KeychainStore.password(profileID: profile.id)) ?? nil)
            : nil
        _password = State(initialValue: savedPassword ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                HStack(alignment: .top, spacing: 22) {
                    VStack(spacing: 22) {
                        connectionCard
                        monitoringCard
                    }.frame(maxWidth: .infinity)
                    VStack(spacing: 22) {
                        actionCard
                        activityCard
                    }.frame(width: 345)
                }
                securityCard
            }.padding(30)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("删除“\(draft.name)”？", isPresented: $showDeleteConfirmation) {
            Button("删除配置", role: .destructive) { model.store.deleteSelected() }
        } message: { Text("服务器信息和保存在 Keychain 中的密码都会删除。") }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("远程磁盘").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(TailTheme.ink)
                Text("通过 Tailscale 安全地把服务器目录挂载到 Finder").foregroundStyle(TailTheme.muted)
            }
            Spacer()
            StatusBadge(quality: model.quality)
        }
    }

    private var connectionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("服务器连接").font(.title3.bold())
                        Text("填写 MagicDNS 名称或 Tailscale IP").font(.caption).foregroundStyle(TailTheme.muted)
                    }
                    Spacer()
                    Button("删除配置", role: .destructive) { showDeleteConfirmation = true }.buttonStyle(.plain)
                }
                HStack(spacing: 14) {
                    field("配置名称") { TextField("家庭服务器", text: $draft.name) }
                    field("服务器地址") { TextField("server.tailnet.ts.net", text: $draft.host) }
                }
                HStack(spacing: 14) {
                    field("用户名") { TextField("username", text: $draft.username) }
                    field("SSH 端口") { TextField("22", value: $draft.port, format: .number).frame(width: 110) }
                }
                HStack(spacing: 14) {
                    field("远程目录") { TextField("/", text: $draft.remotePath) }
                    field("本地挂载目录") { TextField("~/TailMount/服务器", text: $draft.mountFolder) }
                }
                Picker("认证方式", selection: $draft.authentication) {
                    ForEach(AuthenticationMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                if draft.authentication == .key {
                    field("私钥路径") { TextField("~/.ssh/id_ed25519", text: $draft.privateKeyPath) }
                } else {
                    HStack(alignment: .bottom, spacing: 12) {
                        field("密码") { SecureField("仅存入 macOS Keychain", text: $password) }
                        Toggle("记住密码", isOn: $draft.rememberPassword).toggleStyle(.checkbox).padding(.bottom, 7)
                    }
                }
                HStack {
                    Toggle("登录后恢复此挂载", isOn: $draft.restoreAfterLogin).toggleStyle(.checkbox)
                    Spacer()
                    Button("保存配置") { model.save(profile: draft, password: password) }.buttonStyle(.borderedProminent).tint(TailTheme.accent)
                }
            }
        }
    }

    private var actionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill((model.isMounted ? TailTheme.success : TailTheme.accent).opacity(0.11))
                    Image(systemName: model.isMounted ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.plus")
                        .font(.system(size: 28)).foregroundStyle(model.isMounted ? TailTheme.success : TailTheme.accent)
                }.frame(width: 60, height: 60)
                Text(model.isMounted ? "远程磁盘已就绪" : "准备挂载").font(.title2.bold())
                Text(model.isMounted ? "已连接到 \(draft.resolvedMountFolder)" : "先验证 Tailscale 与 SSH 端口，再将服务器目录显示为 Finder 磁盘。")
                    .font(.callout).foregroundStyle(TailTheme.muted).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("挂载预览").font(.caption).foregroundStyle(TailTheme.muted)
                    Text(draft.destination).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                Button(model.isBusy ? "正在处理…" : (model.isMounted ? "重新挂载" : "挂载远程磁盘")) {
                    model.save(profile: draft, password: password)
                    Task { await model.mount(profile: draft, password: password) }
                }.buttonStyle(PrimaryButtonStyle()).disabled(model.isBusy || !model.dependencyState.isReady)
                HStack {
                    Button("测试网络与 SSH 端口") { Task { await model.testConnection(profile: draft) } }.buttonStyle(.bordered).disabled(model.isBusy)
                    Button("卸载") { Task { await model.unmount(profile: draft) } }.buttonStyle(.bordered).disabled(!model.isMounted || model.isBusy)
                }.frame(maxWidth: .infinity)
                Button("在 Finder 中打开") { SSHFSService.openInFinder(draft) }
                    .buttonStyle(.bordered).tint(TailTheme.accent).disabled(!model.isMounted).frame(maxWidth: .infinity)
            }
        }
    }

    private var monitoringCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("连接质量").font(.title3.bold())
                    Spacer()
                    Text(model.statusDetail).font(.caption).foregroundStyle(TailTheme.muted)
                }
                HStack(spacing: 28) {
                    metric("当前延时", model.latencyMS.map { "\(Int($0)) ms" } ?? "--")
                    metric("近期成功率", "\(Int(model.successRate))%")
                    metric("监测周期", "10 秒")
                }
                Chart(model.samples) { sample in
                    if let latency = sample.latencyMS {
                        LineMark(x: .value("时间", sample.date), y: .value("延时", latency))
                            .foregroundStyle(TailTheme.accent.gradient)
                            .interpolationMethod(.catmullRom)
                        AreaMark(x: .value("时间", sample.date), y: .value("延时", latency))
                            .foregroundStyle(TailTheme.accent.opacity(0.08).gradient)
                            .interpolationMethod(.catmullRom)
                    }
                }.frame(height: 120).chartYAxis { AxisMarks(position: .leading) }
            }
        }
    }

    private var activityCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("活动记录").font(.headline)
                    Spacer()
                    Button("复制诊断") { model.copyActivities() }.buttonStyle(.plain).font(.caption)
                    Button("清空") { model.clearActivities() }.buttonStyle(.plain).font(.caption)
                }
                if model.activities.isEmpty {
                    Text("暂无记录").foregroundStyle(TailTheme.muted).frame(maxWidth: .infinity, minHeight: 110)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(model.activities.prefix(20)) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle().fill(activityColor(entry.level)).frame(width: 7, height: 7).padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.message).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                        if let details = entry.details, !details.isEmpty {
                                            DisclosureGroup("查看诊断详情") {
                                                Text(details)
                                                    .font(.system(.caption2, design: .monospaced))
                                                    .foregroundStyle(TailTheme.muted)
                                                    .textSelection(.enabled)
                                                    .padding(.top, 4)
                                            }
                                            .font(.caption2)
                                            .foregroundStyle(TailTheme.accent)
                                        }
                                        Text(entry.date, style: .time).font(.caption2).foregroundStyle(TailTheme.muted)
                                    }
                                }
                            }
                        }
                    }.frame(height: 240)
                }
            }
        }
    }

    private var securityCard: some View {
        Card {
            HStack(spacing: 16) {
                Image(systemName: "lock.shield.fill").font(.system(size: 24)).foregroundStyle(TailTheme.success)
                    .frame(width: 48, height: 48).background(TailTheme.success.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("安全提示").font(.headline)
                    Text("配置文件不包含密码；选择记忆密码时仅保存到当前用户的 macOS Keychain。建议服务器关闭公网 SSH，并优先使用无口令专用密钥。")
                        .font(.caption).foregroundStyle(TailTheme.muted)
                }
                Spacer()
                Toggle("登录时启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch)
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(TailTheme.muted)
            content().textFieldStyle(.roundedBorder)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(TailTheme.muted)
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded))
        }
    }

    private func activityColor(_ level: ActivityEntry.Level) -> Color {
        switch level {
        case .info: TailTheme.accent
        case .success: TailTheme.success
        case .warning: TailTheme.warning
        case .error: TailTheme.danger
        }
    }
}
