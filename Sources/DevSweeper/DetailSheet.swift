import SwiftUI

struct DetailEntry: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    var subtitle: String? = nil
    var warning: String? = nil
    var date: Date? = nil
    var size: Int64? = nil
    /// Simulator → xóa bằng `simctl delete` thay vì xóa thư mục.
    var simUDID: String? = nil
    var simBooted = false
}

enum DetailLoader {
    static func entries(for item: StorageItem) async -> [DetailEntry] {
        switch item.detail {
        case .derivedData: derivedData(item.path)
        case .simulators: await simulators(item.path)
        case .archives: archives(item.path)
        case .children, nil: children(item.path)
        }
    }

    private static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func list(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0 != ".DS_Store" }
            .map { dir + "/" + $0 }
    }

    static func children(_ dir: String) -> [DetailEntry] {
        list(dir).map { DetailEntry(path: $0, name: ($0 as NSString).lastPathComponent, date: modified($0)) }
    }

    static func derivedData(_ dir: String) -> [DetailEntry] {
        list(dir).map { path in
            let folder = (path as NSString).lastPathComponent
            var e = DetailEntry(path: path, name: folder, date: modified(path))
            guard let data = FileManager.default.contents(atPath: path + "/info.plist"),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return e }
            if let dash = folder.lastIndex(of: "-") { e = DetailEntry(path: path, name: String(folder[..<dash]), date: e.date) }
            if let ws = plist["WorkspacePath"] as? String {
                e.subtitle = ws.hasPrefix(home) ? "~" + ws.dropFirst(home.count) : ws
                if !FileManager.default.fileExists(atPath: ws) { e.warning = "Project không còn tồn tại" }
            }
            if let last = plist["LastAccessedDate"] as? Date { e.date = last }
            return e
        }
    }

    static func archives(_ dir: String) -> [DetailEntry] {
        list(dir).flatMap { dayDir in
            list(dayDir).filter { $0.hasSuffix(".xcarchive") }.map { path in
                var e = DetailEntry(path: path, name: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
                                    date: modified(path))
                if let plist = NSDictionary(contentsOfFile: path + "/Info.plist"),
                   let app = plist["ApplicationProperties"] as? [String: Any] {
                    let id = app["CFBundleIdentifier"] as? String ?? ""
                    let ver = app["CFBundleShortVersionString"] as? String ?? "?"
                    let build = app["CFBundleVersion"] as? String ?? "?"
                    e.subtitle = "\(id)  ·  v\(ver) (\(build))"
                }
                return e
            }
        }
    }

    static func simulators(_ devicesDir: String) async -> [DetailEntry] {
        let r = await Shell.run(["xcrun", "simctl", "list", "devices", "--json"])
        var entries: [DetailEntry] = []
        var known = Set<String>()
        let iso = ISO8601DateFormatter()

        if let json = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
           let devices = json["devices"] as? [String: [[String: Any]]] {
            for (runtime, list) in devices {
                let os = prettyRuntime(runtime)
                for d in list {
                    guard let udid = d["udid"] as? String else { continue }
                    known.insert(udid)
                    let state = d["state"] as? String ?? ""
                    let available = d["isAvailable"] as? Bool ?? true
                    var e = DetailEntry(path: devicesDir + "/" + udid, name: d["name"] as? String ?? udid)
                    e.subtitle = "\(os)  ·  \(state)"
                    e.simUDID = udid
                    e.simBooted = state == "Booted"
                    if !available { e.warning = "Runtime không còn — simulator hỏng" }
                    e.date = (d["lastBootedAt"] as? String).flatMap { iso.date(from: $0) }
                    entries.append(e)
                }
            }
        }
        // Thư mục mồ côi: không còn trong danh sách simctl
        for path in list(devicesDir) where !known.contains((path as NSString).lastPathComponent) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            var e = DetailEntry(path: path, name: (path as NSString).lastPathComponent, date: modified(path))
            e.warning = "Thư mục mồ côi — simctl không còn quản lý"
            entries.append(e)
        }
        return entries
    }

    /// com.apple.CoreSimulator.SimRuntime.iOS-18-1 → iOS 18.1
    private static func prettyRuntime(_ id: String) -> String {
        let raw = id.components(separatedBy: "SimRuntime.").last ?? id
        guard let dash = raw.firstIndex(of: "-") else { return raw }
        return raw[..<dash] + " " + raw[raw.index(after: dash)...].replacingOccurrences(of: "-", with: ".")
    }

    /// Trả về thông báo lỗi, hoặc nil nếu thành công.
    static func delete(_ e: DetailEntry) async -> String? {
        if let udid = e.simUDID {
            if e.simBooted { _ = await Shell.run(["xcrun", "simctl", "shutdown", udid]) }
            let r = await Shell.run(["xcrun", "simctl", "delete", udid])
            return r.ok ? nil : r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            try await DiskUsage.remove(e.path)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

enum DetailSort: String, CaseIterable, Identifiable {
    case size = "Dung lượng"
    case date = "Lần dùng"
    case name = "Tên"
    var id: String { rawValue }
}

struct DetailSheet: View {
    let item: StorageItem
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [DetailEntry] = []
    @State private var loading = true
    @State private var selection = Set<String>()
    @State private var sort: DetailSort = .size
    @State private var confirming: [DetailEntry]?
    @State private var deleting = Set<String>()
    @State private var errors: [String] = []

    private var deletable: Bool { item.detail?.deletable ?? false }

    private var sorted: [DetailEntry] {
        entries.sorted { a, b in
            switch sort {
            case .size: (a.size ?? -1) > (b.size ?? -1)
            case .date: (a.date ?? .distantPast) > (b.date ?? .distantPast)
            case .name: a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    private var selectedEntries: [DetailEntry] { entries.filter { selection.contains($0.path) } }
    private func total(_ list: [DetailEntry]) -> Int64 { list.reduce(0) { $0 + ($1.size ?? 0) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 640)
        .task { await load() }
        .alert(confirmTitle, isPresented: Binding(
            get: { confirming != nil },
            set: { if !$0 { confirming = nil } }
        ), presenting: confirming) { list in
            Button("Xóa", role: .destructive) { Task { await delete(list) } }
            Button("Huỷ", role: .cancel) {}
        } message: { list in
            Text(confirmMessage(list))
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top) {
            Image(systemName: item.icon).font(.title2).foregroundStyle(.tint).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.title3.weight(.semibold))
                Text(model.shortPath(item.path)).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(total(entries).bytes).font(.title3.weight(.semibold).monospacedDigit())
                Text("\(entries.count) mục").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if loading && entries.isEmpty {
            ProgressView("Đang đọc…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView("Trống", systemImage: "tray", description: Text("Không có gì để dọn."))
        } else {
            VStack(spacing: 0) {
                HStack {
                    if deletable {
                        Button(selection.count == entries.count ? "Bỏ chọn tất cả" : "Chọn tất cả") {
                            selection = selection.count == entries.count ? [] : Set(entries.map(\.path))
                        }
                        let flagged = entries.filter { $0.warning != nil }
                        if !flagged.isEmpty {
                            Button("Chọn mục có cảnh báo (\(flagged.count))") {
                                selection.formUnion(flagged.map(\.path))
                            }
                        }
                    } else {
                        Label("Mục này chỉ để xem — dọn bằng công cụ riêng của nó", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Picker("Sắp xếp", selection: $sort) {
                        ForEach(DetailSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                .controlSize(.small)
                .padding(.horizontal, 16).padding(.vertical, 8)

                List(sorted) { e in row(e) }
                    .listStyle(.inset)
            }
        }
    }

    private func row(_ e: DetailEntry) -> some View {
        let maxSize = entries.compactMap(\.size).max() ?? 1
        return HStack(spacing: 10) {
            if deletable {
                Toggle("", isOn: Binding(
                    get: { selection.contains(e.path) },
                    set: { on in if on { selection.insert(e.path) } else { selection.remove(e.path) } }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(deleting.contains(e.path))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.name).font(.body.weight(.medium)).lineLimit(1)
                    if e.simBooted { Badge(text: "Đang chạy", color: .blue) }
                    if let w = e.warning { Badge(text: w, color: .orange) }
                }
                if let s = e.subtitle {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            Text(e.date.map { $0.formatted(.relative(presentation: .named)) } ?? "")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            ProgressView(value: Double(e.size ?? 0), total: Double(max(maxSize, 1)))
                .frame(width: 80)
            Text(e.size.map(\.bytes) ?? "…")
                .font(.body.monospacedDigit())
                .frame(width: 80, alignment: .trailing)
            Group {
                if deleting.contains(e.path) {
                    ProgressView().controlSize(.small)
                } else {
                    Menu {
                        Button("Hiện trong Finder") { model.reveal(e.path) }
                        if deletable {
                            Divider()
                            Button("Xóa…", role: .destructive) { confirming = [e] }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
            }
            .frame(width: 28)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            guard deletable, !deleting.contains(e.path) else { return }
            if selection.contains(e.path) { selection.remove(e.path) } else { selection.insert(e.path) }
        }
    }

    private var footer: some View {
        HStack {
            if !errors.isEmpty {
                Label("\(errors.count) mục không xóa được", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(errors.joined(separator: "\n"))
            } else if deletable {
                Text(selection.isEmpty ? "Chưa chọn mục nào"
                     : "Đã chọn \(selection.count) mục · \(total(selectedEntries).bytes)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Đóng") { dismiss() }.keyboardShortcut(.cancelAction)
            if deletable {
                Button("Xóa đã chọn", role: .destructive) { confirming = selectedEntries }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(selection.isEmpty || !deleting.isEmpty)
            }
        }
        .padding(16)
    }

    // MARK: Actions

    private var confirmTitle: String {
        guard let list = confirming else { return "" }
        return list.count == 1 ? "Xóa \(list[0].name)?" : "Xóa \(list.count) mục?"
    }

    private func confirmMessage(_ list: [DetailEntry]) -> String {
        var msg = "Giải phóng \(total(list).bytes). Xóa vĩnh viễn, không qua Thùng rác."
        if list.contains(where: \.simBooted) { msg += "\n\nSimulator đang chạy sẽ bị tắt trước khi xóa." }
        if list.count > 1 && list.count <= 12 {
            msg += "\n\n" + list.map { "• \($0.name)" }.joined(separator: "\n")
        }
        return msg
    }

    private func load() async {
        loading = true
        entries = await DetailLoader.entries(for: item)
        // Tính dung lượng dần dần để danh sách hiện ngay
        let paths = entries.map(\.path)
        await withTaskGroup(of: (String, Int64?).self) { group in
            var next = 0
            func enqueue() {
                guard next < paths.count else { return }
                let p = paths[next]
                next += 1
                group.addTask { (p, await DiskUsage.size(of: p)) }
            }
            for _ in 0..<4 { enqueue() }
            while let (p, size) = await group.next() {
                if let i = entries.firstIndex(where: { $0.path == p }) { entries[i].size = size ?? 0 }
                enqueue()
            }
        }
        loading = false
    }

    private func delete(_ list: [DetailEntry]) async {
        errors = []
        for e in list {
            deleting.insert(e.path)
            if let err = await DetailLoader.delete(e) {
                errors.append("\(e.name): \(err)")
            } else {
                entries.removeAll { $0.path == e.path }
                selection.remove(e.path)
            }
            deleting.remove(e.path)
        }
        await model.refreshStorageSize(item.path)
    }
}
