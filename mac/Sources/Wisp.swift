import SwiftUI
import AppKit

/// The status bar applies its own monochrome foreground style to ordinary
/// SwiftUI text. Render both values into one non-template image so the two
/// provider colours survive and macOS measures the pair as one compact item.
struct ProviderStatusImage: View {
    @ObservedObject var bridge: Bridge

    var body: some View {
        let claude = bridge.barLabel(for: "claude")
        let codex = bridge.barLabel(for: "codex")
        Image(nsImage: Self.makeImage(claude: claude, codex: codex,
                                      claudeFresh: bridge.barValueTrustworthy(for: "claude"),
                                      codexFresh: bridge.barValueTrustworthy(for: "codex")))
            .renderingMode(.original)
            .accessibilityLabel("Claude \(claude), Codex \(codex)")
    }

    private static func makeImage(claude: String, codex: String,
                                  claudeFresh: Bool, codexFresh: Bool) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        func value(_ text: String, provider: String, fresh: Bool) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: Palette.providerNS(provider).withAlphaComponent(fresh ? 1 : 0.55),
            ])
        }

        let left = value(claude, provider: "claude", fresh: claudeFresh)
        let right = value(codex, provider: "codex", fresh: codexFresh)
        let leftSize = left.size()
        let rightSize = right.size()
        let gap: CGFloat = 6
        let size = NSSize(width: ceil(leftSize.width + gap + rightSize.width),
                          height: ceil(max(leftSize.height, rightSize.height)))
        let image = NSImage(size: size, flipped: false) { rect in
            left.draw(at: NSPoint(x: 0, y: (rect.height - leftSize.height) / 2))
            right.draw(at: NSPoint(x: leftSize.width + gap,
                                   y: (rect.height - rightSize.height) / 2))
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Wisp — the Waveshare bridge, with a face.
///
/// The app exists for two practical reasons, in this order:
///
///   1. It IS the autostart. Before it, the bridge only ran while somebody had
///      it up in a terminal; a reboot left the board orphaned with no sign
///      that it had happened. Now there is an icon.
///   2. Usage becomes readable without depending on the board.
///
/// LSUIElement=true in Info.plist: no Dock icon, no window. Just the menu bar.
/// Shutdown: without this the bridge process outlives the app and is re-adopted
/// by PID 1 — measured, not assumed. It keeps serving forever, and its three
/// `dns-sd` children along with it, announcing a bridge you think you closed.
final class Delegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ note: Notification) {
        MainActor.assumeIsolated {
            Floating.shared.savePosition()
            Bridge.shared.stop()
        }
    }
}

@main
struct WispApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) private var delegate
    @StateObject private var bridge = Bridge.shared

    var body: some Scene {
        MenuBarExtra {
            Panel(bridge: bridge)
        } label: {
            // Orange is Claude, blue is Codex. Only the two values live in the
            // menu bar; opening the panel provides the full labels and context.
            ProviderStatusImage(bridge: bridge)
            .onAppear { bridge.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
