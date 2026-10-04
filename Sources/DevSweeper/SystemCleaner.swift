import AppKit
import Foundation

// MARK: - Large & old files

struct LargeFile: Identifiable {
    var id: String { path }
    let path: String
    let size: Int64
    var lastUsed: Date?
    var modified: Date?

    var name: String { (path as NSString).lastPathComponent }
    /// Lần mở gần nhất (Spotlight) — nếu không có thì lấy ngày sửa.
    var lastTouched: Date? { lastUsed ?? modified }
    var idleDays: Int? { lastTouched.map { Int(Date().timeIntervalSince($0) / 86400) } }
}

enum LargeFileScanner {
    /// Thư mục bỏ qua: Library (đã có màn riêng), cache build, .git (màn Git repo).
    static let skipNames = ["node_modules", ".build", "DerivedData", ".git", "Pods", ".gradle", ".Trash"]

    static func scan(minMB: Int) async -> [LargeFile] {
        var args = ["find", home, "-xdev", "(", "-path", home + "/Library"]
        for n in skipNames { args += ["-o", "-name", n] }
        args += [")", "-prune", "-o", "-type", "f", "-size", "+\(minMB)M", "-print"]
        let paths = await Shell.run(args).out.split(separator: "\n").map(String.init)
        guard !paths.isEmpty else { return [] }

        let fm = FileManager.default
        var files: [LargeFile] = paths.compactMap { p in
            guard let attrs = try? fm.attributesOfItem(atPath: p),
                  let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
            return LargeFile(path: p, size: size, modified: attrs[.modificationDate] as? Date)
        }

        // mdls -raw với nhiều file → giá trị ngăn cách bằng \0
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        for start in stride(from: 0, to: files.count, by: 100) {
            let chunk = Array(files[start..<min(start + 100, files.count)])
            let r = await Shell.run(["mdls", "-raw", "-name", "kMDItemLastUsedDate"] + chunk.map(\.path))
            let values = r.out.components(separatedBy: "\0")
            for (i, v) in values.prefix(chunk.count).enumerated() {
                files[start + i].lastUsed = fmt.date(from: v.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return files.sorted { $0.size > $1.size }
    }
}

// MARK: - Uninstaller

struct InstalledApp: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let bundleId: String
    var size: Int64? = nil
    var lastUsed: Date? = nil

    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: path) }
}

struct RelatedFile: Identifiable, Hashable {
    var id: String { path }
    let path: String
    var size: Int64
    let kind: String
}

enum AppUninstaller {
    static func listApps() async -> [InstalledApp] {
        let fm = FileManager.default
        var apps: [InstalledApp] = []
        for dir in ["/Applications", home + "/Applications"] {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".app") {
                let path = dir + "/" + name
                guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier else { continue }
                apps.append(InstalledApp(path: path, name: (name as NSString).deletingPathExtension, bundleId: id))
            }
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let r = await Shell.run(["mdls", "-raw", "-name", "kMDItemLastUsedDate"] + apps.map(\.path))
        for (i, v) in r.out.components(separatedBy: "\0").prefix(apps.count).enumerated() {
            apps[i].lastUsed = fmt.date(from: v.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return apps
    }

    /// Dữ liệu của app trong ~/Library — chỉ khớp tên thư mục chính xác theo bundle id / tên app
    /// để không xóa nhầm thư mục dùng chung (vd "Microsoft").
    static func related(to app: InstalledApp) async -> [RelatedFile] {
        let fm = FileManager.default
        let lib = home + "/Library"
        let id = app.bundleId
        let names = [id, app.name].map { $0.lowercased() }

        var candidates: [(String, String)] = []
        func exact(_ dir: String, _ kind: String, suffixes: [String] = [""]) {
            for child in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let lower = child.lowercased()
                if names.contains(where: { n in suffixes.contains { lower == n + $0 } }) {
                    candidates.append((dir + "/" + child, kind))
                }
            }
        }
        exact(lib + "/Application Support", "Dữ liệu app")
        exact(lib + "/Caches", "Cache")
        exact(lib + "/Logs", "Log")
        exact(lib + "/HTTPStorages", "Cookie", suffixes: ["", ".binarycookies"])
        exact(lib + "/WebKit", "WebKit")
        exact(lib + "/Saved Application State", "Trạng thái cửa sổ", suffixes: [".savedstate"])
        exact(lib + "/Preferences", "Cài đặt", suffixes: [".plist"])
        exact(lib + "/Application Scripts", "Script")

        // Container của app + extension của nó (id.something)
        for child in (try? fm.contentsOfDirectory(atPath: lib + "/Containers")) ?? []
        where child == id || child.hasPrefix(id + ".") {
            candidates.append((lib + "/Containers/" + child, "Container"))
        }
        // Group container dạng TEAMID.<bundle id>
        for child in (try? fm.contentsOfDirectory(atPath: lib + "/Group Containers")) ?? []
        where child.hasSuffix("." + id) {
            candidates.append((lib + "/Group Containers/" + child, "Group container"))
        }
        for child in (try? fm.contentsOfDirectory(atPath: lib + "/Preferences/ByHost")) ?? []
        where child.hasPrefix(id + ".") {
            candidates.append((lib + "/Preferences/ByHost/" + child, "Cài đặt"))
        }
        for child in (try? fm.contentsOfDirectory(atPath: lib + "/LaunchAgents")) ?? []
        where child.hasPrefix(id) {
            candidates.append((lib + "/LaunchAgents/" + child, "Tự chạy khi đăng nhập"))
        }

        return await Parallel.map(candidates, limit: 6) { path, kind in
            RelatedFile(path: path, size: await DiskUsage.size(of: path) ?? 0, kind: kind)
        }
        .sorted { $0.size > $1.size }
    }

    /// Đưa app + dữ liệu vào Thùng rác (Finder hỏi mật khẩu nếu app thuộc admin).
    @MainActor
    static func trash(_ paths: [String]) async -> String? {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        return await withCheckedContinuation { cont in
            NSWorkspace.shared.recycle(urls) { _, error in
                cont.resume(returning: error?.localizedDescription)
            }
        }
    }
}
