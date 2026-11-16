import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var controller: FrpcController
    @EnvironmentObject private var keepAlive: KeepAlive
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSecrets = false
    @State private var showOptions = false
    @State private var showLog = false
    @State private var showReplaceConfirmation = false
    @State private var connectAfterReplace = false
    @State private var copiedAddress = false
    @State private var showCertificateImporter = false
    @State private var certificateImportSlot = 0
    @State private var showAdvancedConfirmation = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    profileSelector
                    connectionCard
                    configurationCard
                    backgroundCard
                    diagnosticsCard
                    Text("在聊天客户端的 Ollama 服务器设置中填入上方本机地址。电脑上的 Ollama 和发布端 frpc 也需保持运行。")
                        .font(.footnote).foregroundColor(.secondary).padding(.horizontal, 4)
                }
                .padding().frame(maxWidth: 700).frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarHidden(true)
            .onChange(of: controller.selectedSlot) { _ in
                showSecrets = false
                copiedAddress = false
                showReplaceConfirmation = false
                showAdvancedConfirmation = false
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    keepAlive.refreshStatus()
                    controller.refreshOnForeground()
                }
            }
            .alert("使用基础表单替换自定义配置？", isPresented: $showReplaceConfirmation) {
                Button("保留自定义配置", role: .cancel) {}
                Button("替换为基础配置", role: .destructive) {
                    if controller.applyForm(), connectAfterReplace { controller.start() }
                }
            } message: {
                Text("基础表单会重新生成配置，未包含的高级选项将被移除。如需保留，请使用高级 TOML 连接。")
            }
            .alert("切换到高级 TOML？", isPresented: $showAdvancedConfirmation) {
                Button("取消", role: .cancel) {}
                Button("保存当前表单并切换") {
                    if controller.applyForm() { controller.formMode = false }
                }
                Button("使用现有 TOML，舍弃表单修改", role: .destructive) {
                    controller.formMode = false
                }
            } message: {
                Text("高级模式使用 TOML 内容连接。请选择保存当前表单，或使用已有的 TOML。")
            }
            .fileImporter(isPresented: $showCertificateImporter, allowedContentTypes: [.data, .text], allowsMultipleSelection: false) { result in
                if controller.selectedSlot == certificateImportSlot,
                   case .success(let urls) = result, let url = urls.first {
                    _ = controller.importCertificate(from: url)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var profileSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("VPS 配置", systemImage: "server.rack").font(.headline)
            Picker("选择 VPS 配置", selection: Binding(get: { controller.selectedSlot }, set: { slot in
                _ = controller.selectSlot(slot)
            })) {
                ForEach(0..<3) { slot in Text("配置 \(slot + 1)").tag(slot) }
            }.pickerStyle(.segmented).disabled(!controller.canEdit)
            Text(controller.canEdit ? "切换时保存当前草稿。三组地址、密钥和高级设置独立保存在本机钥匙串。" : "请先停止连接，等待停止完成后再切换配置。")
                .font(.footnote).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }.cardStyle()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text("连接本地模型").font(.title2.bold())
                Text("FrpClient · frp \(controller.frpVersion)")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 4)
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: phaseSymbol).font(.title2).foregroundColor(phaseColor).frame(width: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(controller.phase.title).font(.headline)
                    if !controller.statusDetail.isEmpty {
                        Text(controller.statusDetail).font(.subheadline).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if controller.isBusy {
                    ProgressView().accessibilityLabel("正在处理连接")
                }
            }
            if !controller.lastError.isEmpty {
                Label(controller.lastError, systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if controller.canStop {
                    Button(action: controller.stop) {
                        Label("停止连接", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(controller.phase == .stopping)
                } else {
                    Button(action: { applyFormOrConnect(connect: true) }) {
                        Label("保存并连接", systemImage: "bolt.horizontal.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).disabled(controller.isBusy)
                }
                Button(action: controller.testTunnel) {
                    HStack(spacing: 6) {
                        if controller.isTesting { ProgressView() }
                        Text(controller.isTesting ? "正在测试" : "测试连接")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!controller.isRunning || controller.isBusy || controller.isTesting)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("测试结果").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                Text(controller.testResult).font(.subheadline)
                    .foregroundColor(controller.phase == .ready ? .green : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !controller.models.isEmpty {
                    DisclosureGroup("可用模型（\(controller.models.count)）") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(controller.models.prefix(20).enumerated()), id: \.offset) { _, model in
                                Text(model).font(.footnote.monospaced()).textSelection(.enabled)
                            }
                            if controller.models.count > 20 {
                                Text("其余模型可在聊天客户端中查看。").font(.caption).foregroundColor(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }.font(.subheadline)
                }
            }
            Divider()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("聊天客户端服务器地址").font(.caption).foregroundColor(.secondary)
                    Text(controller.endpoint.isEmpty ? "连接后显示" : controller.endpoint)
                        .font(.footnote.monospaced()).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = controller.endpoint
                    copiedAddress = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedAddress = false }
                } label: {
                    Label(copiedAddress ? "已复制" : "复制", systemImage: copiedAddress ? "checkmark" : "doc.on.doc").font(.footnote)
                }.disabled(controller.endpoint.isEmpty)
            }
        }.cardStyle()
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("配置 \(controller.selectedSlot + 1) 的连接设置", systemImage: "slider.horizontal.3").font(.headline)
            Picker("配置方式", selection: Binding(get: { controller.formMode }, set: { form in
                if !form && controller.formMode { showAdvancedConfirmation = true }
                else { controller.formMode = form }
            })) {
                Text("基础表单").tag(true)
                Text("高级 TOML").tag(false)
            }.pickerStyle(.segmented).disabled(!controller.canEdit)
            if controller.formMode { basicForm } else { advancedEditor }
            if !controller.storageMessage.isEmpty {
                Text(controller.storageMessage).font(.footnote).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !controller.canEdit {
                Label("停止连接后可修改配置。", systemImage: "lock").font(.footnote).foregroundColor(.secondary)
            }
        }.cardStyle()
    }

    private var basicForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            if controller.isCustomConfig {
                Label("已载入自定义配置。保存基础表单前会确认是否替换高级选项。", systemImage: "info.circle")
                    .font(.footnote).foregroundColor(.orange)
            }
            entry("服务器地址", placeholder: "例如 frp.example.com", text: $controller.profile.serverAddr).keyboardType(.URL)
            entry("服务器端口", placeholder: "7000", text: $controller.profile.serverPort).keyboardType(.numberPad)
            secretEntry("认证 Token", placeholder: "与中继服务器一致", text: $controller.profile.token)
            secretEntry("访问密钥", placeholder: "与电脑发布端一致", text: $controller.profile.secretKey)
            Toggle("显示密钥", isOn: $showSecrets).font(.subheadline)
            DisclosureGroup("高级连接选项", isExpanded: $showOptions) {
                VStack(alignment: .leading, spacing: 14) {
                    entry("目标代理名称", placeholder: "ollama", text: $controller.profile.serverName)
                    entry("本机访问器名称", placeholder: "ollama-visitor-ios", text: $controller.profile.visitorName)
                    entry("本机端口", placeholder: "11434", text: $controller.profile.bindPort).keyboardType(.numberPad)
                    entry("发布端用户（可留空）", placeholder: "与发布端配置一致", text: $controller.profile.serverUser)
                    Toggle("验证系统信任的服务器证书", isOn: $controller.profile.useSystemCA).font(.subheadline)
                    Text("开启前，中继服务器需配置受信任且域名匹配的证书。现有自签证书可能被拒绝，也可导入对应的 CA 证书。")
                        .font(.caption).foregroundColor(.secondary)
                    HStack {
                        Button("导入 CA 证书") {
                            certificateImportSlot = controller.selectedSlot
                            showCertificateImporter = true
                        }
                        if !controller.profile.trustedCaFile.isEmpty {
                            Spacer()
                            Button("移除 CA", role: .destructive) { controller.profile.trustedCaFile = "" }
                        }
                    }.font(.footnote).buttonStyle(.bordered)
                    if !controller.profile.trustedCaFile.isEmpty {
                        Label(URL(fileURLWithPath: controller.profile.trustedCaFile).lastPathComponent, systemImage: "checkmark.shield")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }.padding(.top, 12)
            }.font(.subheadline)
            Button("保存配置") { applyFormOrConnect(connect: false) }.buttonStyle(.bordered)
        }.disabled(!controller.canEdit)
    }

    private var advancedEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("粘贴完整 frpc 配置。连接时使用这里的内容，高级选项会保留。配置含密钥，请勿分享截图。")
                .font(.footnote).foregroundColor(.secondary)
            TextEditor(text: $controller.configText)
                .font(.system(.footnote, design: .monospaced))
                .autocapitalization(.none).disableAutocorrection(true)
                .frame(minHeight: 260).padding(8)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator).opacity(0.4)))
                .accessibilityLabel("高级 TOML 配置")
            HStack {
                Button("保存配置") { controller.saveConfig() }
                Spacer()
                Button("从 TOML 读取表单") { controller.importAdvancedConfig() }
            }.font(.subheadline).buttonStyle(.bordered)
        }.disabled(!controller.canEdit)
    }

    private var backgroundCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $controller.backgroundEnabled) {
                Label("后台连接辅助", systemImage: "location.circle").font(.headline)
            }
            Text("使用粗略定位争取后台运行时间；位置不保存、不上传。锁屏、低电量或系统回收仍可能中断连接，不能保证一直在线。")
                .font(.footnote).foregroundColor(.secondary)
            if controller.backgroundEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text(keepAlive.authorizationText)
                    Text(keepAlive.activityText).foregroundColor(.secondary)
                }.font(.footnote)
                HStack {
                    Button("允许定位", action: keepAlive.requestPermission)
                    if keepAlive.canRequestAlways {
                        Button("升级为始终允许", action: keepAlive.requestAlways)
                    }
                    Spacer(minLength: 0)
                    if let settings = URL(string: UIApplication.openSettingsURLString) {
                        Link("系统设置", destination: settings)
                    }
                }.font(.footnote).buttonStyle(.bordered)
                Text("切到聊天客户端后，请保留 FrpClient 后台运行；从多任务界面划掉会终止隧道。")
                    .font(.caption).foregroundColor(.secondary)
            }
        }.cardStyle()
    }

    private var diagnosticsCard: some View {
        DisclosureGroup(isExpanded: $showLog) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("日志仅用于排查当前连接。").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("清空", action: controller.clearLog).font(.footnote)
                }
                ScrollView {
                    Text(controller.logText.isEmpty ? "暂无日志" : controller.logText)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 180).padding(10)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }.padding(.top, 12)
        } label: {
            Label("连接诊断", systemImage: "waveform.path.ecg").font(.headline)
        }.cardStyle()
    }

    private func entry(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundColor(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
                .autocapitalization(.none).disableAutocorrection(true).accessibilityLabel(title)
        }
    }

    private func secretEntry(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Group {
                if showSecrets { TextField(placeholder, text: text) }
                else { SecureField(placeholder, text: text) }
            }.textFieldStyle(.roundedBorder)
                .autocapitalization(.none).disableAutocorrection(true).accessibilityLabel(title)
        }
    }

    private func applyFormOrConnect(connect: Bool) {
        if controller.formMode {
            if controller.isCustomConfig {
                connectAfterReplace = connect
                showReplaceConfirmation = true
            } else if controller.applyForm(), connect {
                controller.start()
            }
        } else if connect {
            controller.start()
        } else {
            controller.saveConfig()
        }
    }

    private var phaseColor: Color {
        switch controller.phase {
        case .ready: return .green
        case .connecting, .reconnecting, .stopping: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    private var phaseSymbol: String {
        switch controller.phase {
        case .ready: return "checkmark.circle.fill"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .stopping: return "pause.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .stopped: return "power.circle"
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(18)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
