import Foundation

struct ShellResult {
    let out: String
    let err: String
    let code: Int32
    var ok: Bool { code == 0 }
    var trimmed: String { out.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum Shell {
    /// App mở từ Finder không có PATH của shell → lấy PATH từ login shell một lần.
    static let path: String = {
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return fallback }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self)
        return s.isEmpty ? fallback : s + ":" + fallback
    }()

    static func run(_ args: [String], cwd: String? = nil, input: String? = nil) async -> ShellResult {
        await Task.detached(priority: .utility) { runSync(args, cwd: cwd, input: input) }.value
    }

    static func runSync(_ args: [String], cwd: String? = nil, input: String? = nil) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        p.environment = env
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = input != nil ? Pipe() : nil
        p.standardInput = inPipe ?? FileHandle.nullDevice

        do { try p.run() } catch {
            return ShellResult(out: "", err: error.localizedDescription, code: -1)
        }

        let group = DispatchGroup()
        if let inPipe, let input {
            group.enter()
            DispatchQueue.global().async {
                inPipe.fileHandleForWriting.write(Data(input.utf8))
                try? inPipe.fileHandleForWriting.close()
                group.leave()
            }
        }
        var errData = Data()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()

        return ShellResult(
            out: String(decoding: outData, as: UTF8.self),
            err: String(decoding: errData, as: UTF8.self),
            code: p.terminationStatus
        )
    }
}

enum Parallel {
    /// map bất đồng bộ, giới hạn số tác vụ chạy cùng lúc, giữ nguyên thứ tự.
    static func map<T, R>(_ items: [T], limit: Int = 6, _ f: @escaping (T) async -> R) async -> [R] {
        guard !items.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, R).self) { group in
            var results = [R?](repeating: nil, count: items.count)
            var next = 0
            while next < min(limit, items.count) {
                let i = next
                group.addTask { (i, await f(items[i])) }
                next += 1
            }
            while let (i, r) = await group.next() {
                results[i] = r
                if next < items.count {
                    let j = next
                    group.addTask { (j, await f(items[j])) }
                    next += 1
                }
            }
            return results.map { $0! }
        }
    }
}

enum DiskUsage {
    static func size(of path: String) async -> Int64? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let r = await Shell.run(["du", "-sk", path])
        guard let kb = r.out.split(separator: "\t").first.flatMap({ Int64($0) }) else { return nil }
        return kb * 1024
    }

    /// Xóa hẳn (không qua Thùng rác) — chỉ dùng cho cache có thể build lại.
    static func remove(_ path: String) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.removeItem(atPath: path)
        }.value
    }

    static func removeContents(of path: String) async throws {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        for c in children {
            try await remove((path as NSString).appendingPathComponent(c))
        }
    }
}
