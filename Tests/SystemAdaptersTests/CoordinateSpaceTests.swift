import Testing
import CoreGraphics
@testable import SystemAdapters

@Suite struct CoordinateSpaceTests {
    // Primary display 1440×900. A Cocoa rect 100 pt tall whose bottom is at y=50
    // sits 750 pt below the top edge in CG space.
    @Test func cocoaToCGFlipsY() {
        let cocoa = CGRect(x: 10, y: 50, width: 200, height: 100)
        let cg = CoordinateSpace.cgRect(fromCocoa: cocoa, primaryHeight: 900)
        #expect(cg == CGRect(x: 10, y: 750, width: 200, height: 100))
    }

    @Test func conversionIsAnInvolution() {
        let cg = CGRect(x: 300, y: 120, width: 640, height: 480)
        let back = CoordinateSpace.cgRect(fromCocoa: CoordinateSpace.cocoaRect(fromCG: cg, primaryHeight: 900), primaryHeight: 900)
        #expect(back == cg)
    }

    @Test func pointConversion() {
        #expect(CoordinateSpace.cgPoint(fromCocoa: CGPoint(x: 5, y: 900), primaryHeight: 900) == CGPoint(x: 5, y: 0))
    }
}
