import Testing
import ApplicationServices
import QuartzCore
@testable import SystemAdapters

/// The shim itself: what it resolves on this macOS, and that the switch reaches the very
/// next call rather than the next launch.
///
/// `.serialized` because `PrivateAPI.shared` is one object for the process — these tests move the
/// switch, and every one of them puts it back.
@Suite(.serialized) @MainActor struct PrivateAPITests {
    /// The inventory. A symbol added without a row in `docs/private-api-index.md` fails here first,
    /// and one added without a feature to report it under fails the test below.
    @Test func theInventoryIsNineSymbols() {
        #expect(PrivateSymbol.allCases == [
            .axUIElementGetWindow, .cgsMainConnectionID, .cgsSetConnectionProperty,
            .cgsSpaceCreate, .cgsSpaceSetAbsoluteLevel, .cgsShowSpaces, .cgsAddWindowsToSpaces,
            .caBackdropLayer, .caFilter,
        ])
        #expect(PrivateSymbol.allCases.map(\.rawValue) == [
            "_AXUIElementGetWindow", "CGSMainConnectionID", "CGSSetConnectionProperty",
            "CGSSpaceCreate", "CGSSpaceSetAbsoluteLevel", "CGSShowSpaces", "CGSAddWindowsToSpaces",
            "OBJC_CLASS_$_CABackdropLayer", "OBJC_CLASS_$_CAFilter",
        ])
        for symbol in PrivateSymbol.allCases {
            #expect(!symbol.framework.isEmpty)
        }
    }

    /// Settings reports the four things the symbols buy, in this order, rather than the symbols. Every
    /// symbol belongs to at least one of them, so none is used without the user being able to see it,
    /// and the connection id is in both features that set something on this process's connection.
    @Test func theFourFeaturesCoverEverySymbol() {
        #expect(PrivateFeature.allCases == [.windowMatching, .handlePointer, .elevatedSnapBar, .snapBarBlur])
        // `title` is localized; the English words are pinned in `LocalizationTests`.
        let titles = PrivateFeature.allCases.map(\.title)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == PrivateFeature.allCases.count)
        #expect(PrivateFeature.windowMatching.symbols == [.axUIElementGetWindow])
        #expect(PrivateFeature.handlePointer.symbols == [.cgsMainConnectionID, .cgsSetConnectionProperty])
        #expect(PrivateFeature.elevatedSnapBar.symbols == [
            .cgsMainConnectionID, .cgsSpaceCreate, .cgsSpaceSetAbsoluteLevel, .cgsShowSpaces,
            .cgsAddWindowsToSpaces,
        ])
        #expect(PrivateFeature.snapBarBlur.symbols == [.caBackdropLayer, .caFilter])
        let reported = Set(PrivateFeature.allCases.flatMap(\.symbols))
        #expect(reported == Set(PrivateSymbol.allCases))
    }

    /// A feature is there when all of its symbols are, which on the macOS this was written on is all
    /// four, and like a symbol's answer it does not follow the switch.
    @Test func aFeatureIsAvailableWhenEveryOneOfItsSymbolsIs() {
        let was = PrivateAPI.shared.isEnabled
        defer { PrivateAPI.shared.isEnabled = was }
        for enabled in [true, false] {
            PrivateAPI.shared.isEnabled = enabled
            for feature in PrivateFeature.allCases {
                let everySymbol = feature.symbols.allSatisfy { PrivateAPI.shared.isAvailable($0) }
                #expect(PrivateAPI.shared.isAvailable(feature) == everySymbol)
                #expect(PrivateAPI.shared.isAvailable(feature), "\(feature) is not whole on this macOS")
            }
        }
    }

    /// Measured on macOS 27.0 (build 26A428), the machine this was written on. A future macOS that
    /// drops one of these is allowed to fail this test — that is the test's purpose — but nothing else
    /// may fail with it, which is what every other test here is about.
    @Test func everySymbolResolvesOnThisMacOS() {
        for symbol in PrivateSymbol.allCases {
            #expect(PrivateAPI.shared.isAvailable(symbol), "\(symbol.rawValue) is not on this macOS")
        }
    }

    /// Flipping the switch takes effect on the next call. Nothing caches the pointer across the
    /// flip, and `isAvailable` answers about the machine rather than about the switch, so the Settings
    /// status lines keep telling the truth while the feature is off.
    @Test func theSwitchIsReadOnEveryCallAndDoesNotChangeWhatTheMachineHas() {
        let was = PrivateAPI.shared.isEnabled
        defer { PrivateAPI.shared.isEnabled = was }

        PrivateAPI.shared.isEnabled = true
        #expect(PrivateAPI.shared.pointer(for: .axUIElementGetWindow) != nil)
        PrivateAPI.shared.isEnabled = false
        #expect(PrivateAPI.shared.pointer(for: .axUIElementGetWindow) == nil)
        #expect(PrivateAPI.shared.isAvailable(.axUIElementGetWindow))
        PrivateAPI.shared.isEnabled = true
        #expect(PrivateAPI.shared.pointer(for: .axUIElementGetWindow) != nil)
    }

    /// With the switch off, `windowID(of:)` answers nil for every
    /// element instead of crashing, and `windows(ofPid:)` — which is where the public route lives —
    /// still hands back one handle per window.
    @Test func withTheSwitchOffNothingTrapsAndTheHandlesStillCome() {
        let was = PrivateAPI.shared.isEnabled
        defer { PrivateAPI.shared.isEnabled = was }
        PrivateAPI.shared.isEnabled = false

        let ax = AccessibilityWindows()
        #expect(ax.windowID(of: AXUIElementCreateSystemWide()) == nil)
        // A pid nothing is running under: `kAXWindows` comes back empty, the public route matches an
        // empty list against an empty list, and the answer is empty rather than a trap.
        #expect(ax.windows(ofPid: -1).isEmpty)
        #expect(ax.handle(forWindowID: 1, pid: -1) == nil)
    }

    /// The notch shape's backdrop is two Objective-C classes resolved like any other symbol, so the
    /// switch reaches them the same way: off, both makers answer nil and the caller draws no
    /// backdrop; on, the layer is a real `CABackdropLayer` told to look behind its window, and the
    /// filter carries exactly what it was given.
    @Test func theBackdropLayersFollowTheSwitchAndCarryWhatTheyWereGiven() throws {
        let was = PrivateAPI.shared.isEnabled
        defer { PrivateAPI.shared.isEnabled = was }
        let mask = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())

        PrivateAPI.shared.isEnabled = false
        #expect(!BackdropLayers.isAvailable)
        #expect(BackdropLayers.makeBackdropLayer() == nil)
        #expect(BackdropLayers.makeVariableBlur(radius: 11, mask: mask) == nil)
        #expect(BackdropLumaTracker().layer == nil)

        PrivateAPI.shared.isEnabled = true
        #expect(BackdropLayers.isAvailable)
        let layer = try #require(BackdropLayers.makeBackdropLayer())
        #expect(NSStringFromClass(type(of: layer)) == "CABackdropLayer")
        #expect(layer.value(forKey: "windowServerAware") as? Bool == true)
        let filter = try #require(BackdropLayers.makeVariableBlur(radius: 11, mask: mask))
        #expect(filter.value(forKey: "name") as? String == "variableBlur")
        #expect(filter.value(forKey: "inputRadius") as? Double == 11)
        #expect(filter.value(forKey: "inputNormalizeEdges") as? Bool == true)
        let tracker = BackdropLumaTracker()
        #expect(tracker.layer?.value(forKey: "tracksLuma") as? Bool == true)
        #expect(tracker.layer?.delegate === tracker)
    }
}
