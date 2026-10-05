import AppKit
import SwiftUI

/// "Compress to…" sheet: the archive's name, folder, format, compression level and an optional password.
struct CompressSheet: View {
    let items: [URL]
    let onCompress: (_ options: Archives.Options, _ name: String, _ folder: URL) -> Void

    @AppStorage("compress.format") private var format: Archives.Format = .zip
    @AppStorage("compress.level") private var level: Archives.Level = .normal
    @AppStorage("compress.zipEncryption") private var zipEncryption: Archives.ZipEncryption = .aes256
    @State private var name: String
    @State private var folder: URL
    @State private var password = ""
    @State private var confirmation = ""
    @State private var showsPassword = false
    @State private var encryptNames = true
    @Environment(\.dismiss) private var dismiss

    init(items: [URL], fallbackFolder: URL, name: String? = nil, password: String = "", confirmation: String = "",
         onCompress: @escaping (Archives.Options, String, URL) -> Void) {
        self.items = items
        self.onCompress = onCompress
        _name = State(initialValue: name ?? Archives.defaultName(for: items))
        _password = State(initialValue: password)
        _confirmation = State(initialValue: confirmation)
        _folder = State(initialValue: Archives.archiveURL(for: items, fallbackFolder: fallbackFolder)?.deletingLastPathComponent() ?? fallbackFolder)
    }

    /// Without the bundled 7-Zip only Finder-style zips can be made.
    private var canCustomize: Bool { Archives.canCreate7z }
    private var effectiveFormat: Archives.Format { canCustomize ? format : .zip }

    private var options: Archives.Options {
        var options = Archives.Options(format: effectiveFormat, level: canCustomize ? level : .normal)
        options.password = canCustomize && !password.isEmpty ? password : nil
        options.zipEncryption = zipEncryption
        options.encryptNames = encryptNames
        return options
    }

    /// Why Compress is unavailable, if it is.
    private var problem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." || trimmed.contains("/") || trimmed.contains(":") || trimmed.contains("\0") {
            return L10n.text("Enter a valid archive name.")
        }
        if !password.isEmpty {
            if !Archives.Options.isValidPassword(password, for: effectiveFormat) {
                return L10n.text("ZIP passwords can only use English letters, digits and symbols.")
            }
        }
        return nil
    }

    /// Typed twice unless shown; a mismatch is only reported once something is in the second field.
    private var passwordsMatch: Bool { showsPassword || password == confirmation }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(items.count == 1 ? L10n.format("Compress “%@”", items[0].lastPathComponent) : L10n.format("Compress %lld items", items.count))
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Form {
                LabeledContent(L10n.text("Archive name:")) {
                    HStack(spacing: 4) {
                        TextField("", text: $name)
                            .labelsHidden()
                            .accessibilityIdentifier("compress-name")
                        if Archives.fileName(name, format: effectiveFormat) != name.trimmingCharacters(in: .whitespacesAndNewlines) {
                            Text("." + effectiveFormat.fileExtension)
                                .foregroundStyle(Theme.secondaryText.swiftUI)
                        }
                    }
                }
                LabeledContent(L10n.text("Save in:")) {
                    HStack {
                        Text(FileManager.default.displayName(atPath: folder.path))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .hint(folder.path)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(L10n.text("Choose…"), action: chooseFolder)
                    }
                }
                if canCustomize {
                    Picker(L10n.text("Format:"), selection: $format) {
                        Text("ZIP").tag(Archives.Format.zip)
                        Text("7z").tag(Archives.Format.sevenZip)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("compress-format")
                    Picker(L10n.text("Compression:"), selection: $level) {
                        Text(L10n.text("Store (no compression)")).tag(Archives.Level.store)
                        Text(L10n.text("Fastest")).tag(Archives.Level.fastest)
                        Text(L10n.text("Normal")).tag(Archives.Level.normal)
                        Text(L10n.text("Maximum")).tag(Archives.Level.maximum)
                        Text(L10n.text("Ultra (slowest)")).tag(Archives.Level.ultra)
                    }
                    .accessibilityIdentifier("compress-level")
                    passwordFields
                }
            }
            .formStyle(.columns)

            HStack {
                if let message = problem ?? (passwordsMatch || confirmation.isEmpty ? nil : L10n.text("The passwords don’t match.")) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer()
                Button(L10n.text("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("Compress")) {
                    onCompress(options, name, folder)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil || !passwordsMatch)
                .accessibilityIdentifier("compress-confirm")
            }
        }
        .font(Theme.font)
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder
    private var passwordFields: some View {
        Group {
            if showsPassword {
                TextField(L10n.text("Password:"), text: $password, prompt: Text(L10n.text("None")))
            } else {
                SecureField(L10n.text("Password:"), text: $password, prompt: Text(L10n.text("None")))
                SecureField(L10n.text("Confirm:"), text: $confirmation)
                    .disabled(password.isEmpty)
            }
        }
        .accessibilityIdentifier("compress-password")
        Toggle(L10n.text("Show password"), isOn: $showsPassword)
        // Shown before a password is typed, so the sheet doesn't grow under the pointer; they apply only with one.
        Group {
            switch effectiveFormat {
            case .zip:
                Picker(L10n.text("Encryption:"), selection: $zipEncryption) {
                    Text("AES-256").tag(Archives.ZipEncryption.aes256)
                    Text("ZipCrypto").tag(Archives.ZipEncryption.zipCrypto)
                }
                Text(zipEncryption == .aes256
                     ? L10n.text("Secure. Opens on a Mac and in 7-Zip; Windows File Explorer may not open it.")
                     : L10n.text("Opens almost anywhere, including Windows File Explorer, but is easy to break."))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText.swiftUI)
            case .sevenZip:
                Toggle(L10n.text("Encrypt file names"), isOn: $encryptNames)
            }
        }
        .disabled(password.isEmpty)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Compress")
        panel.prompt = L10n.text("Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
    }
}
