import AppKit
import SDDOrchestratorWorkerCore

/// [specs/42 Task 1, AC-01/AC-02] Draws one `StatusIndicator` as one filled
/// dot for an `NSMenuItem`'s image.
///
/// This is the only place that knows a colour. `StatusIndicator` names the
/// kind of state and stays in the AppKit-free Core target where a test can
/// reach it; the translation to green or red is presentation and lives here.
/// That split is why this file has no unit test: the app target has no test
/// target (see `Package.swift`), and the colours are confirmed by the slice's
/// product proof instead.
///
/// The dot is a drawn image rather than a character in the menu item's title.
/// A coloured glyph in the title would put presentation inside product copy
/// owned by specs/36, specs/38 and specs/39, and would render differently
/// depending on the font and emoji fallback. The image sits beside the title
/// and leaves the words byte-identical.
enum StatusIndicatorImage {
    /// Points, not pixels: the drawing handler runs at whatever scale the
    /// screen asks for, so this is correct on Retina and non-Retina menus
    /// alike. Nine points reads as a dot next to the menu's ~13pt text
    /// without crowding the title.
    private static let diameter: CGFloat = 9

    static func image(for indicator: StatusIndicator) -> NSImage {
        // The handler is re-run every time the image is drawn, which is what
        // makes the dynamic system colours below resolve against the menu's
        // current appearance. Baking a bitmap once would freeze a light-mode
        // colour into a dark menu.
        let image = NSImage(
            size: NSSize(width: diameter, height: diameter),
            flipped: false
        ) { rect in
            fillColour(for: indicator).setFill()
            // Inset by half a point so antialiasing at the circle's edge has
            // somewhere to go and the dot does not look clipped.
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }

        // Explicitly not a template image: AppKit re-tints template images to
        // a single system colour, which would erase the one thing this image
        // exists to carry. (The status-bar button's icon in
        // `AppDelegate.setUpStatusItem()` is a template on purpose; this is
        // the opposite case.)
        image.isTemplate = false

        // Deliberately no accessibility description. The dot is decorative
        // reinforcement of a status line that already says the whole thing in
        // words, so describing it would make VoiceOver read the state twice.
        image.accessibilityDescription = nil

        return image
    }

    /// The system semantic colours, because they already adapt to light and
    /// dark menus and to the accessibility contrast settings, which
    /// hand-picked RGB values would not.
    ///
    /// Green and red are additionally pulled apart in brightness, not only in
    /// hue: `.systemGreen` is lightened and `.systemRed` darkened, which puts
    /// their relative luminance roughly two to one apart. Someone with a
    /// red-green colour vision deficiency still sees a light dot and a dark
    /// dot. The words beside the dot remain the real answer either way.
    private static func fillColour(for indicator: StatusIndicator) -> NSColor {
        switch indicator {
        case .healthy:
            return adjustingBrightness(of: .systemGreen, by: 1.12)
        case .problem:
            return adjustingBrightness(of: .systemRed, by: 0.82)
        case .inProgress:
            // Amber. `.systemOrange` is the closest system colour, and it
            // already sits between the green and the red in brightness.
            return .systemOrange
        case .idle:
            // The label greys are the system's own "present but not
            // important" colour, so the not-paired dot recedes the way a
            // secondary label does instead of competing with a real signal.
            return .secondaryLabelColor
        case .update:
            return .systemBlue
        }
    }

    /// Scales a colour's brightness while keeping its hue.
    ///
    /// Resolving to sRGB first is what makes `getHue` valid on a dynamic
    /// system colour; because this runs inside the drawing handler, the
    /// resolution happens under the appearance the menu is being drawn in. If
    /// a colour cannot be resolved the original is used unchanged, which
    /// costs the brightness separation but never the dot.
    private static func adjustingBrightness(of colour: NSColor, by factor: CGFloat) -> NSColor {
        guard let resolved = colour.usingColorSpace(.sRGB) else { return colour }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        resolved.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return NSColor(
            hue: hue,
            saturation: saturation,
            brightness: min(max(brightness * factor, 0), 1),
            alpha: alpha
        )
    }
}
