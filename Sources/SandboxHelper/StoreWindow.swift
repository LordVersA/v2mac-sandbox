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
                // A Menu, not a toolbar Picker: the Picker drew an empty capsule with no name.
                Menu {
                    Picker("Install In", selection: Binding(get: { target?.id }, set: { model.storeTarget = $0 })) {
                        ForEach(gateway.vms) { vm in Text(vm.name).tag(Optional(vm.id)) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(target?.name ?? String(localized: "No mini VM yet"), systemImage: "shippingbox").labelStyle(.titleAndIcon)
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

/// An app's icon from the signed index, else a mark from its id.
struct PluginIcon: View {
    let plugin: PluginManifest
    let size: CGFloat

    var body: some View {
        if let image = plugin.iconSvg.flatMap(PluginManifest.image) {
            Image(nsImage: image).resizable().frame(width: size, height: size).accessibilityHidden(true)
        } else {
            mark
        }
    }

    private var mark: some View {
        let hue = Double(plugin.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % 360) / 360
        return RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
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
            VStack(alignment: .leading, spacing: 24) {
                header
                facts
                if let description = plugin.description { Text(description).font(.title3).lineSpacing(2) }
                section("Permissions") {
                    let asks = plugin.permissions ?? []
                    if asks.isEmpty {
                        Label("No special permissions.", systemImage: "checkmark.shield").foregroundStyle(.secondary)
                    } else {
                        ForEach(asks, id: \.self) { ask in
                            Label {
                                Text(SandboxWindow.permissionText[ask, default: ask])
                            } icon: {
                                Image(systemName: Self.permissionIcon[ask, default: "key"]).foregroundStyle(.tint)
                            }
                        }
                    }
                }
                if let notes = plugin.securityNotes { section("Security Notes") { Text(notes).foregroundStyle(.secondary) } }
                if let changelog = plugin.changelog { section("What's New") { Text(changelog).foregroundStyle(.secondary) } }
                if let source = plugin.source {
                    section("Source") {
                        if let url = URL(string: source.repo) { Link(source.repo, destination: url) }
                        Text("Commit \(String(source.commit.prefix(12)))").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    private static let permissionIcon = ["clipboard": "doc.on.clipboard", "shared": "folder", "ssh-agent": "key"]

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            PluginIcon(plugin: plugin, size: 96)
            VStack(alignment: .leading, spacing: 5) {
                Text(plugin.name).font(.largeTitle.weight(.bold)).lineLimit(2).minimumScaleFactor(0.7)
                if let publisher = plugin.publisher { Text(publisher).font(.title3).foregroundStyle(.secondary).lineLimit(1) }
                Label("Verified: signed by the V2Mac store", systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.medium)).foregroundStyle(.green).lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.green.opacity(0.14), in: .capsule)
                    .padding(.top, 4)
                    .help("Unchanged since it was published. Verified doesn't mean safe: check its permissions.")
            }
            .layoutPriority(1) // the name gets the room first; the button side shrinks
            Spacer(minLength: 16)
            action
        }
    }

    /// The App Store's strip of short facts under the header.
    private var facts: some View {
        HStack(spacing: 0) {
            fact("Version", plugin.version, "number")
            Divider().frame(height: 36)
            fact("Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file), "arrow.down.circle")
            Divider().frame(height: 36)
            fact("Type", plugin.display == "gui" ? String(localized: "Window") : String(localized: "Terminal"),
                 plugin.display == "gui" ? "macwindow" : "apple.terminal")
            Divider().frame(height: 36)
            fact("Permissions", "\((plugin.permissions ?? []).count)", "hand.raised")
        }
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14, style: .continuous))
    }

    private func fact(_ title: LocalizedStringKey, _ value: String, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).textCase(.uppercase)
            Label(value, systemImage: symbol).font(.headline).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var action: some View {
        if let target, let install = gateway.installs[Gateway.installKey(target, plugin.id)] {
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = install.fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                Text(install.fraction.map { String(localized: "Downloading… \(Int($0 * 100))% of \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))") }
                     ?? String(localized: "Installing in \(target.name)…"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(minWidth: 120, maxWidth: 220)
        } else if let target, let installed {
            VStack(alignment: .trailing, spacing: 8) {
                let update = installed.version != plugin.version && !installed.unverified
                HStack {
                    if update {
                        Button("Update") { model.install(plugin, in: target, keeping: installed.granted) }.buttonStyle(.glassProminent)
                        Button("Open") { NSWorkspace.shared.open(StubApps.url(installed, in: target)) }.buttonStyle(.glass)
                    } else {
                        Button("Open") { NSWorkspace.shared.open(StubApps.url(installed, in: target)) }.buttonStyle(.glassProminent)
                    }
                }
                .controlSize(.large)
                Label("Installed in \(target.name)", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.green).lineLimit(1).fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.green.opacity(0.14), in: .capsule)
            }
        } else {
            VStack(alignment: .trailing, spacing: 6) {
                Button("Install") { if let target { model.install(plugin, in: target) } }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .disabled(target == nil || model.store.isExpired || model.state != .running || !gateway.ready)
                if target == nil {
                    Text("Make a mini VM first.").font(.caption).foregroundStyle(.secondary)
                } else if model.state != .running {
                    Text("Start the sandbox to install.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14, style: .continuous))
        }
    }
}
