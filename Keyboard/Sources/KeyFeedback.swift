import AudioToolbox
import UIKit

/// Key tap feedback: a light haptic and the system keyboard click.
///
/// iOS keeps its own Keyboard Feedback toggles (Settings > Sounds & Haptics)
/// private to the system keyboard — there is no public API for a custom
/// keyboard to read or follow them — so this keyboard plays both on every
/// tap. Neither needs Full Access. `tap()` is called from the key actions
/// themselves (not from a press-state observer): when the phone reports no
/// feedback, the one-time diagnostics line tells whether the tap path ran
/// at all.
@MainActor
enum KeyFeedback {
    /// One shared, prepared generator, so the first tap is not late.
    private static let haptic = UIImpactFeedbackGenerator(style: .light)
    private static var loggedFirstTap = false

    /// While a dictation records or transcribes, the click is skipped but
    /// the haptic stays: iOS mutes system sounds under an active recording
    /// session anyway (the audible result is a click chopped off mid-play),
    /// and the live microphone should not hear key clicks at all. The
    /// keyboard model drives this from its session state.
    static var clicksMuted = false

    /// One key tap. `click: false` for keys whose action opens or drives the
    /// dictation itself: their click would be cut off by the session the
    /// moment it activates.
    static func tap(click: Bool = true) {
        haptic.impactOccurred()
        if click, !clicksMuted {
            // 1104 is the system keyboard click.
            AudioServicesPlaySystemSound(1104)
        }
        if !loggedFirstTap {
            loggedFirstTap = true
            KeyboardDiagnostics.record("key feedback tap fired")
        }
    }
}
