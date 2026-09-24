import Foundation

let home = NSHomeDirectory()

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

struct DiskInfo {
    var total: Int64 = 0
    var free: Int64 = 0
    var used: Int64 { max(total - free, 0) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func current() -> DiskInfo {
        let url = URL(fileURLWithPath: home)
        guard let v = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]) else { return DiskInfo() }
        return DiskInfo(
            total: Int64(v.volumeTotalCapacity ?? 0),
            free: v.volumeAvailableCapacityForImportantUsage ?? 0
        )
    }
}

enum Cleaner {
    /// Xóa toàn bộ nội dung bên trong thư mục (giữ lại thư mục).
    case deleteContents
    /// Chạy một lệnh dọn dẹp chính thức của công cụ.
    case command([String])
}

struct StorageItem: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let icon: String
    let note: String
    let cleaner: Cleaner?
    var size: Int64? = nil
}

enum StorageCatalog {
    static var items: [StorageItem] {
        let lib = home + "/Library"
        let dev = lib + "/Developer"
        return [
            .init(name: "Xcode DerivedData", path: dev + "/Xcode/DerivedData", icon: "hammer",
                  note: "Build cache của Xcode, sẽ tự build lại", cleaner: .deleteContents),
            .init(name: "Simulators", path: dev + "/CoreSimulator/Devices", icon: "iphone",
                  note: "Dọn = xóa các simulator không còn runtime", cleaner: .command(["xcrun", "simctl", "delete", "unavailable"])),
            .init(name: "Simulator caches", path: dev + "/CoreSimulator/Caches", icon: "iphone.gen3.badge.exclamationmark",
                  note: "Cache dyld của simulator", cleaner: .deleteContents),
            .init(name: "iOS DeviceSupport", path: dev + "/Xcode/iOS DeviceSupport", icon: "cable.connector",
                  note: "Symbol của các máy thật đã từng cắm, tải lại khi cần", cleaner: .deleteContents),
            .init(name: "Xcode Archives", path: dev + "/Xcode/Archives", icon: "archivebox",
                  note: "Bản archive + dSYM. Cân nhắc trước khi xóa", cleaner: .deleteContents),
            .init(name: "SwiftPM cache", path: lib + "/Caches/org.swift.swiftpm", icon: "shippingbox",
                  note: "Package Swift đã tải", cleaner: .deleteContents),
            .init(name: "CocoaPods cache", path: lib + "/Caches/CocoaPods", icon: "shippingbox.fill",
                  note: "Pod đã tải", cleaner: .deleteContents),
            .init(name: "Gradle cache", path: home + "/.gradle/caches", icon: "building.columns",
                  note: "Dependency + build cache Android", cleaner: .deleteContents),
            .init(name: "npm cache", path: home + "/.npm/_cacache", icon: "cube.box",
                  note: "Package npm đã tải", cleaner: .deleteContents),
            .init(name: "Yarn cache", path: lib + "/Caches/Yarn", icon: "cube.box.fill",
                  note: "Package yarn đã tải", cleaner: .deleteContents),
            .init(name: "pnpm store", path: lib + "/pnpm/store", icon: "cube",
                  note: "Dọn = pnpm store prune", cleaner: .command(["pnpm", "store", "prune"])),
            .init(name: "Homebrew cache", path: lib + "/Caches/Homebrew", icon: "mug",
                  note: "Dọn = brew cleanup --prune=all", cleaner: .command(["brew", "cleanup", "--prune=all"])),
            .init(name: "Android SDK", path: lib + "/Android/sdk", icon: "apps.iphone",
                  note: "Chỉ thống kê", cleaner: nil),
            .init(name: "Android emulators", path: home + "/.android/avd", icon: "apps.iphone.badge.plus",
                  note: "Chỉ thống kê — xóa trong Android Studio", cleaner: nil),
            .init(name: "Docker", path: lib + "/Containers/com.docker.docker", icon: "shippingbox.circle",
                  note: "Chỉ thống kê — dọn bằng docker system prune", cleaner: nil),
            .init(name: "Library/Caches (tất cả)", path: lib + "/Caches", icon: "tray.full",
                  note: "Chỉ thống kê — gồm cả các mục ở trên", cleaner: nil),
        ]
    }
}

struct CacheDir: Identifiable, Hashable {
    var id: String { path }
    let path: String
    var size: Int64
    let isDerivedData: Bool
}

enum MergeState: Equatable {
    case main
    case merged(String)
    case likelyMerged(String)
    case open(String)
    case notMerged(String)
    case unknown(String)
    case prunable

    var isMerged: Bool { if case .merged = self { return true }; return false }
    var isMergedOrLikely: Bool {
        switch self {
        case .merged, .likelyMerged: return true
        default: return false
        }
    }
}

struct Worktree: Identifiable {
    var id: String { path }
    let path: String
    let repoPath: String
    let branch: String?
    let head: String
    let isMain: Bool
    let locked: Bool
    let prunable: Bool
    var state: MergeState = .unknown("")
    var dirty = false
    var caches: [CacheDir] = []
    var totalSize: Int64? = nil

    var name: String { (path as NSString).lastPathComponent }
    var cacheSize: Int64 { caches.reduce(0) { $0 + $1.size } }
    var canRemove: Bool { !isMain && !locked }
}

struct Repo: Identifiable {
    var id: String { path }
    let path: String
    let defaultRef: String?
    let hasGitHub: Bool
    var worktrees: [Worktree]
    var name: String { (path as NSString).lastPathComponent }
}

struct FolderNode: Identifiable {
    var id: String { path }
    let path: String
    let size: Int64
    var children: [FolderNode]?
    var name: String { (path as NSString).lastPathComponent }
}
