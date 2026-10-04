import SwiftUI

private func relative(_ date: Date?) -> String {
    date.map { $0.formatted(.relative(presentation: .named)) } ?? "chưa rõ"
}

// MARK: - Simulator runtimes

struct RuntimesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let maxSize = model.runtimes.map(\.size).max() ?? 1
        List {
            SwiftUI.Section {
                ForEach(model.runtimes) { rt in
                    HStack(spacing: 12) {
                        Image(systemName: "iphone.gen3").font(.title3).foregroundStyle(.tint).frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(rt.name).font(.body.weight(.medium))
                                Text(rt.build).font(.caption.monospaced()).foregroundStyle(.secondary)
                                if !rt.bootedDevices.isEmpty { Badge(text: "Đang chạy", color: .blue) }
                                if rt.devices.isEmpty { Badge(text: "Không simulator nào", color: .secondary) }
                                if rt.suggestRemove { Badge(text: "Nên gỡ", color: .orange) }
                                if !rt.deletable { Badge(text: "Không gỡ được", color: .gray) }
                            }
                            Text("\(rt.devices.count) simulator · dùng lần cuối \(relative(rt.lastUsed))")
                                .font(.caption).foregroundStyle(.secondary)
                            if !rt.devices.isEmpty {
                                Text(rt.devices.joined(separator: ", "))
                                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
                            }
                        }
                        Spacer()
                        ProgressView(value: Double(rt.size), total: Double(max(maxSize, 1))).frame(width: 90)
                        Text(rt.size.bytes).font(.body.monospacedDigit()).frame(width: 80, alignment: .trailing)
                        Group {
                            if model.busy.contains(rt.id) {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Gỡ") { model.askDeleteRuntime(rt) }.disabled(!rt.deletable)
                            }
                        }
                        .frame(width: 50)
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("Runtime là hệ điều hành của simulator (mỗi bản 6–10 GB, nằm ngoài thư mục Home). Gỡ runtime sẽ xóa luôn các simulator dùng nó; tải lại trong Xcode → Settings → Components.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .overlay {
            if model.runtimes.isEmpty {
                if model.runtimesLoading { ProgressView() }
                else { ContentUnavailableView("Không có runtime nào", systemImage: "iphone.slash") }
            }
        }
        .navigationTitle("Simulator runtime")
        .toolbar {
            Button { Task { await model.loadRuntimes() } } label: { Label("Quét lại", systemImage: "arrow.clockwise") }
                .disabled(model.runtimesLoading)
        }
        .task { if model.runtimes.isEmpty { await model.loadRuntimes() } }
    }
}

// MARK: - Git repos

struct GitReposView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            SwiftUI.Section {
                ForEach(model.gitRepos) { repo in
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(.tint).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(repo.name).font(.body.weight(.medium))
                                if repo.worktrees > 1 { Badge(text: "\(repo.worktrees) worktree", color: .secondary) }
                                if repo.needsGC { Badge(text: "Nên gc", color: .orange) }
                            }
                            Text(model.shortPath(repo.path)).font(.caption).foregroundStyle(.secondary)
                            Text("pack \(repo.packSize.bytes) (\(repo.packs) file) · object rời \(repo.looseCount) = \(repo.looseSize.bytes) · rác \(repo.garbageSize.bytes)")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(repo.gitSize.bytes).font(.body.monospacedDigit())
                            if repo.reclaimable > 0 {
                                Text("lấy lại ~\(repo.reclaimable.bytes)").font(.caption).foregroundStyle(.green)
                            }
                        }
                        .frame(width: 110, alignment: .trailing)
                        Group {
                            if model.busy.contains(repo.path) {
                                ProgressView().controlSize(.small)
                            } else {
                                Menu {
                                    Button("Hiện trong Finder") { model.reveal(repo.path) }
                                    Button("Chạy git gc…") { model.askGC(repo) }
                                } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                            }
                        }
                        .frame(width: 28)
                    }
                    .padding(.vertical, 3)
                }
            } footer: {
                Text("Dung lượng thư mục .git của các repo trong thư mục project. Repo đã nén gọn (ít object rời, 1 pack) thì git gc không lấy lại được gì — muốn nhỏ hơn phải clone nông (--depth) hoặc xóa repo tham khảo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .overlay {
            if model.gitRepos.isEmpty {
                if model.gitLoading { ProgressView("Đang quét repo…") }
                else { ContentUnavailableView("Không có repo", systemImage: "folder") }
            }
        }
        .navigationTitle("Git repo")
        .toolbar {
            Button { Task { await model.loadGitRepos() } } label: { Label("Quét lại", systemImage: "arrow.clockwise") }
                .disabled(model.gitLoading)
        }
        .task { if model.gitRepos.isEmpty { await model.loadGitRepos() } }
    }
}

// MARK: - Large files

struct LargeFilesView: View {
    @EnvironmentObject var model: AppModel
    @State private var minMB = 200
    @State private var idleFilter = 0 // ngày; 0 = tất cả
    @State private var selection = Set<String>()

    private var visible: [LargeFile] {
        model.largeFiles.filter { idleFilter == 0 || ($0.idleDays ?? 0) >= idleFilter }
    }
    private var selected: [LargeFile] { model.largeFiles.filter { selection.contains($0.path) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Lớn hơn", selection: $minMB) {
                    ForEach([100, 200, 500, 1000], id: \.self) { Text($0 >= 1000 ? "1 GB" : "\($0) MB").tag($0) }
                }
                .fixedSize()
                Picker("Không mở trong", selection: $idleFilter) {
                    Text("Tất cả").tag(0)
                    Text("1 tháng").tag(30)
                    Text("3 tháng").tag(90)
                    Text("6 tháng").tag(180)
                    Text("1 năm").tag(365)
                }
                .fixedSize()
                Spacer()
                Text("\(visible.count) file · \(visible.reduce(Int64(0)) { $0 + $1.size }.bytes)")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()

            if !model.largeScanned {
                ContentUnavailableView {
                    if model.largeLoading { ProgressView(); Text("Đang tìm file lớn trong Home…") }
                    else { Label("Tìm file lớn và lâu không mở", systemImage: "doc.text.magnifyingglass") }
                } description: {
                    Text("Quét thư mục Home (trừ Library, cache build và .git). Ngày mở lần cuối lấy từ Spotlight.")
                } actions: {
                    if !model.largeLoading {
                        Button("Bắt đầu quét") { Task { await model.loadLargeFiles(minMB: minMB) } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                List(visible) { f in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { selection.contains(f.path) },
                            set: { on in if on { selection.insert(f.path) } else { selection.remove(f.path) } }
                        ))
                        .toggleStyle(.checkbox).labelsHidden()
                        Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name).lineLimit(1)
                            Text(model.shortPath((f.path as NSString).deletingLastPathComponent))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(f.lastUsed != nil ? "mở \(relative(f.lastUsed))" : "sửa \(relative(f.modified))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: 130, alignment: .trailing)
                        Text(f.size.bytes).font(.body.monospacedDigit()).frame(width: 80, alignment: .trailing)
                        Menu {
                            Button("Hiện trong Finder") { model.reveal(f.path) }
                            Button("Chuyển vào Thùng rác…", role: .destructive) { model.askTrashFiles([f]) }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selection.contains(f.path) { selection.remove(f.path) } else { selection.insert(f.path) }
                    }
                }
                Divider()
                HStack {
                    Text(selection.isEmpty ? "Chưa chọn file nào"
                         : "Đã chọn \(selection.count) file · \(selected.reduce(Int64(0)) { $0 + $1.size }.bytes)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Chuyển vào Thùng rác", role: .destructive) { model.askTrashFiles(selected) }
                        .disabled(selection.isEmpty)
                }
                .padding(12)
            }
        }
        .navigationTitle("File lớn")
        .toolbar {
            Button { Task { await model.loadLargeFiles(minMB: minMB) } } label: {
                if model.largeLoading { ProgressView().controlSize(.small) }
                else { Label("Quét lại", systemImage: "arrow.clockwise") }
            }
            .disabled(model.largeLoading)
        }
        .onChange(of: minMB) { _, v in
            if model.largeScanned { Task { await model.loadLargeFiles(minMB: v) } }
        }
        .onChange(of: model.largeFiles.map(\.path)) { _, paths in selection.formIntersection(paths) }
    }
}

// MARK: - Uninstaller

enum AppSort: String, CaseIterable, Identifiable {
    case size = "Dung lượng", lastUsed = "Lần mở", name = "Tên"
    var id: String { rawValue }
}

struct UninstallView: View {
    @EnvironmentObject var model: AppModel
    @State private var sort: AppSort = .size
    @State private var search = ""
    @State private var target: InstalledApp?

    private var visible: [InstalledApp] {
        model.apps
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { a, b in
                switch sort {
                case .size: (a.size ?? 0) > (b.size ?? 0)
                case .lastUsed: (a.lastUsed ?? .distantPast) < (b.lastUsed ?? .distantPast)
                case .name: a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
    }

    var body: some View {
        List(visible) { app in
            HStack(spacing: 10) {
                Image(nsImage: app.icon).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.name).font(.body.weight(.medium))
                        if app.isRunning { Badge(text: "Đang chạy", color: .blue) }
                    }
                    Text(app.lastUsed != nil ? "Mở lần cuối \(relative(app.lastUsed))" : "Chưa ghi nhận lần mở nào")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(app.size.map(\.bytes) ?? "…").font(.body.monospacedDigit()).frame(width: 80, alignment: .trailing)
                Button("Gỡ…") { target = app }
            }
            .padding(.vertical, 2)
        }
        .searchable(text: $search, prompt: "Tìm app")
        .overlay { if model.apps.isEmpty && model.appsLoading { ProgressView() } }
        .navigationTitle("Gỡ app")
        .toolbar {
            Picker("Sắp xếp", selection: $sort) {
                ForEach(AppSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Button { Task { await model.loadApps() } } label: { Label("Quét lại", systemImage: "arrow.clockwise") }
                .disabled(model.appsLoading)
        }
        .task { if model.apps.isEmpty { await model.loadApps() } }
        .sheet(item: $target) { app in
            UninstallSheet(app: app).environmentObject(model)
        }
    }
}

struct UninstallSheet: View {
    let app: InstalledApp
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var related: [RelatedFile] = []
    @State private var selection = Set<String>()
    @State private var loading = true
    @State private var working = false
    @State private var error: String?

    private var total: Int64 {
        (app.size ?? 0) + related.filter { selection.contains($0.path) }.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: app.icon).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gỡ \(app.name)").font(.title3.weight(.semibold))
                    Text(app.bundleId).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Text(total.bytes).font(.title3.weight(.semibold).monospacedDigit())
            }
            .padding(16)
            Divider()

            List {
                SwiftUI.Section("Ứng dụng") {
                    HStack {
                        Image(systemName: "checkmark.square.fill").foregroundStyle(.tint)
                        Text(model.shortPath(app.path)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(app.size.map(\.bytes) ?? "…").monospacedDigit()
                    }
                }
                SwiftUI.Section("Dữ liệu đi kèm trong ~/Library") {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if related.isEmpty {
                        Text("Không tìm thấy").foregroundStyle(.secondary)
                    }
                    ForEach(related) { f in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { selection.contains(f.path) },
                                set: { on in if on { selection.insert(f.path) } else { selection.remove(f.path) } }
                            ))
                            .toggleStyle(.checkbox).labelsHidden()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.shortPath(f.path)).lineLimit(1).truncationMode(.middle)
                                Text(f.kind).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(f.size.bytes).monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(2)
                } else if app.isRunning {
                    Label("App đang chạy — thoát app trước khi gỡ", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Text("Tất cả được chuyển vào Thùng rác — vẫn khôi phục được.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Chuyển vào Thùng rác", role: .destructive) {
                    working = true
                    Task {
                        error = await model.uninstall(app, related: related.filter { selection.contains($0.path) })
                        working = false
                        if error == nil { dismiss() }
                    }
                }
                .disabled(loading || working || app.isRunning)
            }
            .padding(16)
        }
        .frame(minWidth: 640, idealWidth: 700, minHeight: 460, idealHeight: 540)
        .task {
            related = await AppUninstaller.related(to: app)
            selection = Set(related.map(\.path))
            loading = false
        }
    }
}
