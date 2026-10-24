import AppKit
import SwiftUI
import V2MacCore

/// The V2Mac Store (plan §7): the signed index's apps with search, and one app's details, installing
/// into the mini VM picked in the toolbar.
struct StoreWindow: View {
    let model: WindowModel
    @State private var search = ""
    @State private var selection: String?

    private var store: StoreClient { model.store }
    private var gateway: Gateway { model.gateway }
    private var target: MiniVM? { gateway.vms.first { $0.id == model.storeTarget } ?? gateway.vms.first }

    private var plugins: [PluginManifest] {
        let all = store.index?.plugins ?? []
        let words = search.split(separator: " ")
        guard !words.isEmpty else { return all }
        return all.filter { p in
            let text = [p.name, p.publisher, p.description].compactMap { $0 }.joined(separator: " ")
            return words.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
    }

    private var selected: PluginManifest? { plugins.first { $0.id == selection } ?? plugins.first }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { selected?.id }, set: { selection = $0 })) {
                ForEach(plugins, id: \.id) { plugin in
                    StoreRow(plugin: plugin, installed: target?.apps.contains { $0.id == plugin.id } == true).tag(plugin.id)
                }
            }
            .overlay { listOverlay }
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
        } detail: {
            if let plugin = selected {
                StoreDetail(plugin: plugin, model: model, target: target).id(plugin.id)
            } else {
                ContentUnavailableView("No App Selected", systemImage: "square.grid.2x2")
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: Text("Search apps"))
        .navigationTitle("V2Mac Store")
        .navigationSubtitle(target.map { String(localized: "Installs into \($0.name)") } ?? String(localized: "No mini VM yet"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker(selection: Binding(get: { target?.id }, set: { model.storeTarget = $0 })) {
                    ForEach(gateway.vms) { vm in Text(vm.name).tag(Optional(vm.id)) }
                } label: {
                    Label("Install In", systemImage: "square.stack.3d.up")
                }
                .help("The mini VM apps are installed into")
                .disabled(gateway.vms.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("More", systemImage: "ellipsis") {
                    Button("Refresh Store", systemImage: "arrow.clockwise") { Task { await store.refresh(force: true) } }
                    if let target {
                        Button("Add from Folder (Unverified)…", systemImage: "folder.badge.questionmark") { model.sideload(into: target) }
                    }
                }
                .menuIndicator(.hidden)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.index != nil, store.isExpired {
                Label("The store index has expired; installs and updates wait for a new one.", systemImage: "clock.badge.exclamationmark")
                    .font(.callout).foregroundStyle(.orange).padding(8).frame(maxWidth: .infinity)
                    .background(.orange.opacity(0.12))
            }
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    @ViewBuilder private var listOverlay: some View {
        if store.index == nil {
            ContentUnavailableView {
                Label("Store Unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text(store.problem ?? String(localized: "Loading the store…"))
            } actions: {
                Button("Try Again") { Task { await store.refresh(force: true) } }
            }
        } else if plugins.isEmpty {
            if search.isEmpty { ContentUnavailableView("No Apps Yet", systemImage: "square.grid.2x2") } else { ContentUnavailableView.search(text: search) }
        }
    }
}

/// An app's mark until store layers carry icons. shortcut: plugin icons aren't fetched yet; draw them
/// from the index once the API carries an icon URL.
struct PluginIcon: View {
    let plugin: PluginManifest
    let size: CGFloat

    var body: some View {
        let hue = Double(plugin.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % 360) / 360
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(Color(hue: hue, saturation: 0.55, brightness: 0.85).gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: plugin.display == "gui" ? "macwindow" : "apple.terminal")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

private struct StoreRow: View {
    let plugin: PluginManifest
    let installed: Bool

    var body: some View {
        HStack(spacing: 10) {
            PluginIcon(plugin: plugin, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plugin.name).fontWeight(.medium).lineLimit(1)
                    if installed {
                        Text("Installed").font(.caption2.weight(.medium)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.green.opacity(0.15), in: .capsule).foregroundStyle(.green)
                    }
                }
                Text(plugin.description ?? plugin.publisher ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct StoreDetail: View {
    let plugin: PluginManifest
    let model: WindowModel
    let target: MiniVM?

    private var gateway: Gateway { model.gateway }
    private var installed: InstalledApp? { target?.apps.first { $0.id == plugin.id } }
    private var size: Int64 { (plugin.layers ?? []).reduce(0) { $0 + $1.size } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let description = plugin.description { Text(description).font(.body) }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    row("Version", plugin.version)
                    row("Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    row("Type", plugin.display == "gui" ? String(localized: "Window app") : String(localized: "Terminal app"))
                    if let publisher = plugin.publisher { row("Publisher", publisher) }
                }
                section("Permissions") {
                    let asks = plugin.permissions ?? []
                    if asks.isEmpty {
                        Text("No special permissions.").foregroundStyle(.secondary)
                    } else {
                        ForEach(asks, id: \.self) { Label(SandboxWindow.permissionText[$0, default: $0], systemImage: "key") }
                    }
                }
                if let notes = plugin.securityNotes { section("Security Notes") { Text(notes) } }
                if let changelog = plugin.changelog { section("What's New") { Text(changelog) } }
                if let source = plugin.source {
                    section("Source") {
                        if let url = URL(string: source.repo) { Link(source.repo, destination: url) }
                        Text("Commit \(String(source.commit.prefix(12)))").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            PluginIcon(plugin: plugin, size: 88)
            VStack(alignment: .leading, spacing: 4) {
                Text(plugin.name).font(.title.weight(.semibold))
                if let publisher = plugin.publisher { Text(publisher).foregroundStyle(.secondary) }
                Label("Verified: signed by the V2Mac store", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
                    .help("Unchanged since it was published. Verified doesn't mean safe: check its permissions.")
                action.padding(.top, 6)
            }
        }
    }

    @ViewBuilder private var action: some View {
        if let target, let install = gateway.installs[Gateway.installKey(target, plugin.id)] {
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = install.fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                Text(install.fraction.map { String(localized: "Downloading… \(Int($0 * 100))% of \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))") }
                     ?? String(localized: "Installing in \(target.name)…"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(width: 240)
        } else if let target, let installed {
            HStack {
                if installed.version != plugin.version, !installed.unverified {
                    Button("Update") { model.install(plugin, in: target, keeping: installed.granted) }.buttonStyle(.glassProminent)
                }
                Button("Open") { NSWorkspace.shared.open(StubApps.url(installed, in: target)) }.buttonStyle(.glass)
                Text("Installed in \(target.name)").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            HStack {
                Button("Install") { if let target { model.install(plugin, in: target) } }
                    .buttonStyle(.glassProminent)
                    .disabled(target == nil || model.store.isExpired || model.state != .running || !gateway.ready)
                if target == nil {
                    Text("Make a mini VM first.").font(.caption).foregroundStyle(.secondary)
                } else if model.state != .running {
                    Text("Start the sandbox to install.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}
