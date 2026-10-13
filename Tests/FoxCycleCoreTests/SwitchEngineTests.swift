import Testing
@testable import FoxCycleCore

@Suite struct SwitchEngineTests {
    let ms: UInt64 = 1_000_000
    let ring4 = ring("A1", "A2", "B1", "C1")

    /// Activates everything successfully and records the call order.
    final class Recorder {
        var calls: [String] = []
        var outcomes: [String: ActivationOutcome] = [:]
        func activate(_ id: String) -> ActivationOutcome {
            calls.append(id)
            return outcomes[id] ?? .activated
        }
    }

    @Test func startsFromFocusedWindow() {
        var engine = SwitchEngine<String>()
        let recorder = Recorder()
        let report = engine.performSwitch(direction: .forward, ring: ring4, now: { 0 },
                                          focusedWindow: { "B1" }, activate: recorder.activate)
        #expect(report.currentSource == .focused)
        #expect(report.outcome == .activated("C1"))
        #expect(recorder.calls == ["C1"])
    }

    @Test func trustsLastTargetWhileFocusLags() {
        var engine = SwitchEngine<String>(trustLastTargetNanos: 750 * ms)
        let recorder = Recorder()
        var clock: UInt64 = 0
        _ = engine.performSwitch(direction: .forward, ring: ring4, now: { clock },
                                 focusedWindow: { "A1" }, activate: recorder.activate)
        clock = 100 * ms
        // AX still reports A1 (switch to A2 not visible yet); without trust this would bounce back to A2.
        let report = engine.performSwitch(direction: .forward, ring: ring4, now: { clock },
                                          focusedWindow: { "A1" }, activate: recorder.activate)
        #expect(report.currentSource == .lastTarget)
        #expect(recorder.calls == ["A2", "B1"])
    }

    @Test func fallsBackToFocusedAfterTrustWindow() {
        var engine = SwitchEngine<String>(trustLastTargetNanos: 750 * ms)
        let recorder = Recorder()
        var clock: UInt64 = 0
        _ = engine.performSwitch(direction: .forward, ring: ring4, now: { clock },
                                 focusedWindow: { "A1" }, activate: recorder.activate)
        clock = 2_000 * ms
        // The user clicked C1 in the meantime.
        let report = engine.performSwitch(direction: .forward, ring: ring4, now: { clock },
                                          focusedWindow: { "C1" }, activate: recorder.activate)
        #expect(report.currentSource == .focused)
        #expect(report.outcome == .activated("A1"))
    }

    @Test func lastTargetThatLeftTheRingIsNotTrusted() {
        var engine = SwitchEngine<String>()
        let recorder = Recorder()
        _ = engine.performSwitch(direction: .forward, ring: ring4, now: { 0 },
                                 focusedWindow: { "A1" }, activate: recorder.activate)
        var shrunk = ring4
        shrunk.remove("A2")
        let report = engine.performSwitch(direction: .forward, ring: shrunk, now: { 1 },
                                          focusedWindow: { "B1" }, activate: recorder.activate)
        #expect(report.currentSource == .focused)
        #expect(report.outcome == .activated("C1"))
    }

    @Test func skipsWindowsThatAreGone() {
        var engine = SwitchEngine<String>()
        let recorder = Recorder()
        recorder.outcomes = ["A2": .windowGone, "B1": .windowGone]
        let report = engine.performSwitch(direction: .forward, ring: ring4, now: { 0 },
                                          focusedWindow: { "A1" }, activate: recorder.activate)
        #expect(report.windowsGone == ["A2", "B1"])
        #expect(report.outcome == .activated("C1"))
    }

    @Test func abandonsWhenTargetIsUnresponsive() {
        var engine = SwitchEngine<String>()
        let recorder = Recorder()
        recorder.outcomes = ["A2": .unresponsive]
        let report = engine.performSwitch(direction: .forward, ring: ring4, now: { 0 },
                                          focusedWindow: { "A1" }, activate: recorder.activate)
        #expect(report.outcome == .abandoned("A2"))
        #expect(recorder.calls == ["A2"])
        #expect(engine.lastTarget == nil)
    }

    @Test func reportsNoTargetWhenEverythingIsGone() {
        var engine = SwitchEngine<String>()
        let recorder = Recorder()
        recorder.outcomes = ["A2": .windowGone, "B1": .windowGone, "C1": .windowGone]
        let report = engine.performSwitch(direction: .forward, ring: ring4, now: { 0 },
                                          focusedWindow: { "A1" }, activate: recorder.activate)
        #expect(report.outcome == .noTarget)
    }

    @Test func unknownCurrentEntersRing() {
        var engine = SwitchEngine<String>()
        let recorder = Recorder()
        let forward = engine.performSwitch(direction: .forward, ring: ring4, now: { 0 },
                                           focusedWindow: { nil }, activate: recorder.activate)
        #expect(forward.currentSource == .unknown)
        #expect(forward.outcome == .activated("A1"))

        var fresh = SwitchEngine<String>()
        let backward = fresh.performSwitch(direction: .backward, ring: ring4, now: { 0 },
                                           focusedWindow: { nil }, activate: recorder.activate)
        #expect(backward.outcome == .activated("C1"))
    }

    @Test func fullLapsInBothDirections() {
        var engine = SwitchEngine<String>()
        let recorder = Recorder()
        var clock: UInt64 = 0
        for _ in 0..<8 {
            clock += 100 * ms
            _ = engine.performSwitch(direction: .forward, ring: ring4, now: { clock },
                                     focusedWindow: { nil }, activate: recorder.activate)
        }
        for _ in 0..<4 {
            clock += 100 * ms
            _ = engine.performSwitch(direction: .backward, ring: ring4, now: { clock },
                                     focusedWindow: { nil }, activate: recorder.activate)
        }
        #expect(recorder.calls == ["A1", "A2", "B1", "C1", "A1", "A2", "B1", "C1", "B1", "A2", "A1", "C1"])
    }
}
