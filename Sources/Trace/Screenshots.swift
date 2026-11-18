import AppKit
import SwiftUI
import TraceCore

/// Takes the screenshots used in the README. Started with
/// `--demo --shots <folder>`: the app walks through its pages, saves one
/// PNG per page into the folder and quits. It draws its own window, so no
/// screen recording permission is involved.
@MainActor
enum Screenshots {
    private struct Shot {
        let name: String
        let prepare: (AppModel) -> Void
    }

    static func runIfRequested(model: AppModel) {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--shots"), index + 1 < args.count else { return }
        let folder = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let shots: [Shot] = [
            Shot(name: "overview") { $0.pane = .overview },
            Shot(name: "lanes") { model in
                model.pane = .timeline
                model.timelineMode = .gantt
            },
            Shot(name: "timeline") { model in
                model.pane = .timeline
                model.timelineMode = .byTag
            },
            Shot(name: "projects") { model in
                model.pane = .timeline
                model.timelineMode = .byProject
            },
            Shot(name: "records") { model in
                // Open the session with the documentation page and select it.
                let event = model.events.first { $0.title.hasPrefix("AXUIElement") }
                model.showRecords(block: model.blocks.first { block in
                    block.events.contains { $0.id == event?.id }
                }?.start, event: event?.id)
            },
            Shot(name: "focus") { $0.pane = .focus },
            Shot(name: "reports") { $0.showReport(.week) },
            Shot(name: "year") { $0.showReport(.year) },
            Shot(name: "tags") { $0.pane = .tags },
            Shot(name: "rules") { $0.pane = .rules },
            Shot(name: "overview-dark") { model in
                model.pane = .overview
                NSApp.appearance = NSAppearance(named: .darkAqua)
            },
            Shot(name: "overview-zh") { model in
                NSApp.appearance = NSAppearance(named: .aqua)
                model.language = .zhHans
            },
        ]

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else {
                NSApp.terminate(nil)
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            window.setContentSize(NSSize(width: 1320, height: 860))
            window.center()
            let language = model.language
            for shot in shots {
                shot.prepare(model)
                try? await Task.sleep(for: .seconds(1.6))
                if let data = capture(window) {
                    try? data.write(to: folder.appendingPathComponent("\(shot.name).png"))
                }
            }
            model.language = language
            try? await Task.sleep(for: .seconds(0.5))
            let watcher = model.watcher
            let panels: [(String, AnyView)] = [
                ("menu", AnyView(MenuBarView())),
                ("menu-session", AnyView(MenuBarView(startsPicking: true))),
                ("new-tag", AnyView(NewTagForm().frame(width: 900).padding(20).background(Theme.bg))),
            ] + model.tags.prefix(1).map { ("tag-sources", AnyView(TagSourcesSheet(tag: $0))) }
            for (name, view) in panels {
                if let data = await panel(view.environmentObject(model).environmentObject(watcher)) {
                    try? data.write(to: folder.appendingPathComponent("\(name).png"))
                }
            }
            NSApp.terminate(nil)
        }
    }

    /// A panel or sheet, shown in a window of its own on the menu material.
    private static func panel(_ view: some View) async -> Data? {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .menu
        effect.state = .active
        host.frame = effect.bounds
        effect.addSubview(host)
        let panel = NSPanel(contentRect: effect.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = effect
        panel.center()
        panel.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1.2))
        defer { panel.close() }
        guard let rep = effect.bitmapImageRepForCachingDisplay(in: effect.bounds) else { return nil }
        effect.cacheDisplay(in: effect.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// The window as a PNG with rounded corners and a soft shadow around it.
    private static func capture(_ window: NSWindow) -> Data? {
        guard let frame = window.contentView?.superview,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        guard let image = rep.cgImage else { return nil }

        let scale = CGFloat(rep.pixelsWide) / frame.bounds.width
        let margin = 56 * scale
        let size = CGSize(width: CGFloat(rep.pixelsWide) + margin * 2, height: CGFloat(rep.pixelsHigh) + margin * 2)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: margin, y: margin, width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        let shape = CGPath(roundedRect: rect, cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 34 * scale,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
        ctx.addPath(shape)
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.addPath(shape)
        ctx.clip()
        ctx.draw(image, in: rect)
        ctx.resetClip()
        ctx.addPath(shape)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
        ctx.setLineWidth(scale)
        ctx.strokePath()

        guard let result = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])
    }
}
