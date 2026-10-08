//
//  SettingsView.swift
//  Pocket Poster
//
//  Created by lemin on 6/1/25.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    // Prefs
    @AppStorage("pbHash") var pbHash: String = "" // PosterBoard hash
    @AppStorage("cpHash") var cpHash: String = "" // CarPlay hash
    @AppStorage("ignoreDurationLimit") var ignoreDurationLimit: Bool = false
    
    @State var checkingForHash: Bool = false
    @State var hashCheckTask: Task<Void, any Error>? = nil
    @State var detectingOnDevice: Bool = false
    @State var probingPosterboardd: Bool = false
    @State var probeShareItems: [Any] = []
    @State var showProbeShare: Bool = false
    
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Enter PosterBoard App Hash", text: $pbHash)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .font(.system(.body, design: .monospaced))
                    if CarPlayManager.supportsCarPlay() {
                        TextField("Enter CarPlayWallpaper App Hash", text: $cpHash)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .font(.system(.body, design: .monospaced))
                    }
                    
                    if SymHandler.prefersBadQuery {
                        Text("bad_query available — on-device detect works (no PC).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Spacer()
                        // On-device detect via bad_query (iOS 26/27)
                        if SymHandler.prefersBadQuery {
                            Button(action: {
                                detectOnDevice()
                            }) {
                                if detectingOnDevice {
                                    ProgressView()
                                } else {
                                    Text("Detect On-Device")
                                }
                            }
                            .foregroundStyle(.blue)
                            .disabled(detectingOnDevice)
                        }
                        
                        // Run task to check until file exists from Nugget pc over AFC
                        Button(action: {
                            if !FileManager.default.fileExists(atPath: SymHandler.getPosterBoardHashURL().path()) {
                                // don't show the alert because it is already there
                                UIApplication.shared.confirmAlert(title: NSLocalizedString("Waiting for app hash...", comment: ""), body: NSLocalizedString("Connect your device to Nugget and click the \"Pocket Poster Helper\" button.", comment: ""), confirmTitle: NSLocalizedString("Cancel", comment: ""), onOK: {
                                    cancelWaitForHash()
                                }, noCancel: true)
                            }
                            startWaitForHash()
                        }) {
                            Text(SymHandler.prefersBadQuery ? "Detect via Nugget" : "Detect")
                        }
                        .foregroundStyle(.green)
                        .onChange(of: checkingForHash) { _ in
                            if !checkingForHash {
                                // hide ui alert
                                UIApplication.shared.dismissAlert(animated: true)
                            }
                        }
                    }
                }
            } header: {
                Label("App Hash", systemImage: "lock.app.dashed")
            }
            
            Section {
                Toggle(isOn: $ignoreDurationLimit, label: {
                    Label("Disable Video Duration Limit", systemImage: "ruler")
                })
            } header: {
                Label("Preferences", systemImage: "gear")
            }
            
            Section {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    UserDefaults.standard.set(false, forKey: "finishedTutorial")
                }) {
                    Label("Replay Tutorial", systemImage: "questionmark.circle")
                }
                
                Button(action: {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    do {
                        try PosterBoardManager.clearCache()
                        Haptic.shared.notify(.success)
                        UIApplication.shared.alert(title: NSLocalizedString("App Cache Successfully Cleared!", comment: ""), body: "")
                    } catch {
                        Haptic.shared.notify(.error)
                        UIApplication.shared.alert(body: error.localizedDescription)
                    }
                }) {
                    Label("Clear App Cache", systemImage: "trash.circle")
                }
                .foregroundStyle(.red)
                
                Button(action: {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    UserDefaults.standard.set(nil, forKey: "ActiveCarPlayWallpapers")
                    try? FileManager.default.removeItem(at: CarPlayManager.getCarPlayPhotosURL())
                    Haptic.shared.notify(.success)
                    UIApplication.shared.alert(title: NSLocalizedString("CarPlay Applied Wallpapers Successfully Cleared!", comment: ""), body: "")
                }) {
                    Label("Reset CarPlay Applied Wallpapers", systemImage: "trash.circle")
                }
                .foregroundStyle(.red)

                // posterboardd storage probe — maps daemon dirs, SQLite schemas, blob cols
                Button(action: {
                    guard !probingPosterboardd else { return }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    probingPosterboardd = true
                    UIApplication.shared.alert(
                        title: "Probing posterboardd…",
                        body: "Scanning daemon storage, SQLite schema, binary strings. May take ~10s.",
                        animated: true,
                        withButton: false
                    )
                    DispatchQueue.global(qos: .userInitiated).async {
                        let output = SymHandler.probePosterboardd()
                        DispatchQueue.main.async {
                            probingPosterboardd = false
                            UIApplication.shared.dismissAlert(animated: true)
                            // Save to Documents and offer share
                            let diagURL = SymHandler.getLCDocumentsDirectory()
                                .appendingPathComponent("pp_posterboardd_diag.txt")
                            probeShareItems = [output as Any, diagURL]
                            showProbeShare = true
                            Haptic.shared.notify(.success)
                        }
                    }
                }) {
                    HStack {
                        if probingPosterboardd {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "stethoscope")
                        }
                        Text(probingPosterboardd ? "Probing…" : "Probe posterboardd")
                    }
                }
                .foregroundStyle(.orange)
                .disabled(probingPosterboardd)
                .sheet(isPresented: $showProbeShare) {
                    ShareSheet(items: probeShareItems)
                }
            } header: {
                Label("Actions", systemImage: "gear")
            }
            
            // MARK: Links
            Section {
                if let scURL = URL(string: PosterBoardManager.ShortcutURL) {
                    Link(destination: scURL) {
                        Label("Download Fallback Shortcut", systemImage: "arrow.down.circle")
                    }
                }
                if let fbURL = URL(string: "shortcuts://run-shortcut?name=PosterBoard&input=text&text=troubleshoot") {
                    Link(destination: fbURL) {
                        Label("Create Additional Fallback Method", systemImage: "appclip")
                    }
                }
                if let nURL = URL(string: "https://github.com/leminlimez/Nugget") {
                    Link(destination: nURL) {
                        Label("Nugget GitHub", image: "github.fill")
                    }
                }
            } header: {
                Label("Links", systemImage: "link")
            }
            
            // MARK: Socials
            Section {
                Link(destination: URL(string: "https://github.com/leminlimez/Pocket-Poster")!) {
                    Label("View on GitHub", image: "github.fill")
                }
                Link(destination: URL(string: "https://discord.gg/MN8JgqSAqT")!) {
                    Label("Join the Discord", image: "discord.fill")
                }
                Link(destination: URL(string: "https://ko-fi.com/leminlimez")!) {
                    Label("Support on Ko-Fi", image: "ko-fi")
                }
            } header: {
                Label("Socials", systemImage: "globe")
            }
            
            // MARK: Credits
            Section {
                LinkCell(imageName: "Mak5er", url: "https://github.com/Mak5er", title: "Mak5er", contribution: "bad_query port · iOS 27 build", circle: true)
                LinkCell(imageName: "leminlimez", url: "https://github.com/leminlimez", title: "LeminLimez", contribution: NSLocalizedString("Main Developer", comment: "leminlimez's contribution"), circle: true)
                LinkCell(imageName: "serstars", url: "https://github.com/SerStars", title: "SerStars", contribution: NSLocalizedString("Website Designer", comment: ""), circle: true)
                LinkCell(imageName: "Nathan", url: "https://github.com/verygenericname", title: "Nathan", contribution: NSLocalizedString("Exploit (.Trash)", comment: ""), circle: true)
                LinkCell(imageName: "duy", url: "https://github.com/khanhduytran0", title: "DuyKhanhTran", contribution: NSLocalizedString("Exploit (.Trash)", comment: ""), circle: true)
                LinkCell(imageName: "sky", url: "https://github.com/forcequitOS/bad_query", title: "forcequitOS", contribution: "bad_query (iOS 26/27)", circle: false)
                LinkCell(imageName: "sky", url: "https://bsky.app/profile/did:plc:xykfeb7ieeo335g3aly6vev4", title: "dootskyre", contribution: NSLocalizedString("Fallback Shortcut Creator", comment: ""), circle: true)
                LinkCell(imageName: "POEditor", url: "https://poeditor.com/join/project/MPZOsunwVj", title: NSLocalizedString("Community Translators", comment: ""), contribution: "POEditor")
            } header: {
                Label("Credits", systemImage: "wrench.and.screwdriver")
            }
        }
    }
    
    /// Scan containers on-device with bad_query / fsgetpath — no computer needed.
    func detectOnDevice() {
        detectingOnDevice = true
        UIApplication.shared.alert(
            title: "Scanning containers…",
            body: "Looking for PosterBoard via bad_query. This may take a moment.",
            animated: true,
            withButton: false
        )
        
        DispatchQueue.global(qos: .userInitiated).async {
            var pb: String?
            var cp: String?
            var errMsg: String?
            
            do {
                pb = try BadQuery.findPosterBoardHash()
            } catch {
                errMsg = error.localizedDescription
            }
            
            if CarPlayManager.supportsCarPlay() {
                cp = try? BadQuery.findCarPlayHash()
            }
            
            // Always show a closeable result alert (loading alert has no OK button —
            // dismiss must complete before the next alert is presented).
            DispatchQueue.main.async {
                detectingOnDevice = false
                
                if let pb {
                    pbHash = pb.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let cp {
                        cpHash = cp.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    Haptic.shared.notify(.success)
                    let body = cp != nil
                        ? "PosterBoard:\n\(pbHash)\n\nCarPlay:\n\(cpHash)"
                        : "PosterBoard:\n\(pbHash)"
                    // alert() auto-dismisses any previous (buttonless) sheet first
                    UIApplication.shared.alert(title: "Hash found!", body: body, withButton: true)
                } else {
                    Haptic.shared.notify(.error)
                    UIApplication.shared.alert(
                        title: "Detect failed",
                        body: errMsg ?? "Could not find PosterBoard container. Open Wallpaper settings once, then retry.",
                        withButton: true
                    )
                }
            }
        }
    }
    
    func startWaitForHash() {
        checkingForHash = true
        hashCheckTask = Task {
            let filePath = SymHandler.getPosterBoardHashURL()
            while !FileManager.default.fileExists(atPath: filePath.path()) {
                try? await Task.sleep(nanoseconds: 500_000_000) // Sleep 0.5s
                try Task.checkCancellation()
            }
            
            do {
                let contents = try String(contentsOf: filePath)
                try? FileManager.default.removeItem(at: filePath)
                await MainActor.run {
                    pbHash = contents
                }
                // check for carplay hash
                if UIDevice.current.userInterfaceIdiom == .phone {
                    let carplayPath = SymHandler.getCarPlayHashURL()
                    if FileManager.default.fileExists(atPath: carplayPath.path()) {
                        let carplayContents = try String(contentsOf: carplayPath)
                        try? FileManager.default.removeItem(at: carplayPath)
                        await MainActor.run {
                            cpHash = carplayContents
                        }
                    }
                }
            } catch {
                print(error.localizedDescription)
            }

            await MainActor.run {
                checkingForHash = false
                hashCheckTask = nil
            }
        }
    }
    
    func cancelWaitForHash() {
        hashCheckTask?.cancel()
        hashCheckTask = nil
        checkingForHash = false
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
