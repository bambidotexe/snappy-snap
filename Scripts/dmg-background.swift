#!/usr/bin/env swift
// Draws the backdrop the disk-image window shows behind its two icons: the app's name, one line on what it
// is, and an arrow from where the app sits to where the Applications folder sits. The icons themselves are
// real files, placed by the image's own layout — this only paints what is behind them.
//
//   swift dmg-background.swift <name> <accent hex> <out.png> [out@2x.png] [description]
//
// The accent is the arrow's head. The description defaults to the app's own line.
//
// The geometry below is the one `Scripts/dmg-settings.py` lays the icons out with; both must agree or the
// arrow misses the icons. Finder never scales this picture: it draws it at natural size from the top-left
// corner of the icon view, and its chrome (title bar, tab bar, path or status bar, each a per-user setting)
// eats the bottom of the canvas — up to about 120 pt. Everything that matters sits in the top 340 pt, and
// below that the canvas is flat backdrop so a crop is invisible.

import AppKit
import Foundation

// The disk-image window, in points. The icon centres are what `Scripts/dmg-settings.py` positions the two
// files at; a 128 pt icon at y = 244 spans 180–308, and Finder's 13 pt label under it ends by about 332.
let windowSize = CGSize(width: 660, height: 480)
let appIconCentre = CGPoint(x: 175, y: 244)
let dropIconCentre = CGPoint(x: 485, y: 244)
let iconSide: CGFloat = 128
let titleCentreY: CGFloat = 90
let descriptionCentreY: CGFloat = 128
let contentFloor: CGFloat = 340

// The palette is the app icon's: a warm near-black plate, a warm gunmetal snake, one red for its eye and
// tongue. The backdrop is that gunmetal lifted to paper, light enough for Finder's dark icon labels; the
// name is set in the snake's metal, darkening from top to bottom the way the icon's bevel does.
func colour(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
}
let paperTop = colour(0xF4F3EF)
let paperBottom = colour(0xEAE9E4)
let gunmetal = colour(0x888781)
let metalLight = colour(0x74736C)
let metalDark = colour(0x2E2F2B)

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("dmg-background: " + message + "\n").utf8))
    exit(1)
}

/// "#RRGGBB" or "RRGGBB".
func colour(_ hex: String) -> NSColor {
    let text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard text.count == 6, let value = UInt32(text, radix: 16) else { die("accent must be six hex digits, got \(hex)") }
    return colour(value)
}

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    die("usage: dmg-background.swift <name> <accent hex> <out.png> [out@2x.png] [description]")
}
let appName = arguments[1]
let accent = colour(arguments[2])
let description = arguments.count >= 6 ? arguments[5] : "Snap windows to halves, quarters and layouts"

/// The glyph outlines of one line of text, as a path whose origin is the line's left baseline point, and
/// the line's typographic width. Outlines rather than `draw(in:)` so the fill can be a gradient.
func textPath(_ string: String, font: NSFont, kern: CGFloat) -> (path: CGPath, width: CGFloat) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font, .kern: kern]))
    let path = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
        CTRunGetPositions(run, CFRangeMake(0, count), &positions)
        guard let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] else { continue }
        let ctFont = runFont as! CTFont
        for index in 0..<count {
            var transform = CGAffineTransform(translationX: positions[index].x, y: positions[index].y)
            if let glyph = CTFontCreatePathForGlyph(ctFont, glyphs[index], &transform) { path.addPath(glyph) }
        }
    }
    return (path, CTLineGetTypographicBounds(line, nil, nil, nil))
}

/// One chevron of the kind the snake on the icon is made of: a filled "❯" with a notched back, its tip at
/// the origin, pointing along +x. `reach` is an arm's half-height, `depth` how far back the arms go,
/// `thickness` an arm's width measured along x.
func chevron(reach: CGFloat, depth: CGFloat, thickness: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: .zero)
    path.addLine(to: CGPoint(x: -depth, y: reach))
    path.addLine(to: CGPoint(x: -depth - thickness, y: reach))
    path.addLine(to: CGPoint(x: -thickness, y: 0))
    path.addLine(to: CGPoint(x: -depth - thickness, y: -reach))
    path.addLine(to: CGPoint(x: -depth, y: -reach))
    path.closeSubpath()
    return path
}

/// One drawing, rendered at whatever scale the caller asks for. AppKit's origin is bottom-left; the constants
/// above read top-down, so `y(_:)` flips them.
func render(scale: CGFloat) -> Data {
    let pixels = CGSize(width: windowSize.width * scale, height: windowSize.height * scale)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { die("could not allocate the bitmap") }
    bitmap.size = windowSize

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { die("could not open a context") }
    NSGraphicsContext.current = context
    let cg = context.cgContext
    func y(_ topDown: CGFloat) -> CGFloat { windowSize.height - topDown }

    // The backdrop: paper, a shade darker towards the bottom. The gradient stops at the content floor and
    // everything below it is the flat bottom colour, so whatever Finder crops off is one colour.
    paperBottom.setFill()
    cg.fill(CGRect(origin: .zero, size: windowSize))
    NSGradient(colors: [paperTop, paperBottom])?
        .draw(in: NSRect(x: 0, y: y(contentFloor), width: windowSize.width, height: contentFloor), angle: -90)

    // The name, centred over the icons, set tight the way a wordmark is, filled with the snake's metal.
    let titleFont = NSFont.systemFont(ofSize: 40, weight: .semibold)
    let title = textPath(appName, font: titleFont, kern: -0.8)
    var titleTransform = CGAffineTransform(translationX: (windowSize.width - title.width) / 2,
                                           y: y(titleCentreY) - titleFont.capHeight / 2)
    if let outline = title.path.copy(using: &titleTransform) {
        cg.saveGState()
        cg.addPath(outline)
        cg.clip()
        let box = outline.boundingBox
        NSGradient(colors: [metalLight, metalDark])?
            .draw(in: NSRect(x: box.minX, y: box.minY, width: box.width, height: box.height), angle: -90)
        cg.restoreGState()
    }

    // One line on what the app is, under the name.
    let centred = NSMutableParagraphStyle()
    centred.alignment = .center
    let descriptionAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15, weight: .regular),
        .foregroundColor: gunmetal,
        .paragraphStyle: centred,
    ]
    let line = description as NSString
    let lineHeight = line.size(withAttributes: descriptionAttributes).height
    line.draw(in: NSRect(x: 0, y: y(descriptionCentreY) - lineHeight / 2, width: windowSize.width, height: lineHeight),
              withAttributes: descriptionAttributes)

    // The arrow: a train of the icon's own chevrons on the icons' centre line, from the app to the folder.
    // Each one is a little larger and heavier than the last, and the first fade in from the paper; the
    // sixth, largest, is the head, in the accent. One pitch throughout, so the head continues the rhythm.
    let trainStart = appIconCentre.x + iconSide / 2 + 24
    let trainEnd = dropIconCentre.x - iconSide / 2 - 22
    let centreY = y(appIconCentre.y)
    let count = 6
    let firstTip = trainStart + 16
    let pitch = (trainEnd - firstTip) / CGFloat(count - 1)
    for index in 0..<count {
        let t = CGFloat(index) / CGFloat(count - 1)
        let isHead = index == count - 1
        let reach: CGFloat = isHead ? 20 : 11 + 3.5 * t
        let thickness: CGFloat = isHead ? 9.5 : 6 + 1.5 * t
        let shape = chevron(reach: reach, depth: reach * 0.8, thickness: thickness)
        var transform = CGAffineTransform(translationX: firstTip + pitch * CGFloat(index), y: centreY)
        guard let placed = shape.copy(using: &transform) else { continue }
        let fade = (1 - t) * (1 - t)
        let fill = isHead ? accent : gunmetal.blended(withFraction: 0.55 * fade, of: paperBottom) ?? gunmetal
        cg.setFillColor(fill.cgColor)
        cg.addPath(placed)
        cg.fillPath()
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { die("could not encode the PNG") }
    return data
}

do {
    try render(scale: 1).write(to: URL(fileURLWithPath: arguments[3]))
    if arguments.count >= 5 { try render(scale: 2).write(to: URL(fileURLWithPath: arguments[4])) }
} catch {
    die("could not write: \(error.localizedDescription)")
}
