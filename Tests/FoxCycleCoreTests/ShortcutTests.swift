import Testing
@testable import FoxCycleCore

@Suite struct ShortcutMatcherTests {
    let grave = ShortcutMatcher.graveKeyCode

    @Test func commandGraveIsForward() {
        #expect(ShortcutMatcher.direction(keyCode: grave, modifiers: [.command]) == .forward)
    }

    @Test func commandShiftGraveIsBackward() {
        #expect(ShortcutMatcher.direction(keyCode: grave, modifiers: [.command, .shift]) == .backward)
    }

    @Test(arguments: [
        Modifiers(),
        [.shift],
        [.command, .option],
        [.command, .control],
        [.command, .shift, .option],
        [.command, .shift, .control],
    ] as [Modifiers])
    func otherModifierCombinationsAreIgnored(_ modifiers: Modifiers) {
        #expect(ShortcutMatcher.direction(keyCode: grave, modifiers: modifiers) == nil)
    }

    @Test func otherKeysAreIgnored() {
        #expect(ShortcutMatcher.direction(keyCode: 48 /* Tab */, modifiers: [.command]) == nil)
        #expect(ShortcutMatcher.direction(keyCode: 10 /* ISO section */, modifiers: [.command]) == nil)
    }
}

@Suite struct InputGateTests {
    let grave = ShortcutMatcher.graveKeyCode
    let second: UInt64 = 1_000_000_000

    func ready() -> InterceptState {
        var state = InterceptState()
        state.isEnabled = true
        state.firefoxFrontmostPid = 42
        state.eligibleWindowCount = 3
        return state
    }

    @Test func switchesAndMarksInFlight() {
        var state = ready()
        let decision = InputGate.decide(keyCode: grave, modifiers: [.command], isAutorepeat: false, now: 10, state: &state)
        #expect(decision == .switchWindow(.forward, firefoxPid: 42))
        #expect(state.switchStartedAt == 10)
    }

    @Test func nonShortcutPassesThroughWithoutTouchingState() {
        var state = ready()
        let decision = InputGate.decide(keyCode: grave, modifiers: [.command, .control], isAutorepeat: false, now: 10, state: &state)
        #expect(decision == .passThrough)
        #expect(state == ready())
    }

    @Test func passesThroughWhenFirefoxIsNotFrontmost() {
        var state = ready()
        state.firefoxFrontmostPid = nil
        #expect(InputGate.decide(keyCode: grave, modifiers: [.command], isAutorepeat: false, now: 10, state: &state) == .passThrough)
    }

    @Test(arguments: [0, 1])
    func passesThroughWithFewerThanTwoWindows(_ count: Int) {
        var state = ready()
        state.eligibleWindowCount = count
        #expect(InputGate.decide(keyCode: grave, modifiers: [.command], isAutorepeat: false, now: 10, state: &state) == .passThrough)
    }

    @Test func passesThroughWhenDisabled() {
        var state = ready()
        state.isEnabled = false
        #expect(InputGate.decide(keyCode: grave, modifiers: [.command], isAutorepeat: false, now: 10, state: &state) == .passThrough)
    }

    @Test func heldKeyIsSwallowed() {
        var state = ready()
        let decision = InputGate.decide(keyCode: grave, modifiers: [.command], isAutorepeat: true, now: 10, state: &state)
        #expect(decision == .swallow(.autorepeat))
        #expect(state.switchStartedAt == nil)
    }

    @Test func heldKeyOutsideFirefoxPassesThrough() {
        var state = ready()
        state.firefoxFrontmostPid = nil
        #expect(InputGate.decide(keyCode: grave, modifiers: [.command], isAutorepeat: true, now: 10, state: &state) == .passThrough)
    }

    @Test func pressDuringInFlightSwitchIsSwallowed() {
        var state = ready()
        state.switchStartedAt = 10
        let decision = InputGate.decide(keyCode: grave, modifiers: [.command, .shift], isAutorepeat: false, now: 10 + second / 10, state: &state)
        #expect(decision == .swallow(.inFlight))
        #expect(state.switchStartedAt == 10)
    }

    @Test func staleInFlightMarkerDoesNotLockOut() {
        var state = ready()
        state.switchStartedAt = 10
        let now = 10 + InputGate.inFlightTimeoutNanos
        #expect(InputGate.decide(keyCode: grave, modifiers: [.command], isAutorepeat: false, now: now, state: &state)
            == .switchWindow(.forward, firefoxPid: 42))
        #expect(state.switchStartedAt == now)
    }
}
