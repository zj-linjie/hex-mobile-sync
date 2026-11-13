import Foundation
import Testing
@testable import HexMobileCore

@Suite("Space key trackpad gesture")
struct SpaceTrackpadTests {
    /// A gesture with every threshold far from the test's movements, so the
    /// tests exercise one rule at a time. The hold never elapses on its own:
    /// these tests call `holdElapsed` themselves.
    private var tuned: SpaceTrackpad.Tuning {
        var tuning = SpaceTrackpad.Tuning()
        tuning.holdSeconds = 10
        return tuning
    }

    /// `#expect` expands its expression in a closure over an immutable
    /// copy, so every mutating call goes through one of these first.
    private func moved(_ trackpad: inout SpaceTrackpad, x: Double, at time: Double) -> Int {
        trackpad.moved(x: x, at: time)
    }

    private func holdElapsed(_ trackpad: inout SpaceTrackpad, at time: Double) -> Bool {
        trackpad.holdElapsed(at: time)
    }

    private func ended(_ trackpad: inout SpaceTrackpad) -> SpaceTrackpad.Release {
        trackpad.ended()
    }

    @Test("A quick tap is a space, not a trackpad")
    func quickTapIsSpace() {
        var trackpad = SpaceTrackpad(tuning: tuned)
        trackpad.began(x: 100, at: 0)
        #expect(moved(&trackpad, x: 102, at: 0.05) == 0)
        #expect(ended(&trackpad) == .space)
        #expect(trackpad.phase == .idle)
    }

    @Test("The hold elapsing engages the trackpad")
    func holdEngages() {
        var trackpad = SpaceTrackpad(tuning: tuned)
        trackpad.began(x: 100, at: 0)
        #expect(holdElapsed(&trackpad, at: 10))
        #expect(trackpad.phase == .trackpad)
        #expect(ended(&trackpad) == .trackpadEnded)
    }

    @Test("Sliding past the slop before the hold cancels: no space, no cursor")
    func slideBeforeHoldCancels() {
        var trackpad = SpaceTrackpad(tuning: tuned)
        trackpad.began(x: 100, at: 0)
        #expect(moved(&trackpad, x: 121, at: 0.1) == 0)
        #expect(trackpad.phase == .cancelled)
        // Wandering back over the key revives nothing.
        #expect(moved(&trackpad, x: 100, at: 0.2) == 0)
        #expect(!holdElapsed(&trackpad, at: 10))
        #expect(ended(&trackpad) == .none)
    }

    @Test("Jitters within the slop keep the hold armed")
    func jitterWithinSlopKeepsPressing() {
        var trackpad = SpaceTrackpad(tuning: tuned)
        trackpad.began(x: 100, at: 0)
        for (x, time) in zip([104.0, 96, 105, 95], [0.05, 0.1, 0.15, 0.2]) {
            #expect(moved(&trackpad, x: x, at: time) == 0)
        }
        #expect(trackpad.phase == .pressing)
        #expect(holdElapsed(&trackpad, at: 10))
    }

    @Test("A slow slide steps one character per pointsPerChar")
    func slowSlideStepsCharacters() {
        var trackpad = SpaceTrackpad(tuning: tuned)
        trackpad.began(x: 100, at: 0)
        trackpad.holdElapsed(at: 10)
        // Two frames of half a character add up to one step; 18 points per
        // 20 ms frame is a 900-points-per-second drag, still below the
        // flick threshold, so nothing is boosted.
        #expect(moved(&trackpad, x: 109, at: 10.02) == 0)
        #expect(moved(&trackpad, x: 118, at: 10.04) == 1)
        #expect(moved(&trackpad, x: 136, at: 10.06) == 1)
        // Sliding back a full character's distance steps the cursor left.
        #expect(moved(&trackpad, x: 118, at: 10.08) == -1)
        #expect(ended(&trackpad) == .trackpadEnded)
    }

    @Test("A fast flick covers many characters per point")
    func fastFlickAccelerates() {
        var trackpad = SpaceTrackpad(tuning: tuned)
        trackpad.began(x: 0, at: 0)
        trackpad.holdElapsed(at: 10)
        // 80 points in 20 ms is 4000 points per second: each point counts
        // flingBoost times, so 80 points become 80×3/18 ≈ 13 characters.
        let steps = moved(&trackpad, x: 80, at: 10.02)
        #expect(steps >= 12 && steps <= 14)
    }

    @Test("A slow crawl is not accelerated")
    func slowCrawlIsNotBoosted() {
        var trackpad = SpaceTrackpad(tuning: tuned)
        trackpad.began(x: 0, at: 0)
        trackpad.holdElapsed(at: 10)
        // 80 points over half a second is 160 points per second: below the
        // flick threshold, so about 4 characters.
        let steps = moved(&trackpad, x: 80, at: 10.5)
        #expect(steps == 4)
    }

    @Test("The carry left by a release never leaks into the next gesture")
    func carryDoesNotLeak() {
        var trackpad = SpaceTrackpad(tuning: tuned)
        trackpad.began(x: 0, at: 0)
        trackpad.holdElapsed(at: 10)
        #expect(moved(&trackpad, x: 9, at: 10.02) == 0) // half a character owed
        #expect(ended(&trackpad) == .trackpadEnded)
        trackpad.began(x: 0, at: 20)
        trackpad.holdElapsed(at: 30)
        #expect(moved(&trackpad, x: 9, at: 30.02) == 0) // still only half
        #expect(moved(&trackpad, x: 18, at: 30.04) == 1)
    }

    @Test("Events without a touch move nothing")
    func strayEventsMoveNothing() {
        var trackpad = SpaceTrackpad(tuning: tuned)
        #expect(moved(&trackpad, x: 500, at: 1) == 0)
        #expect(!holdElapsed(&trackpad, at: 2))
        #expect(ended(&trackpad) == .none)
    }
}
