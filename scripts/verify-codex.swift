import AppKit
import Foundation

@main
struct LiveCheck {
    static func main() {
        do {
            _ = NSApplication.shared
            let workspace = try OCRWorkspace()
            defer { workspace.remove() }
            var settings = OCRSettings(); settings.backend = .codex; settings.fastMode = false
            if CommandLine.arguments.contains("--claude-availability") { settings.backend = .claude }
            let discovery = try ModelDiscovery.discover(settings: settings, workspace: workspace.directory)
            print("AVAILABLE: " + discovery.status)
            for model in discovery.models { print("MODEL: \(model.id), fast=\(model.fastTier ?? "unavailable"), default=\(model.isDefault)") }
            if CommandLine.arguments.contains("--recognize") {
                let image = NSImage(size: NSSize(width: 900, height: 240))
                image.lockFocus()
                NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 240).fill()
                ("SCREEN TEXT 2026\n画面の文字をコピー" as NSString).draw(in: NSRect(x: 36, y: 30, width: 830, height: 180), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
                image.unlockFocus()
                let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try rep.representation(using: .png, properties: [:])!.write(to: workspace.image)
                let result = try SubscriptionOCR.recognize(settings: settings, workspace: workspace, cancellation: Cancellation())
                guard result.contains("SCREEN TEXT 2026"), result.contains("画面の文字をコピー") else { throw OCRError.invalidResponse }
                print("SYNTHETIC OCR PASSED: " + result.replacingOccurrences(of: "\n", with: " | "))
            }
        } catch { print("FAILED: " + error.localizedDescription); exit(1) }
    }
}
