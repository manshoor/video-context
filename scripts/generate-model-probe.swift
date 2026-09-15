import AppKit
let image = NSImage(size: NSSize(width: 512, height: 200))
image.lockFocus()
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: 512, height: 200).fill()
("VC-TEST-42" as NSString).draw(at: NSPoint(x: 40, y: 70), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 48, weight: .bold), .foregroundColor: NSColor.black])
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
