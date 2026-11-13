import Foundation

/// The space key's trackpad gesture: rest a finger on the key past a hold
/// and the keyboard becomes a cursor trackpad; slide to move the insertion
/// point, release to leave it there — like the system keyboard's
/// hold-space cursor mode.
///
/// Pure arithmetic over touch x and time (no UIKit), so the keyboard view
/// stays thin and the gesture itself runs in `swift test` on a Mac. The
/// view owns the hold timer and calls ``holdElapsed(at:)`` when it fires;
/// the character steps ``moved(x:at:)`` returns go to the text proxy's
/// relative cursor move, the only cursor API a keyboard extension has.
public struct SpaceTrackpad: Sendable, Equatable {

    /// The tunable feel of the gesture. Distances are keyboard points,
    /// times are seconds on one clock the caller chooses.
    public struct Tuning: Sendable, Equatable {
        /// How long the finger must rest on the key before the trackpad
        /// engages. The view's hold timer reads this: the state machine
        /// itself only asks, when the timer fires, that it is still
        /// pressing (see ``holdElapsed(at:)``).
        public var holdSeconds = 0.28
        /// Sliding farther than this from the touch-down point before the
        /// hold elapses cancels the gesture: no space, no trackpad (a drag
        /// across the key, not a press of it).
        public var cancelSlop = 20.0
        /// Horizontal distance per one-character step at sliding speed.
        public var pointsPerChar = 18.0
        /// Above this speed (points per second) a flick counts each point
        /// ``flingBoost`` times, so a fast swipe jumps many characters. A
        /// deliberate drag reaches about 1000; a flick is 3000 and up.
        public var flingVelocity = 1500.0
        public var flingBoost = 3.0

        public init() {}
    }

    /// Where the gesture stands.
    public enum Phase: Sendable, Equatable {
        /// No touch, or the last one is over.
        case idle
        /// Finger down, within the slop, waiting for the hold to elapse.
        case pressing
        /// The keyboard is a trackpad: slides move the cursor.
        case trackpad
        /// The finger slid out before the hold elapsed: the release does
        /// nothing.
        case cancelled
    }

    /// What the finger lifting does.
    public enum Release: Sendable, Equatable {
        /// A plain tap: the space key's normal action.
        case space
        /// The trackpad is over; the cursor stays where the slide left it.
        case trackpadEnded
        /// The gesture cancelled before engaging (or never began).
        case none
    }

    public private(set) var phase: Phase = .idle
    public let tuning: Tuning
    /// Where the touch went down.
    private var startX = 0.0
    private var lastX = 0.0
    private var lastAt = 0.0
    /// Character distance moved but not yet emitted as whole steps,
    /// positive to the right.
    private var charCarry = 0.0

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    // MARK: - Events

    /// The finger touched down at `x`.
    public mutating func began(x: Double, at time: Double) {
        phase = .pressing
        startX = x
        lastX = x
        lastAt = time
        charCarry = 0
    }

    /// The hold timer fired with the finger still down. Returns whether the
    /// trackpad engaged; a cancelled gesture never revives.
    @discardableResult
    public mutating func holdElapsed(at time: Double) -> Bool {
        guard phase == .pressing else { return false }
        phase = .trackpad
        lastAt = time
        return true
    }

    /// The finger moved to `x`. Returns whole character steps the cursor
    /// should take (positive right): zero unless the trackpad is engaged,
    /// and always zero while the gesture is within its cancel slop.
    public mutating func moved(x: Double, at time: Double) -> Int {
        defer {
            lastX = x
            lastAt = time
        }
        switch phase {
        case .pressing:
            // The slop is measured from the touch-down point, so small
            // jitters of a resting finger never cancel the hold.
            if abs(x - startX) > tuning.cancelSlop {
                phase = .cancelled
            }
            return 0
        case .trackpad:
            // A clock that reports no progress (or went backwards) still
            // moves the cursor: one frame of the display's refresh is the
            // least time a move can take.
            let elapsed = max(time - lastAt, 1.0 / 120)
            let distance = x - lastX
            let speed = abs(distance) / elapsed
            let effective = speed > tuning.flingVelocity
                ? distance * tuning.flingBoost
                : distance
            charCarry += effective / tuning.pointsPerChar
            // Emit only whole characters, keeping the remainder so a slow
            // crawl still adds up across frames.
            let steps = Int(charCarry.rounded(.towardZero))
            charCarry -= Double(steps)
            return steps
        case .idle, .cancelled:
            return 0
        }
    }

    /// The finger lifted.
    public mutating func ended() -> Release {
        defer {
            phase = .idle
            charCarry = 0
        }
        switch phase {
        case .idle, .cancelled: return .none
        case .pressing: return .space
        case .trackpad: return .trackpadEnded
        }
    }
}
