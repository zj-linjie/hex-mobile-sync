import AudioToolbox
import UIKit

/// Key tap feedback: a light haptic and the system keyboard click.
///
/// iOS keeps its own Keyboard Feedback toggles (Settings > Sounds & Haptics)
/// private to the system keyboard — there is no public API for a custom
/// keyboard to read or follow them — so this keyboard plays both on every
/// tap. Neither needs Full Access.
@MainActor
enum KeyFeedback {
    /// One shared, prepared generator, so the first tap is not late.
    private static let haptic = UIImpactFeedbackGenerator(style: .light)

    static func tap() {
        haptic.impactOccurred()
        // 1104 is the system keyboard click.
        AudioServicesPlaySystemSound(1104)
    }
}
