import Testing
import CoreGraphics
@testable import SnapCore

@Suite struct ModelTests {
    @Test func centerOfRect() {
        let r = CGRect(x: 10, y: 20, width: 100, height: 50)
        #expect(r.center == CGPoint(x: 60, y: 45))
    }

    @Test func roundedToPointsRoundsEachComponent() {
        let r = CGRect(x: 10.4, y: 20.6, width: 99.5, height: 49.49)
        #expect(r.roundedToPoints() == CGRect(x: 10, y: 21, width: 100, height: 49))
    }

    @Test func approximateEqualityUsesTolerance() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 1.5, y: -1.5, width: 101, height: 99)
        #expect(a.isApproximatelyEqual(to: b, tolerance: 2))
        #expect(!a.isApproximatelyEqual(to: b, tolerance: 1))
    }
}
