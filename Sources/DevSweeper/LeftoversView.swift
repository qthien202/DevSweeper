import SwiftUI

struct LeftoversView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection = Set<String>()

    private var selected: [Leftover] { model.leftovers.filter { selection.contains($0.path) } }
    private func total(_ list: [Leftover]) -> Int64 { list.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.leftovers.isEmpty {
                ContentUnavailableView {
                    if model.leftoverScanning {
                        ProgressView()
                        Text("Đang tìm rác build…")
                    } else {
                        Label("Sạch sẽ", systemImage: "sparkles")
                    }
                } description: {
                    if !model.leftoverScanning {
                        Text("Không có trace, DerivedData tạm hay scratchpad nào đáng kể.")
                    }
                }
            } else {
                List {
                    ForEach(LeftoverKind.allCases) { kind in
                        let rows = model.leftovers.filter { $0.kind == kind }
                        if !rows.isEmpty {
                            SwiftUI.Section {
                                ForEach(rows) { row($0) }
                            } header: {
                                HStack {
                                    Label(kind.rawValue, systemImage: kind.icon).font(.headline)
                                    Spacer()
                                    Text(total(rows).bytes).font(.subheadline.monospacedDigit())
                                }
                            } footer: {
                                Text(kind.note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .navigationTitle("Rác build")
        .toolbar {
            Button {
                Task { await model.scanLeftovers() }
            } label: {
                if model.leftoverScanning { ProgressView().controlSize(.small) }
                else { Label("Quét lại", systemImage: "arrow.clockwise") }
            }
            .disabled(model.leftoverScanning)
        }
        .onChange(of: model.leftovers.map(\.path)) { _, paths in
            selection.formIntersection(paths)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatCard(title: "Tổng rác", value: model.leftoverTotal.bytes)
            StatCard(title: "An toàn để xóa", value: total(model.safeLeftovers).bytes, color: .green)
            StatCard(title: "Còn trống", value: model.disk.free.bytes, color: model.isLowDisk ? .red : .primary)
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if model.autoClean {
                    Label("Tự dọn mỗi giờ · rác cũ hơn \(model.autoCleanMinAgeHours) giờ", systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                    if let last = model.lastAutoClean {
                        Text("Lần cuối \(last.formatted(.relative(presentation: .named))): \(model.lastAutoCleanFreed.bytes)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Label("Tự dọn đang tắt (Cài đặt)", systemImage: "pause.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }

    private func row(_ item: Leftover) -> some View {
        let safe = item.isSafe(minAge: model.autoCleanMinAge)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selection.contains(item.path) },
                set: { on in if on { selection.insert(item.path) } else { selection.remove(item.path) } }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                    if item.inUse { Badge(text: "Đang dùng", color: .blue) }
                    if let pr = item.prLabel { Badge(text: pr, color: item.prDone ? .green : .orange) }
                    if safe && !item.inUse { Badge(text: "An toàn", color: .green) }
                }
                if let s = item.subtitle, !s.isEmpty {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            Text(item.modified.map { $0.formatted(.relative(presentation: .named)) } ?? "")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(item.size.bytes)
                .font(.body.monospacedDigit())
                .frame(width: 80, alignment: .trailing)
            Group {
                if model.busy.contains(item.path) {
                    ProgressView().controlSize(.small)
                } else {
                    Menu {
                        Button("Hiện trong Finder") { model.reveal(item.path) }
                        Divider()
                        Button("Xóa…", role: .destructive) { model.askDeleteLeftovers([item]) }
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
            if selection.contains(item.path) { selection.remove(item.path) } else { selection.insert(item.path) }
        }
    }

    private var footer: some View {
        HStack {
            Button("Chọn mục an toàn (\(model.safeLeftovers.count))") {
                selection = Set(model.safeLeftovers.map(\.path))
            }
            .disabled(model.safeLeftovers.isEmpty)
            Button("Bỏ chọn") { selection = [] }
                .disabled(selection.isEmpty)
            Spacer()
            Text(selection.isEmpty ? "Chưa chọn mục nào" : "Đã chọn \(selection.count) mục · \(total(selected).bytes)")
                .foregroundStyle(.secondary)
            Button("Xóa đã chọn", role: .destructive) { model.askDeleteLeftovers(selected) }
                .disabled(selection.isEmpty)
        }
        .padding(12)
    }
}
