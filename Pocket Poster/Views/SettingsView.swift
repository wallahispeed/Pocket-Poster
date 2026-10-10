//
//  SettingsView.swift
//  Pocket Poster
//
//  Created by lemin on 6/1/25.
//

import SwiftUI

struct SettingsView: View {
    // Prefs
    @AppStorage("pbHash") var pbHash: String = "" // PosterBoard hash
    @AppStorage("cpHash") var cpHash: String = "" // CarPlay hash
    @AppStorage("ignoreDurationLimit") var ignoreDurationLimit: Bool = false
    
    @State var checkingForHash: Bool = false
    @State var hashCheckTask: Task<Void, any Error>? = nil
    @State var detectingOnDevice: Bool = false
    @State var probingPosterboardd: Bool = false
    @State var probeOutput: String = ""
    @State var showProbeOutput: Bool = false
    @State var probingV6: Bool = false
    @State var triggeringDecode: Bool = false
    @State var probingV7: Bool = false
    @State var injectingV7: Bool = false
    @State var injectingV8: Bool = false
    @State var injectingV9: Bool = false
    @State var injectingV10: Bool = false
    @State var probingV11:   Bool = false
    @State var injectingV11: Bool = false
    @State var probingV12:   Bool = false
    @State var injectingV12: Bool = false
    @State var injectingV13: Bool = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 6) {
                    Image(systemName: "tag.fill").foregroundStyle(.orange)
                    Text("inject13-r6").font(.system(.body, design: .monospaced)).bold().foregroundStyle(.orange)
                }
            } header: {
                Label("Build", systemImage: "info.circle")
            }

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

                // Inject v13 — PRPosterCustomTimeFontConfiguration path-traversal gadget
                // 15x ../ from extensionBundleURL → root → PB container probe font via CGFontCreateFontsWithURL
                Button(action: {
                    guard !injectingV13 else { return }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    injectingV13 = true
                    UIApplication.shared.alert(
                        title: "Inject v13…",
                        body: "PRPosterCustomTimeFontConfiguration path-traversal via extensionBundleRelativeFilePath.",
                        animated: true,
                        withButton: false
                    )
                    DispatchQueue.global(qos: .userInitiated).async {
                        let output = SymHandler.inject13()
                        let didWrite = output.contains("WRITTEN")
                        // Always save to Documents so output survives the respring
                        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                            try? output.write(to: docs.appendingPathComponent("inject13-diag.txt"),
                                              atomically: true, encoding: .utf8)
                        }
                        DispatchQueue.main.async {
                            injectingV13 = false
                            probeOutput = output
                            UIApplication.shared.dismissAlert(animated: true)
                            Haptic.shared.notify(.success)
                            showProbeOutput = true
                            if didWrite {
                                // Respring so posterboardd restarts and reads our injected config
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

                // Probe v12 — deep NSKA (class+value) + font-path gadget + SQLite write probe
                Button(action: {
                    guard !probingV12 else { return }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    probingV12 = true
                    UIApplication.shared.alert(
                        title: "Probe v12…",
                        body: "Deep NSKA dump + font-loading binary search + SQLite write probe.",
                        animated: true,
                        withButton: false
                    )
                    DispatchQueue.global(qos: .userInitiated).async {
                        let output = SymHandler.probe12()
                        DispatchQueue.main.async {
                            probingV12 = false
                            probeOutput = output
                            UIApplication.shared.dismissAlert(animated: true)
                            Haptic.shared.notify(.success)
                            showProbeOutput = true
                        }
                    }
                }) {
                    HStack {
                        if probingV12 {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "magnifyingglass.circle.fill")
                        }
                        Text(probingV12 ? "Probing v12…" : "Probe v12 (deep-NSKA + font-path)")
                    }
                }
                .foregroundStyle(.indigo)
                .disabled(probingV12)

                // Inject v12 — PRPosterSystemTimeFontConfiguration (isSystemItem=false, fontPath)
                Button(action: {
                    guard !injectingV12 else { return }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    injectingV12 = true
                    UIApplication.shared.alert(
                        title: "Inject v12…",
                        body: "PRPosterSystemTimeFontConfiguration isSystemItem=false + font probe file.",
                        animated: true,
                        withButton: false
                    )
                    DispatchQueue.global(qos: .userInitiated).async {
                        let output = SymHandler.inject12()
                        DispatchQueue.main.async {
                            injectingV12 = false
                            probeOutput = output
                            UIApplication.shared.dismissAlert(animated: true)
                            Haptic.shared.notify(.success)
                            showProbeOutput = true
                        }
                    }
                }) {
                    HStack {
                        if injectingV12 {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "bolt.fill")
                        }
                        Text(injectingV12 ? "Injecting v12…" : "Inject v12 (SystemFontConfig)")
                    }
                }
                .foregroundStyle(.red)
                .disabled(injectingV12)

                // Probe v11 — ClockPoster contents/ deep scan + PFPosterDescriptor key dump +
                //              binary NSExpression/predicate string search + SQLite blob decode
                Button(action: {
                    guard !probingV11 else { return }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    probingV11 = true
                    UIApplication.shared.alert(
                        title: "Probe v11…",
                        body: "ClockPoster contents/ scan + gadget key dumps + binary pattern search.",
                        animated: true,
                        withButton: false
                    )
                    DispatchQueue.global(qos: .userInitiated).async {
                        let output = SymHandler.probe11()
                        DispatchQueue.main.async {
                            probingV11 = false
                            probeOutput = output
                            UIApplication.shared.dismissAlert(animated: true)
                            Haptic.shared.notify(.success)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                showProbeOutput = true
                            }
                        }
                    }
                }) {
                    HStack {
                        if probingV11 {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "magnifyingglass.circle")
                        }
                        Text(probingV11 ? "Probing v11…" : "Probe v11 (ClockPoster+gadget keys)")
                    }
                }
                .foregroundStyle(.purple)
                .disabled(probingV11)

                // Inject v11 — NSFunctionExpression/KVC as timeFontConfiguration +
                //              PRComplicationDescriptor with app bundle ID +
                //              ClockPoster contents/ path targeting
                Button(action: {
                    guard !injectingV11 else { return }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    injectingV11 = true
                    UIApplication.shared.alert(
                        title: "Inject v11…",
                        body: "NSFunctionExpression + PRComplicDesc + ClockPoster contents/ targeting.",
                        animated: true,
                        withButton: false
                    )
                    DispatchQueue.global(qos: .userInitiated).async {
                        let output = SymHandler.inject11()
                        DispatchQueue.main.async {
                            injectingV11 = false
                            probeOutput = output
                            UIApplication.shared.dismissAlert(animated: true)
                            Haptic.shared.notify(.success)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                showProbeOutput = true
                            }
                        }
                    }
                }) {
                    HStack {
                        if injectingV11 {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "bolt.trianglebadge.exclamationmark")
                        }
                        Text(injectingV11 ? "Injecting v11…" : "Inject v11 (funcExpr+ClockPoster)")
                    }
                }
                .foregroundStyle(.red)
                .disabled(injectingV11)

                // Inject v10 — type-confusion probe: NSExpression as timeFontConfiguration (full NSCoding object)
                //              + PFPosterDescriptor as complications
                Button(action: {
                    guard !injectingV10 else { return }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    injectingV10 = true
                    UIApplication.shared.alert(
                        title: "Inject v10…",
                        body: "NSExpression as timeFontConfiguration — probing type confusion on clock render path.",
                        animated: true,
                        withButton: false
                    )
                    DispatchQueue.global(qos: .userInitiated).async {
                        let output = SymHandler.inject10()
                        DispatchQueue.main.async {
                            injectingV10 = false
                            probeOutput = output
                            UIApplication.shared.dismissAlert(animated: true)
                            Haptic.shared.notify(.success)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                showProbeOutput = true
                            }
                        }
                    }
                }) {
                    HStack {
                        if injectingV10 {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        Text(injectingV10 ? "Injecting v10…" : "Inject v10 (type confusion)")
                    }
                }
                .foregroundStyle(.red)
                .disabled(injectingV10)

                // Inject v9 — gadget probe: NSExpression / PFPosterDescriptor / PFPosterPath as complications
                //             + NSString probe on timeFontConfiguration key
                Button(action: {
                    guard !injectingV9 else { return }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    injectingV9 = true
                    UIApplication.shared.alert(
                        title: "Inject v9…",
                        body: "Testing NSExpression, PFPosterDescriptor, PFPosterPath gadgets + font type probe.",
                        animated: true,
                        withButton: false
                    )
                    DispatchQueue.global(qos: .userInitiated).async {
                        let output = SymHandler.inject9()
                        DispatchQueue.main.async {
                            injectingV9 = false
                            probeOutput = output
                            UIApplication.shared.dismissAlert(animated: true)
                            Haptic.shared.notify(.success)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                showProbeOutput = true
                            }
                        }
                    }
                }) {
                    HStack {
                        if injectingV9 {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "bolt.shield")
                        }
                        Text(injectingV9 ? "Probing gadgets…" : "Inject v9 (gadget probe)")
                    }
                }
                .foregroundStyle(.orange)
                .disabled(injectingV9)

                // Inject v8 — class-matched all providers + NSDictionary probe on WallpaperKit complication
                Button(action: {
                    guard !injectingV8 else { return }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    injectingV8 = true
                    UIApplication.shared.alert(
                        title: "Inject v8…",
                        body: "Fixing clock + probing decode security on WallpaperKit complication.",
                        animated: true,
                        withButton: false
                    )
                    DispatchQueue.global(qos: .userInitiated).async {
                        let output = SymHandler.inject8()
                        DispatchQueue.main.async {
                            injectingV8 = false
                            probeOutput = output
                            UIApplication.shared.dismissAlert(animated: true)
                            Haptic.shared.notify(.success)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                showProbeOutput = true
                            }
                        }
                    }
                }) {
                    HStack {
                        if injectingV8 {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "shield.lefthalf.filled")
                        }
                        Text(injectingV8 ? "Injecting v8…" : "Inject v8 (decode probe)")
                    }
                }
                .foregroundStyle(.indigo)
                .disabled(injectingV8)

                // Inject v7 — write class-matched payloads to WallpaperKit instance files
                Button(action: {
                    guard !injectingV7 else { return }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    injectingV7 = true
                    UIApplication.shared.alert(
                        title: "Injecting v7…",
                        body: "Writing class-matched payloads to WallpaperKit instance files.",
                        animated: true,
                        withButton: false
                    )
                    DispatchQueue.global(qos: .userInitiated).async {
                        let output = SymHandler.inject7()
                        DispatchQueue.main.async {
                            injectingV7 = false
                            probeOutput = output
                            UIApplication.shared.dismissAlert(animated: true)
                            Haptic.shared.notify(.success)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                showProbeOutput = true
                            }
                        }
                    }
                }) {
                    HStack {
                        if injectingV7 {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.down.doc.fill")
                        }
                        Text(injectingV7 ? "Injecting v7…" : "Inject v7 (class-matched)")
                    }
                }
                .foregroundStyle(.purple)
                .disabled(injectingV7)

                // Probe v7 — class introspection + NSKeyedArchive CodingKey extraction
                Button(action: {
                    guard !probingV7 else { return }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    probingV7 = true
                    UIApplication.shared.alert(
                        title: "Probe v7…",
                        body: "Class introspection + archive key extraction from v1 files.",
                        animated: true,
                        withButton: false
                    )
                    DispatchQueue.global(qos: .userInitiated).async {
                        let output = SymHandler.probe7()
                        DispatchQueue.main.async {
                            probingV7 = false
                            probeOutput = output
                            UIApplication.shared.dismissAlert(animated: true)
                            Haptic.shared.notify(.success)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                showProbeOutput = true
                            }
                        }
                    }
                }) {
                    HStack {
                        if probingV7 {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "magnifyingglass.circle.fill")
                        }
                        Text(probingV7 ? "Probing v7…" : "Probe v7 (class introspect)")
                    }
                }
                .foregroundStyle(.mint)
                .disabled(probingV7)

                // Probe v6 — proc_listpids + full versions/ tree + crash logs
                Button(action: {
                    guard !probingV6 else { return }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    probingV6 = true
                    UIApplication.shared.alert(
                        title: "Probe v6…",
                        body: "PID scan + full versions/ tree + crash logs + transient trigger.",
                        animated: true,
                        withButton: false
                    )
                    DispatchQueue.global(qos: .userInitiated).async {
                        let output = SymHandler.probe6()
                        DispatchQueue.main.async {
                            probingV6 = false
                            probeOutput = output
                            UIApplication.shared.dismissAlert(animated: true)
                            Haptic.shared.notify(.success)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                showProbeOutput = true
                            }
                        }
                    }
                }) {
                    HStack {
                        if probingV6 {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "magnifyingglass.circle")
                        }
                        Text(probingV6 ? "Probing v6…" : "Probe v6 (deep)")
                    }
                }
                .foregroundStyle(.cyan)
                .disabled(probingV6)

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
                            probeOutput = output
                            UIApplication.shared.dismissAlert(animated: true)
                            Haptic.shared.notify(.success)
                            // Wait for the dismiss animation to finish before presenting sheet
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                showProbeOutput = true
                            }
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

                // Trigger decode — SIGTERM posterboardd, post Darwin notifs, read crash logs
                Button(action: {
                    guard !triggeringDecode else { return }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    triggeringDecode = true
                    UIApplication.shared.alert(
                        title: "Triggering decode…",
                        body: "SIGTERM posterboardd + Darwin notifs. Waiting 4s for crash. Keep screen on.",
                        animated: true,
                        withButton: false
                    )
                    DispatchQueue.global(qos: .userInitiated).async {
                        let output = SymHandler.triggerDecodeAndCheckCrash()
                        DispatchQueue.main.async {
                            triggeringDecode = false
                            probeOutput = output
                            UIApplication.shared.dismissAlert(animated: true)
                            Haptic.shared.notify(.success)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                showProbeOutput = true
                            }
                        }
                    }
                }) {
                    HStack {
                        if triggeringDecode {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "bolt.trianglebadge.exclamationmark")
                        }
                        Text(triggeringDecode ? "Triggering…" : "Trigger Decode")
                    }
                }
                .foregroundStyle(.red)
                .disabled(triggeringDecode)
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
        // Sheet on the List so it isn't buried in a Button inside a cell
        .sheet(isPresented: $showProbeOutput) {
            ProbeOutputView(output: probeOutput)
        }
    }
    
    /// Scan containers on-device with bad_query / fsgetpath — no computer needed.
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

