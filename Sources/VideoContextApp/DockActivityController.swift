import AppKit
import VideoContextCore

@MainActor
final class DockActivityController {
    private let enabled: Bool
    init(enabled: Bool = true) { self.enabled = enabled }
    private var animationTask: Task<Void, Never>?
    private let tileView = ActivityDockView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))

    func update(_ activity: AppActivity?) {
        guard enabled else { return }
        guard let activity else {
            animationTask?.cancel()
            animationTask = nil
            NSApp.dockTile.contentView = nil
            NSApp.dockTile.display()
            return
        }
        tileView.setAccessibilityLabel("Video Context: \(activity.title)")
        tileView.icon = NSApp.applicationIconImage
        tileView.fraction = activity.fraction
        NSApp.dockTile.contentView = tileView
        NSApp.dockTile.display()
        guard animationTask == nil else { return }
        animationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.tileView.angle = reduceMotion ? 0 : self.tileView.angle + 12
                self.tileView.reduceMotion = reduceMotion
                NSApp.dockTile.display()
                do { try await Task.sleep(for: reduceMotion ? .seconds(1) : .milliseconds(125)) }
                catch { return }
            }
        }
    }
}

@MainActor
private final class ActivityDockView: NSView {
    var icon: NSImage?
    var angle = 0.0
    var fraction: Double?
    var reduceMotion = false

    override func draw(_ dirtyRect: NSRect) {
        icon?.draw(in: bounds)
        let center = NSPoint(x: bounds.maxX - 26, y: 26)
        let background = NSBezierPath(ovalIn: NSRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44))
        NSColor.windowBackgroundColor.setFill()
        background.fill()
        let track = NSBezierPath(ovalIn: NSRect(x: center.x - 16, y: center.y - 16, width: 32, height: 32))
        track.lineWidth = 4
        NSColor.separatorColor.setStroke()
        track.stroke()
        let ring = NSBezierPath()
        ring.lineWidth = 4
        ring.lineCapStyle = .round
        let start = fraction == nil ? angle : 90
        let sweep = fraction.map { $0 * 360 } ?? (reduceMotion ? 280 : 100)
        ring.appendArc(withCenter: center, radius: 16, startAngle: start, endAngle: start - sweep, clockwise: true)
        NSColor.systemIndigo.setStroke()
        ring.stroke()
        if fraction != nil && !reduceMotion {
            let radians = angle * .pi / 180
            let point = NSPoint(x: center.x + cos(radians) * 16, y: center.y + sin(radians) * 16)
            NSColor.systemIndigo.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
        }
    }
}
