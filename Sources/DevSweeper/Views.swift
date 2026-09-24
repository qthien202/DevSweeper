import AppKit
import SwiftUI

// MARK: - App

@main
struct DevSweeperApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Dev Sweeper", id: "main") {
            MainView().environmentObject(model)
        }
        .defaultSize(width: 1000, height: 680)

        MenuBarExtra {
            MenuBarView().environmentObject(model)
        } label: {
            Image(systemName: "externaldrive.badge.minus")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu bar

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DiskBar(disk: model.disk)

            if model.worktreeScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.worktreeProgress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else if model.worktreesScannedAt != nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.mergedWorktrees.count) worktree đã merge")
                        .font(.headline)
                    Text("\(model.mergedCacheSize.bytes) cache build có thể dọn")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Mở Dev Sweeper", systemImage: "macwindow")
            }
            Button {
                Task {
                    await model.scanStorage()
                    await model.scanWorktrees()
                }
            } label: {
                Label("Quét lại", systemImage: "arrow.clockwise")
            }
            .disabled(model.worktreeScanning)

            Divider()
            Button("Thoát") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .padding(14)
        .frame(width: 280)
        .onAppear { model.refreshDisk() }
    }
}

// MARK: - Main window

enum Section: String, CaseIterable, Identifiable {
    case overview = "Dung lượng"
    case worktrees = "Worktrees"
    case bigFolders = "Thư mục lớn"
    case settings = "Cài đặt"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .worktrees: "arrow.triangle.branch"
        case .bigFolders: "folder.badge.questionmark"
        case .settings: "gearshape"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var section: Section? = .worktrees

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                DiskBar(disk: model.disk).padding(12)
            }
        } detail: {
            Group {
                switch section ?? .worktrees {
                case .overview: StorageView()
                case .worktrees: WorktreesView()
                case .bigFolders: BigFoldersView()
                case .settings: SettingsView()
                }
            }
            .alert("Lỗi", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .alert(model.pending?.title ?? "", isPresented: Binding(
            get: { model.pending != nil },
            set: { if !$0 { model.pending = nil } }
        ), presenting: model.pending) { action in
            Button(action.confirm, role: .destructive) { Task { await action.run() } }
            Button("Huỷ", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Shared components

struct DiskBar: View {
    let disk: DiskInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Ổ đĩa", systemImage: "internaldrive").font(.caption.weight(.semibold))
                Spacer()
                Text("còn \(disk.free.bytes)").font(.caption.monospacedDigit())
            }
            ProgressView(value: disk.usedFraction)
                .tint(disk.usedFraction > 0.9 ? .red : disk.usedFraction > 0.75 ? .orange : .accentColor)
            Text("\(disk.used.bytes) / \(disk.total.bytes) đã dùng")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(color)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minWidth: 120, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension MergeState {
    var title: String {
        switch self {
        case .main: "Checkout chính"
        case .merged: "Đã merge"
        case .likelyMerged: "Có thể đã merge"
        case .open: "PR đang mở"
        case .notMerged: "Chưa merge"
        case .unknown: "Không rõ"
        case .prunable: "Thư mục đã mất"
        }
    }
    var detail: String {
        switch self {
        case .merged(let s), .likelyMerged(let s), .open(let s), .notMerged(let s), .unknown(let s): s
        case .main: "Không thể xóa, chỉ dọn cache"
        case .prunable: "Chỉ còn metadata, có thể prune"
        }
    }
    var color: Color {
        switch self {
        case .main: .secondary
        case .merged: .green
        case .likelyMerged: .mint
        case .open: .blue
        case .notMerged: .orange
        case .unknown, .prunable: .gray
        }
    }
}

// MARK: - Storage

struct StorageView: View {
    @EnvironmentObject var model: AppModel
    @State private var detailItem: StorageItem?

    var body: some View {
        let items = model.storage.sorted { ($0.size ?? -1) > ($1.size ?? -1) }
        let maxSize = items.compactMap(\.size).max() ?? 1

        List {
            ForEach(items) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.icon)
                        .frame(width: 24)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.name).font(.body.weight(.medium))
                            Spacer()
                            Text(item.size.map(\.bytes) ?? (model.storageScanning ? "…" : "—"))
                                .font(.body.monospacedDigit())
                                .foregroundStyle(item.size == nil ? .secondary : .primary)
                        }
                        ProgressView(value: Double(item.size ?? 0), total: Double(max(maxSize, 1)))
                            .tint(item.cleaner == nil ? .gray : .accentColor)
                        Text(item.note).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        if model.busy.contains(item.path) {
                            ProgressView().controlSize(.small)
                        } else {
                            if item.detail != nil {
                                Button("Chi tiết") { detailItem = item }
                                    .disabled((item.size ?? 0) == 0)
                            }
                            if item.cleaner != nil {
                                Button("Dọn") { model.askClean(item) }
                                    .disabled((item.size ?? 0) == 0)
                            }
                        }
                    }
                    .frame(width: 130, alignment: .trailing)
                }
                .padding(.vertical, 4)
                .contextMenu {
                    Button("Hiện trong Finder") { model.reveal(item.path) }
                }
            }
        }
        .sheet(item: $detailItem) { item in
            DetailSheet(item: item).environmentObject(model)
        }
        .navigationTitle("Dung lượng")
        .toolbar {
            Button {
                Task { await model.scanStorage() }
            } label: {
                if model.storageScanning { ProgressView().controlSize(.small) }
                else { Label("Quét lại", systemImage: "arrow.clockwise") }
            }
            .disabled(model.storageScanning)
        }
    }
}

// MARK: - Worktrees

enum WorktreeFilter: String, CaseIterable, Identifiable {
    case all = "Tất cả"
    case merged = "Đã merge"
    case notMerged = "Chưa merge"
    var id: String { rawValue }
}

enum WorktreeSort: String, CaseIterable, Identifiable {
    case cache = "Cache"
    case total = "Tổng"
    case name = "Tên"
    var id: String { rawValue }
}

struct WorktreesView: View {
    @EnvironmentObject var model: AppModel
    @State private var filter: WorktreeFilter = .all
    @State private var sort: WorktreeSort = .cache

    private func visible(_ wts: [Worktree]) -> [Worktree] {
        let filtered = wts.filter { wt in
            switch filter {
            case .all: true
            case .merged: wt.state.isMergedOrLikely || wt.state == .prunable
            case .notMerged: !wt.state.isMergedOrLikely && wt.state != .prunable
            }
        }
        return filtered.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            switch sort {
            case .cache: return a.cacheSize > b.cacheSize
            case .total: return (a.totalSize ?? 0) > (b.totalSize ?? 0)
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.repos.isEmpty {
                ContentUnavailableView {
                    if model.worktreeScanning {
                        ProgressView()
                        Text(model.worktreeProgress)
                    } else {
                        Label("Không tìm thấy worktree", systemImage: "arrow.triangle.branch")
                    }
                } description: {
                    if !model.worktreeScanning {
                        Text("Thêm thư mục chứa project trong Cài đặt rồi quét lại.")
                    }
                }
            } else {
                List {
                    ForEach(model.repos) { repo in
                        let rows = visible(repo.worktrees)
                        if !rows.isEmpty {
                            SwiftUI.Section {
                                ForEach(rows) { WorktreeRow(wt: $0) }
                            } header: {
                                HStack {
                                    Text(repo.name).font(.headline)
                                    if let d = repo.defaultRef { Badge(text: d, color: .secondary) }
                                    if !repo.hasGitHub { Badge(text: "không có GitHub", color: .gray) }
                                    Spacer()
                                    Text(model.shortPath(repo.path)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Worktrees")
        .toolbar {
            ToolbarItemGroup {
                Picker("Sắp xếp", selection: $sort) {
                    ForEach(WorktreeSort.allCases) { Text("Theo \($0.rawValue.lowercased())").tag($0) }
                }
                Picker("Lọc", selection: $filter) {
                    ForEach(WorktreeFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Button {
                    Task { await model.scanWorktrees() }
                } label: {
                    Label("Quét lại", systemImage: "arrow.clockwise")
                }
                .disabled(model.worktreeScanning)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            let all = model.allWorktrees.filter { !$0.isMain }
            StatCard(title: "Worktree", value: "\(all.count)")
            StatCard(title: "Đã merge", value: "\(model.mergedWorktrees.count)", color: .green)
            StatCard(title: "Cache đã merge", value: model.mergedCacheSize.bytes, color: .green)
            StatCard(title: "Tổng cache", value: model.allWorktrees.reduce(Int64(0)) { $0 + $1.cacheSize }.bytes)
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if model.worktreeScanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(model.worktreeProgress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                HStack {
                    Button("Xóa cache đã merge") { model.askCleanAllMergedCaches() }
                        .disabled(model.mergedCacheSize == 0 || model.worktreeScanning)
                    Button("Xóa worktree đã merge (\(model.removableMerged.count))", role: .destructive) {
                        model.askRemoveAllMerged()
                    }
                    .disabled(model.removableMerged.isEmpty || model.worktreeScanning)
                }
            }
        }
        .padding(12)
    }
}

struct WorktreeRow: View {
    @EnvironmentObject var model: AppModel
    let wt: Worktree

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(wt.name).font(.body.weight(.medium))
                    Badge(text: wt.state.title, color: wt.state.color)
                    if wt.dirty { Badge(text: "Có thay đổi chưa commit", color: .orange) }
                    if wt.locked { Badge(text: "Locked", color: .gray) }
                }
                Text(wt.branch ?? "detached @ \(wt.head.prefix(9))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if !wt.state.detail.isEmpty {
                    Text(wt.state.detail).font(.caption).foregroundStyle(.secondary)
                }
                if !wt.caches.isEmpty {
                    Text(wt.caches.map { cacheLabel($0) }.joined(separator: "  ·  "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(wt.cacheSize > 0 ? wt.cacheSize.bytes : "—")
                    .font(.body.weight(.semibold).monospacedDigit())
                Text("tổng \(wt.totalSize.map(\.bytes) ?? "—")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(minWidth: 90, alignment: .trailing)

            Group {
                if model.busy.contains(wt.path) {
                    ProgressView().controlSize(.small)
                } else {
                    Menu {
                        Button("Hiện trong Finder") { model.reveal(wt.path) }
                        Button("Xóa cache build (\(wt.cacheSize.bytes))") { model.askCleanCaches(wt) }
                            .disabled(wt.cacheSize == 0)
                        if wt.canRemove {
                            Divider()
                            Button(wt.state == .prunable ? "Prune worktree" : "Xóa worktree…", role: .destructive) {
                                model.askRemove(wt)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
            }
            .frame(width: 32)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Hiện trong Finder") { model.reveal(wt.path) }
        }
    }

    private func cacheLabel(_ c: CacheDir) -> String {
        let name = c.isDerivedData
            ? "DerivedData"
            : String(c.path.dropFirst(wt.path.count + 1))
        return "\(name) \(c.size.bytes)"
    }
}

// MARK: - Big folders

struct BigFoldersView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.bigFolders.isEmpty {
                ContentUnavailableView {
                    if model.bigScanning {
                        ProgressView()
                        Text("Đang quét thư mục Home… (có thể mất vài phút)")
                    } else {
                        Label("Thư mục nào đang chiếm nhiều dung lượng?", systemImage: "folder.badge.questionmark")
                    }
                } description: {
                    if !model.bigScanning {
                        Text("Quét toàn bộ thư mục Home, liệt kê các thư mục ≥ 50 MB (2 cấp).")
                    }
                } actions: {
                    if !model.bigScanning {
                        Button("Bắt đầu quét") { Task { await model.scanBigFolders() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                let maxSize = model.bigFolders.first?.size ?? 1
                List(model.bigFolders, children: \.children) { node in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.tint)
                        Text(node.name)
                        Spacer()
                        ProgressView(value: Double(node.size), total: Double(maxSize))
                            .frame(width: 140)
                        Text(node.size.bytes)
                            .font(.body.monospacedDigit())
                            .frame(width: 80, alignment: .trailing)
                        Button { model.reveal(node.path) } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(.borderless)
                            .help("Hiện trong Finder")
                    }
                }
            }
        }
        .navigationTitle("Thư mục lớn")
        .toolbar {
            Button {
                Task { await model.scanBigFolders() }
            } label: {
                if model.bigScanning { ProgressView().controlSize(.small) }
                else { Label("Quét lại", systemImage: "arrow.clockwise") }
            }
            .disabled(model.bigScanning)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            SwiftUI.Section("Thư mục chứa project") {
                ForEach(model.roots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder")
                        Text(model.shortPath(root))
                        Spacer()
                        Button(role: .destructive) {
                            model.roots.removeAll { $0 == root }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Thêm thư mục…") { addRoot() }
            }
            SwiftUI.Section("Kiểm tra merge") {
                Toggle("git fetch --prune trước khi quét", isOn: $model.fetchBeforeScan)
                Text("Cập nhật trạng thái nhánh trên remote. Trạng thái PR lấy qua GitHub CLI (`gh`) — cần `gh auth login`.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Khi xóa worktree") {
                Toggle("Xóa luôn nhánh local nếu đã merge", isOn: $model.deleteBranchOnRemove)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Cài đặt")
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !model.roots.contains(url.path) {
                model.roots.append(url.path)
            }
        }
    }
}
