import SwiftUI
import UniformTypeIdentifiers

/// Adds or edits an SFTP site, like WinSCP's Login dialog.
struct SiteEditorSheet: View {
    let isNew: Bool
    let connectAfterSaving: Bool
    let sites: SFTPSites
    let onSave: (SFTPSite) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var site: SFTPSite
    @State private var password = ""
    @State private var hasSavedPassword: Bool
    @State private var portText: String

    init(site: SFTPSite, connect: Bool, sites: SFTPSites = .shared, onSave: @escaping (SFTPSite) -> Void) {
        isNew = sites.sites.contains { $0.id == site.id } == false
        connectAfterSaving = connect
        self.sites = sites
        self.onSave = onSave
        _site = State(initialValue: site)
        _hasSavedPassword = State(initialValue: sites.password(for: site) != nil)
        _portText = State(initialValue: String(site.port))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? L10n.text("New SFTP Site") : L10n.format("Edit “%@”", site.title))
                .font(.system(size: 15, weight: .semibold))
            Form {
                TextField(L10n.text("Name:"), text: $site.name, prompt: Text(site.endpoint.displayName))
                TextField(L10n.text("Host:"), text: $site.host, prompt: Text("server.example.com"))
                    .accessibilityIdentifier("site-host")
                TextField(L10n.text("Port:"), text: $portText)
                    .onChange(of: portText) { _, text in site.port = Int(text.filter(\.isNumber)) ?? 0 }
                TextField(L10n.text("User name:"), text: $site.username)
                    .accessibilityIdentifier("site-user")
                Picker(L10n.text("Sign in with:"), selection: $site.authentication) {
                    Text(L10n.text("Password")).tag(SFTPSite.Authentication.password)
                    Text(L10n.text("Private key")).tag(SFTPSite.Authentication.privateKey)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("site-auth")
                if site.authentication == .password {
                    SecureField(L10n.text("Password:"), text: $password,
                                prompt: Text(hasSavedPassword ? L10n.text("Saved in Keychain") : L10n.text("Ask when connecting")))
                    if hasSavedPassword {
                        Button(L10n.text("Forget Saved Password")) {
                            sites.setPassword(nil, for: site)
                            hasSavedPassword = false
                        }
                    }
                } else {
                    LabeledContent(L10n.text("Key file:")) {
                        HStack {
                            TextField("", text: $site.keyPath, prompt: Text("~/.ssh/id_ed25519"))
                                .labelsHidden()
                                .accessibilityIdentifier("site-key")
                            Button(L10n.text("Choose…"), action: chooseKey)
                        }
                    }
                    Text(L10n.text("Ed25519, ECDSA or RSA keys in OpenSSH or PEM format. Foldera asks for the passphrase if the key has one."))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText.swiftUI)
                }
                TextField(L10n.text("Start folder:"), text: $site.startPath, prompt: Text(L10n.text("Login folder")))
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button(L10n.text("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if connectAfterSaving {
                    Button(L10n.text("Save")) { save(connect: false) }
                        .disabled(!site.isComplete)
                }
                Button(connectAfterSaving ? L10n.text("Save and Connect") : L10n.text("Save")) { save(connect: connectAfterSaving) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!site.isComplete)
            }
        }
        .font(Theme.font)
        .padding(20)
        .frame(width: 460)
    }

    private func save(connect: Bool) {
        var saved = site
        saved.host = saved.host.trimmingCharacters(in: .whitespaces)
        sites.save(saved, password: password.isEmpty ? nil : password)
        dismiss()
        if connect { onSave(saved) }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.prompt = L10n.text("Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        site.keyPath = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Finder's Connect to Server: an address plus recently used ones.
struct ConnectServerSheet: View {
    let model: ExplorerWindowModel
    @State var address: String
    @Environment(\.dismiss) private var dismiss
    @State private var recent = RecentServers.all()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Connect to Server"))
                .font(.system(size: 15, weight: .semibold))
            TextField(L10n.text("Server address"), text: $address, prompt: Text("smb://server/share  ·  sftp://user@server"))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("server-address")
                .onSubmit(connect)
            Text(L10n.text("SMB, AFP, NFS and WebDAV servers are mounted by macOS. SFTP servers open in Foldera."))
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.swiftUI)
            if !recent.isEmpty {
                Text(L10n.text("Recent servers"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText.swiftUI)
                List(recent, id: \.self, selection: Binding(get: { address }, set: { address = $0 ?? address })) { server in
                    Text(server).lineLimit(1).truncationMode(.middle)
                        .onTapGesture(count: 2) {
                            address = server
                            connect()
                        }
                        .simultaneousGesture(TapGesture().onEnded { address = server })
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: 120)
            }
            HStack {
                if !recent.isEmpty {
                    Button(L10n.text("Clear Recent")) {
                        RecentServers.clear()
                        recent = []
                    }
                }
                Spacer()
                Button(L10n.text("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("Connect"), action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(URL(string: address.trimmingCharacters(in: .whitespaces))?.scheme == nil)
            }
        }
        .font(Theme.font)
        .padding(20)
        .frame(width: 440)
    }

    private func connect() {
        let text = address.trimmingCharacters(in: .whitespaces)
        // Plain host names default to SMB, like Finder.
        let full = text.contains("://") ? text : "smb://" + text
        dismiss()
        if !model.openServerAddress(full, mountWebAddresses: true) {
            BrowserTab.present(RemoteError.failed(L10n.format("“%@” isn’t a server address Foldera can connect to.", text)))
        }
    }
}
