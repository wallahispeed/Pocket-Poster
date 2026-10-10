//
//  SettingsView.swift
//  Pocket Poster
//
//  Stripped to: inject13-r7 only (version marker, app hash, inject13, respring).
//  All prior inject/probe buttons removed.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("pbHash") var pbHash: String = ""
    @AppStorage("cpHash") var cpHash: String = ""
    @AppStorage("ignoreDurationLimit") var ignoreDurationLimit: Bool = false

    @State var checkingForHash: Bool = false
    @State var hashCheckTask: Task<Void, any Error>? = nil
    @State var detectingOnDevice: Bool = false
    @State var injectingV13: Bool = false
    @State var probeOutput: String = ""
    @State var showProbeOutput: Bool = false

    var body: some View {
        List {
            // Version marker — bump this string whenever you build a new IPA
            Section {
                HStack(spacing: 6) {
                    Image(systemName: "tag.fill").foregroundStyle(.orange)
                    Text("inject13-r7")
                        .font(.system(.body, design: .monospaced))
                        .bold()
                        .foregroundStyle(.orange)
                }
            } header: {
                Label("Build", systemImage: "info.circle")
            }

            // App Hash
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
                        if SymHandler.prefersBadQuery {
                            Button(action: { detectOnDevice() }) {
                                if detectingOnDevice {
                                    ProgressView()
                                } else {
                                    Text("Detect On-Device")
                                }
                            }
                            .foregroundStyle(.blue)
                            .disabled(detectingOnDevice)
                        }

                        Button(action: {
                            if !FileManager.default.fileExists(atPath: SymHandler.getPosterBoardHashURL().path()) {
                                UIApplication.shared.confirmAlert(
                                    title: NSLocalizedString("Waiting for app hash...", comment: ""),
                                    body: NSLocalizedString("Connect your device to Nugget and click the \"Pocket Poster Helper\" button.", comment: ""),
                                    confirmTitle: NSLocalizedString("Cancel", comment: ""),
                                    onOK: { cancelWaitForHash() },
                                    noCancel: true
                                )
                            }
                            startWaitForHash()
                        }) {
                            Text(SymHandler.prefersBadQuery ? "Detect via Nugget" : "Detect")
                        }
                        .foregroundStyle(.green)
                        .onChange(of: checkingForHash) { _ in
                            if !checkingForHash {
                                UIApplication.shared.dismissAlert(animated: true)
                            }
                        }
                    }
                }
            } header: {
                Label("App Hash", systemImage: "lock.app.dashed")
            }

            // Preferences
            Section {
                Toggle(isOn: $ignoreDurationLimit, label: {
                    Label("Disable Video Duration Limit", systemImage: "ruler")
                })
            } header: {
                Label("Preferences", systemImage: "gear")
            }

            // Actions
            Section {
                // Inject v13 — PRPosterCustomTimeFontConfiguration path-traversal gadget
                Button(action: {
                    guard !injectingV13 else { return }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    injectingV13 = true
                    UIApplication.shared.alert(
                        title: "Inject v13…",
                        body: "PRPosterCustomTimeFontConfiguration path-traversal.\nResults saved to Documents/inject13-diag.txt",
                        animated: true,
                        withButton: false
                    )
                    DispatchQueue.global(qos: .userInitiated).async {
                        let output = SymHandler.inject13()
                        let didWrite = output.contains("WRITTEN")
                        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                            try? output.write(
                                to: docs.appendingPathComponent("inject13-diag.txt"),
                                atomically: true,
                                encoding: .utf8
                            )
                        }
                        DispatchQueue.main.async {
                            injectingV13 = false
                            probeOutput = output
                            UIApplication.shared.dismissAlert(animated: true)
                            Haptic.shared.notify(didWrite ? .success : .error)
                            showProbeOutput = true
                            if didWrite {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    RespringHelper.respring()
                                }
                            }
                        }
                    }
                }) {
                    HStack {
                        if injectingV13 {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.up.right.circle.fill")
                        }
                        Text(injectingV13 ? "Injecting v13…" : "Inject v13 (CustomFont path-traversal)")
                    }
                }
                .foregroundStyle(.orange)
                .disabled(injectingV13)

                // Manual respring (useful when inject ran on a previous launch)
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    RespringHelper.respring()
                }) {
                    Label("Respring Now", systemImage: "arrow.clockwise.circle.fill")
                }
                .foregroundStyle(.red)

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
            } header: {
                Label("Actions", systemImage: "bolt.circle")
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showProbeOutput) {
            ProbeOutputView(output: probeOutput)
        }
    }

    func detectOnDevice() {
        detectingOnDevice = true
        UIApplication.shared.alert(
            title: "Scanning containers…",
            body: "Scanning inodes via bad_query (extended range up to 80M). May take 30–60s.",
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
                try? await Task.sleep(nanoseconds: 500_000_000)
                try Task.checkCancellation()
            }

            do {
                let contents = try String(contentsOf: filePath)
                try? FileManager.default.removeItem(at: filePath)
                await MainActor.run { pbHash = contents }

                if UIDevice.current.userInterfaceIdiom == .phone {
                    let carplayPath = SymHandler.getCarPlayHashURL()
                    if FileManager.default.fileExists(atPath: carplayPath.path()) {
                        let carplayContents = try String(contentsOf: carplayPath)
                        try? FileManager.default.removeItem(at: carplayPath)
                        await MainActor.run { cpHash = carplayContents }
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
