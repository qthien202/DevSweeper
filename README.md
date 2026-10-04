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
- **Rác build**: trace Instruments (`.ktrace`/`.trace`), DerivedData tạm (`-derivedDataPath` trong `/tmp`, `$TMPDIR`), scratchpad của các phiên Claude Code (ghép với PR qua transcript), cache cài app của Xcode
- **Tự dọn mỗi giờ**: chỉ xóa rác cũ hơn ngưỡng (mặc định 24 giờ), không có tiến trình nào dùng, không ghi trong 30 phút; scratchpad chỉ khi PR đã merge/đóng. Ổ dưới ngưỡng (mặc định 30 GB) → thông báo + dọn thêm cache cài app của Xcode
- **Simulator runtime**: dung lượng từng runtime, simulator nào dùng, lần dùng cuối; gỡ bằng `simctl runtime delete`
- **Simulator**: xóa dữ liệu (erase) mà không xóa simulator; **DeviceSupport** đánh dấu máy không cắm hơn 60 ngày
- **Git repo**: dung lượng `.git`, object rời, số pack; chạy `git gc` khi thật sự lấy lại được
- **File lớn**: file ≥ 100 MB–1 GB trong Home, lọc theo lần mở cuối (Spotlight), chuyển vào Thùng rác
- **Gỡ app**: gỡ app kèm dữ liệu trong `~/Library` (Application Support, Caches, Containers, Preferences…), chuyển vào Thùng rác
- **Thư mục lớn**: quét Home 2 cấp, liệt kê thư mục ≥ 50 MB

## Build
```bash
./build.sh
cp -R build/DevSweeper.app /Applications/
```
Yêu cầu macOS 15+. Để kiểm tra PR cần `gh auth login`.
