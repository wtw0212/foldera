import SwiftUI

/// "Rename N Items" sheet: Finder's Replace Text / Add Text / Format, with a live before → after list.
struct BulkRenameSheet: View {
    let items: [FileItem]
    let onDone: (_ renamed: [URL]) -> Void

    @State private var rule = BulkRenameRule()
    @Environment(\.dismiss) private var dismiss

    private var renameItems: [BulkRename.Item] {
        items.map { BulkRename.Item(url: $0.url, date: $0.dateModified) }
    }

    private var folders: Set<URL> { Set(items.filter(\.isNavigable).map(\.url)) }

    var body: some View {
        let newNames = BulkRename.newNames(for: renameItems, rule: rule, folders: folders)
        let problems = BulkRename.problems(for: renameItems, newNames: newNames)
        let changed = zip(items, newNames).filter { $0.0.name != $0.1 }.count

        VStack(alignment: .leading, spacing: 14) {
            Text("Rename \(items.count) items")
                .font(.system(size: 15, weight: .semibold))

            Picker("", selection: $rule.mode) {
                ForEach(BulkRenameRule.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            options
                .frame(minHeight: 96, alignment: .top)

            preview(newNames: newNames, problems: problems)

            HStack {
                if !problems.isEmpty {
                    Label("\(problems.count) name\(problems.count == 1 ? "" : "s") can’t be used", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text(changed == 1 ? "1 item will be renamed" : "\(changed) items will be renamed")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { rename(newNames) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!problems.isEmpty || changed == 0)
            }
            .font(Theme.font)
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }

    @ViewBuilder
    private var options: some View {
        Form {
            switch rule.mode {
            case .replace:
                TextField("Find:", text: $rule.find)
                TextField("Replace with:", text: $rule.replaceWith)
                HStack {
                    Toggle("Match case", isOn: $rule.matchCase)
                    Toggle("Include extension", isOn: $rule.includeExtension)
                }
            case .add:
                HStack {
                    TextField("Add:", text: $rule.addText)
                    Picker("", selection: $rule.addPosition) {
                        ForEach(BulkRenameRule.Position.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            case .format:
                HStack {
                    Picker("Name format:", selection: $rule.formatStyle) {
                        ForEach(BulkRenameRule.FormatStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Where:", selection: $rule.formatPosition) {
                        ForEach(BulkRenameRule.Position.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .fixedSize()
                }
                HStack {
                    TextField("Custom format:", text: $rule.customFormat)
                    if rule.formatStyle != .date {
                        TextField("Start numbers at:", value: $rule.startNumber, format: .number)
                            .frame(width: 180)
                    }
                }
                if rule.formatStyle == .date {
                    Text("Uses each item’s date modified.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.columns)
    }

    private func preview(newNames: [String], problems: [Int: String]) -> some View {
        List {
            ForEach(Array(zip(items, newNames).enumerated()), id: \.offset) { index, pair in
                let (item, newName) = pair
                HStack(spacing: 8) {
                    Image(nsImage: FileIcons.icon(for: item))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(item.name)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(newName)
                        .fontWeight(newName == item.name ? .regular : .medium)
                        .foregroundStyle(problems[index] == nil ? Color.primary : Color.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(problems[index] ?? newName)
                }
                .font(Theme.font)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
    }

    private func rename(_ newNames: [String]) {
        let renames = zip(items, newNames).map { item, name in
            (from: item.url, to: item.url.deletingLastPathComponent().appendingPathComponent(name))
        }
        do {
            let done = try BulkRename.apply(renames)
            FileUndo.shared.record(.batchRenamed(done), name: "Rename")
            onDone(done.map(\.to))
            dismiss()
        } catch let failure as FileChange.Failure {
            FileUndo.shared.record(failure.remaining, name: "Rename")
            if case .batchRenamed(let remaining) = failure.remaining { onDone(remaining.map(\.to)) }
            dismiss()
            BrowserTab.present(failure)
        } catch {
            BrowserTab.present(error)
        }
    }
}
