// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SommelierKit
import SwiftUI

/// The steps of setting up DirectX 12 (Apple's D3DMetal) from the player's own Game Porting Toolkit download: for a
/// different version than the one Sommelier installs by itself, or when that download failed.
enum D3DSetupStep {
    /// What this is and why; a button opens Apple's download page.
    case intro
    /// Apple's page is open; Sommelier watches Downloads (and mounted disks) for the toolkit.
    case waiting
    /// The disk image asks for Apple's license before it opens; Finder shows it.
    case needsDiskLicense(URL)
    /// Checking Apple's signature and copying D3DMetal out.
    case checking
    /// D3DMetal checked; Apple's license shown for the user to accept.
    case license(StagedD3DMetal, String)
    case installing
    case done(String)
    case failed(String)
}

extension AppModel {
    static func isGamePortingToolkit(_ name: String) -> Bool { D3DMetalStore.isToolkitName(name) }

    func beginD3DMetalSetup() {
        d3dSetup = isD3DMetalReady ? .done(d3dMetalInfo?.version ?? "") : .intro
    }

    func openD3DMetalDownloadPage() {
        d3dSetup = .waiting
        Task { NSWorkspace.shared.open(await D3DMetalStore.currentDownload()) }
        watchForToolkit()
    }

    /// Watches Downloads for the finished disk image and /Volumes for an opened one. A download in progress
    /// (Safari's `.download`, Chrome's `.crdownload`) doesn't count until it is renamed to `.dmg`.
    func watchForToolkit() {
        stopWatchingForToolkit()
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let volumes = URL(fileURLWithPath: "/Volumes")
        toolkitWatchers = [downloads, volumes].map { folder in
            DirectoryWatcher(directory: folder, latency: 1) { Task { @MainActor in self.checkForToolkit() } }
        }
        checkForToolkit()
    }

    func stopWatchingForToolkit() { toolkitWatchers = []; triedToolkits = [] }

    func checkForToolkit() {
        guard case .waiting = d3dSetup ?? .intro else { return }
        let fm = FileManager.default
        let volumes = ((try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil)) ?? [])
            .filter { Self.isGamePortingToolkit($0.lastPathComponent) }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let images = ((try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "dmg" && Self.isGamePortingToolkit($0.lastPathComponent) }
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        guard let candidate = (volumes + images).first(where: { !triedToolkits.contains($0) }) else { return }
        triedToolkits.insert(candidate)
        Task { await importD3DMetal(from: candidate, chosenByUser: false) }
    }

    /// Checks and stages D3DMetal from a disk image, an opened disk or a folder.
    func importD3DMetal(from url: URL, chosenByUser: Bool = true) async {
        d3dSetup = .checking
        do {
            let staged = try await D3DMetalStore(paths: paths).stage(from: url)
            stopWatchingForToolkit()
            d3dSetup = .license(staged, Self.licenseText(staged.license))
        } catch D3DMetalError.couldNotOpen where url.pathExtension.lowercased() == "dmg" {
            d3dSetup = .needsDiskLicense(url)                       // the image wants Apple's license accepted in Finder
        } catch {
            if chosenByUser {
                d3dSetup = .failed(error.localizedDescription)
            } else {
                d3dSetup = .waiting                                 // a look-alike file; keep waiting for the real one
                checkForToolkit()
            }
        }
    }

    /// Opens the image in Finder, which shows Apple's license; once agreed, the disk mounts and is picked up.
    func openToolkitImage(_ image: URL) {
        NSWorkspace.shared.open(image)
        d3dSetup = .waiting
        triedToolkits = [image]
        watchForToolkit()
        triedToolkits.insert(image)
    }

    func acceptD3DMetalLicense(_ staged: StagedD3DMetal) async {
        d3dSetup = .installing
        do {
            let store = D3DMetalStore(paths: paths)
            try store.commit(staged, engines: engines)
            reloadEngines()
            d3dMetalInfo = store.installed
            d3dSetup = .done(staged.info.version)
        } catch {
            d3dSetup = .failed(error.localizedDescription)
        }
    }

    func cancelD3DMetalSetup() {
        if case .license(let staged, _) = d3dSetup { D3DMetalStore(paths: paths).discard(staged) }
        stopWatchingForToolkit()
        d3dSetup = nil
    }

    static func licenseText(_ url: URL?) -> String {
        guard let url else { return String(localized: "Apple's license for the Game Porting Toolkit applies. You accepted it on Apple's website.") }
        if let rich = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) { return rich.string }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

private extension URL {
    var modified: Date? { (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
}

/// Apple's license for D3DMetal: the one installed with it, else the copy in the app (the same terms).
struct D3DMetalLicenseView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let installed = D3DMetalStore(paths: model.paths).licenseFile
        let file = installed ?? Bundle.main.url(forResource: "AppleD3DMetalLicense", withExtension: "rtf")
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ScrollView {
                Text(AppModel.licenseText(file)).font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .padding(Theme.Space.s)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.thumbnail).fill(.quaternary.opacity(0.5)))
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 560, height: 480)
    }
}

/// The DirectX 12 setup sheet.
struct DirectX12SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var choosing = false
    @State private var downloadSeemsStuck = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m - 4) {
                Image(systemName: "cpu").font(.system(size: 28)).foregroundStyle(Theme.wineLight)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set Up DirectX 12").font(.title2.bold())
                    Text("Needed once for games that use DirectX 12.").foregroundStyle(.secondary)
                }
            }
            Divider()
            content
        }
        .padding(Theme.Space.l)
        .frame(width: 520)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.diskImage, .folder]) { result in
            if case .success(let url) = result { Task { await model.importD3DMetal(from: url) } }
        }
        .onDisappear { model.stopWatchingForToolkit() }
        .task(id: model.d3dSetup.map { if case .waiting = $0 { true } else { false } } ?? false) {
            downloadSeemsStuck = false
            guard case .waiting? = model.d3dSetup else { return }
            try? await Task.sleep(for: .seconds(120))
            if !Task.isCancelled { downloadSeemsStuck = true }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.d3dSetup ?? .intro {
        case .intro:
            VStack(alignment: .leading, spacing: Theme.Space.m - 4) {
                step(1, "Open Apple's download page and sign in with your Apple Account. It's free.")
                step(2, "Download the Game Porting Toolkit.")
                step(3, "Sommelier finds the download by itself and sets everything up.")
                Text("Sommelier sets this up by itself. Use this only to pick a different version from Apple.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            buttons {
                Button("I Already Have It…") { choosing = true }
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelD3DMetalSetup() }.keyboardShortcut(.cancelAction)
                Button("Download from Apple") { model.openD3DMetalDownloadPage() }.keyboardShortcut(.defaultAction)
            }
        case .waiting:
            HStack(spacing: Theme.Space.m - 4) {
                LoadingGrape()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waiting for the download…").font(.headline)
                    Text("Sign in on Apple's website if it asks. The download starts by itself, and Sommelier picks it up from Downloads.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            // The direct link may be gone (a newer toolkit replaced it): after two minutes, Apple's downloads page.
            if downloadSeemsStuck {
                HStack {
                    Text("Download didn't start? Open Apple's downloads page.").font(.callout).foregroundStyle(.secondary)
                    Button("Open") { NSWorkspace.shared.open(D3DMetalStore.downloadPage) }.controlSize(.small)
                }
            }
            buttons {
                Button("Choose File…") { choosing = true }
                Button("Download Again") { Task { NSWorkspace.shared.open(await D3DMetalStore.currentDownload()) } }
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelD3DMetalSetup() }.keyboardShortcut(.cancelAction)
            }
        case .needsDiskLicense(let image):
            Text("Apple asks you to agree to its license before the disk opens. Open it, agree, and Sommelier continues by itself.")
                .fixedSize(horizontal: false, vertical: true)
            buttons {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelD3DMetalSetup() }.keyboardShortcut(.cancelAction)
                Button("Open and Agree") { model.openToolkitImage(image) }.keyboardShortcut(.defaultAction)
            }
        case .checking, .installing:
            HStack(spacing: Theme.Space.m - 4) {
                LoadingGrape()
                Text(model.isD3DSetupInstalling ? "Installing DirectX 12…" : "Checking Apple's signature…")
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        case .license(let staged, let text):
            Text("Apple's license for D3DMetal \(staged.info.version)").font(.headline)
            ScrollView { Text(text).font(.caption).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(height: 200)
                .padding(Theme.Space.s)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.thumbnail).fill(.quaternary.opacity(0.5)))
            buttons {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelD3DMetalSetup() }.keyboardShortcut(.cancelAction)
                Button("Agree and Install") { Task { await model.acceptD3DMetalLicense(staged) } }.keyboardShortcut(.defaultAction)
            }
        case .done(let version):
            Label("DirectX 12 is ready (D3DMetal \(version)).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.onDark).font(.headline)
            Text("Games that need DirectX 12 can now be installed and played.").foregroundStyle(.secondary)
            buttons {
                Spacer()
                Button("Done") { model.cancelD3DMetalSetup() }.keyboardShortcut(.defaultAction)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.wineLight)
                .fixedSize(horizontal: false, vertical: true)
            buttons {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelD3DMetalSetup() }.keyboardShortcut(.cancelAction)
                Button("Try Again") { model.d3dSetup = .intro }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s + 2) {
            Text(verbatim: "\(number)").font(.callout.weight(.bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Circle().fill(Theme.wineLight))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func buttons<B: View>(@ViewBuilder _ content: () -> B) -> some View {
        HStack { content() }.padding(.top, Theme.Space.s)
    }
}
