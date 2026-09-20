import CoreGraphics
import Testing
@testable import SnapCore

@Suite struct PressReconcilerTests {
    private let press = CGPoint(x: 400, y: 300)

    @Test func aPressTheSessionDeliversIsNeverDeliveredTwice() {
        var reconciler = PressReconciler()
        reconciler.deviceDown(at: press, timestamp: 10)
        let answer1 = reconciler.sessionDown(timestamp: 10)
        #expect(answer1)
        let answer2 = reconciler.sessionDragged()
        #expect(answer2 == nil)
        let answer3 = reconciler.deviceUp(timestamp: 20)
        #expect(!answer3)
        let answer4 = reconciler.sessionUp(timestamp: 20)
        #expect(answer4)
    }

    @Test func aPressTheSessionNeverSawIsDeliveredBeforeItsFirstDrag() {
        var reconciler = PressReconciler()
        reconciler.deviceDown(at: press, timestamp: 10)
        let answer5 = reconciler.sessionDragged()
        #expect(answer5 == press)
        let answer6 = reconciler.sessionDragged()
        #expect(answer6 == nil)
        let answer7 = reconciler.deviceUp(timestamp: 20)
        #expect(answer7)
    }

    @Test func aSwallowedPressThatNeverDragsDeliversNothing() {
        var reconciler = PressReconciler()
        reconciler.deviceDown(at: press, timestamp: 10)
        let answer8 = reconciler.deviceUp(timestamp: 20)
        #expect(!answer8)
        let answer9 = reconciler.sessionDragged()
        #expect(answer9 == nil)
    }

    @Test func theSessionAnsweringFirstStillClaimsThePress() {
        var reconciler = PressReconciler()
        let answer10 = reconciler.sessionDown(timestamp: 10)
        #expect(answer10)
        reconciler.deviceDown(at: press, timestamp: 10)
        let answer11 = reconciler.sessionDragged()
        #expect(answer11 == nil)
        let answer12 = reconciler.deviceUp(timestamp: 20)
        #expect(!answer12)
    }

    @Test func aReleaseDeliveredFromTheDeviceIsNotDeliveredAgainByTheSession() {
        var reconciler = PressReconciler()
        reconciler.deviceDown(at: press, timestamp: 10)
        _ = reconciler.sessionDragged()
        let answer13 = reconciler.deviceUp(timestamp: 20)
        #expect(answer13)
        let answer14 = reconciler.sessionUp(timestamp: 20)
        #expect(!answer14)
        let answer15 = reconciler.sessionUp(timestamp: 30)
        #expect(answer15)
    }

    @Test func aGestureAfterASwallowedOneStartsClean() {
        var reconciler = PressReconciler()
        reconciler.deviceDown(at: press, timestamp: 10)
        _ = reconciler.sessionDragged()
        _ = reconciler.deviceUp(timestamp: 20)
        reconciler.deviceDown(at: press, timestamp: 30)
        let answer16 = reconciler.sessionDown(timestamp: 30)
        #expect(answer16)
        let answer17 = reconciler.sessionDragged()
        #expect(answer17 == nil)
        let answer18 = reconciler.deviceUp(timestamp: 40)
        #expect(!answer18)
    }
}
