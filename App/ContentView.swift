import SwiftUI

struct ContentView: View {
    @ObservedObject var model: VPNModel
    @State private var legacyShowSettings = false
    @State private var path: [Destination] = []
    private enum Destination: Hashable { case settings }
    private var showSettings: Bool { legacyShowSettings || !path.isEmpty }
    @ScaledMetric(relativeTo: .caption) private var flagFontSize: CGFloat = 17
    @ScaledMetric(relativeTo: .caption) private var flagBaselineOffset: CGFloat = 2
    private let orange = Color(red: 1, green: 0.38, blue: 0.08)

    private func t(_ text: LocalizedText) -> String { text.localized(in: model.settings.language) }

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack(path: $path) {
                home.navigationDestination(for: Destination.self) { _ in SettingsView(model: model) }
            }
        } else {
            NavigationView {
                ZStack {
                    home
                    NavigationLink(isActive: $legacyShowSettings) { SettingsView(model: model) } label: { EmptyView() }
                }
            }.navigationViewStyle(.stack)
        }
    }

    private var home: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 20) {
                    Button {
                        if model.active { model.disconnect() } else { Task { await model.connect() } }
                    } label: {
                        ConnectionPowerButton(status: model.authorizingVPN && !model.active ? .connecting : model.status)
                    }.buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(t(model.active ? "断开连接" : "连接 WARP")).accessibilityValue(t(LocalizedText(model.statusLabel))).accessibilityIdentifier("connectButton")
                        .disabled(model.switching || model.disconnectingForOptimization || !model.active && (model.scanning || model.measuring || !model.cacheIsFresh))
                    preparation
                    connectionInfo
                }
                .padding(24).frame(maxWidth: .infinity)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28))

                nodes
            }.padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 22)
        }.id(model.settings.language).disabled(model.preparingApp || model.authorizingVPN).background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text("TrashVPN").font(.system(size: 22, weight: .bold, design: .rounded))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        if #available(iOS 16.0, *) { path.append(.settings) }
                        else { legacyShowSettings = true }
                    } label: { Image(systemName: "gearshape") }
                        .disabled(model.preparingApp || model.authorizingVPN)
                        .accessibilityLabel(t("设置")).accessibilityIdentifier("settingsButton")
                }
            }
            .alert(t("连接提示"), isPresented: Binding(get: { model.errorMessage != nil && !showSettings }, set: { if !$0 { model.errorMessage = nil } })) {
                Button(t("好")) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
    }

    private var connectionInfo: some View {
        HStack {
            if model.connected {
                if let location = model.connectionLocation {
                    HStack(alignment: .firstTextBaseline, spacing: 24) {
                        Label { countryText(location) } icon: { Image(systemName: "globe") }
                        Label(t("数据中心: \(location.colo)"), systemImage: "server.rack")
                    }
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(location.localizedLabel(in: model.settings.language))
                    .accessibilityIdentifier("connectionLocation")
                } else {
                    Text(t(model.locatingConnection ? "正在检测连接位置…" : "连接位置暂不可用"))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .accessibilityIdentifier("connectionLocation")
                }
            } else {
                Label(model.selected.kind.detail, systemImage: "lock.shield")
                Spacer()
                Text(model.addressFamily.label)
            }
        }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func countryText(_ location: ConnectionLocation) -> Text {
        let parts = t("国家: \(location.flag)").components(separatedBy: location.flag)
        return Text(verbatim: parts[0]) + Text(verbatim: location.flag).font(.system(size: flagFontSize))
            .baselineOffset(-flagBaselineOffset) + Text(verbatim: parts.dropFirst().joined(separator: location.flag))
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(model.progress.localizedDisplayTitle(in: model.settings.language)).font(.caption).lineLimit(1).minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                    .accessibilityIdentifier("progressStage")
                Button(t(model.scanning ? "暂停" : model.resumablePreparation && !model.active ? "继续优选" : "重新优选")) {
                    if model.scanning { model.stopScan() } else { model.scan() }
                }.font(.caption.weight(.semibold)).buttonStyle(.bordered).controlSize(.small)
                    .fixedSize().disabled(!model.canOptimize).accessibilityIdentifier("scanButton")
            }
            PreparationProgressBar(progress: model.progress, running: model.scanning, language: model.settings.language)
            if model.scanning || model.resumablePreparation || model.disconnectingForOptimization || model.progress.stage == .failed {
                Text(t(model.message)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("messageText")
            }
        }
    }

    private var nodes: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(t("选择节点")).font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("nodeSectionTitle")
                testButton(.latency, title: "延迟", identifier: "latencyTestButton")
                testButton(.download, title: "测速", identifier: "speedTestButton")
            }
            VStack(spacing: 10) {
                Button { model.chooseAutomatic() } label: {
                    nodeRow(title: "自动选择", endpoint: model.automaticEndpoint, checked: model.displayAutomatic,
                        latencyID: "automaticLatency", speedID: "automaticSpeed")
                }.buttonStyle(.plain).disabled(model.selectionUnavailable).accessibilityIdentifier("automaticNode")
                    .accessibilityValue(t(model.displayAutomatic ? "已选择" : "未选择"))
                ForEach(Array(model.endpoints.enumerated()), id: \.element.id) { index, endpoint in
                    Button { model.chooseNode(endpoint) } label: {
                        nodeRow(title: model.nodeName(endpoint), endpoint: endpoint, checked: !model.displayAutomatic && model.displaySelected == endpoint,
                            latencyID: "endpointLatency\(index)", speedID: "endpointSpeed\(index)")
                    }.buttonStyle(.plain).disabled(model.selectionUnavailable).accessibilityIdentifier("endpoint\(index)")
                        .accessibilityValue(t(!model.displayAutomatic && model.displaySelected == endpoint ? "已选择" : "未选择"))
                }
            }
        }.padding(20).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }
    private func testButton(_ kind: NodeMeasurementKind, title: String, identifier: String) -> some View {
        Button(model.measurementKind == kind ? t("停止") : t(LocalizedText(title))) { model.testCachedNodes(kind) }
            .font(.caption.weight(.semibold)).buttonStyle(.bordered).controlSize(.small)
            .disabled(model.measurementKind != kind && !model.canTestCachedNodes)
            .accessibilityIdentifier(identifier)
    }
    private func nodeRow(title: String, endpoint: WARPEndpoint, checked: Bool, latencyID: String, speedID: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(checked ? orange : Color.secondary.opacity(0.4))
            Text(t(LocalizedText(title))).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 2)
            metric(value: model.latency(for: endpoint).map { $0 < 0 ? "-1" : "\($0) ms" },
                failed: (model.latency(for: endpoint) ?? 0) < 0, green: true,
                busy: model.testingNodeID == endpoint.id && model.measurementKind == .latency, identifier: latencyID, width: 70)
            metric(value: model.speed(for: endpoint).map { $0 < 0 ? "失败" : String(format: "%.1f Mbps", $0) },
                failed: (model.speed(for: endpoint) ?? 0) < 0, green: false,
                busy: model.testingNodeID == endpoint.id && model.measurementKind == .download, identifier: speedID, width: 82)
        }.padding(12).background(checked ? orange.opacity(0.08) : Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
    private func metric(value: String?, failed: Bool, green: Bool, busy: Bool, identifier: String, width: CGFloat) -> some View {
        Group {
            if busy { ProgressView().controlSize(.small).tint(orange) }
            else { Text(t(LocalizedText(value ?? "—"))).font(.caption.monospacedDigit()).foregroundStyle(failed ? Color.red : value == nil ? Color.secondary : green ? Color.green : Color.primary).lineLimit(1).minimumScaleFactor(0.7) }
        }.frame(width: width).accessibilityElement(children: .ignore).accessibilityLabel(busy ? t("测试中") : t(LocalizedText(value ?? "未测试")))
            .accessibilityValue(busy ? t("测试中") : t(LocalizedText(value ?? "未测试"))).accessibilityIdentifier(identifier)
    }
}
