import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var model: VPNModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: UserSettings
    @State private var mtu: String
    @State private var timeout: String
    @State private var validationError: String?
    init(model: VPNModel) {
        self.model = model
        _draft = State(initialValue: model.settings)
        _mtu = State(initialValue: String(model.settings.mtu))
        _timeout = State(initialValue: String(model.settings.probeTimeout))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("隧道协议", selection: $draft.tunnelProtocol) {
                        ForEach(WARPProtocol.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).disabled(model.active).accessibilityIdentifier("protocolPicker")
                        .onChange(of: draft.tunnelProtocol) { _, kind in model.selectProtocol(kind) }
                } header: { Label("连接协议", systemImage: "lock.shield") } footer: {
                    Text(model.active ? "断开 VPN 后可切换协议。" : "切换协议后自动检查注册与缓存。\(draft.tunnelProtocol.detail)")
                }
                Section {
                    Picker("主题", selection: $draft.theme) {
                        ForEach(UserSettings.Theme.allCases) { Text($0.label).tag($0) }
                    }.accessibilityIdentifier("themePicker").onChange(of: draft.theme) { _, value in model.setTheme(value) }
                } header: { Label("外观", systemImage: "paintpalette") }
                Section {
                    Picker("地址族", selection: $draft.addressFamily) {
                        ForEach(IPAddressFamily.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("addressFamilyPicker")
                    HStack {
                        Text("MTU")
                        Spacer()
                        TextField("0", text: $mtu).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 100).accessibilityIdentifier("mtuField")
                    }
                } header: { Label("网络", systemImage: "network") } footer: {
                    Text("地址族用于连接 WARP 入口。MTU 填 0 为自动（1280），手动范围为 1280–1500，不确定时建议保持自动。网络与 DNS 修改保存后生效，已连接的隧道将在下次连接时应用。")
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("自定义 DNS").font(.subheadline)
                        ZStack(alignment: .topLeading) {
                            if draft.customDNS.isEmpty { Text(verbatim: "留空使用默认 DNS\n1.1.1.1\nhttps://dns.example.com/dns-query").font(.caption).foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 4).allowsHitTesting(false) }
                            TextEditor(text: $draft.customDNS).font(.system(.caption, design: .monospaced)).frame(minHeight: 86)
                                .scrollContentBackground(.hidden).autocorrectionDisabled().textInputAutocapitalization(.never)
                                .accessibilityIdentifier("customDNSField")
                        }
                    }.disabled(draft.doNotSetDNS).opacity(draft.doNotSetDNS ? 0.45 : 1)
                    Toggle("DNS 防泄漏", isOn: Binding(get: { draft.dnsLeakProtection }, set: { value in
                        draft.dnsLeakProtection = value; if value { draft.doNotSetDNS = false }
                    })).accessibilityIdentifier("dnsLeakSwitch")
                    Toggle("不向隧道下发 DNS", isOn: Binding(get: { draft.doNotSetDNS }, set: { value in
                        draft.doNotSetDNS = value; if value { draft.dnsLeakProtection = false }
                    })).accessibilityIdentifier("noDNSSwitch")
                } header: { Label("DNS", systemImage: "server.rack") } footer: {
                    Text(draft.doNotSetDNS ? "保留系统 DNS，自定义 DNS 不生效，DNS 防泄漏同时关闭。" : "每行一个 DNS，最多 8 个；支持 IP、IP:端口、DoH、DoT、DoQ。防泄漏开启时，DNS 与解析 DNS 服务器域名的请求都通过隧道发送；关闭时使用直连上游。")
                }
                Section {
                    Picker("优选强度", selection: $draft.strength) {
                        ForEach(UserSettings.Strength.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("strengthPicker")
                    Picker("缓存有效期", selection: $draft.cacheHours) {
                        ForEach(UserSettings.cacheDurations, id: \.self) { Text("\($0) 小时").tag($0) }
                    }.accessibilityIdentifier("cacheHoursPicker")
                    HStack {
                        Text("探测超时")
                        Spacer()
                        TextField("5", text: $timeout).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 70).accessibilityIdentifier("timeoutField")
                        Text("秒").foregroundStyle(.secondary)
                    }
                } header: { Label("优选", systemImage: "sparkles") } footer: {
                    Text("\(draft.strength.label)强度：最多检查 \(draft.strength.candidates) 个候选，入围最多 \(draft.strength.finalists) 个节点，每节点稳定性复测 \(draft.strength.rounds) 次，再做 \(draft.strength.downloadRounds) 次下载测速。筛选通过后延迟最低的节点用于自动选择；本档下载量最多约 \(draft.strength.maxDownloadMiB) MiB。超时范围 1–30 秒。缓存期限从上次优选完成时计算，打开应用不会延长期限。")
                }
                Section {
                    NavigationLink { DiagnosticsView(model: model) } label: { Label("连接诊断", systemImage: "waveform.path.ecg") }.accessibilityIdentifier("diagnosticsButton")
                    LabeledContent("版本", value: model.versionLabel)
                } header: { Text("关于") }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() }.accessibilityIdentifier("settingsClose") }
                ToolbarItem(placement: .topBarTrailing) { Button("保存") { save() }.fontWeight(.semibold).accessibilityIdentifier("settingsDone") }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                        .accessibilityIdentifier("keyboardDone")
                }
            }
            .alert("设置提示", isPresented: Binding(get: { validationError != nil || model.errorMessage != nil }, set: { if !$0 { validationError = nil; model.errorMessage = nil } })) {
                Button("好") { validationError = nil; model.errorMessage = nil }
            } message: { Text(validationError ?? model.errorMessage ?? "") }
        }.preferredColorScheme(model.settings.theme.colorScheme)
    }
    private func save() {
        guard let mtuValue = Int(mtu.trimmingCharacters(in: .whitespaces)), let timeoutValue = Int(timeout.trimmingCharacters(in: .whitespaces)) else {
            validationError = "MTU 和探测超时请填写整数。"; return
        }
        draft.mtu = mtuValue; draft.probeTimeout = timeoutValue
        do { try model.applySettings(draft); dismiss() } catch { validationError = error.localizedDescription }
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: VPNModel
    var body: some View {
        ScrollView { Text(model.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding().accessibilityIdentifier("diagnosticText") }
            .navigationTitle("连接诊断").navigationBarTitleDisplayMode(.inline)
            .toolbar { ShareLink(item: model.reportURL) { Image(systemName: "square.and.arrow.up") } }
            .task { await model.refreshDiagnostics() }
    }
}

extension UserSettings.Theme {
    var colorScheme: ColorScheme? { switch self { case .system: return nil; case .light: return .light; case .dark: return .dark } }
}
