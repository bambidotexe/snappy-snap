import Testing
import CoreGraphics
@testable import SnapCore

/// The custom areas held under Command: what the configuration means, and where each area lands.
///
/// Rects are compared through `expectRect`, never with `#expect(a == b)` on a `CGFloat` and a `Double`:
/// that comparison boxes both and reports identical bit patterns as unequal.
@Suite struct CustomZonesTests {
    /// The built-in display: 1512 × 982, menu bar 37, Dock 45, so a 1512 × 900 working area at y 37.
    let builtIn = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                              visibleFrame: CGRect(x: 0, y: 37, width: 1512, height: 900),
                              name: "Built-in Retina Display", isBuiltIn: true)
    /// An attached 1920 × 1080 monitor to the right, with a 1920 × 1055 working area.
    let monitor = DisplayInfo(id: 2, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                              visibleFrame: CGRect(x: 1512, y: 25, width: 1920, height: 1055),
                              name: "Y27qf-30", isBuiltIn: false)
    let gap = 8.0

    func zones(_ json: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> CustomZones {
        let parse = CustomZones.parse(json)
        return try #require(parse.zones, "\(parse.problem ?? "no zones")", sourceLocation: sourceLocation)
    }

    func problem(_ json: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        try #require(CustomZones.parse(json).problem, "expected a failure", sourceLocation: sourceLocation)
    }

    func expectRect(_ actual: CGRect?, _ expected: CGRect,
                    sourceLocation: SourceLocation = #_sourceLocation) throws {
        let actual = try #require(actual, sourceLocation: sourceLocation)
        #expect(abs(Double(actual.minX) - Double(expected.minX)) < 0.001, sourceLocation: sourceLocation)
        #expect(abs(Double(actual.minY) - Double(expected.minY)) < 0.001, sourceLocation: sourceLocation)
        #expect(abs(Double(actual.width) - Double(expected.width)) < 0.001, sourceLocation: sourceLocation)
        #expect(abs(Double(actual.height) - Double(expected.height)) < 0.001, sourceLocation: sourceLocation)
    }

    // MARK: - What ships

    /// The text a user who has never opened the editor has, and the text the Settings page shows as a
    /// reference. Both are written by hand, so both are parsed here rather than trusted.
    @Test func theDefaultConfigurationAndTheExampleBothParse() throws {
        #expect(try zones(CustomZones.defaultConfiguration).areaCount == 1)
        #expect(try zones(CustomZones.example).areaCount == 1)
    }

    /// The default is one almost-maximized area: nine tenths of the working area, centred, on the
    /// built-in display. Its two resolution keys do not claim a 1512 × 982 panel.
    @Test func theDefaultConfigurationCentresOneAreaOnTheBuiltInDisplay() throws {
        let areas = try zones(CustomZones.defaultConfiguration).areas(on: builtIn, gap: gap)
        #expect(areas.rects.count == 1)
        // 0.9 of 1512 × 900 is 1360.8 × 810, centred in a working area at y 37, then half a gap in on
        // every side because no side of it lies on the working area's own edge.
        try expectRect(areas.rects.first, CGRect(x: 75.6 + 4, y: 37 + 45 + 4,
                                                 width: 1360.8 - 8, height: 810 - 8))
    }

    /// An attached 1920 × 1080 monitor takes the resolution key, not `*`: 1440 × 900 rather than 0.8 of
    /// the working area.
    @Test func theDefaultConfigurationTakesTheResolutionKeyOnAMatchingMonitor() throws {
        let areas = try zones(CustomZones.defaultConfiguration).areas(on: monitor, gap: gap)
        let rect = try #require(areas.rects.first)
        #expect(abs(Double(rect.width) - (1440 - 8)) < 0.001)
        #expect(abs(Double(rect.height) - (900 - 8)) < 0.001)
    }

    // MARK: - Selectors

    /// The four kinds of key rank by specificity and **not** by where they are written: the exact name
    /// wins from the bottom of the object just as it would from the top.
    @Test func anExactNameBeatsTheBuiltInTokenWhichBeatsResolutionWhichBeatsTheWildcard() throws {
        let json = """
        [
          {
            "*": { "bounds": { "x": 0, "y": 0, "width": 100, "height": 100 } },
            "screenResolution:1512x982": { "bounds": { "x": 0, "y": 0, "width": 200, "height": 200 } },
            "screenName:built-in": { "bounds": { "x": 0, "y": 0, "width": 300, "height": 300 } },
            "screenName:Built-in Retina Display": { "bounds": { "x": 0, "y": 0, "width": 400, "height": 400 } }
          }
        ]
        """
        let all = try zones(json)
        #expect(Double(try #require(all.areas(on: builtIn, gap: 0).rects.first).width) == 400)

        // Drop the exact name and the token takes it; drop that and the resolution does; then `*`.
        let noName = json.replacingOccurrences(of: "\"screenName:Built-in Retina Display\"", with: "\"screenName:nobody\"")
        #expect(Double(try #require(try zones(noName).areas(on: builtIn, gap: 0).rects.first).width) == 300)
        let noToken = noName.replacingOccurrences(of: "\"screenName:built-in\"", with: "\"screenName:nobody-either\"")
        #expect(Double(try #require(try zones(noToken).areas(on: builtIn, gap: 0).rects.first).width) == 200)
        let noResolution = noToken.replacingOccurrences(of: "screenResolution:1512x982", with: "screenResolution:640x480")
        #expect(Double(try #require(try zones(noResolution).areas(on: builtIn, gap: 0).rects.first).width) == 100)
    }

    /// `built-in` is a reserved word answered by the display's own flag, not by its name, so it keeps
    /// working whatever Apple calls the panel. Both spellings, either case.
    @Test func theBuiltInTokenReadsTheFlagAndNotTheName() throws {
        for token in ["built-in", "builtin", "BUILT-IN", "BuiltIn"] {
            let json = """
            [{ "screenName:\(token)": { "bounds": { "x": 0, "y": 0, "width": 300, "height": 300 } } }]
            """
            #expect(try zones(json).areas(on: builtIn, gap: 0).rects.count == 1, "\(token) missed the built-in display")
            #expect(try zones(json).areas(on: monitor, gap: 0).rects.isEmpty, "\(token) claimed an external monitor")
        }
        // A display whose name happens to be "built-in" but which macOS does not report as built in is
        // not claimed by the token: the flag is the whole test.
        let impostor = DisplayInfo(id: 3, frame: monitor.frame, visibleFrame: monitor.visibleFrame,
                                   name: "built-in", isBuiltIn: false)
        let json = #"[{ "screenName:built-in": { "bounds": { "x": 0, "y": 0, "width": 300, "height": 300 } } }]"#
        #expect(try zones(json).areas(on: impostor, gap: 0).rects.isEmpty)
    }

    /// Names compare exactly — case and surrounding space aside. A substring must not match, or the two
    /// monitors macOS calls "Y27qf-30" and "Y27qf-30 (1)" could never be told apart.
    @Test func aNameMatchesExactlyAndNeverAsASubstring() throws {
        func claims(_ key: String, _ display: DisplayInfo) throws -> Bool {
            let json = """
            [{ "screenName:\(key)": { "bounds": { "x": 0, "y": 0, "width": 300, "height": 300 } } }]
            """
            return try !zones(json).areas(on: display, gap: 0).rects.isEmpty
        }
        #expect(try claims("Y27qf-30", monitor))
        #expect(try claims("y27QF-30", monitor), "case must not matter")
        #expect(try claims("  Y27qf-30  ", monitor), "surrounding space must not matter")
        #expect(try !claims("Y27qf", monitor), "a prefix must not match")
        #expect(try !claims("Y27qf-30 (1)", monitor), "a longer name must not match")

        let second = DisplayInfo(id: 4, frame: monitor.frame, visibleFrame: monitor.visibleFrame,
                                 name: "Y27qf-30 (1)", isBuiltIn: false)
        #expect(try !claims("Y27qf-30", second), "the shorter name must not claim the other monitor")
        #expect(try claims("Y27qf-30 (1)", second))
    }

    /// The frame, not the working area, and within the tolerance on each side.
    @Test func aResolutionMatchesTheFrameWithinTheTolerance() throws {
        func claims(_ key: String, _ display: DisplayInfo) throws -> Bool {
            let json = """
            [{ "screenResolution:\(key)": { "bounds": { "x": 0, "y": 0, "width": 300, "height": 300 } } }]
            """
            return try !zones(json).areas(on: display, gap: 0).rects.isEmpty
        }
        #expect(try claims("1512x982", builtIn))
        #expect(try !claims("1512x900", builtIn), "the working area's height must not match")
        let tolerance = Settings.Fixed.customAreaResolutionTolerance
        #expect(try claims("1512x\(982 - tolerance)", builtIn))
        #expect(try !claims("1512x\(982 - tolerance * 3)", builtIn))
    }

    /// A matched `null` says the area is not on this display, and **stops**: a `*` written beside it is
    /// not consulted. That is the only way to take one area off one screen and leave it on the others.
    @Test func aMatchedNullStopsTheSearchInsteadOfFallingThroughToTheWildcard() throws {
        let json = """
        [
          {
            "screenName:Y27qf-30": null,
            "*": { "bounds": { "x": 0, "y": 0, "width": 300, "height": 300 } }
          }
        ]
        """
        let all = try zones(json)
        #expect(all.areaCount == 1, "the element is still an area, it simply has none on that display")
        #expect(all.areas(on: monitor, gap: 0).rects.isEmpty, "null must not fall through to *")
        #expect(all.areas(on: builtIn, gap: 0).rects.count == 1, "every other display still takes *")
    }

    /// No key matching at all is the same as a matched `null`, and neither affects the other elements.
    @Test func anElementWithNoMatchingKeyContributesNothingAndLeavesTheOthersAlone() throws {
        let json = """
        [
          { "screenName:absent": { "bounds": { "x": 0, "y": 0, "width": 300, "height": 300 } } },
          { "*": { "bounds": { "x": 0, "y": 0, "width": 400, "height": 400 } } }
        ]
        """
        let areas = try zones(json).areas(on: builtIn, gap: 0)
        #expect(areas.rects.count == 1)
        #expect(Double(try #require(areas.rects.first).width) == 400)
    }

    // MARK: - Where an area lands

    /// `bounds` is measured from the working area's top-left, not the display's, so the menu bar is
    /// already excluded.
    @Test func boundsAreMeasuredFromTheWorkingAreasTopLeft() throws {
        let json = #"[{ "*": { "bounds": { "x": 100, "y": 100, "width": 960, "height": 700 } } }]"#
        let areas = try zones(json).areas(on: builtIn, gap: 0)
        try expectRect(areas.rects.first, CGRect(x: 100, y: 37 + 100, width: 960, height: 700))
    }

    /// Every anchor puts the area's own anchor point on the working area's. With no offset, `top-left`
    /// is flush with the corner, `center` is centred, `bottom-right` is flush with the far corner.
    @Test func eachAnchorPutsTheAreasOwnAnchorPointOnTheWorkingAreas() throws {
        let cases: [(String, CGPoint)] = [
            ("top-left", CGPoint(x: 0, y: 0)),
            ("top", CGPoint(x: 556, y: 0)),
            ("top-right", CGPoint(x: 1112, y: 0)),
            ("left", CGPoint(x: 0, y: 350)),
            ("center", CGPoint(x: 556, y: 350)),
            ("right", CGPoint(x: 1112, y: 350)),
            ("bottom-left", CGPoint(x: 0, y: 700)),
            ("bottom", CGPoint(x: 556, y: 700)),
            ("bottom-right", CGPoint(x: 1112, y: 700)),
        ]
        for (anchor, origin) in cases {
            let json = """
            [{ "*": { "anchor": "\(anchor)", "size": { "width": 400, "height": 200 } } }]
            """
            let areas = try zones(json).areas(on: builtIn, gap: 0)
            try expectRect(areas.rects.first,
                           CGRect(x: origin.x, y: 37 + origin.y, width: 400, height: 200))
        }
    }

    /// `offset` displaces the area from its anchor, x right and y down, and defaults to nothing.
    @Test func anOffsetDisplacesTheAreaFromItsAnchor() throws {
        let json = """
        [{ "*": { "anchor": "top-left", "offset": { "x": 20, "y": 40 },
                  "size": { "width": 800, "height": 600 } } }]
        """
        let areas = try zones(json).areas(on: builtIn, gap: 0)
        try expectRect(areas.rects.first, CGRect(x: 20, y: 37 + 40, width: 800, height: 600))

        // One axis alone is legal; the other stays 0.
        let oneAxis = #"[{ "*": { "anchor": "top-left", "offset": { "y": 40 }, "size": { "width": 800, "height": 600 } } }]"#
        try expectRect(try zones(oneAxis).areas(on: builtIn, gap: 0).rects.first,
                       CGRect(x: 0, y: 37 + 40, width: 800, height: 600))
    }

    /// A percentage is a fraction of the working area's own extent on that axis, and the two axes may
    /// be written differently.
    @Test func aPercentageIsAFractionOfTheWorkingAreaAndTheAxesMayBeMixed() throws {
        let json = #"[{ "*": { "anchor": "top-left", "size": { "widthPercent": 0.5, "heightPercent": 0.25 } } }]"#
        try expectRect(try zones(json).areas(on: builtIn, gap: 0).rects.first,
                       CGRect(x: 0, y: 37, width: 756, height: 225))

        let mixed = #"[{ "*": { "anchor": "top-left", "size": { "width": 400, "heightPercent": 0.5 } } }]"#
        try expectRect(try zones(mixed).areas(on: builtIn, gap: 0).rects.first,
                       CGRect(x: 0, y: 37, width: 400, height: 450))
    }

    // MARK: - The gap

    /// A side lying on the working area's own edge takes a whole gap; every other side takes half of
    /// one. So an area written flush into a corner sits one gap in from both edges.
    @Test func aSideOnTheWorkingAreasEdgeTakesAWholeGapAndEveryOtherSideTakesHalf() throws {
        let json = #"[{ "*": { "bounds": { "x": 0, "y": 0, "width": 756, "height": 900 } } }]"#
        let areas = try zones(json).areas(on: builtIn, gap: gap)
        // Left, top and bottom lie on the working area; the right edge is inside it.
        try expectRect(areas.rects.first,
                       CGRect(x: 8, y: 37 + 8, width: 756 - 8 - 4, height: 900 - 16))
    }

    /// The reason the rule is written that way: two areas written flush against each other end exactly
    /// one gap apart, which is what every other zone in the app does.
    @Test func twoAreasWrittenFlushEndExactlyOneGapApart() throws {
        let json = """
        [
          { "*": { "bounds": { "x": 0, "y": 0, "width": 756, "height": 900 } } },
          { "*": { "bounds": { "x": 756, "y": 0, "width": 756, "height": 900 } } }
        ]
        """
        let rects = try zones(json).areas(on: builtIn, gap: gap).rects
        #expect(rects.count == 2)
        #expect(abs((Double(rects[1].minX) - Double(rects[0].maxX)) - gap) < 0.001)
    }

    /// With the gap switched off nothing is inset at all: the numbers written are the frame taken.
    @Test func withNoGapTheWrittenNumbersAreTheFrame() throws {
        let json = #"[{ "*": { "bounds": { "x": 0, "y": 0, "width": 756, "height": 900 } } }]"#
        try expectRect(try zones(json).areas(on: builtIn, gap: 0).rects.first,
                       CGRect(x: 0, y: 37, width: 756, height: 900))
    }

    /// An area the gap would swallow is dropped rather than offered inside out: a negative extent would
    /// make `CGRect.contains` standardize it into a rectangle that is not where it was written.
    @Test func anAreaTheGapSwallowsIsDroppedRatherThanTurnedInsideOut() throws {
        let json = #"[{ "*": { "bounds": { "x": 100, "y": 100, "width": 4, "height": 4 } } }]"#
        #expect(try zones(json).areas(on: builtIn, gap: gap).rects.isEmpty)
    }

    // MARK: - Overlap

    /// Areas may overlap freely; the pointer is in the **first written** of the ones that hold it.
    @Test func theFirstElementHoldingThePointerIsTheOneItIsIn() throws {
        let json = """
        [
          { "*": { "bounds": { "x": 100, "y": 100, "width": 200, "height": 200 } } },
          { "*": { "bounds": { "x": 0, "y": 0, "width": 1000, "height": 800 } } }
        ]
        """
        let areas = try zones(json).areas(on: builtIn, gap: 0)
        #expect(areas.index(at: CGPoint(x: 150, y: 37 + 150)) == 0, "inside both, the first wins")
        #expect(areas.index(at: CGPoint(x: 50, y: 37 + 50)) == 1, "inside only the second")
        #expect(areas.index(at: CGPoint(x: 1400, y: 37 + 50)) == nil, "inside neither")
    }

    // MARK: - Comments

    /// The configuration is written by hand, so it takes comments. They are allowed anywhere whitespace
    /// is, and a `//` inside a string stays part of the string.
    @Test func commentsAreAllowedWhereverWhitespaceIs() throws {
        let json = """
        // before the document
        [
          /* an area */
          {
            // a key
            "*": { "anchor": "center", /* between members */ "size": { "width": 400, "height": 200 } }
          } // after the element
        ]
        /* after the document */
        """
        let areas = try zones(json).areas(on: builtIn, gap: 0)
        try expectRect(areas.rects.first, CGRect(x: 556, y: 37 + 350, width: 400, height: 200))
    }

    /// A `/` inside a string is an ordinary character, or a display named "a/b" could never be selected.
    @Test func aSlashInsideAStringIsNotAComment() throws {
        let named = DisplayInfo(id: 5, frame: monitor.frame, visibleFrame: monitor.visibleFrame,
                                name: "a//b /* c */ d", isBuiltIn: false)
        let json = """
        [{ "screenName:a//b /* c */ d": { "bounds": { "x": 0, "y": 0, "width": 300, "height": 300 } } }]
        """
        #expect(try zones(json).areas(on: named, gap: 0).rects.count == 1)
    }

    /// A comment is source text, so a failure below one still names its own line.
    @Test func aCommentDoesNotShiftTheLineNumberOfAFailureBelowIt() throws {
        let json = """
        [
          /* one
             two
             three */
          { "*": }
        ]
        """
        #expect(try problem(json).contains("line 5"))
    }

    /// An unclosed block comment would otherwise swallow the rest of the configuration in silence.
    @Test func anUnclosedBlockCommentIsReported() throws {
        #expect(try problem("[ /* never closed ]").contains("never closed"))
    }

    // MARK: - What a failure says

    /// A failure names where it is, because the user is looking at a text editor and has to find it.
    @Test func aFailureNamesTheArrayIndexAndTheKey() throws {
        let unknownKey = """
        [
          { "*": { "bounds": { "x": 0, "y": 0, "width": 10, "height": 10 } } },
          { "screenName:x": { "anchor": "center", "size": { "width": 10, "height": 10 }, "wat": 1 } }
        ]
        """
        let message = try problem(unknownKey)
        #expect(message.contains("[1]"), "names the element: \(message)")
        #expect(message.contains("screenName:x"), "names the key: \(message)")
        #expect(message.contains("wat"), "names what is wrong: \(message)")
    }

    /// The selector is checked before anything inside it, so a typo in the key is reported as one.
    @Test func aKeyThatIsNotASelectorIsReportedAsOne() throws {
        let message = try problem(#"[{ "screenname:x": { "bounds": { "x": 0, "y": 0, "width": 1, "height": 1 } } }]"#)
        #expect(message.contains("not a screen selector"), "\(message)")
    }

    /// The two ways of writing an area are alternatives, and mixing them is a mistake worth naming.
    @Test func boundsCannotBeCombinedWithAnAnchor() throws {
        let message = try problem("""
        [{ "*": { "bounds": { "x": 0, "y": 0, "width": 1, "height": 1 }, "anchor": "center" } }]
        """)
        #expect(message.contains("bounds"), "\(message)")
    }

    /// A percentage outside 0…1 is a number the user meant as a percent sign, and a zero or negative
    /// extent is an area that cannot hold a pointer.
    @Test func sizesAreRejectedWhenTheyCannotDescribeAnArea() throws {
        #expect(try problem(#"[{ "*": { "anchor": "center", "size": { "widthPercent": 90, "heightPercent": 0.5 } } }]"#)
            .contains("fraction"))
        #expect(try problem(#"[{ "*": { "bounds": { "x": 0, "y": 0, "width": 0, "height": 10 } } }]"#)
            .contains("greater than 0"))
    }

    /// The top level is an array of areas. Anything else is the user's first mistake and says so.
    @Test func theTopLevelMustBeAnArray() throws {
        #expect(try problem(#"{ "*": { "bounds": { "x": 0, "y": 0, "width": 1, "height": 1 } } }"#)
            .contains("array"))
        #expect(try problem("").contains("empty"))
    }

    /// An empty array is a configuration that offers nothing — not a failure, and not a reason to fall
    /// back to anything.
    @Test func anEmptyArrayIsValidAndOffersNoAreas() throws {
        let all = try zones("[]")
        #expect(all.areaCount == 0)
        #expect(all.areas(on: builtIn, gap: gap).rects.isEmpty)
    }
}
