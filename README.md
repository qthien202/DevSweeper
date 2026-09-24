# DevSweeper

App macOS (SwiftUI, menu bar + cửa sổ) dọn dẹp dung lượng cho dev iOS / React Native / Android.

## Tính năng
- **Worktrees**: quét các repo trong thư mục project, liệt kê mọi `git worktree`, kiểm tra đã merge chưa:
  - PR đã merge qua GitHub CLI (`gh`) — nhận được cả **squash merge**
  - Commit đã nằm trong nhánh mặc định (`origin/HEAD`)
  - Nhánh remote đã bị xóa (`[gone]`)
- Tính **cache build** của từng worktree: `node_modules`, `.build`, `Pods`, `build`, `.gradle`… (chỉ những thư mục bị `.gitignore`) + **DerivedData** của Xcode (map qua `WorkspacePath` trong `info.plist`)
- Xóa cache hoặc xóa hẳn worktree đã merge (từng cái hoặc hàng loạt; worktree có thay đổi chưa commit bị loại khỏi thao tác hàng loạt)
- **Dung lượng**: thống kê DerivedData, Simulators, DeviceSupport, Archives, SwiftPM, CocoaPods, Gradle, npm, Yarn, pnpm, Homebrew, Docker…
- **Thư mục lớn**: quét Home 2 cấp, liệt kê thư mục ≥ 50 MB

## Build
```bash
./build.sh
cp -R build/DevSweeper.app /Applications/
```
Yêu cầu macOS 15+. Để kiểm tra PR cần `gh auth login`.
