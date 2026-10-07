import AppKit
import SwiftUI

final class AboutBoxController {
    static let shared = AboutBoxController()
    private var panel: NSPanel?

    func show() {
        if let panel { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 552, height: 320), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.contentView = NSHostingView(rootView: AboutBoxView())
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AboutBoxView: View {
    private var buildTimestamp: String {
        let date = Bundle.main.executableURL.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        guard let date else { return "Version: Development" }
        let formatter = DateFormatter(); formatter.dateFormat = "yyMMdd-HHmm"; formatter.timeZone = .current
        return "Version: \(formatter.string(from: date))"
    }

    var body: some View {
        ZStack {
            VisualEffectBackground()
            VStack(alignment: .leading, spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)).padding(.bottom, 22)
                Text("Monopathy").font(.headline.weight(.semibold)).padding(.bottom, 4)
                Text(buildTimestamp).font(.body).padding(.bottom, 14)
                Text("A standard-rules Monopoly table for LAN-connected decision-makers.").font(.body).padding(.bottom, 14)
                Text("©2026 Mark Gadzikowski. All Rights Reserved Worldwide.").font(.body.weight(.semibold))
                Text("Contact: monopathy@quantumpenguin.net").font(.body).padding(.top, 18)
                Spacer()
                HStack { Spacer(); Button("OK") { NSApp.keyWindow?.close() }.keyboardShortcut(.defaultAction).controlSize(.large).frame(width: 228); Spacer() }
            }.padding(.top, 24).padding(.horizontal, 20).padding(.bottom, 16)
        }.frame(width: 552, height: 320)
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView { let view = NSVisualEffectView(); view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active; return view }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
