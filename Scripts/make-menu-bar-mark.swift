// Draws the menu bar's mark: Assets/1_snake_solid_alt.svg into Sources/SnappySnap/Resources/MenuBarMark.pdf.
// Run from the repo root — `swift Scripts/make-menu-bar-mark.swift` — whenever the artwork or either of the
// two numbers below changes. Its output is committed, so the app builds without it.
//
// The SVG is one filled <path> whose `d` uses only absolute M, L and Z, in a 1024 × 1024 box, drawn with the
// even-odd rule so the eye and the fangs stay open. Its <metadata> (a C2PA manifest) is stripped before
// scanning, and its declared fill — a cream meant for dark backgrounds — is ignored: the PDF is a template
// image, so it is filled opaque black and AppKit tints it to whatever the menu bar needs.
//
// The page stays 1024 × 1024 and `AppDelegate.menuBarMark()` shows it at `imageSide` points; the path is
// scaled about its own centre to make the drawn glyph `glyphHeight` points tall, then moved down `dropOffset`.
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    .deletingLastPathComponent().deletingLastPathComponent()
let svgURL = root.appendingPathComponent("Assets/1_snake_solid_alt.svg")
let pdfURL = root.appendingPathComponent("Sources/SnappySnap/Resources/MenuBarMark.pdf")
let side: CGFloat = 1024

/// In points, against the status item's image. `imageSide` must equal `AppDelegate.menuBarMarkSide`:
/// nothing checks it, because this script is not part of any target. `glyphHeight` and `dropOffset` are
/// fitted by eye against the neighbouring menu-bar icons — the mark's own box leaves 14% padding on every
/// side, so drawn at the full 18 it reads small and pale beside them.
let imageSide: CGFloat = 18
let glyphHeight: CGFloat = 15.5
let dropOffset: CGFloat = 0.5

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard var svg = try? String(contentsOf: svgURL, encoding: .utf8) else { fail("cannot read \(svgURL.path)") }

/// Nothing inside <metadata> may be mistaken for the drawing.
if let open = svg.range(of: "<metadata>"), let close = svg.range(of: "</metadata>", range: open.upperBound..<svg.endIndex) {
    svg.removeSubrange(open.lowerBound..<close.upperBound)
}

/// Every `d="…"` attribute, in document order.
var pathData: [String] = []
var rest = svg[...]
while let start = rest.range(of: " d=\"") {
    rest = rest[start.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { fail("unterminated d attribute") }
    pathData.append(String(rest[..<end]))
    rest = rest[end...]
}
guard pathData.count == 1 else { fail("expected 1 path, found \(pathData.count)") }

/// SVG y grows down, PDF y grows up: flip while building the path.
func makePath(_ d: String) -> CGPath {
    let path = CGMutablePath()
    var command: Character = " "
    var numbers: [CGFloat] = []
    var number = ""

    func flushNumber() {
        guard !number.isEmpty else { return }
        guard let value = Double(number) else { fail("bad number \(number)") }
        numbers.append(CGFloat(value))
        number = ""
    }
    func flushCommand() {
        flushNumber()
        switch command {
        case "M":
            guard numbers.count == 2 else { fail("M needs 2 numbers, got \(numbers.count)") }
            path.move(to: CGPoint(x: numbers[0], y: side - numbers[1]))
        case "L":
            guard numbers.count == 2 else { fail("L needs 2 numbers, got \(numbers.count)") }
            path.addLine(to: CGPoint(x: numbers[0], y: side - numbers[1]))
        case "Z":
            path.closeSubpath()
        default:
            break
        }
        numbers = []
    }

    for character in d {
        switch character {
        case "M", "L", "Z":
            flushCommand()
            command = character
        case " ", ",", "\n", "\t":
            flushNumber()
        case "0"..."9", ".", "-":
            number.append(character)
        default:
            fail("unsupported path command \(character)")
        }
    }
    flushCommand()
    return path
}

var mediaBox = CGRect(x: 0, y: 0, width: side, height: side)
guard let context = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, nil) else { fail("cannot create \(pdfURL.path)") }
context.beginPDFPage(nil)
context.setFillColor(CGColor(gray: 0, alpha: 1))

let artwork = makePath(pathData[0])
let box = artwork.boundingBoxOfPath
let scale = (glyphHeight / imageSide * side) / box.height
let target = CGPoint(x: side / 2, y: side / 2 - dropOffset / imageSide * side)  // PDF y is up, so down is minus
var transform = CGAffineTransform(translationX: -box.midX, y: -box.midY)
    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    .concatenating(CGAffineTransform(translationX: target.x, y: target.y))
guard let placed = artwork.copy(using: &transform) else { fail("cannot transform the path") }
print("scale \(scale), artwork \(placed.boundingBoxOfPath)")
context.addPath(placed)
context.fillPath(using: .evenOdd)
context.endPDFPage()
context.closePDF()
print("wrote \(pdfURL.path)")
