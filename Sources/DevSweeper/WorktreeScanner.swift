import Foundation

private struct PullRequest: Decodable {
    let number: Int
    let headRefName: String
    let headRefOid: String
    let state: String // OPEN | MERGED | CLOSED
}

private struct RepoContext {
    let path: String
    let defaultRef: String?
    let gone: Set<String>
    let prs: [String: [PullRequest]]
    let allWorktreePaths: [String]
    let derivedData: [(dir: String, workspace: String)]
}

enum WorktreeScanner {
    /// Thư mục build/cache (phải bị .gitignore thì mới được coi là cache).
    static let cacheNames = [
        "node_modules", "Pods", ".build", "build", "DerivedData", ".gradle",
        ".dart_tool", ".next", ".expo", ".turbo", ".cxx", ".parcel-cache",
    ]

    static func scan(roots: [String], fetch: Bool, progress: @escaping @MainActor (String) -> Void) async -> [Repo] {
        await progress("Đang tìm repo…")
        let repoPaths = await findRepos(roots: roots)
        let derived = derivedDataIndex()

        var repos: [Repo] = []
        for (i, path) in repoPaths.enumerated() {
            await progress("[\(i + 1)/\(repoPaths.count)] \((path as NSString).lastPathComponent)")
            if let repo = await scanRepo(path, fetch: fetch, derived: derived) {
                repos.append(repo)
            }
        }
        return repos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Repo

    static func findRepos(roots: [String]) async -> [String] {
        var found = Set<String>()
        for root in roots where FileManager.default.fileExists(atPath: root) {
            var args = ["find", root, "-maxdepth", "6", "("]
            for (i, n) in cacheNames.enumerated() {
                if i > 0 { args.append("-o") }
                args += ["-name", n]
            }
            args += [")", "-prune", "-o", "-name", ".git", "-type", "d", "-print", "-prune"]
            let r = await Shell.run(args)
            for line in r.out.split(separator: "\n") {
                found.insert((String(line) as NSString).deletingLastPathComponent)
            }
        }
        return found.sorted()
    }

    private static func scanRepo(_ path: String, fetch: Bool, derived: [(dir: String, workspace: String)]) async -> Repo? {
        let list = await Shell.run(["git", "-C", path, "worktree", "list", "--porcelain"])
        guard list.ok else { return nil }
        let parsed = parsePorcelain(list.out, repo: path)
        // Chỉ quan tâm repo có worktree phụ
        guard parsed.count > 1 else { return nil }

        if fetch {
            _ = await Shell.run(["git", "-C", path, "fetch", "--prune", "--quiet", "origin"])
        }

        let remote = await Shell.run(["git", "-C", path, "remote", "get-url", "origin"]).trimmed
        let hasGitHub = remote.contains("github.com")

        let ctx = RepoContext(
            path: path,
            defaultRef: await defaultRef(path),
            gone: await goneBranches(path),
            prs: hasGitHub ? await pullRequests(path) : [:],
            allWorktreePaths: parsed.map(\.path),
            derivedData: derived
        )

        let worktrees = await Parallel.map(parsed, limit: 6) { await inspect($0, ctx: ctx) }
        return Repo(path: path, defaultRef: ctx.defaultRef, hasGitHub: hasGitHub, worktrees: worktrees)
    }

    private static func parsePorcelain(_ out: String, repo: String) -> [Worktree] {
        var result: [Worktree] = []
        for block in out.components(separatedBy: "\n\n") {
            var path: String?, head = "", branch: String?
            var locked = false, prunable = false, bare = false
            for line in block.split(separator: "\n").map(String.init) {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                else if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
                else if line.hasPrefix("branch ") {
                    branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "")
                }
                else if line.hasPrefix("locked") { locked = true }
                else if line.hasPrefix("prunable") { prunable = true }
                else if line == "bare" { bare = true }
            }
            guard let path, !bare else { continue }
            result.append(Worktree(
                path: path, repoPath: repo, branch: branch, head: head,
                isMain: result.isEmpty, locked: locked, prunable: prunable
            ))
        }
        return result
    }

    private static func defaultRef(_ repo: String) async -> String? {
        let r = await Shell.run(["git", "-C", repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
        if r.ok, !r.trimmed.isEmpty { return r.trimmed }
        for c in ["origin/main", "origin/master", "origin/develop", "main", "master", "develop"] {
            if await Shell.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", c]).ok { return c }
        }
        return nil
    }

    /// Nhánh local có upstream đã bị xóa trên remote (thường là đã merge + auto delete branch).
    private static func goneBranches(_ repo: String) async -> Set<String> {
        let r = await Shell.run(["git", "-C", repo, "for-each-ref",
                                 "--format=%(refname:short)\t%(upstream:track)", "refs/heads"])
        var set = Set<String>()
        for line in r.out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2, parts[1].contains("gone") { set.insert(String(parts[0])) }
        }
        return set
    }

    private static func pullRequests(_ repo: String) async -> [String: [PullRequest]] {
        let r = await Shell.run(["gh", "pr", "list", "--state", "all", "--limit", "1000",
                                 "--json", "number,headRefName,headRefOid,state"], cwd: repo)
        guard r.ok, let prs = try? JSONDecoder().decode([PullRequest].self, from: Data(r.out.utf8)) else { return [:] }
        return Dictionary(grouping: prs, by: \.headRefName)
    }

    private static func isAncestor(_ commit: String, of ref: String, repo: String) async -> Bool {
        await Shell.run(["git", "-C", repo, "merge-base", "--is-ancestor", commit, ref]).ok
    }

    // MARK: - Worktree

    private static func inspect(_ wt: Worktree, ctx: RepoContext) async -> Worktree {
        var wt = wt
        if wt.prunable {
            wt.state = .prunable
            return wt
        }

        let status = await Shell.run(["git", "-C", wt.path, "status", "--porcelain"])
        wt.dirty = !status.trimmed.isEmpty
        wt.state = await mergeState(wt, ctx: ctx)
        wt.caches = await caches(of: wt, ctx: ctx)
        wt.totalSize = await DiskUsage.size(of: wt.path)
        return wt
    }

    private static func mergeState(_ wt: Worktree, ctx: RepoContext) async -> MergeState {
        if wt.isMain { return .main }
        let base = ctx.defaultRef.map { $0.replacingOccurrences(of: "origin/", with: "") } ?? "nhánh chính"
        let inDefault = await ctx.defaultRef.asyncMap { await isAncestor(wt.head, of: $0, repo: ctx.path) } ?? false

        guard let branch = wt.branch else {
            if inDefault { return .merged("Detached HEAD, đã nằm trong \(base)") }
            let mergedPR = ctx.prs.values.joined().first { $0.state == "MERGED" && $0.headRefOid == wt.head }
            if let pr = mergedPR { return .merged("Detached tại PR #\(pr.number) đã merge") }
            return .unknown("Detached HEAD, không nằm trong \(base)")
        }

        let prs = (ctx.prs[branch] ?? []).sorted { $0.number > $1.number }
        if let pr = prs.first(where: { $0.state == "MERGED" }) {
            var containsHead = pr.headRefOid == wt.head
            if !containsHead { containsHead = await isAncestor(wt.head, of: pr.headRefOid, repo: ctx.path) }
            if containsHead {
                return .merged("PR #\(pr.number) đã merge")
            }
            return .notMerged("PR #\(pr.number) đã merge nhưng còn commit mới sau đó")
        }
        if let pr = prs.first(where: { $0.state == "OPEN" }) { return .open("PR #\(pr.number) đang mở") }
        if inDefault { return .merged("Không có commit riêng, đã nằm trong \(base)") }
        if ctx.gone.contains(branch) { return .likelyMerged("Nhánh trên remote đã bị xóa") }
        if let pr = prs.first(where: { $0.state == "CLOSED" }) {
            return .notMerged("PR #\(pr.number) đã đóng mà không merge")
        }
        return .notMerged("Chưa có PR merge")
    }

    private static func caches(of wt: Worktree, ctx: RepoContext) async -> [CacheDir] {
        // Bỏ qua worktree lồng bên trong (vd .claude/worktrees/*) — chúng được tính riêng
        let nested = ctx.allWorktreePaths.filter { $0 != wt.path && $0.hasPrefix(wt.path + "/") }
        var args = ["find", wt.path, "-maxdepth", "5", "(", "-name", ".git"]
        for n in nested { args += ["-o", "-path", n] }
        args += [")", "-prune", "-o", "-type", "d", "("]
        for (i, n) in cacheNames.enumerated() {
            if i > 0 { args.append("-o") }
            args += ["-name", n]
        }
        args += [")", "-print", "-prune"]
        let found = await Shell.run(args).out.split(separator: "\n").map(String.init)

        var paths: [(String, Bool)] = []
        if !found.isEmpty {
            // Chỉ lấy thư mục bị git ignore → chắc chắn là sinh ra, không phải source
            let ignored = await Shell.run(["git", "-C", wt.path, "check-ignore", "--stdin"],
                                          input: found.joined(separator: "\n") + "\n")
            paths += ignored.out.split(separator: "\n").map { (String($0), false) }
        }

        for dd in ctx.derivedData where owner(of: dd.workspace, among: ctx.allWorktreePaths) == wt.path {
            paths.append((dd.dir, true))
        }

        let sized = await Parallel.map(paths, limit: 4) { p, isDD in
            CacheDir(path: p, size: await DiskUsage.size(of: p) ?? 0, isDerivedData: isDD)
        }
        return sized.filter { $0.size > 0 }.sorted { $0.size > $1.size }
    }

    private static func owner(of path: String, among worktrees: [String]) -> String? {
        worktrees
            .filter { path == $0 || path.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
    }

    /// DerivedData/<Project-hash>/info.plist chứa WorkspacePath → biết thư mục đó thuộc worktree nào.
    static func derivedDataIndex() -> [(dir: String, workspace: String)] {
        let root = home + "/Library/Developer/Xcode/DerivedData"
        let fm = FileManager.default
        var result: [(String, String)] = []
        for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let dir = root + "/" + name
            guard let data = fm.contents(atPath: dir + "/info.plist"),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let ws = plist["WorkspacePath"] as? String else { continue }
            result.append((dir, ws))
        }
        return result
    }
}

extension Optional {
    func asyncMap<U>(_ f: (Wrapped) async -> U) async -> U? {
        guard let self else { return nil }
        return await f(self)
    }
}
