import AppKit

let width = 560
let height = 320
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2,
                             pixelsHigh: height * 2, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

func drawText(_ text: String, top: CGFloat, size: CGFloat, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (text as NSString).draw(in: NSRect(x: 20, y: CGFloat(height) - top - size * 1.6,
                                      width: CGFloat(width) - 40, height: size * 1.6),
                           withAttributes: [.font: NSFont.systemFont(ofSize: size),
                                            .foregroundColor: color, .paragraphStyle: paragraph])
}

drawText("将应用拖入右侧文件夹", top: 24, size: 19, color: .darkGray)
drawText("Drag the app to Applications", top: 57, size: 13, color: .gray)

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 258, y: 150))
arrow.line(to: NSPoint(x: 302, y: 150))
arrow.move(to: NSPoint(x: 290, y: 162))
arrow.line(to: NSPoint(x: 302, y: 150))
arrow.line(to: NSPoint(x: 290, y: 138))
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor.gray.setStroke()
arrow.stroke()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
let bookmark = try applications.bookmarkData(options: .suitableForBookmarkFile,
                                           includingResourceValuesForKeys: nil, relativeTo: nil)
let alias = URL(fileURLWithPath: CommandLine.arguments[2])
try URL.writeBookmarkData(bookmark, to: alias)
if !NSWorkspace.shared.setIcon(NSWorkspace.shared.icon(forFile: applications.path),
                              forFile: alias.path, options: []) {
    throw CocoaError(.fileWriteUnknown)
}
