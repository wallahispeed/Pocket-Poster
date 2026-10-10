//
//  ContentView.swift
//  Pocket Poster
//
//  Created by lemin on 5/31/25.
//

import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

extension UIDocumentPickerViewController {
    @objc func fix_init(forOpeningContentTypes contentTypes: [UTType], asCopy: Bool) -> UIDocumentPickerViewController {
        return fix_init(forOpeningContentTypes: contentTypes, asCopy: true)
    }
}

struct ContentView: View {
    // Prefs
    @AppStorage("pbHash") var pbHash: String = ""
    
    @ObservedObject var pbManager = PosterBoardManager.shared
    
    private let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    
    @State var showTendiesImporter: Bool = false
    @State var hideResetHelp: Bool = true
    
    var body: some View {
        NavigationStack {
            List {
                Section {} header: {
                    Label("Version \(Bundle.main.releaseVersionNumber ?? "UNKNOWN") (\(Int(buildNumber) != 0 ? "Beta \(buildNumber)" : NSLocalizedString("Release", comment:"")))", systemImage: "info.circle.fill")
                        .font(.caption)
                }
                
                Section {
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                        showTendiesImporter.toggle()
                    }) {
                        Label("Select Tendies", systemImage: "document.circle")
                    }
                    .buttonStyle(TintedButton(color: .green, fullwidth: true))
                }
                .listRowInsets(EdgeInsets())
                .padding(7)
                
                if !pbManager.selectedTendies.isEmpty {
                    Section {
                        ForEach(pbManager.selectedTendies, id: \.self) { tendie in
                            Text(tendie.deletingPathExtension().lastPathComponent)
                        }
                        .onDelete(perform: delete)
                    } header: {
                        Label("Selected Tendies", systemImage: "document")
                    }
                }
                
                Section {
                    if pbHash == "" && !SymHandler.prefersBadQuery {
                        Text("Enter your PosterBoard app hash in Settings.")
                    } else {
                        VStack {
                            if pbHash == "" && SymHandler.prefersBadQuery {
                                Text("No hash set — will auto-detect via bad_query on Apply.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !pbManager.selectedTendies.isEmpty || !pbManager.videos.isEmpty {
                                Button(action: {
                                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                    UIApplication.shared.alert(title: NSLocalizedString("Applying Wallpapers...", comment: ""), body: NSLocalizedString("Please wait", comment: ""), animated: false, withButton: false)

                                    DispatchQueue.global(qos: .userInitiated).async {
                                        do {
                                            var hash = pbHash
                                            if hash.isEmpty {
                                                UIApplication.shared.change(title: NSLocalizedString("Applying Wallpapers...", comment: ""), body: "Detecting PosterBoard container…")
                                                hash = try BadQuery.findPosterBoardHash()
                                                DispatchQueue.main.async { pbHash = hash }
                                            }
                                            try pbManager.applyTendies(appHash: hash)
                                            SymHandler.cleanup() // just to be extra sure
                                            try? FileManager.default.removeItem(at: pbManager.getTendiesStoreURL())
                                            
                                            DispatchQueue.main.async {
                                                pbManager.selectedTendies.removeAll()
                                                pbManager.videos.removeAll()
                                                Haptic.shared.notify(.success)
                                                // Instant Mond-style respring (no alert delay)
                                                RespringHelper.respring()
                                            }
                                        } catch CocoaError.fileWriteUnknown {
                                            presentError(ApplyError.wrongAppHash)
                                        } catch CocoaError.fileWriteFileExists {
                                            presentError(ApplyError.collectionsNeedsReset)
                                        } catch {
                                            print(error.localizedDescription)
                                            presentError(ApplyError.unexpected(info: error.localizedDescription))
                                        }
                                    }
                                }) {
                                    Label("Apply", systemImage: "checkmark.circle")
                                }
                                .buttonStyle(TintedButton(color: .blue, fullwidth: true))
                            }
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                UIApplication.shared.alert(title: "Physics Wallpaper", body: "Starting…", animated: false, withButton: false)
                                DispatchQueue.global(qos: .userInitiated).async {
                                    do {
                                        var hash = pbHash
                                        if hash.isEmpty {
                                            DispatchQueue.main.async {
                                                UIApplication.shared.change(title: "Physics Wallpaper", body: "Detecting PosterBoard…")
                                            }
                                            hash = try BadQuery.findPosterBoardHash()
                                            DispatchQueue.main.async { pbHash = hash }
                                        }
                                        try PhysicsWallpaperGenerator.apply(appHash: hash) { msg in
                                            UIApplication.shared.change(title: "Physics Wallpaper", body: msg)
                                        }
                                        DispatchQueue.main.async {
                                            Haptic.shared.notify(.success)
                                            RespringHelper.respring()
                                        }
                                    } catch {
                                        DispatchQueue.main.async {
                                            Haptic.shared.notify(.error)
                                            UIApplication.shared.alert(body: error.localizedDescription)
                                        }
                                    }
                                }
                            }) {
                                Label("Apply Physics Wallpaper", systemImage: "sparkles")
                            }
                            .buttonStyle(TintedButton(color: .purple, fullwidth: true))
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                UIApplication.shared.alert(title: "inject13", body: "Injecting…", animated: false, withButton: false)
                                DispatchQueue.global(qos: .userInitiated).async {
                                    do {
                                        let paths = try inject13()
                                        DispatchQueue.main.async {
                                            Haptic.shared.notify(.success)
                                            UIApplication.shared.alert(title: "inject13", body: "Wrote \(paths.count) file(s).\nLock/unlock to trigger posterboardd.")
                                        }
                                    } catch {
                                        DispatchQueue.main.async {
                                            Haptic.shared.notify(.error)
                                            UIApplication.shared.alert(title: "inject13 failed", body: error.localizedDescription)
                                        }
                                    }
                                }
                            }) {
                                Label("inject13 (font parser)", systemImage: "ladybug")
                            }
                            .buttonStyle(TintedButton(color: .orange, fullwidth: true))
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                RespringHelper.respring()
                            }) {
                                Label("Respring", systemImage: "arrow.counterclockwise.circle")
                            }
                            .buttonStyle(TintedButton(color: .gray, fullwidth: true))
                            Button(action: {
                                UIApplication.shared.confirmAlert(
                                    title: NSLocalizedString("Reset Collections", comment: ""),
                                    body: SymHandler.prefersBadQuery
                                        ? "This will wipe custom PosterBoard descriptors via bad_query, then respring."
                                        : NSLocalizedString("Do you want to reset collections?", comment: ""),
                                    onOK: {
                                        UIApplication.shared.alert(
                                            title: "Resetting…",
                                            body: "Please wait",
                                            animated: true,
                                            withButton: false
                                        )
                                        DispatchQueue.global(qos: .userInitiated).async {
                                            do {
                                                var hash = pbHash
                                                if hash.isEmpty && SymHandler.prefersBadQuery {
                                                    hash = try BadQuery.findPosterBoardHash()
                                                    DispatchQueue.main.async { pbHash = hash }
                                                }
                                                guard !hash.isEmpty else {
                                                    throw ApplyError.wrongAppHash
                                                }
                                                try pbManager.resetCollections(appHash: hash)
                                                DispatchQueue.main.async {
                                                    Haptic.shared.notify(.success)
                                                    // Instant Mond-style respring
                                                    RespringHelper.respring()
                                                }
                                            } catch {
                                                presentError(ApplyError.unexpected(info: error.localizedDescription))
                                            }
                                        }
                                    },
                                    noCancel: false
                                )
                            }) {
                                Label("Reset Collections", systemImage: "arrow.clockwise.circle")
                            }
                            .buttonStyle(TintedButton(color: .red, fullwidth: true))
                        }
                        .listRowInsets(EdgeInsets())
                        .padding(7)
                    }
                } header: {
                    Label("Actions", systemImage: "hammer")
                }
            }
            .navigationTitle("Pocket Poster")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let wpURL = URL(string: PosterBoardManager.WallpapersURL) {
                        Link(destination: wpURL) {
                            Image(systemName: "safari")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing, content: {
                    NavigationLink(destination: {
                        SettingsView()
                    }, label: {
                        Image(systemName: "gear")
                    })
                })
            }
        }
        .fileImporter(isPresented: $showTendiesImporter, allowedContentTypes: [UTType(filenameExtension: "tendies", conformingTo: .data)!], allowsMultipleSelection: true, onCompletion: { result in
            switch result {
            case .success(let url):
                if pbManager.selectedTendies.count + url.count > PosterBoardManager.MaxTendies {
                    UIApplication.shared.alert(title: NSLocalizedString("Max Tendies Reached", comment: ""), body: String(format: NSLocalizedString("You can only apply %@ descriptors.", comment: ""), "\(PosterBoardManager.MaxTendies)"))
                } else {
                    pbManager.selectedTendies.append(contentsOf: url)
                }
            case .failure(let error):
                Haptic.shared.notify(.error)
                UIApplication.shared.alert(body: error.localizedDescription)
            }
        })
        .overlay {
            OnBoardingView(cards: resetCollectionsInfo, isFinished: $hideResetHelp)
                .opacity(hideResetHelp ? 0.0 : 1.0)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.5), value: hideResetHelp)
        }
    }
    
    func delete(at offsets: IndexSet) {
        pbManager.selectedTendies.remove(atOffsets: offsets)
    }
    
    func presentError(_ error: ApplyError) {
        SymHandler.cleanup()
        DispatchQueue.main.async {
            Haptic.shared.notify(.error)
            // alert() dismisses any buttonless progress sheet first, always with OK
            UIApplication.shared.alert(body: error.localizedDescription, withButton: true)
        }
    }
    
    init() {
        // Fix file picker
        let fixMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.fix_init(forOpeningContentTypes:asCopy:)))!
        let origMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:)))!
        method_exchangeImplementations(origMethod, fixMethod)
    }
}
