//
//  ProbeOutputView.swift
//  Pocket Poster
//

import SwiftUI
import UIKit

struct ProbeOutputView: View {
    let output: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationView {
            ScrollView {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("posterboardd Probe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button {
                        UIPasteboard.general.string = output
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "Copied!" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .tint(copied ? .green : .blue)

                    ShareLink(item: output, subject: Text("posterboardd probe")) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}
