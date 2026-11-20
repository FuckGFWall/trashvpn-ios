import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: VPNModel
    private enum InputField: Hashable, CaseIterable { case mtu, cacheDays, timeout, minimumSpeed, dns }
    @FocusState private var focusedField: InputField?
    @State private var previousFocusedField: InputField?
    @State private var customDNS: String
    @ScaledMetric(relativeTo: .caption) private var legacyDNSHeight: CGFloat = 76
    @State private var inputErrors: [InputField: String] = [:]
    @State private var mtu: String
    @State private var cacheDays: String
    @State private var timeout: String
    @State private var minimumSpeed: String
    @State private var strengthPosition: Double
    @State private var adjustingStrength = false
    @State private var validationError: String?
    @State private var exportFormat: NodeExportFormat = .clash
    @State private var exportCount = 0
    @State private var exportFeedback: String?
    @State private var exportAvailabilityError: String?
    private var exportFormats: [NodeExportFormat] { NodeExportFormat.available(for: model.settings.tunnelProtocol) }
    private var activeExportFormat: NodeExportFormat { exportFormats.contains(exportFormat) ? exportFormat : .clash }
    private var exportKey: String { model.settings.tunnelProtocol.rawValue + ":" + model.settings.addressFamily.rawValue }
    init(model: VPNModel) {
        self.model = model
        _strengthPosition = State(initialValue: Double(UserSettings.Strength.allCases.firstIndex(of: model.settings.strength) ?? 1))
        _customDNS = State(initialValue: model.settings.customDNS)
        _mtu = State(initialValue: String(model.settings.mtu))
        _cacheDays = State(initialValue: String(model.settings.cacheDays))
        _timeout = State(initialValue: String(model.settings.probeTimeout))
        _minimumSpeed = State(initialValue: model.settings.minimumDownloadMbps.formatted(.number.grouping(.never)))
    }
    private func t(_ text: LocalizedText) -> String { text.localized(in: model.settings.language) }
    var body: some View {
        Form {
            Section {
                choiceMenu("隧道协议", choices: WARPProtocol.allCases, selection: setting(\.tunnelProtocol)) {
                    t(LocalizedText($0.label))
                }
                .disabled(model.switching || model.active && !model.connected)
                .accessibilityIdentifier("protocolPicker")
            } header: { Label(t("连接协议"), systemImage: "lock.shield") }
            Section {
                Menu {
                    ForEach(UserSettings.Theme.allCases) { theme in
                        Button { setting(\.theme).wrappedValue = theme } label: {
                            if theme == model.settings.theme { Label(t(LocalizedText(theme.label)), systemImage: "checkmark") }
                            else { Text(t(LocalizedText(theme.label))) }
                        }
                    }
                } label: { menuLabel("主题", value: t(LocalizedText(model.settings.theme.label))) }
                    .accessibilityIdentifier("themePicker")
                Menu {
                    ForEach(AppLanguage.supported) { language in
                        Button { setting(\.language).wrappedValue = language } label: {
                            if language == model.settings.language.resolved { Label(languageName(language), systemImage: "checkmark") }
                            else { Text(languageName(language)) }
                        }
                    }
                } label: { menuLabel("语言", value: languageName(model.settings.language)) }
                    .accessibilityIdentifier("languagePicker")
                    .accessibilityLabel(t("语言") + ", " + languageName(model.settings.language))
            } header: { Label(t("外观"), systemImage: "paintpalette") }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(t("优选强度"))
                        Spacer()
                        Text(t(LocalizedText(selectedStrength.label))).foregroundStyle(.tint)
                            .accessibilityIdentifier("strengthValue")
                    }
                    Slider(value: $strengthPosition, in: 0...2, step: 1) { editing in
                        adjustingStrength = editing
                        if !editing { saveStrength() }
                    }
                    .accessibilityLabel(t("优选强度"))
                    .accessibilityValue(t(LocalizedText(selectedStrength.label)))
                    .accessibilityIdentifier("strengthSlider")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: strengthPosition = min(2, strengthPosition + 1)
                        case .decrement: strengthPosition = max(0, strengthPosition - 1)
                        @unknown default: return
                        }
                        saveStrength()
                    }
                    HStack {
                        ForEach(Array(UserSettings.Strength.allCases.enumerated()), id: \.element.id) { index, strength in
                            if index > 0 { Spacer() }
                            Text(t(LocalizedText(strength.label))).font(.caption)
                                .foregroundStyle(selectedStrength == strength ? Color.accentColor : Color.secondary)
                        }
                    }.accessibilityHidden(true)
                }.padding(.vertical, 4)
                Toggle(t("优选完成后自动连接"), isOn: setting(\.autoConnectAfterOptimization))
                    .accessibilityIdentifier("autoConnectAfterOptimizationSwitch")
                HStack {
                    Text(t("探测超时"))
                    Spacer()
                    TextField("5", text: $timeout).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 70).focused($focusedField, equals: .timeout).accessibilityIdentifier("timeoutField")
                    Text(t("秒")).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { focusedField = .timeout }
                inputError(.timeout)
                Toggle(t("下载测速"), isOn: setting(\.downloadTestEnabled)).accessibilityIdentifier("downloadTestSwitch")
                HStack {
                    Text(t("最小下载速度"))
                    Spacer()
                    TextField("3", text: $minimumSpeed).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                        .focused($focusedField, equals: .minimumSpeed).accessibilityIdentifier("minimumDownloadSpeedField")
                    Text("Mbps").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { focusedField = .minimumSpeed }
                .disabled(!model.settings.downloadTestEnabled).opacity(model.settings.downloadTestEnabled ? 1 : 0.45)
                inputError(.minimumSpeed)
            } header: { Label(t("优选"), systemImage: "sparkles") } footer: {
                Text(t("\(model.settings.strength.label)强度：每轮最多检查 \(model.settings.strength.candidates) 个候选，入围最多 \(model.settings.strength.qualityCandidates) 个节点；稳定性检查 \(model.settings.strength.minimumRounds) 次，异常时最多补测到 \(model.settings.strength.maximumRounds) 次。取得 \(model.settings.strength.desiredResults) 个合格节点即结束，自动选择其中延迟最低的节点。"))
            }
            Section {
                Toggle(t("缓存永不过期"), isOn: setting(\.cacheNeverExpires))
                    .accessibilityIdentifier("cacheNeverExpiresSwitch")
                HStack {
                    Text(t("有效期"))
                    Spacer()
                    TextField(String(UserSettings.defaultCacheDays), text: $cacheDays)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .focused($focusedField, equals: .cacheDays)
                        .accessibilityLabel(t("有效期"))
                        .accessibilityIdentifier("cacheDaysField")
                    Text(t("天")).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { focusedField = .cacheDays }
                .disabled(model.settings.cacheNeverExpires)
                .opacity(model.settings.cacheNeverExpires ? 0.45 : 1)
                inputError(.cacheDays)
            } header: { Label(t("缓存"), systemImage: "internaldrive") }
            Section {
                choiceMenu("地址族", choices: IPAddressFamily.allCases, selection: setting(\.addressFamily)) {
                    t(LocalizedText($0.label))
                }
                .accessibilityIdentifier("addressFamilyPicker")
                HStack {
                    Text(t("MTU"))
                    Spacer()
                    TextField("0", text: $mtu).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 100).focused($focusedField, equals: .mtu).accessibilityIdentifier("mtuField")
                }
                .contentShape(Rectangle())
                .onTapGesture { focusedField = .mtu }
                inputError(.mtu)
            } header: { Label(t("网络"), systemImage: "network") } footer: {
                Text(t("设置为 0 则使用自动 MTU。"))
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("自定义 DNS")).font(.subheadline)
                    dnsInput
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .dns).accessibilityIdentifier("customDNSField")
                        .environment(\.layoutDirection, .leftToRight)
                }.disabled(model.settings.doNotSetDNS).opacity(model.settings.doNotSetDNS ? 0.45 : 1)
                inputError(.dns)
                Toggle(t("DNS 防泄漏"), isOn: Binding(get: { model.settings.dnsLeakProtection }, set: { enabled in
                    var value = model.settings
                    value.dnsLeakProtection = enabled; if enabled { value.doNotSetDNS = false }
                    apply(value)
                })).accessibilityIdentifier("dnsLeakSwitch")
                Toggle(t("不向隧道下发 DNS"), isOn: Binding(get: { model.settings.doNotSetDNS }, set: { enabled in
                    var value = model.settings
                    value.doNotSetDNS = enabled; if enabled { value.dnsLeakProtection = false }
                    apply(value)
                })).accessibilityIdentifier("noDNSSwitch")
            } header: { Label(t("DNS"), systemImage: "server.rack") } footer: {
                Text(t("每行一个 DNS，最多 8 个；支持 IP、IP:端口、DoH、DoT、DoQ。"))
            }
            Section {
                HStack(spacing: 16) {
                    choiceMenu("节点导出", choices: exportFormats, selection: Binding(get: { activeExportFormat }, set: {
                        exportFormat = $0
                        exportFeedback = nil
                    })) { $0.label }
                    .accessibilityIdentifier("exportFormatMenu")
                    .accessibilityValue(activeExportFormat.label)
                    Button(t(exportFeedback == nil ? "复制" : "已复制")) { copyNodes() }
                        .buttonStyle(.borderless).disabled(exportCount == 0).accessibilityIdentifier("copyNodesButton")
                }
            } header: { Label(t("节点"), systemImage: "square.and.arrow.up") } footer: {
                Text(exportAvailabilityError ?? t("复制本地缓存中的 \(exportCount) 个节点。"))
                    .accessibilityIdentifier("exportStatus")
            }
            Section {
                ForEach(ProjectLink.community) { link in
                    Link(destination: link.url) {
                        HStack(spacing: 12) {
                            projectIcon(link)
                                .frame(width: 28, height: 28)
                                .background(link.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            Text(t(link.title)).foregroundStyle(Color.primary).lineLimit(1)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(Color.secondary.opacity(0.6))
                        }.padding(.horizontal, 16).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).listRowInsets(EdgeInsets())
                        .accessibilityIdentifier("projectLink-" + link.id)
                }
                HStack {
                    Text(t("版本"))
                    Spacer()
                    Text(model.versionLabel).foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("versionRow")
                NavigationLink { DiagnosticsView(model: model) } label: { Label(t("连接诊断"), systemImage: "waveform.path.ecg") }.accessibilityIdentifier("diagnosticsButton")
            } header: { Text(t("关于")) }
            Section {
                Link(destination: ProjectLink.donate.url) {
                    HStack(spacing: 14) {
                        Image(systemName: "heart.fill").font(.system(size: 18))
                            .frame(width: 28, height: 28).background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
                        Text(t("捐赠")).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right").font(.subheadline.weight(.semibold))
                    }.foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).listRowInsets(EdgeInsets()).accessibilityIdentifier("projectLink-donate")
                    .listRowBackground(LinearGradient(colors: [Color(red: 0.83, green: 0.23, blue: 0.04), Color(red: 0.76, green: 0.12, blue: 0.05)], startPoint: .leading, endPoint: .trailing))
            } header: { Text(t("捐赠")) }
        }
        // A fresh collection view avoids UIKit retaining mirrored cell layers after RTL changes.
        .id(model.settings.language)
        .disabled(model.switching || model.measuring || model.disconnectingForOptimization)
        .navigationTitle(t("设置")).navigationBarTitleDisplayMode(.inline)
        .background {
            if #available(iOS 26.0, *) {
                SettingsBackGesture(edgeOnly: !model.settings.language.isRightToLeft)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .task(id: [mtu, cacheDays, timeout, minimumSpeed, customDNS]) {
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            saveTextInputs()
        }
        .onChange(of: model.settings.language) { _ in saveTextInputs() }
        .onChange(of: focusedField) { field in
            let previous = previousFocusedField
            previousFocusedField = field
            if let previous { saveTextInput(previous) }
        }
        .onChange(of: model.settings.strength) { strength in
            if !adjustingStrength { strengthPosition = Double(UserSettings.Strength.allCases.firstIndex(of: strength) ?? 1) }
        }
        .onChange(of: model.settings.cacheNeverExpires) { enabled in
            if enabled {
                cacheDays = String(model.settings.cacheDays)
                inputErrors[.cacheDays] = nil
            }
        }
        .onDisappear { saveTextInputs(); saveStrength() }
        .task(id: exportKey) { exportFeedback = nil; refreshExportCount() }
        .onChange(of: model.cache) { _ in refreshExportCount() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(t("完成")) { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                    .accessibilityIdentifier("keyboardDone")
            }
        }
        .alert(t("设置提示"), isPresented: Binding(get: { validationError != nil || model.errorMessage != nil }, set: { if !$0 { validationError = nil; model.errorMessage = nil } })) {
            Button(t("好")) { validationError = nil; model.errorMessage = nil }
        } message: { Text(validationError ?? model.errorMessage ?? "") }
        .preferredColorScheme(model.settings.theme.colorScheme)
    }
    @ViewBuilder private var dnsInput: some View {
        let placeholder = t("留空使用默认 DNS 1.1.1.1")
        if #available(iOS 16.0, *) {
            TextField(placeholder, text: $customDNS, axis: .vertical).lineLimit(1...4)
        } else {
            TextEditor(text: $customDNS)
                .frame(height: legacyDNSHeight)
                .overlay(alignment: .topLeading) {
                    if customDNS.isEmpty {
                        Text(placeholder).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 8)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(t("自定义 DNS"))
        }
    }
    private var selectedStrength: UserSettings.Strength {
        UserSettings.Strength.allCases[min(2, max(0, Int(strengthPosition.rounded())))]
    }
    private func saveStrength() {
        guard model.settings.strength != selectedStrength else { return }
        var value = model.settings; value.strength = selectedStrength; apply(value)
    }
    private func languageName(_ language: AppLanguage) -> String { language.resolved.nativeName }
    private func choiceMenu<Value: Hashable>(_ title: LocalizedText, choices: [Value], selection: Binding<Value>,
                                             label: @escaping (Value) -> String) -> some View {
        Menu {
            ForEach(choices, id: \.self) { choice in
                Button { selection.wrappedValue = choice } label: {
                    if choice == selection.wrappedValue { Label(label(choice), systemImage: "checkmark") }
                    else { Text(label(choice)) }
                }
            }
        } label: { menuLabel(title, value: label(selection.wrappedValue)) }
    }
    private func menuLabel(_ title: LocalizedText, value: String) -> some View {
        HStack(spacing: 12) {
            Text(t(title)).foregroundStyle(Color.primary)
            Spacer(minLength: 12)
            Text(value).lineLimit(1).fixedSize(horizontal: true, vertical: false).foregroundStyle(.tint)
            Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tint)
        }.font(.body).contentShape(Rectangle())
    }
    @ViewBuilder private func projectIcon(_ link: ProjectLink) -> some View {
        if let asset = link.assetName {
            Image(asset).resizable().scaledToFit()
                .frame(width: 17, height: 17).foregroundStyle(Color.primary)
        } else if let symbol = link.symbol {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(link.color)
        }
    }
    private func refreshExportCount() {
        do {
            exportCount = try model.cachedExportCount(kind: model.settings.tunnelProtocol, family: model.settings.addressFamily)
            exportAvailabilityError = nil
        } catch { exportCount = 0; exportAvailabilityError = error.localizedDescription }
    }
    private func copyNodes() {
        do {
            let payload = try model.exportCachedNodes(kind: model.settings.tunnelProtocol, family: model.settings.addressFamily, format: activeExportFormat)
            UIPasteboard.general.string = payload.text
            exportFeedback = "已复制 \(payload.count) 个 \(model.settings.tunnelProtocol.label) · \(model.settings.addressFamily.label) 节点。"
        } catch { validationError = error.localizedDescription; refreshExportCount() }
    }
    private func setting<Value>(_ keyPath: WritableKeyPath<UserSettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { newValue in
            saveTextInputs()
            var value = model.settings
            value[keyPath: keyPath] = newValue
            apply(value)
        })
    }
    private func apply(_ value: UserSettings) {
        guard value != model.settings else { return }
        do { try model.applySettings(value) } catch { validationError = error.localizedDescription }
    }
    @ViewBuilder private func inputError(_ field: InputField) -> some View {
        if let error = inputErrors[field] {
            Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("settingsInputError")
        }
    }
    private func saveTextInputs() {
        for field in InputField.allCases { saveTextInput(field) }
    }
    private func saveTextInput(_ field: InputField) {
        var value = model.settings
        do {
            switch field {
            case .mtu:
                guard let number = Int(mtu.trimmingCharacters(in: .whitespaces)), number == 0 || (1280...1500).contains(number) else {
                    throw WARPError.message("MTU 请填写 0（自动），或 1280–1500 的整数。")
                }
                value.mtu = number
            case .cacheDays:
                guard !value.cacheNeverExpires else { return }
                let text = cacheDays.trimmingCharacters(in: .whitespaces)
                let digits = text.compactMap(\.wholeNumberValue).filter { (0...9).contains($0) }
                guard digits.count == text.count, let number = Int(digits.map(String.init).joined()),
                      UserSettings.validCacheDays.contains(number) else {
                    throw WARPError.message("缓存有效期请输入 1 至 36500 天的整数。")
                }
                value.cacheDays = number
            case .timeout:
                guard let number = Int(timeout.trimmingCharacters(in: .whitespaces)), (1...30).contains(number) else {
                    throw WARPError.message("探测超时应为 1–30 秒。")
                }
                value.probeTimeout = number
            case .minimumSpeed:
                let text = minimumSpeed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                guard let number = Double(text), number.isFinite, (0.1...1000).contains(number) else {
                    if !value.downloadTestEnabled { inputErrors[field] = nil; return }
                    throw WARPError.message("最小下载速度应为 0.1–1000 Mbps。")
                }
                value.minimumDownloadMbps = number
            case .dns:
                guard customDNS != model.settings.customDNS else { inputErrors[field] = nil; return }
                value.customDNS = customDNS
                // Validate even when the DNS editor is disabled, so an invalid draft is never saved.
                _ = try value.dnsServers()
            }
            inputErrors[field] = nil
        } catch { inputErrors[field] = error.localizedDescription; return }
        apply(value)
    }
}

enum ProjectLink: String, CaseIterable, Identifiable {
    case website, github, telegram, youtube, x, donate
    var id: String { rawValue }
    static var community: [Self] { allCases.filter { $0 != .donate } }
    var url: URL {
        let value: String
        switch self {
        case .website: value = "https://itmanager.top"
        case .github: value = "https://github.com/FuckGFWall/trashvpn-ios"
        case .telegram: value = "https://t.me/+eJ2kUZ3kUJ9jZmNl"
        case .youtube: value = "https://www.youtube.com/@TrashVPN"
        case .x: value = "https://x.com/trashvpn"
        case .donate: value = "https://itmanager.top/donate.html"
        }
        return URL(string: value)!
    }
    var title: LocalizedText {
        switch self {
        case .website: return "官网"
        case .github: return "GitHub"
        case .telegram: return "Telegram"
        case .youtube: return "YouTube"
        case .x: return "X"
        case .donate: return "捐赠"
        }
    }
    var assetName: String? { self == .github ? "GitHubMark" : self == .x ? "XMark" : nil }
    var symbol: String? {
        switch self {
        case .website: return "globe"
        case .github: return nil
        case .telegram: return "paperplane.fill"
        case .youtube: return "play.rectangle.fill"
        case .x: return nil
        case .donate: return "heart.fill"
        }
    }
    var color: Color {
        switch self {
        case .website, .donate: return .orange
        case .github, .x: return .primary
        case .telegram: return .blue
        case .youtube: return .red
        }
    }
}

@available(iOS 26.0, *)
private struct SettingsBackGesture: UIViewControllerRepresentable {
    let edgeOnly: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.edgeOnly = edgeOnly
        controller.updateGesture()
    }

    final class Controller: UIViewController {
        var edgeOnly = false
        private weak var disabledGesture: UIGestureRecognizer?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updateGesture()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            restoreGesture()
        }

        func updateGesture() {
            if !edgeOnly {
                restoreGesture()
            } else if let gesture = navigationController?.interactiveContentPopGestureRecognizer, gesture.isEnabled {
                gesture.isEnabled = false
                disabledGesture = gesture
            }
        }

        private func restoreGesture() {
            disabledGesture?.isEnabled = true
            disabledGesture = nil
        }
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: VPNModel
    @State private var report: String?
    @State private var document: DiagnosticsDocument?
    @State private var exporting = false
    @State private var exportError: String?

    private func t(_ text: LocalizedText) -> String { text.localized(in: model.settings.language) }

    var body: some View {
        DiagnosticsTextView(text: report ?? model.diagnosticsOverview)
            .navigationTitle(t("连接诊断")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            if let report { UIPasteboard.general.string = report }
                        } label: {
                            Label(t("复制到剪贴板"), systemImage: "doc.on.doc")
                        }
                        .disabled(report == nil)
                        Button {
                            if let report {
                                document = DiagnosticsDocument(text: report)
                                exporting = true
                            }
                        } label: {
                            Label(t("导出为文件"), systemImage: "doc")
                        }
                        .disabled(report == nil)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(t("共享"))
                    .accessibilityIdentifier("diagnosticShareMenu")
                }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .plainText,
                          defaultFilename: "WARP-Diagnostics") { result in
                if case .failure(let error) = result { exportError = error.localizedDescription }
            }
            .alert(t("导出诊断失败"), isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button(t("好")) { exportError = nil }
            } message: { Text(exportError ?? "") }
            .task {
                while !Task.isCancelled {
                    let snapshot = await model.diagnosticsReport()
                    guard !Task.isCancelled else { return }
                    report = snapshot
                    do { try await Task.sleep(nanoseconds: 3_000_000_000) }
                    catch { return }
                }
            }
    }
}

private struct DiagnosticsTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(frame: .zero, textContainer: nil)
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textColor = .label
        view.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.layoutManager.allowsNonContiguousLayout = true
        view.accessibilityIdentifier = "diagnosticText"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard view.text != text else { return }
        let offset = view.contentOffset
        let selection = view.selectedRange
        view.text = text
        view.accessibilityLabel = text
        if selection.length > 0, NSMaxRange(selection) <= text.utf16.count { view.selectedRange = selection }
        view.setContentOffset(offset, animated: false)
    }
}

private struct DiagnosticsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension UserSettings.Theme {
    var colorScheme: ColorScheme? { switch self { case .system: return nil; case .light: return .light; case .dark: return .dark } }
}
