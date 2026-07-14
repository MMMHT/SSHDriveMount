import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "TailMount-1024.png"
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

let outer = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 210, yRadius: 210)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.29, green: 0.32, blue: 0.97, alpha: 1),
    NSColor(calibratedRed: 0.45, green: 0.31, blue: 0.94, alpha: 1)
])!
gradient.draw(in: outer, angle: -45)

NSColor.white.withAlphaComponent(0.14).setFill()
NSBezierPath(roundedRect: NSRect(x: 242, y: 212, width: 540, height: 600), xRadius: 105, yRadius: 105).fill()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 410, weight: .bold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: paragraph
]
("T" as NSString).draw(in: NSRect(x: 230, y: 315, width: 564, height: 470), withAttributes: attributes)

NSColor.white.withAlphaComponent(0.9).setFill()
NSBezierPath(roundedRect: NSRect(x: 330, y: 232, width: 364, height: 34), xRadius: 17, yRadius: 17).fill()
NSBezierPath(ovalIn: NSRect(x: 642, y: 285, width: 36, height: 36)).fill()

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: output))
