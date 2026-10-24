import AppKit
import SwiftUI
import V2MacCore

/// The Sandbox window (plan M2): mini VMs in the sidebar; the selected one's exit, apps and
/// privacy switches in the detail. The VM's power lives in the toolbar.
struct SandboxWindow: View {
    let model: WindowModel
    @State private var selection: MiniVM.ID?
    @State private var confirm: (title: String, action: () -> Void)?

    private var gateway: Gateway { model.gateway }
    private var selected: MiniVM? { gateway.vms.first { $0.id == selection } ?? gateway.vms.first }

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            detail
        }
        .navigationTitle("V2Mac Sandbox")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { power }
            ToolbarItem(placement: .primaryAction) { addMenu.disabled(model.state != .running || !gateway.ready) }
        }
        .frame(minWidth: 720, minHeight: 480)
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Continue", role: .destructive) { confirm?.action() }
        } message: {
            Text("This can't be undone.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { selected?.id }, set: { selection = $0 })) {
            Section("Mini VMs") {
                ForEach(gateway.vms) { vm in
                    HStack(spacing: 10) {
                        VMBadge(vm: vm, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(vm.name).lineLimit(1)
                            Text(vm.apps.isEmpty ? String(localized: "No apps") : String(localized: "\(vm.apps.count) apps"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        statusDot(gateway.exits[vm.id] ?? .unknown)
                    }
                    .padding(.vertical, 2)
                    .tag(vm.id)
                    .contextMenu { vmActions(vm) }
                }
            }
        }
        .overlay {
            if gateway.vms.isEmpty {
                Text("No mini VMs yet").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }

    private func statusDot(_ status: Gateway.ExitStatus) -> some View {
        let color: Color = switch status {
        case .ok: .green
        case .down: .red
        case .none: .secondary
        case .unknown: .orange
        }
        return Circle().fill(color).frame(width: 7, height: 7).accessibilityLabel(exitText(status))
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch model.state {
        case .stopped:
            ContentUnavailableView {
                Label("Sandbox is stopped", systemImage: "shield.lefthalf.filled.slash")
            } description: {
                Text("Start it to open your apps. Each mini VM reaches the internet only through the server you pick for it.")
            } actions: {
                Button("Start Sandbox") { model.start() }.buttonStyle(.glassProminent).controlSize(.large)
            }
        case .booting, .stopping:
            ContentUnavailableView {
                Label {
                    Text(model.state == .booting ? "Starting the sandbox…" : "Stopping the sandbox…")
                } icon: {
                    Image(systemName: "shield.lefthalf.filled").symbolEffect(.pulse, isActive: true)
                }
            } description: {
                ProgressView().controlSize(.small)
            }
        case .running:
            if let vm = selected {
                VMDetail(vm: vm, model: model, confirm: $confirm, actions: vmActions)
                    .id(vm.id)
            } else {
                ContentUnavailableView {
                    Label("No mini VMs", systemImage: "square.stack.3d.up")
                } description: {
                    Text("A mini VM is a separate computer for your apps, with its own exit and its own data.")
                } actions: {
                    addMenu.buttonStyle(.glassProminent).controlSize(.large).fixedSize().disabled(!gateway.ready)
                }
            }
        }
    }

    // MARK: Toolbar

    @ViewBuilder private var power: some View {
        switch model.state {
        case .stopped: Button("Start", systemImage: "play.fill") { model.start() }.help("Start the sandbox")
        case .running: Button("Stop", systemImage: "stop.fill") { model.stop() }.help("Stop the sandbox and close its apps")
        case .booting, .stopping:
            // In a button, so the toolbar gives it the same round glass as its neighbours, not a sliver.
            Button {} label: { ProgressView().controlSize(.small).frame(width: 18, height: 18) }
                .disabled(true)
                .help(model.state == .booting ? "Starting the sandbox…" : "Stopping the sandbox…")
        }
    }

    private var addMenu: some View {
        Menu("New Mini VM", systemImage: "plus") {
            Button("Empty Mini VM") { select(gateway.add()) }
            if let templates = model.store.index?.templates, !templates.isEmpty {
                Section("From a Template") { ForEach(templates, id: \.id) { t in Button(t.name) { addFromTemplate(t) } } }
            }
            if !gateway.vms.isEmpty {
                Section("Clone with Apps and Data") { ForEach(gateway.vms) { vm in Button(vm.name) { select(gateway.add(cloning: vm)) } } }
            }
        }
        .help("Add a mini VM")
    }

    private func select(_ vm: MiniVM?) { if let vm { selection = vm.id } }

    private func openTerminal(_ vm: MiniVM) {
        do { try gateway.openTerminal(vm) } catch { NSAlert(error: error).runModal() }
    }

    @ViewBuilder private func vmActions(_ vm: MiniVM) -> some View {
        Button("Open Terminal", systemImage: "apple.terminal") { openTerminal(vm) }
        Button("Show Shared Folder", systemImage: "folder") { NSWorkspace.shared.open(gateway.sharedFolder(vm)) }
        Button("Clone", systemImage: "plus.square.on.square") { select(gateway.add(cloning: vm)) }
        Divider()
        Button("Wipe Data…", systemImage: "eraser") { confirm = (String(localized: "Wipe all data of \(vm.name)?"), { gateway.wipe(vm) }) }
        Button("Delete…", systemImage: "trash", role: .destructive) { confirm = (String(localized: "Delete \(vm.name) and all its data?"), { gateway.delete(vm) }) }
    }

    private var subtitle: String {
        switch model.state {
        case .stopped: String(localized: "Stopped")
        case .booting: String(localized: "Starting…")
        case .running: String(localized: "Running")
        case .stopping: String(localized: "Stopping…")
        }
    }

    /// A new mini VM named after the template with its apps (plan "Add": Template); one approval for all.
    private func addFromTemplate(_ template: StoreIndex.Template) {
        let plugins = template.plugins.compactMap { model.store.index?.plugin($0) }
        let asks = Array(Set(plugins.flatMap { $0.permissions ?? [] })).sorted()
        guard !model.store.isExpired, let granted = Self.approve(plugins.map(\.name).joined(separator: ", "), asks: asks, into: template.name),
              let vm = gateway.add(name: template.name) else { return }
        selection = vm.id
        Task {
            for plugin in plugins {
                do { try await gateway.install(store: plugin, granted: (plugin.permissions ?? []).filter(granted.contains), in: vm, download: model.download) }
                catch { NSAlert(error: error).runModal() }
            }
        }
    }

    /// Asks the user to approve an app's permissions (plan §6); nil when cancelled.
    static func approve(_ name: String, asks: [String], into vm: String, note: String? = nil) -> [String]? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Install \(name) in \(vm)?")
        let lines = asks.map { "• " + permissionText[$0, default: $0] }
        alert.informativeText = ([note].compactMap { $0 } + (asks.isEmpty ? [] : [String(localized: "It asks to:")] + lines)).joined(separator: "\n")
        alert.addButton(withTitle: asks.isEmpty ? String(localized: "Install") : String(localized: "Allow and Install"))
        if !asks.isEmpty { alert.addButton(withTitle: String(localized: "Install Without These")) }
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return asks
        case .alertSecondButtonReturn where !asks.isEmpty: return []
        default: return nil
        }
    }

    static let permissionText = [
        "ssh-agent": String(localized: "Use the SSH keys in your Mac's ssh-agent while it is open"),
        "clipboard": String(localized: "Use the clipboard"),
        "shared": String(localized: "Read and write this mini VM's Shared folder"),
    ]
}

func exitText(_ status: Gateway.ExitStatus) -> String {
    switch status {
    case .ok(let place): place
    case .down: String(localized: "Not connected")
    case .none: String(localized: "Blocked")
    case .unknown: String(localized: "Checking…")
    }
}

/// A mini VM's colour mark: its initial on its hue.
struct VMBadge: View {
    let vm: MiniVM
    let size: CGFloat

    var body: some View {
        let color = Color(hue: vm.hue, saturation: 0.55, brightness: 0.85)
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(vm.name.prefix(1).uppercased())
                    .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .overlay(alignment: .bottomTrailing) {
                if vm.disposable {
                    Image(systemName: "flame.fill")
                        .font(.system(size: size * 0.3))
                        .foregroundStyle(.orange)
                        .background(Circle().fill(.background).padding(-2))
                        .offset(x: 3, y: 3)
                }
            }
            .accessibilityHidden(true)
    }
}

/// One mini VM: header, exit, apps, privacy.
private struct VMDetail<Actions: View>: View {
    let vm: MiniVM
    let model: WindowModel
    @Binding var confirm: (title: String, action: () -> Void)?
    let actions: (MiniVM) -> Actions

    private var gateway: Gateway { model.gateway }
    private var status: Gateway.ExitStatus { gateway.exits[vm.id] ?? .unknown }

    var body: some View {
        Form {
            Section { header }
            Section {
                Picker(selection: Binding(get: { vm.exit }, set: { gateway.setExit(vm, $0) })) {
                    Label("No exit (blocked)", systemImage: "nosign").tag(String?.none)
                    Divider()
                    ForEach(gateway.servers, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                } label: {
                    Label("Server", systemImage: "point.3.connected.trianglepath.dotted")
                }
                LabeledContent {
                    exitLabel
                } label: {
                    Label("Exit", systemImage: "globe")
                }
            } header: {
                Text("Network")
            } footer: {
                Text("Every app here reaches the internet only through this server. Without one, all its traffic is blocked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Apps") { apps }
            Section {
                Toggle(isOn: Binding(get: { vm.pasteIn }, set: { gateway.setClipboard(vm, pasteIn: $0) })) {
                    Label("Paste from Mac", systemImage: "arrow.down.doc")
                }
                Toggle(isOn: Binding(get: { vm.copyOut }, set: { gateway.setClipboard(vm, copyOut: $0) })) {
                    Label("Copy to Mac", systemImage: "arrow.up.doc")
                }
                Toggle(isOn: Binding(get: { vm.disposable }, set: { gateway.setDisposable(vm, $0) })) {
                    Label {
                        Text("Disposable")
                        Text("Its data is erased each time the sandbox stops.")
                    } icon: {
                        Image(systemName: "flame")
                    }
                }
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.open(gateway.sharedFolder(vm)) }
                } label: {
                    Label("Shared folder", systemImage: "folder")
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Apps also need the clipboard permission to use the clipboard.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(!gateway.ready)
    }

    private var header: some View {
        HStack(spacing: 14) {
            VMBadge(vm: vm, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(vm.name).font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    exitLabel
                    if vm.disposable {
                        Text("Disposable").font(.caption.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.15), in: .capsule).foregroundStyle(.orange)
                    }
                }
                .font(.callout)
            }
            Spacer()
            Button {
                do { try gateway.openTerminal(vm) } catch { NSAlert(error: error).runModal() }
            } label: {
                Label("Terminal", systemImage: "apple.terminal")
            }
            .buttonStyle(.glass)
            .help("Open a shell in \(vm.name), through its exit")
            Menu {
                actions(vm)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var exitLabel: some View {
        switch status {
        case .ok(let place): Label(place, systemImage: "checkmark.shield.fill").foregroundStyle(.green)
        case .down: Label("Not connected", systemImage: "exclamationmark.shield.fill").foregroundStyle(.red)
        case .none: Label("Blocked", systemImage: "nosign").foregroundStyle(.secondary)
        case .unknown: HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking…").foregroundStyle(.secondary) }
        }
    }

    // MARK: Apps

    private var apps: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 12)], alignment: .leading, spacing: 12) {
            ForEach(vm.apps) { app in appTile(app) }
            ForEach(pending, id: \.key) { installTile($0.value) }
            addAppTile
        }
        .padding(.vertical, 6)
    }

    private func appTile(_ app: InstalledApp) -> some View {
        let revoked = model.store.index?.revocation(of: app)
        let newer = model.store.index?.plugin(app.id).flatMap { $0.version != app.version && !app.unverified ? $0 : nil }
        return Button {
            NSWorkspace.shared.open(StubApps.url(app, in: vm))
        } label: {
            VStack(spacing: 6) {
                Image(systemName: app.display == "gui" ? "macwindow" : "apple.terminal")
                    .font(.system(size: 26))
                    .frame(width: 52, height: 52)
                    .background(Color(hue: vm.hue, saturation: 0.25, brightness: 0.95).opacity(0.35).gradient,
                                in: .rect(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if revoked != nil {
                            badge("exclamationmark.octagon.fill", .red)
                        } else if newer != nil {
                            badge("arrow.down.circle.fill", .blue)
                        } else if app.unverified {
                            badge("questionmark.circle.fill", .orange)
                        }
                    }
                Text(app.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(revoked.map { String(localized: "Withdrawn from the store: \($0.reason)") }
            ?? (app.unverified ? String(localized: "Unverified: sideloaded, not from the V2Mac store") : String(localized: "Open \(app.name)")))
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(StubApps.url(app, in: vm)) }
            if let newer { Button("Update to \(newer.version)", systemImage: "arrow.down.circle") { model.install(newer, in: vm, keeping: app.granted) } }
            Button("Verify Installation…", systemImage: "checkmark.seal") { verify(app) }
            Divider()
            Button("Remove \(app.name)", systemImage: "trash", role: .destructive) { gateway.uninstall(app, from: vm) }
        }
    }

    /// Store installs into this mini VM that haven't finished.
    private var pending: [(key: String, value: Gateway.Install)] {
        gateway.installs.filter { $0.key.hasPrefix(vm.id + "/") }.sorted { $0.key < $1.key }
    }

    private func installTile(_ install: Gateway.Install) -> some View {
        VStack(spacing: 6) {
            Group {
                if let fraction = install.fraction {
                    ProgressView(value: fraction).progressViewStyle(.circular)
                } else {
                    ProgressView()
                }
            }
            .controlSize(.small)
            .frame(width: 52, height: 52)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12, style: .continuous))
            Text(install.name).font(.caption).lineLimit(1)
            Text(install.fraction.map { String(localized: "Downloading \(Int($0 * 100))%") } ?? String(localized: "Installing…"))
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private func badge(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol).symbolRenderingMode(.palette).foregroundStyle(.white, color)
            .font(.system(size: 14)).offset(x: 5, y: -5)
    }

    private var addAppTile: some View {
        Button { model.openStore(vm.id) } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 52, height: 52)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                Text("Add App").font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Get apps for \(vm.name) from the V2Mac Store")
    }

    /// Verify Installation (plan §7): where it came from and whether its layers are unchanged since
    /// published. "Verified" means unchanged, not safe.
    private func verify(_ app: InstalledApp) {
        let granted = app.granted.isEmpty ? String(localized: "none") : app.granted.joined(separator: ", ")
        var lines = [String(localized: "Version \(app.version)"), String(localized: "Permissions: \(granted)")]
        if app.unverified {
            lines.append(String(localized: "Unverified: sideloaded from a folder, not from the V2Mac store."))
        } else {
            if let source = app.source { lines.append(String(localized: "Source: \(source.repo) at \(source.commit)")) }
            let listed = model.store.index?.plugin(app.id)
            lines.append(listed?.version == app.version && listed?.layers == app.layers ? String(localized: "Listed in the signed store index.") : String(localized: "Not in the current signed store index as installed."))
            if let revoked = model.store.index?.revocation(of: app) { lines.append(String(localized: "Withdrawn: \(revoked.reason)")) }
            let intact = app.layers.allSatisfy { (try? SandboxFiles.sha256(of: gateway.layerCache.appendingPathComponent($0.sha256))) == $0.sha256 }
            lines.append(intact ? String(localized: "Layers re-hashed: unchanged since published.") : String(localized: "Layers re-hashed: CHANGED or missing."))
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "\(app.name) in \(vm.name)")
        alert.informativeText = lines.joined(separator: "\n")
        alert.runModal()
    }
}
