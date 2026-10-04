import Foundation

/// Rác do các lần build / profile / phiên Claude để lại ngoài thư mục project.
enum LeftoverKind: String, CaseIterable, Identifiable {
    case trace = "Trace Instruments"
    case tempDerivedData = "DerivedData tạm"
    case scratchpad = "Scratchpad của phiên Claude"
    case xcodeDelta = "Cache cài app của Xcode"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .trace: "waveform.path.ecg"
        case .tempDerivedData: "hammer"
        case .scratchpad: "brain"
        case .xcodeDelta: "iphone.and.arrow.forward"
        }
    }
    var note: String {
        switch self {
        case .trace: ".ktrace / .trace trong /tmp và $TMPDIR — xctrace để lại khi ghi xong hoặc bị ngắt"
        case .tempDerivedData: "Thư mục -derivedDataPath riêng của từng lần build trong /tmp và $TMPDIR"
        case .scratchpad: "Thư mục tạm của từng phiên Claude Code — ghép với PR mà phiên đó làm"
        case .xcodeDelta: "Bản app cũ Xcode giữ để cài lên máy thật nhanh hơn — tự tạo lại"
        }
    }
}

struct Leftover: Identifiable {
    var id: String { path }
    let path: String
    let kind: LeftoverKind
    let name: String
    var subtitle: String? = nil
    var size: Int64 = 0
    var modified: Date? = nil
    /// Đang được tiến trình khác dùng / vừa ghi gần đây → không bao giờ tự xóa.
    var inUse = false
    /// Trạng thái PR (với scratchpad).
    var prLabel: String? = nil
    var prDone = false

    var age: TimeInterval { modified.map { Date().timeIntervalSince($0) } ?? .infinity }

    /// Có được tự dọn không, với ngưỡng tuổi cho trước.
    func isSafe(minAge: TimeInterval) -> Bool {
        guard !inUse, age >= minAge else { return false }
        switch kind {
        case .trace, .tempDerivedData: return true
        case .scratchpad: return prDone
        case .xcodeDelta: return true
        }
    }
}

enum LeftoverScanner {
    static let recentWrite: TimeInterval = 30 * 60

    static var tmpDirs: [String] {
        var dirs = ["/private/tmp"]
        let t = (NSTemporaryDirectory() as NSString).standardizingPath
        if !t.isEmpty, t != "/private/tmp" { dirs.append(t) }
        return dirs
    }

    /// /private/tmp/claude-<uid>
    static var claudeTmp: String { "/private/tmp/claude-\(getuid())" }

    static func scan() async -> [Leftover] {
        let running = await Shell.run(["ps", "-axo", "command"]).out
        var items: [Leftover] = []
        items += traces()
        items += tempDerivedData()
        items += await scratchpads()
        items += xcodeDeltas()

        return await Parallel.map(items, limit: 6) { item in
            var item = item
            if item.size == 0 { item.size = await DiskUsage.size(of: item.path) ?? 0 }
            if !item.inUse {
                item.inUse = await isInUse(item.path, running: running, isDir: item.kind != .trace)
            }
            return item
        }
        .filter { $0.size > 1024 * 1024 }
        .sorted { $0.size > $1.size }
    }

    // MARK: - Kinds

    private static func traces() -> [Leftover] {
        var result: [Leftover] = []
        for dir in tmpDirs {
            for path in children(of: dir) where path.hasSuffix(".ktrace") || path.hasSuffix(".trace") {
                result.append(Leftover(path: path, kind: .trace, name: name(path),
                                       subtitle: shortDir(dir), modified: modified(path)))
            }
        }
        return result
    }

    private static func tempDerivedData() -> [Leftover] {
        var dirs = tmpDirs
        // dd-* nằm thẳng trong /tmp/claude-<uid>/ (không phải thư mục project bắt đầu bằng "-")
        dirs.append(claudeTmp)
        var result: [Leftover] = []
        for dir in dirs {
            for path in children(of: dir) where !name(path).hasPrefix("-") && looksLikeDerivedData(path) {
                var item = Leftover(path: path, kind: .tempDerivedData, name: name(path),
                                    subtitle: shortDir(dir), modified: newestModification(path))
                if let ws = workspacePath(path) { item.subtitle = shortDir(dir) + "  → " + short(ws) }
                result.append(item)
            }
        }
        return result
    }

    private static func xcodeDeltas() -> [Leftover] {
        let cache = (NSTemporaryDirectory() as NSString).deletingLastPathComponent + "/C"
        let paths = [
            home + "/Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches/AppInstallationBinaryDeltas",
            cache + "/com.apple.DeveloperTools/All/Xcode/EmbeddedAppDeltas",
        ]
        return paths.filter { FileManager.default.fileExists(atPath: $0) }.map {
            Leftover(path: $0, kind: .xcodeDelta, name: name($0), subtitle: short(($0 as NSString).deletingLastPathComponent),
                     modified: newestModification($0))
        }
    }

    /// /tmp/claude-<uid>/<project>/<session>/scratchpad, ghép với transcript
    /// ~/.claude/projects/<project>/<session>.jsonl để biết phiên làm PR nào.
    private static func scratchpads() async -> [Leftover] {
        var result: [Leftover] = []
        var prCache: [String: (String, Bool)?] = [:] // "cwd#N" → (label, done)

        for project in children(of: claudeTmp) where name(project).hasPrefix("-") {
            for session in children(of: project) {
                let pad = session + "/scratchpad"
                guard FileManager.default.fileExists(atPath: pad),
                      let size = await DiskUsage.size(of: pad), size >= 50 * 1024 * 1024 else { continue }
                let transcript = home + "/.claude/projects/\(name(project))/\(name(session)).jsonl"
                let lastActive = modified(transcript) ?? newestModification(pad)

                var item = Leftover(path: pad, kind: .scratchpad, name: String(name(session).prefix(8)),
                                    size: size, modified: lastActive)
                // Phiên còn hoạt động gần đây → coi như đang dùng
                if let lastActive, Date().timeIntervalSince(lastActive) < recentWrite { item.inUse = true }

                if let info = await transcriptInfo(transcript) {
                    item.subtitle = [info.worktree.map { "worktree \($0)" }, info.pr.map { "PR #\($0)" }]
                        .compactMap { $0 }.joined(separator: " · ")
                    if let pr = info.pr, let cwd = info.cwd {
                        let key = "\(cwd)#\(pr)"
                        if prCache[key] == nil { prCache[key] = await prState(pr, cwd: cwd) }
                        if let state = prCache[key] ?? nil {
                            item.prLabel = state.0
                            item.prDone = state.1
                        }
                    }
                } else {
                    item.subtitle = "Không tìm thấy transcript"
                }
                result.append(item)
            }
        }
        return result
    }

    // MARK: - Transcript / PR

    private struct TranscriptInfo { let cwd: String?; let pr: Int?; let worktree: String? }

    /// PR và worktree được nhắc nhiều nhất trong transcript (dùng grep — transcript có thể >150 MB).
    private static func transcriptInfo(_ path: String) async -> TranscriptInfo? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let cwdLine = await Shell.run(["grep", "-m1", "-oE", #""cwd":"[^"]+""#, path]).trimmed
        let cwd = cwdLine.isEmpty ? nil : String(cwdLine.dropFirst(7).dropLast())

        let prs = await Shell.run(["grep", "-oE", #"pull/[0-9]+|PR #[0-9]+"#, path]).out
        var prCounts: [Int: Int] = [:]
        for line in prs.split(separator: "\n") {
            if let n = Int(line.filter(\.isNumber)) { prCounts[n, default: 0] += 1 }
        }

        var wtCounts: [String: Int] = [:]
        if let cwd {
            let parent = (cwd as NSString).deletingLastPathComponent + "/"
            let escaped = parent.map { ".[]()*+?{}|^$\\".contains($0) ? "\\\($0)" : String($0) }.joined()
            let names = await Shell.run(["grep", "-oE", escaped + "[A-Za-z0-9._-]+", path]).out
            for line in names.split(separator: "\n") {
                let n = String(line.dropFirst(parent.count))
                if n != name(cwd) { wtCounts[n, default: 0] += 1 }
            }
        }
        return TranscriptInfo(
            cwd: cwd,
            pr: prCounts.max { $0.value < $1.value }?.key,
            worktree: wtCounts.max { $0.value < $1.value }?.key
        )
    }

    private static func prState(_ number: Int, cwd: String) async -> (String, Bool)? {
        guard FileManager.default.fileExists(atPath: cwd) else { return nil }
        let r = await Shell.run(["gh", "pr", "view", "\(number)", "--json", "state", "--jq", ".state"], cwd: cwd)
        switch r.trimmed {
        case "MERGED": return ("PR #\(number) đã merge", true)
        case "CLOSED": return ("PR #\(number) đã đóng", true)
        case "OPEN": return ("PR #\(number) đang mở", false)
        default: return nil
        }
    }

    // MARK: - Helpers

    private static func isInUse(_ path: String, running: String, isDir: Bool) async -> Bool {
        if running.contains(path) { return true }
        if isDir {
            // Có file nào được ghi trong 30 phút gần đây?
            let r = await Shell.run(["find", path, "-mmin", "-30", "-print", "-quit"])
            if !r.trimmed.isEmpty { return true }
            return false
        }
        return !(await Shell.run(["lsof", "-t", path]).trimmed.isEmpty)
    }

    private static func looksLikeDerivedData(_ path: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: path + "/Build/Intermediates.noindex")
            || fm.fileExists(atPath: path + "/Build/Products")
            || fm.fileExists(atPath: path + "/ModuleCache.noindex")
            || workspacePath(path) != nil
    }

    private static func workspacePath(_ dir: String) -> String? {
        guard let data = FileManager.default.contents(atPath: dir + "/info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["WorkspacePath"] as? String
    }

    private static func children(of dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).map { dir + "/" + $0 }
    }

    private static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// mtime mới nhất trong 2 cấp đầu — đủ để biết build gần nhất lúc nào mà không duyệt cả cây.
    private static func newestModification(_ path: String) -> Date? {
        var newest = modified(path)
        for c in children(of: path) {
            for d in [c] + children(of: c) {
                if let m = modified(d), m > (newest ?? .distantPast) { newest = m }
            }
        }
        return newest
    }

    private static func short(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }

    private static func shortDir(_ dir: String) -> String {
        dir == "/private/tmp" ? "/tmp" : (dir.contains("/var/folders/") ? "$TMPDIR" : short(dir))
    }

    /// Xóa một mục rác. Với delta cache thì xóa nội dung, giữ thư mục.
    static func delete(_ item: Leftover) async -> String? {
        do {
            if item.kind == .xcodeDelta {
                try await DiskUsage.removeContents(of: item.path)
            } else {
                try await DiskUsage.remove(item.path)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
