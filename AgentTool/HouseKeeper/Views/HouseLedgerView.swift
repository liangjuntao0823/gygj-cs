import SwiftUI

// MARK: - v2.45 单套房账本视图（带搜索；全部历史操作 + 操作人）

struct HouseLedgerView: View {
    let roomKey: String
    let displayRoomNo: String

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var events: [HouseLedgerEvent] = []
    @State private var isSyncing = false
    @State private var syncHint: String?

    private var filtered: [HouseLedgerEvent] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return events }
        return events.filter { event in
            if event.action.localizedCaseInsensitiveContains(q)
                || event.detail.localizedCaseInsensitiveContains(q)
                || event.operatorName.localizedCaseInsensitiveContains(q) {
                return true
            }
            return event.fieldChanges.contains { change in
                change.field.localizedCaseInsensitiveContains(q)
                    || change.oldValue.localizedCaseInsensitiveContains(q)
                    || change.newValue.localizedCaseInsensitiveContains(q)
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                if let syncHint {
                    Text(syncHint)
                        .font(.footnote)
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.orange.opacity(0.10))
                }
                if filtered.isEmpty {
                    emptyState
                } else {
                    eventList
                }
            }
            .background(AppTheme.background)
            .navigationTitle("\(displayRoomNo) 账本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        if isSyncing { ProgressView() } else { Text("刷新") }
                    }
                    .disabled(isSyncing)
                }
            }
            .onAppear { reload() }
            .task { await refresh() }
        }
    }

    // MARK: 搜索框

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("搜索动作 / 操作人 / 明细", text: $searchText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: 列表

    private var eventList: some View {
        List {
            Section {
                ForEach(filtered) { event in
                    HouseLedgerRow(event: event)
                        .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                }
            } header: {
                Text("共 \(events.count) 条记录" + (searchText.isEmpty ? "" : "，匹配 \(filtered.count) 条"))
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(searchText.isEmpty ? "暂无账本记录" : "没有匹配的记录")
                .font(.subheadline)
                .foregroundColor(.secondary)
            if !searchText.isEmpty {
                Button("清空搜索") { searchText = "" }
                    .font(.footnote)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 数据

    private func reload() {
        events = HouseLedgerStore.events(roomKey: roomKey)
    }

    private func refresh() async {
        guard let config = CosConfig.load(), config.isValid else {
            syncHint = "未配置云存储，只显示本机记录"
            return
        }
        isSyncing = true
        syncHint = nil
        do {
            try await HouseLedgerStore.pull(roomKey: roomKey, config: config)
            reload()
        } catch {
            syncHint = "云端刷新失败：\(error.localizedDescription)"
        }
        isSyncing = false
    }
}

// MARK: 单条事件

private struct HouseLedgerRow: View {
    let event: HouseLedgerEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "person.circle.fill")
                    .font(.caption)
                    .foregroundColor(AppTheme.primary)
                Text(event.operatorName)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
                if event.migrated {
                    Text("历史")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(Capsule())
                }
                Spacer()
                Text(HouseLedgerFormat.date(event.date))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text(event.action)
                .font(.subheadline.weight(.medium))
            if !event.detail.isEmpty {
                Text(event.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !event.fieldChanges.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(event.fieldChanges, id: \.self) { change in
                        HStack(alignment: .top, spacing: 5) {
                            Text(change.field)
                                .font(.caption2.weight(.medium))
                                .foregroundColor(.secondary)
                            Text(display(change.oldValue))
                                .font(.caption2)
                                .foregroundColor(.red)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                            Text(display(change.newValue))
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func display(_ value: String) -> String { value.isEmpty ? "（空）" : value }
}
