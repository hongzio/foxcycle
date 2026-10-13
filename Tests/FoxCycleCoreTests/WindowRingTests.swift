import Testing
@testable import FoxCycleCore

typealias Entry = WindowRing<String>.Entry

func ring(_ ids: String...) -> WindowRing<String> {
    var ring = WindowRing<String>()
    ring.sync(present: ids.map { Entry(id: $0, isAvailable: true) })
    return ring
}

@Suite struct WindowRingTests {
    @Test func cyclesForwardAcrossProfilesWithWrapAround() {
        let ring = ring("A1", "A2", "B1", "C1")
        #expect(ring.candidates(after: "A1", direction: .forward) == ["A2", "B1", "C1"])
        #expect(ring.candidates(after: "C1", direction: .forward) == ["A1", "A2", "B1"])
    }

    @Test func cyclesBackwardWithWrapAround() {
        let ring = ring("A1", "A2", "B1", "C1")
        #expect(ring.candidates(after: "A1", direction: .backward) == ["C1", "B1", "A2"])
        #expect(ring.candidates(after: "B1", direction: .backward) == ["A2", "A1", "C1"])
    }

    @Test func unknownCurrentEntersAtStartOrEnd() {
        let ring = ring("A1", "A2", "B1")
        #expect(ring.candidates(after: nil, direction: .forward) == ["A1", "A2", "B1"])
        #expect(ring.candidates(after: nil, direction: .backward) == ["B1", "A2", "A1"])
        #expect(ring.candidates(after: "Z9", direction: .forward).first == "A1")
    }

    @Test func emptyAndSingleRings() {
        #expect(WindowRing<String>().candidates(after: nil, direction: .forward).isEmpty)
        let single = ring("A1")
        #expect(single.candidates(after: "A1", direction: .forward).isEmpty)
        #expect(single.candidates(after: nil, direction: .forward) == ["A1"])
    }

    @Test func newWindowsAreAppendedWithoutReorderingExisting() {
        var ring = ring("A1", "A2", "B1")
        // Discovery order differs (e.g. AX z-order after focus changes); existing slots must not move.
        ring.sync(present: [Entry(id: "B2", isAvailable: true), Entry(id: "B1", isAvailable: true),
                            Entry(id: "A2", isAvailable: true), Entry(id: "A1", isAvailable: true)])
        #expect(ring.ids == ["A1", "A2", "B1", "B2"])
    }

    @Test func closedWindowsAreRemoved() {
        var ring = ring("A1", "A2", "B1", "C1")
        ring.sync(present: [Entry(id: "A1", isAvailable: true), Entry(id: "B1", isAvailable: true),
                            Entry(id: "C1", isAvailable: true)])
        #expect(ring.ids == ["A1", "B1", "C1"])
        ring.remove("B1")
        #expect(ring.candidates(after: "A1", direction: .forward) == ["C1"])
    }

    @Test func minimizedWindowKeepsItsSlotAndIsSkipped() {
        var ring = ring("A1", "A2", "B1", "C1")
        ring.sync(present: [Entry(id: "A1", isAvailable: true), Entry(id: "A2", isAvailable: false),
                            Entry(id: "B1", isAvailable: true), Entry(id: "C1", isAvailable: true)])
        #expect(ring.ids == ["A1", "A2", "B1", "C1"])
        #expect(ring.availableCount == 3)
        #expect(ring.candidates(after: "A1", direction: .forward) == ["B1", "C1"])

        // Restored: back in its original slot, not at the end.
        ring.sync(present: [Entry(id: "A1", isAvailable: true), Entry(id: "A2", isAvailable: true),
                            Entry(id: "B1", isAvailable: true), Entry(id: "C1", isAvailable: true)])
        #expect(ring.candidates(after: "A1", direction: .forward) == ["A2", "B1", "C1"])
    }

    @Test func unavailableCurrentStillAnchorsPosition() {
        var ring = ring("A1", "A2", "B1")
        ring.sync(present: [Entry(id: "A1", isAvailable: true), Entry(id: "A2", isAvailable: false),
                            Entry(id: "B1", isAvailable: true)])
        #expect(ring.candidates(after: "A2", direction: .forward) == ["B1", "A1"])
    }

    @Test func repeatedFocusChangesNeverOscillate() {
        // Walking forward from each successive target visits every window once per lap (no A→B→A→B).
        let ring = ring("A1", "A2", "B1", "C1")
        var current = "A1"
        var visited: [String] = []
        for _ in 0..<8 {
            current = ring.candidates(after: current, direction: .forward)[0]
            visited.append(current)
        }
        #expect(visited == ["A2", "B1", "C1", "A1", "A2", "B1", "C1", "A1"])
    }
}
