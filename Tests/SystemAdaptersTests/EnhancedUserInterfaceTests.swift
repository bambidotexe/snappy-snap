import Testing
@testable import SystemAdapters

/// The bracket every window write is made in, against closures that stand in for the application: no
/// Accessibility is asked. What is pinned is the order of the calls, because the order is the rule —
/// the writes have to happen while the attribute reads off, and the attribute has to be put back on
/// after them.
@Suite struct EnhancedUserInterfaceTests {

    /// Records every call the bracket makes, and answers the reads from a script.
    private final class App {
        enum Call: Equatable { case read, set(Bool), writes }
        var calls: [Call] = []
        var answers: [Bool?]

        init(answers: [Bool?]) { self.answers = answers }

        func read() -> Bool? {
            calls.append(.read)
            return answers.isEmpty ? nil : answers.removeFirst()
        }

        func set(_ on: Bool) { calls.append(.set(on)) }

        func bracket(_ result: Int = 1) -> (Int, EnhancedUserInterface.Finding) {
            var runs = 0
            return EnhancedUserInterface.bracket(read: read, set: set) {
                calls.append(.writes)
                runs += 1
                return result * runs
            }
        }
    }

    @Test func anApplicationWithTheAttributeOffIsWrittenOnceAndNeverTouched() {
        let app = App(answers: [false])
        let (result, finding) = app.bracket()
        #expect(app.calls == [.read, .writes])
        #expect(result == 1)
        #expect(finding == .off)
    }

    /// An application that does not answer the read is written as if the attribute were off: the
    /// bracket must never be the reason a write is skipped.
    @Test func anUnansweredReadWritesOnceAndTouchesNothing() {
        let app = App(answers: [nil])
        let (result, finding) = app.bracket()
        #expect(app.calls == [.read, .writes])
        #expect(result == 1)
        #expect(finding == .unknown)
    }

    @Test func anApplicationWithTheAttributeOnIsWrittenWithItOffAndGetsItBack() {
        let app = App(answers: [true, false])
        let (result, finding) = app.bracket()
        #expect(app.calls == [.read, .set(false), .writes, .read, .set(true)])
        #expect(result == 1)
        #expect(finding == .on)
    }

    /// A client that turns it back on while the writes run (Granola does, every 0.56 s, on Chrome
    /// during a Meet) may have cost some of them: they are made once more with it off, and the answer
    /// is the second run's.
    @Test func turnedBackOnDuringTheWritesWritesOnceMoreWithItOff() {
        let app = App(answers: [true, true])
        let (result, finding) = app.bracket(10)
        #expect(app.calls == [.read, .set(false), .writes, .read, .set(false), .writes, .set(true)])
        #expect(result == 20, "the answer is the second run's")
        #expect(finding == .onAgainDuringWrites)
    }

    /// Once more, and only once: a client flipping it twice inside one step would be flipping it every
    /// few milliseconds, and the next step is the retry for that.
    @Test func theWritesAreMadeAtMostTwice() {
        let app = App(answers: [true, true, true, true])
        _ = app.bracket()
        #expect(app.calls.filter { $0 == .writes }.count == 2)
        #expect(app.calls.last == .set(true))
    }
}
