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
                Text("从微信复制电表缴费页链接粘贴到这里，App 会解析 openId 作为查询身份。换微信后需更换链接（openId 随微信账号变化）。链接默认仅保存在本机；若开启下方「云端轮询」，查询链接与 openId、电表清单会同步到你自己配置的服务器，用于服务器云端定时轮询（频率可在下方自行设置）；查出来的告警是否推送到手机，由设置一级菜单「云端推送」里的电表通知开关控制。")
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
    @State private var pollTag: Int = 1          // 云端轮询间隔：1–12 小时
    @State private var runningNow = false         // 「立即轮询一次」请求中
    @State private var appearCount = 0           // 诊断：onAppear 触发次数

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
                Label("开启云端轮询", systemImage: "cloud.bolt.fill")
                    .font(.system(size: 14))
            }
            .disabled(busy || runningNow)

            pollIntervalBlock

            VStack(alignment: .leading, spacing: 10) {
                    Text("电表云端接入")
                        .font(.system(size: 12))
                        .foregroundColor(.themeText3)
                    Text("服务器地址")
                        .font(.system(size: 12))
                        .foregroundColor(.themeText3)
                    HStack(spacing: 8) {
                        TextField("http://114.132.93.85:8082", text: $endpointInput)
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
                            Label("本机已保存电表云端令牌", systemImage: "checkmark.shield.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.themeAccentDark)
                            Spacer()
                            Button("清除", role: .destructive) { clearToken() }
                                .font(.system(size: 12))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            TextField("首次使用填电表接入码（测试期 123456）", text: $codeInput)
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
                                Label("立即同步配置", systemImage: "arrow.clockwise")
                            }
                            Button {
                                Task { await runNow() }
                            } label: {
                                HStack(spacing: 5) {
                                    if runningNow { ProgressView().controlSize(.small) }
                                    Label("立即轮询一次", systemImage: "bolt.fill")
                                }
                            }
                            .disabled(runningNow)
                            Spacer()
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.themeAccentDark)
                    }
                }
                .padding(.vertical, 2)

            let diag = sync.tokenDiagnostic
            VStack(alignment: .leading, spacing: 3) {
                Text("【测试诊断·正式版移除】onAppear=\(appearCount)次 tokenSaved=\(tokenSaved ? "T" : "F")")
                Text("内存=\(diag.memory ? "有" : "无") 钥匙串=\(diag.keychain ? "有" : "无") 文件=\(diag.file ? "有" : "无")(exists=\(diag.fileExists)) 判定=\(diag.resolved ? "有令牌" : "无令牌")")
                Text("路径: \(diag.filePath)")
                    .lineLimit(2)
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(.red)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
            .cornerRadius(8)

            NavigationLink {
                CloudPushSettingsView()
            } label: {
                Label("通知开关与 Bark 推送通道", systemImage: "bell.badge.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
        } header: {
            Text("云端轮询（测试）")
        } footer: {
            Text("这个开关只决定服务器要不要按间隔替你查询电表（查询链接/openId、阈值、间隔与电表清单会自动同步；开启时进电表首页自动拉取云端快照，关闭后保持纯手动刷新）。查出来的告警要不要推送到手机，由「设置 → 云端推送 → 电表推送」开关控制（需先在下方接入电表云端，并在云端推送页绑定 Bark）。长期令牌只存本机（钥匙串优先、私有目录兜底），不上云、不进备份。")
        }
        .onAppear {
            appearCount += 1
            endpointInput = store.settings.cloudEndpoint
            tokenSaved = sync.hasToken
            let hours = store.settings.cloudPollMinutes / 60
            pollTag = (1...12).contains(hours) ? hours : 1
        }
    }

    // MARK: 云端轮询间隔（租户级，随 config 下发，服务器热生效）

    @ViewBuilder
    private var pollIntervalBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("服务器轮询间隔")
                .font(.system(size: 12))
                .foregroundColor(.themeText3)
            Picker("服务器轮询间隔", selection: $pollTag) {
                ForEach(1...12, id: \.self) { h in
                    Text("\(h) 小时").tag(h)
                }
            }
            .pickerStyle(.menu)
            .font(.system(size: 13))
            .onChange(of: pollTag) { _, tag in
                store.settings.cloudPollMinutes = tag * 60
                store.saveSettings()   // 防抖全量同步，pollIntervalSeconds 随 config 下发
            }

            Text("云端轮询开启并同步后，由服务器按此频率（1–12 小时）代你查询电表平台；未开启时选择先保存在本机。它与本页上方仅在 App 打开时生效的「定时自动刷新」是两套机制。保存并同步后服务器下一轮即按新间隔调度，无需重启。")
                .font(.system(size: 10))
                .foregroundColor(.themeText3)
        }
        .padding(9)
        .background(Color.themeBorder.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 9))
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
            tip = "请先在下方「电表云端接入」填写接入码并验证成功，再开启云端轮询"
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
        if sync.hasToken {
            // 已有令牌绝不重复接入，从源头杜绝重复 enroll 产生重复租户
            tokenSaved = true
            return true
        }
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
    private func runNow() async {
        runningNow = true
        defer { runningNow = false }
        let result = await sync.runNow(store: store)
        store.cloudStatusText = result
    }
}

// MARK: - 统一推送通道设置页（notify-hub：账号建档 / 一人多设备 Bark / 模块开关 / 最近投递）

struct NotifyHubSettingsView: View {
    @ObservedObject private var hub = NotifyHub.shared

    @State private var codeInput = ""
    @State private var usernameInput = ""
    @State private var barkInput = ""
    @State private var deviceNameInput = "我的 iPhone"
    @State private var addBarkInput = ""
    @State private var addDeviceNameInput = "我的 iPhone"
    @State private var showAddDevice = false
    @State private var formTip: String?
    @State private var testTip: String?
    @State private var confirmLogout = false

    private var canBind: Bool {
        !barkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !codeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Label("通道服务器", systemImage: "server.rack")
                        .font(.system(size: 13))
                    Spacer()
                    Text(hub.endpoint)
                        .font(.system(size: 11))
                        .foregroundColor(.themeText3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 175, alignment: .trailing)
                }
                HStack {
                    Label("投递隔离", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 13))
                    Spacer()
                    Text("仅发本账号设备")
                        .font(.system(size: 12))
                        .foregroundColor(.themeAccentDark)
                }
            } footer: {
                Text("推送通道与电表云端轮询共用同一台服务器，地址可在「电表监控设置 → 云端轮询 → 电表云端接入」修改。通道按账号隔离：服务器只把事件发到该账号绑定的手机，将来多人使用也不会互推；各业务模块的通知开关在「设置 → 云端推送」首页。")
            }

            if !hub.isBound {
                bindSection
            } else {
                accountSection
                switchSection
                devicesSection
                testSection
                eventsSection
            }
        }
        .navigationTitle("云端推送通道")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            codeInput = hub.cachedEnrollCode()
            if usernameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let cosName = CloudUser.username.trimmingCharacters(in: .whitespacesAndNewlines)
                usernameInput = cosName.isEmpty ? hub.username : cosName
            }
            if hub.isBound { Task { await hub.refreshMe() } }
        }
        .alert("退出本机通道登录？", isPresented: $confirmLogout) {
            Button("退出", role: .destructive) { hub.logout() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅清除本机登录令牌与缓存，服务器上的账号和设备绑定仍保留。")
        }
    }

    // MARK: 首次绑定

    private var bindSection: some View {
        Section {
            TextField("用户名（如：涛，建议与房账用户名一致）", text: $usernameInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14))
            TextField("粘贴 Bark 首页推送链接或 Key", text: $barkInput, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 13))
                .padding(8)
                .background(Color.themeBorder.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            TextField("接入码（测试期 123456）", text: $codeInput)
                .textInputAutocapitalization(.never)
                .keyboardType(.numberPad)
                .font(.system(size: 14))
            TextField("本机名称（如：涛的 iPhone）", text: $deviceNameInput)
                .font(.system(size: 14))
            Button {
                Task { await bind() }
            } label: {
                HStack(spacing: 8) {
                    if hub.busy { ProgressView().controlSize(.small) }
                    Text("绑定账号并同步本机 Bark")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(canBind ? Color.themeAccentDark : Color.themeBorder)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(hub.busy || !canBind)
            if let formTip, !formTip.isEmpty {
                Text(formTip).font(.system(size: 12)).foregroundColor(.red)
            }
        } header: {
            Text("首次绑定")
        } footer: {
            Text("先在 iPhone 的 Bark App 首页复制推送链接（形如 http://服务器地址/一串字符），整段粘贴到上面，App 会自动识别 Key。因 iOS 沙盒限制，公寓管家无法直接读取 Bark 的 Key，只需粘贴这一次。用户名用于在服务器建立独立推送档案，电表等业务事件只投到该账号名下设备；接入码测试期固定 123456，正式版可改为动态码。")
        }
    }

    @MainActor
    private func bind() async {
        let err = await hub.register(code: codeInput, username: usernameInput,
                                     barkText: barkInput, deviceName: deviceNameInput)
        if err == nil {
            barkInput = ""
            formTip = nil
            switch hub.lastBindMeterSync {
            case .some(true):
                testTip = "绑定成功，电表云端绑定已自动同步；建议立即发送一条通道测试通知"
            case .some(false):
                testTip = "推送账号已绑定；电表配置稍后进入电表页会自动补同步，也可在电表设置手动同步一次"
            case .none:
                testTip = "绑定成功，建议立即发送一条通道测试通知"
            }
        } else {
            formTip = err
        }
    }

    // MARK: 账号

    private var accountSection: some View {
        Section {
            HStack {
                Label("当前账号", systemImage: "person.fill")
                    .font(.system(size: 14))
                Spacer()
                Text(hub.username.isEmpty ? "已绑定" : hub.username)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.themeAccentDark)
            }
            HStack {
                Label("绑定设备", systemImage: "iphone")
                    .font(.system(size: 14))
                Spacer()
                Text("\(hub.devices.count) 台")
                    .font(.system(size: 13))
                    .foregroundColor(.themeText3)
            }
            Button(role: .destructive) {
                confirmLogout = true
            } label: {
                Label("退出本机登录", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 13))
            }
        } header: {
            Text("我的推送账号")
        }
    }

    // MARK: 开关

    private var switchSection: some View {
        Section {
            Toggle("启用云端推送通道（总开关）", isOn: Binding(
                get: { hub.channelEnabled },
                set: { on in Task { await hub.updatePrefs(channelEnabled: on) } }
            ))
        } header: {
            Text("通道总开关")
        } footer: {
            Text("关闭后服务器不再向你的设备推送任何模块通知，也不会回退到服务器全局 Key。电表等业务模块的独立通知开关在「设置 → 云端推送」首页；后续到期提醒、收租提醒等也会加到那里。")
        }
    }

    // MARK: 设备

    private var devicesSection: some View {
        Section {
            if hub.devices.isEmpty {
                Text("暂无设备，请点下方添加本机 Bark")
                    .font(.system(size: 12))
                    .foregroundColor(.themeText3)
            }
            ForEach(hub.devices) { device in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(device.displayName)
                            .font(.system(size: 14, weight: .medium))
                        Spacer()
                        Text(device.keyMasked ?? "")
                            .font(.system(size: 11))
                            .foregroundColor(.themeText3)
                    }
                    if let err = device.lastError, !err.isEmpty {
                        Label("最近投递异常：\(err)", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .lineLimit(2)
                    } else if let ok = device.lastOkAt, ok > 0 {
                        Text("最近成功：\(Date(timeIntervalSince1970: ok).formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10))
                            .foregroundColor(.themeText3)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        Task { await hub.removeDevice(device) }
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }

            if showAddDevice {
                VStack(spacing: 8) {
                    TextField("新设备 Bark 链接或 Key", text: $addBarkInput, axis: .vertical)
                        .lineLimit(1...3)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 13))
                        .padding(8)
                        .background(Color.themeBorder.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    TextField("设备名称（如：备用 iPhone）", text: $addDeviceNameInput)
                        .font(.system(size: 13))
                    Button {
                        Task { await addDevice() }
                    } label: {
                        HStack(spacing: 8) {
                            if hub.busy { ProgressView().controlSize(.small) }
                            Text("添加这台设备").font(.system(size: 13, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(addBarkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                   ? Color.themeBorder : Color.themeAccentDark)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .disabled(hub.busy || addBarkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button {
                    withAnimation { showAddDevice = true }
                } label: {
                    Label("添加手机 / 设备", systemImage: "plus.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
            }

            if let t = hub.statusText, !t.isEmpty {
                Text(t).font(.system(size: 11)).foregroundColor(.red)
            }
        } header: {
            Text("我的设备")
        } footer: {
            Text("同一账号最多绑 10 台手机，事件会发到每一台；在某台设备行左滑可删除。更换手机后在此添加新设备。")
        }
    }

    @MainActor
    private func addDevice() async {
        let code = hub.cachedEnrollCode()
        let err = await hub.register(code: code, username: hub.username,
                                     barkText: addBarkInput, deviceName: addDeviceNameInput)
        if err == nil {
            addBarkInput = ""
            showAddDevice = false
        }
    }

    // MARK: 测试

    private var testSection: some View {
        Section {
            Button {
                Task { testTip = await hub.sendTest() }
            } label: {
                HStack {
                    Label("发送通道测试通知", systemImage: "bell.badge.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if hub.busy { ProgressView().controlSize(.small) }
                }
            }
            .disabled(hub.busy)
            if let testTip, !testTip.isEmpty {
                Text(testTip)
                    .font(.system(size: 12))
                    .foregroundColor(testTip.contains("已投递") ? .themeAccentDark : .red)
            }
            if let last = hub.lastSyncAt {
                Text("最近状态刷新：\(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10))
                    .foregroundColor(.themeText3)
            }
        } footer: {
            Text("测试事件只发送到你账号名下设备，用于验证整条链路：App → 服务器通知中心 → 自建 Bark → iPhone。")
        }
    }

    // MARK: 最近投递

    private var eventsSection: some View {
        Section {
            if hub.events.isEmpty {
                Text("暂无投递记录")
                    .font(.system(size: 12))
                    .foregroundColor(.themeText3)
            }
            ForEach(Array(hub.events.prefix(20))) { event in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(event.title ?? "通知")
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Text(statusLabel(event.status))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(statusColor(event.status))
                    }
                    if let body = event.body, !body.isEmpty {
                        Text(body)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Text("\(event.at ?? "") · \(moduleLabel(event.module)) · 成功 \(event.sent ?? 0)/\(event.total ?? 0)")
                        .font(.system(size: 10))
                        .foregroundColor(.themeText3)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("最近投递")
        }
    }

    private func moduleLabel(_ module: String?) -> String {
        switch module {
        case "meter": return "电表"
        case "system": return "通道"
        default: return module ?? "通知"
        }
    }

    private func statusLabel(_ status: String?) -> String {
        switch status {
        case "sent": return "已送达"
        case "partial": return "部分送达"
        case "failed": return "发送失败"
        case "no_device": return "无设备"
        case "user_disabled": return "总开关关"
        case "module_disabled": return "模块关闭"
        case "pending": return "发送中"
        default: return status ?? ""
        }
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "sent": return .themeAccentDark
        case "partial": return .orange
        case "failed": return .red
        default: return .themeText3
        }
    }
}

// MARK: - 一级菜单「云端推送」（b206）
// 统一通知设置首页：本页只放“收不收业务通知”的模块开关（当前仅电表推送，后续扩展到期/收租/待办）；
// Bark 绑定、多设备、通道总开关、通道测试与最近投递记录收进二级页 NotifyHubSettingsView。
// 注意与「电表监控设置 → 云端轮询」的分工：轮询开关决定服务器查不查电表，本页开关决定查出来的告警推不推到手机。

struct CloudPushSettingsView: View {
    @ObservedObject private var hub = NotifyHub.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { hub.meterModuleEnabled },
                    set: { on in Task { await hub.updatePrefs(meterEnabled: on) } }
                )) {
                    Label("电表推送", systemImage: "bolt.fill")
                        .font(.system(size: 14))
                }
                .disabled(!hub.isBound || !hub.channelEnabled)
            } header: {
                Text("通知开关")
            } footer: {
                Text(meterFooter)
            }

            Section {
                HStack {
                    Label("推送通道", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 13))
                    Spacer()
                    if hub.isBound {
                        Text(channelSummary)
                            .font(.system(size: 11))
                            .foregroundColor(.themeAccentDark)
                            .lineLimit(1)
                    } else {
                        Text("未绑定")
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }
                }
                NavigationLink {
                    NotifyHubSettingsView()
                } label: {
                    Label(hub.isBound ? "通道账号、设备、测试与投递记录" : "绑定 Bark 推送通道",
                          systemImage: "bell.badge.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
            } header: {
                Text("推送通道")
            } footer: {
                Text("通道按账号隔离，事件只投到本账号绑定的手机；首次使用先进入上方绑定 Bark 首页推送链接。电表“要不要服务器轮询查询”在「电表监控设置 → 云端轮询」里控制，与本页“要不要接收通知”相互独立。后续到期、收租、待办等提醒会在本页增加独立开关。")
            }

            Section {
                NavigationLink {
                    MeterTemplateEditView(eventKey: "low", navTitle: "低电量文案")
                } label: {
                    Label("低电量通知文案", systemImage: "battery.25")
                        .font(.system(size: 13))
                }
                NavigationLink {
                    MeterTemplateEditView(eventKey: "off", navTitle: "拉闸文案")
                } label: {
                    Label("拉闸通知文案", systemImage: "power")
                        .font(.system(size: 13))
                }
            } header: {
                Text("自定义文案")
            } footer: {
                Text("自定义主标题、副标题、正文与时间显示，支持占位符，可先预览真实推送；留空字段自动回退默认文案。需先绑定推送通道。")
            }
            .disabled(!hub.isBound)
        }
        .navigationTitle("云端推送")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if hub.isBound { Task { await hub.refreshMe() } }
        }
    }

    private var channelSummary: String {
        let name = hub.username.isEmpty ? "已绑定" : hub.username
        let state = hub.channelEnabled ? "总开关开" : "总开关关"
        return "\(name) · \(hub.devices.count) 台设备 · \(state)"
    }

    private var meterFooter: String {
        if !hub.isBound {
            return "请先在下方「推送通道」绑定 Bark，绑定成功后才能接收电表告警。"
        }
        if !hub.channelEnabled {
            return "推送通道总开关已关闭；请先到下方「通道账号、设备、测试与投递记录」打开总开关，再设置电表推送。"
        }
        return "控制服务器云端轮询产生的低电量、拉闸、值守告警是否推送到本账号设备。关闭后服务器仍会按「电表监控设置 → 云端轮询」的开关与间隔查询并更新云端快照，但不发通知；重新打开即恢复推送。"
    }
}

struct MeterTemplateEditView: View {
    let eventKey: String
    let navTitle: String

    @ObservedObject private var hub = NotifyHub.shared
    @State private var title = ""
    @State private var subtitle = ""
    @State private var bodyText = ""
    @State private var showTime = true
    @State private var loaded = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                TextField("主标题", text: $title)
                TextField("副标题（可留空）", text: $subtitle)
            } header: {
                Text("标题")
            }

            Section {
                TextEditor(text: $bodyText)
                    .frame(minHeight: 110)
                    .font(.system(size: 13))
            } header: {
                Text("正文")
            }

            Section {
                Toggle("通知中显示时间", isOn: $showTime)
            } header: {
                Text("时间")
            } footer: {
                Text("关闭后正文中的 {time} 自动隐藏，并清理多余空格与标点。")
            }

            Section {
                Text("可用占位符：{label} 房号、{uid} 户号、{remain} 剩余电量、{threshold} 阈值、{time} 时间。留空字段自动回退默认文案。")
                    .font(.system(size: 11))
                    .foregroundColor(.themeText3)
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    Label("保存文案", systemImage: "square.and.arrow.down")
                }
                .disabled(busy || !hub.isBound)

                Button {
                    Task {
                        busy = true
                        message = await hub.previewMeterTemplate(eventKey)
                        busy = false
                    }
                } label: {
                    Label("预览（真实推一条）", systemImage: "paperplane.fill")
                }
                .disabled(busy || !hub.isBound)

                if let message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(.themeText3)
                }
            }
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            Task { await load() }
        }
    }

    private func load() async {
        busy = true
        do {
            let set = try await hub.loadMeterTemplates()
            if let tpl = eventKey == "off" ? set.off : set.low {
                title = tpl.title
                subtitle = tpl.subtitle
                bodyText = tpl.body
                showTime = tpl.showTime
            }
            message = nil
        } catch {
            message = "加载失败：\(error.localizedDescription)"
        }
        busy = false
    }

    private func save() async {
        busy = true
        let tpl = MeterTemplate(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            subtitle: subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
            body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
            showTime: showTime)
        do {
            _ = try await hub.saveMeterTemplate(eventKey, tpl: tpl)
            message = "已保存并在后续通知生效"
        } catch {
            message = "保存失败：\(error.localizedDescription)"
        }
        busy = false
    }
}
