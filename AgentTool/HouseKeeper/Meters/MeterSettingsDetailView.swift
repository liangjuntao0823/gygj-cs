//
//  MeterSettingsDetailView.swift
//  公寓管家 · 电表监控设置
//  查询链接自定义更换（换微信换链接）/ 数据源方案 / 低电量阈值 / 定时刷新 / 提醒
//

import SwiftUI

struct MeterSettingsDetailView: View {
    @EnvironmentObject private var store: MeterStore
    @Environment(\.dismiss) private var dismiss

    @State private var linkInput = ""
    @State private var linkTip: String?
    @State private var showLinkSaved = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("官方电表查询链接")
                        .font(.system(size: 13))
                        .foregroundColor(.themeText3)
                    TextField("粘贴微信里的查询链接", text: $linkInput, axis: .vertical)
                        .lineLimit(3...5)
                        .font(.system(size: 14))
                        .padding(10)
                        .background(Color.themeBorder.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        saveLink()
                    } label: {
                        Text("保存链接")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Color.themeAccentDark)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if !store.settings.openId.isEmpty {
                        Label("当前微信身份：\(maskedOpenId)", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.themeAccentDark)
                    }
                    if let tip = linkTip {
                        Text(tip)
                            .font(.system(size: 12))
                            .foregroundColor(tip.contains("已保存") ? .themeAccentDark : .red)
                    }
                }
            } header: {
                Text("查询链接")
            } footer: {
                Text("从微信复制电表缴费页链接粘贴到这里，App 会解析 openId 作为查询身份。换微信后需更换链接（openId 随微信账号变化）。链接默认仅保存在本机；若开启下方「云端值守」，查询链接与 openId、电表清单会同步到你自己配置的服务器，用于 30 分钟云端轮询与推送。")
            }

            Section {
                Picker("数据源方案", selection: Binding(
                    get: { store.settings.provider },
                    set: { store.settings.provider = $0; store.saveSettings() }
                )) {
                    ForEach(MeterProviderKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("数据源")
            } footer: {
                Text("直连接口：无需打开网页，串行查询更快更稳（默认）。网页抓取：通过隐藏网页读取数据，作为官方改版时的兜底。")
            }

            Section {
                HStack {
                    Text("低电量阈值")
                    Spacer()
                    HStack(spacing: 2) {
                        TextField("30", value: Binding(
                            get: { store.settings.lowThreshold },
                            set: { store.settings.lowThreshold = max(1, min(999, $0)); store.saveSettings() }
                        ), format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                        Text("度")
                            .font(.system(size: 13))
                            .foregroundColor(.themeText3)
                    }
                }
                Toggle("低电量提醒", isOn: Binding(
                    get: { store.settings.lowAlertEnabled },
                    set: { store.settings.lowAlertEnabled = $0; store.saveSettings() }
                ))
            } header: {
                Text("预警")
            } footer: {
                Text("刷新后剩余电量低于阈值的房号在列表标红；低电量提醒每天最多推送一次，避免骚扰。拉闸房号同样标红。")
            }

            Section {
                Toggle("定时自动刷新", isOn: Binding(
                    get: { store.settings.autoRefreshEnabled },
                    set: { store.settings.autoRefreshEnabled = $0; store.saveSettings() }
                ))
                if store.settings.autoRefreshEnabled {
                    Picker("刷新间隔", selection: Binding(
                        get: { store.settings.autoRefreshMinutes },
                        set: { store.settings.autoRefreshMinutes = $0; store.saveSettings() }
                    )) {
                        Text("10 分钟").tag(10)
                        Text("30 分钟").tag(30)
                        Text("1 小时").tag(60)
                        Text("2 小时").tag(120)
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("自动刷新")
            } footer: {
                Text("开启后只在 App 运行期间按间隔自动刷新全部电表；关闭后只有手动点「刷新」才更新（进入电表板块不会自动刷新）。")
            }

            MeterCloudWatchSection()
        }
        .navigationTitle("电表监控设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            linkInput = store.settings.queryLink
        }
    }

    private var maskedOpenId: String {
        let id = store.settings.openId
        guard id.count > 8 else { return id }
        return String(id.prefix(4)) + "****" + String(id.suffix(4))
    }

    private func saveLink() {
        let trimmed = linkInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            linkTip = "请先粘贴查询链接"
            return
        }
        guard let openId = store.parseOpenId(from: trimmed), !openId.isEmpty else {
            linkTip = "链接里没有找到 openId，请粘贴完整的电表缴费页链接（形如 http://wy.mlh-china.com/electricmeter/?openId=…）"
            return
        }
        store.applyQueryLink(trimmed)
        store.resetSession()
        linkTip = "已保存，当前微信身份 openId 已更新"
    }
}

// MARK: - 云端值守区（#235：仅在现有电表设置页底部新增，不改动上方原有项目）

private struct MeterCloudWatchSection: View {
    @EnvironmentObject private var store: MeterStore

    @State private var endpointInput = ""
    @State private var codeInput = ""
    @State private var tip: String?
    @State private var busy = false
    @State private var tokenSaved = false

    @MainActor
    private var sync: MeterCloudSync { MeterCloudSync.shared }
    private var codeEmpty: Bool {
        codeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var tipPositive: Bool {
        guard let t = tip else { return false }
        return t.contains("成功") || t.contains("已发送") || t.contains("已保存") || t.contains("已连接")
    }

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { store.settings.cloudWatchEnabled },
                set: { onToggle($0) }
            )) {
                Label("开启云端值守", systemImage: "cloud.bolt.fill")
                    .font(.system(size: 14))
            }
            .disabled(busy)

            if store.settings.cloudWatchEnabled || tokenSaved || busy {
                VStack(alignment: .leading, spacing: 10) {
                    Text("服务器地址")
                        .font(.system(size: 12))
                        .foregroundColor(.themeText3)
                    HStack(spacing: 8) {
                        TextField(MeterCloudConfig.defaultEndpoint, text: $endpointInput)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Button("保存") { saveEndpointOnly() }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.themeAccentDark)
                    }
                    .padding(9)
                    .background(Color.themeBorder.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                    if tokenSaved {
                        HStack(spacing: 6) {
                            Label("本机已保存云端令牌", systemImage: "checkmark.shield.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.themeAccentDark)
                            Spacer()
                            Button("清除", role: .destructive) { clearToken() }
                                .font(.system(size: 12))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            TextField("首次使用填接入码（向服务器部署者获取）", text: $codeInput)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(size: 13))
                                .padding(9)
                                .background(Color.themeBorder.opacity(0.3))
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                            Button {
                                Task { await enrollOnly() }
                            } label: {
                                HStack(spacing: 8) {
                                    if busy { ProgressView().controlSize(.small) }
                                    Text("验证并保存接入码")
                                        .font(.system(size: 13, weight: .bold))
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(codeEmpty ? Color.themeBorder : Color.themeAccentDark)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                            }
                            .disabled(busy || codeEmpty)
                        }
                    }

                    if !store.cloudStatusText.isEmpty {
                        Label(store.cloudStatusText, systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                            .foregroundColor(.themeText3)
                            .lineLimit(3)
                    }
                    if let tip, !tip.isEmpty {
                        Text(tip)
                            .font(.system(size: 12))
                            .foregroundColor(tipPositive ? .themeAccentDark : .red)
                    }

                    if store.settings.cloudWatchEnabled && tokenSaved {
                        HStack(spacing: 18) {
                            Button {
                                Task { _ = await sync.pushConfig(store: store, enabled: true) }
                            } label: {
                                Label("立即同步", systemImage: "arrow.clockwise")
                            }
                            Button {
                                Task { await runTestPush() }
                            } label: {
                                Label("测试推送", systemImage: "bell.badge")
                            }
                            Spacer()
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.themeAccentDark)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("云端值守（测试）")
        } footer: {
            Text("开启后，查询链接/openId、低电量阈值、提醒开关与电表清单会自动同步到你的服务器，由服务器每 30 分钟轮询一次，达到阈值或拉闸时经自建 Bark 推送；之后在本机改阈值、新增/删除电表也会自动同步。开关开启时，每次进入电表首页会自动获取云端最近一轮数据；关闭后完全保持手动刷新。长期令牌只保存在本机钥匙串。")
        }
        .onAppear {
            endpointInput = store.settings.cloudEndpoint
            tokenSaved = sync.hasToken
        }
    }

    // MARK: 动作

    @MainActor
    private func onToggle(_ on: Bool) {
        if on {
            Task { await turnOn() }
        } else {
            store.settings.cloudWatchEnabled = false
            store.saveSettings() // 钩子防抖补发 enabled=false，服务器停止该租户轮询
        }
    }

    @MainActor
    private func turnOn() async {
        busy = true
        defer { busy = false }
        tip = nil
        saveEndpointOnly(showTip: false)

        if !sync.hasToken {
            let code = codeInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty {
                let ok = await performEnroll()
                if !ok { return }
            }
        }
        guard sync.hasToken else {
            tip = "请先填写接入码并验证成功，再开启云端值守"
            return
        }
        UserDefaults.standard.set(true, forKey: MeterCloudConfig.wasEnabledKey)
        store.settings.cloudWatchEnabled = true
        store.saveSettings() // 落盘开关并触发防抖全量同步
        tokenSaved = true
        _ = await sync.pushConfig(store: store, enabled: true) // 立即同步一次，不必等防抖
    }

    @discardableResult
    @MainActor
    private func performEnroll() async -> Bool {
        do {
            _ = try await sync.enroll(store: store, code: codeInput)
            codeInput = ""
            tokenSaved = true
            tip = "接入码验证成功，已连接云端"
            return true
        } catch {
            tip = error.localizedDescription
            return false
        }
    }

    @MainActor
    private func enrollOnly() async {
        busy = true
        defer { busy = false }
        saveEndpointOnly(showTip: false)
        if await performEnroll(), store.settings.cloudWatchEnabled {
            _ = await sync.pushConfig(store: store, enabled: true)
        }
    }

    @MainActor
    private func saveEndpointOnly(showTip: Bool = true) {
        let v = endpointInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        let old = store.settings.cloudEndpointRaw ?? ""
        guard v != old else { return }
        store.settings.cloudEndpoint = v
        store.saveSettings() // 开关未开且未曾开启时，同步钩子不会发网络请求
        if showTip { tip = "服务器地址已保存" }
    }

    @MainActor
    private func clearToken() {
        sync.clearToken()
        tokenSaved = false
        tip = "本机令牌已清除（服务器上已同步的配置仍保留）"
    }

    @MainActor
    private func runTestPush() async {
        busy = true
        defer { busy = false }
        tip = await sync.sendTestPush(store: store)
    }
}
