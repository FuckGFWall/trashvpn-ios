import SwiftUI

struct ContentView: View {
    @ObservedObject var model: VPNModel
    @State private var showSettings = false
    @State private var nodesExpanded = false
    private let orange = Color(red: 1, green: 0.38, blue: 0.08)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("TrashVPN").font(.system(size: 30, weight: .bold, design: .rounded))
                            Text("让连接，自由一点。").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(model.selected.kind.label).font(.caption.weight(.bold)).tracking(1.5)
                            .padding(.horizontal, 13).padding(.vertical, 8)
                            .background(orange.opacity(0.12), in: Capsule()).foregroundStyle(orange)
                    }
                    VStack(spacing: 22) {
                        HStack(spacing: 7) {
                            Circle().fill(model.connected ? .green : orange).frame(width: 7, height: 7)
                            Text(model.statusLabel).font(.subheadline.weight(.semibold)).accessibilityIdentifier("vpnStatus")
                        }
                        Button {
                            if model.active { model.disconnect() } else { Task { await model.connect() } }
                        } label: {
                            ZStack {
                                Circle().stroke(orange.opacity(0.08), lineWidth: 18).frame(width: 164, height: 164)
                                Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0.58, blue: 0.18), orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 140, height: 140).shadow(color: orange.opacity(0.23), radius: 18, y: 9)
                                Image(systemName: "power").font(.system(size: 46, weight: .light)).foregroundStyle(.white)
                            }.padding(.vertical, 6)
                        }.buttonStyle(.plain).disabled(!model.active && (model.scanning || !model.cacheIsFresh))
                            .accessibilityLabel(model.active ? "断开连接" : "连接 WARP").accessibilityIdentifier("connectButton")
                        preparation
                        HStack {
                            Label(model.selected.kind.detail, systemImage: "lock.shield")
                            Spacer()
                            Text(model.addressFamily.label)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(24).frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28))

                    VStack(alignment: .leading, spacing: 14) {
                        DisclosureGroup(isExpanded: $nodesExpanded) {
                            LazyVStack(spacing: 10) {
                                Button { model.chooseAutomatic() } label: {
                                    nodeRow(title: "自动选择", subtitle: "稳定和速度达标后，选择最低延迟", detail: "最低延迟", checked: model.automaticSelection)
                                }.buttonStyle(.plain).disabled(model.active || model.scanning).accessibilityIdentifier("automaticNode").accessibilityValue(model.automaticSelection ? "已选择" : "未选择")
                                ForEach(Array(model.endpoints.enumerated()), id: \.element.id) { index, endpoint in
                                    Button { model.chooseNode(endpoint) } label: {
                                        nodeRow(title: "\(endpoint.kind.label) \(String(format: "%02d", index + 1))", subtitle: endpoint.address,
                                            detail: model.results[endpoint.id]?.label ?? "待测试", checked: !model.automaticSelection && model.selected == endpoint,
                                            resultIdentifier: "endpointResult\(index)")
                                    }.buttonStyle(.plain).disabled(model.active || model.scanning).accessibilityIdentifier("endpoint\(index)").accessibilityValue(!model.automaticSelection && model.selected == endpoint ? "已选择" : "未选择")
                                }
                            }.padding(.top, 14)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("连接节点").font(.headline).foregroundStyle(.primary)
                                HStack(spacing: 6) {
                                    Image(systemName: model.automaticSelection ? "wand.and.stars" : "location.circle")
                                    Text(model.automaticSelection ? "自动选择 · 最低延迟" : "手动选择")
                                    if let result = model.results[model.selected.id], let median = result.median {
                                        Text("\(median) ms").monospacedDigit()
                                    }
                                }.font(.subheadline).foregroundStyle(orange)
                                if model.cacheIsFresh || model.active {
                                    Text(model.selected.address).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                                }
                            }.padding(.vertical, 3)
                        }.accessibilityIdentifier("nodeDisclosure")
                        Text(model.cacheStatus).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("cacheStatus")
                        if nodesExpanded && model.active {
                            Text("断开连接后可切换节点。").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(20).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))

                    if model.connected {
                        VStack(spacing: 12) {
                            Button { Task { await model.verify() } } label: {
                                HStack {
                                    Image(systemName: "checkmark.shield")
                                    Text(model.verifying ? "正在验证出口…" : "验证 WARP 出口").fontWeight(.semibold)
                                }.frame(maxWidth: .infinity).padding(12)
                            }.buttonStyle(.bordered).disabled(model.verifying).accessibilityIdentifier("verifyButton")
                            if !model.trace.isEmpty {
                                Text(model.trace).font(.footnote.monospaced()).multilineTextAlignment(.center)
                                    .foregroundStyle(model.trace.contains("已验证") ? .green : .secondary).accessibilityIdentifier("verificationResult")
                            }
                        }
                    }
                    Text("优选不会开启 VPN。退到后台会暂停优选，连接后可在后台持续使用。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 12)
                }.padding(22)
            }.background(Color(.systemGroupedBackground))
                .toolbar { ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("设置").accessibilityIdentifier("settingsButton")
                } }
                .sheet(isPresented: $showSettings) { SettingsView(model: model) }
                .onChange(of: model.selectionKey) { _, _ in nodesExpanded = false }
                .alert("连接提示", isPresented: Binding(get: { model.errorMessage != nil && !showSettings }, set: { if !$0 { model.errorMessage = nil } })) {
                    Button("好") { model.errorMessage = nil }
                } message: { Text(model.errorMessage ?? "") }
        }
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(model.progress.title).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("progressStage")
                Button(model.scanning ? "暂停" : "重新优选") {
                    if model.scanning { model.stopScan() } else { model.scan() }
                }.font(.caption.weight(.semibold)).disabled(model.active).accessibilityIdentifier("scanButton")
            }
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.13)).frame(height: 6)
                        Capsule().fill(orange).frame(width: geometry.size.width * min(1, max(0, model.progress.fraction)), height: 6)
                        Circle().fill(model.progress.fraction >= 0.5 ? orange : Color(.systemGray4))
                            .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 3))
                            .frame(width: 14, height: 14).offset(x: geometry.size.width / 2 - 7)
                    }.frame(height: 14).animation(.easeOut(duration: 0.2), value: model.progress.fraction)
                }.frame(height: 14)
                HStack {
                    Text("检查"); Spacer(); Text("注册").foregroundStyle(model.progress.fraction >= 0.5 ? orange : Color.secondary); Spacer(); Text("就绪")
                }.font(.caption2).foregroundStyle(.secondary)
            }.accessibilityElement(children: .combine).accessibilityIdentifier("preparationProgress")
                .accessibilityValue("\(Int(model.progress.fraction * 100))%")
            Text(model.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("messageText").frame(minHeight: 32, alignment: .topLeading)
        }
    }

    private func nodeRow(title: String, subtitle: String, detail: String, checked: Bool, resultIdentifier: String = "automaticResult") -> some View {
        HStack(spacing: 11) {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(checked ? orange : Color.secondary.opacity(0.4))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
            }
            Spacer(minLength: 3)
            Text(detail).font(.caption.monospacedDigit()).lineLimit(2).minimumScaleFactor(0.8).foregroundStyle(.secondary).accessibilityIdentifier(resultIdentifier)
        }.padding(13).background(checked ? orange.opacity(0.08) : Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
