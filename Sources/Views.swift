// The strip panel, the view that draws the icons, and the tooltip.
//
// One view draws every icon and tracks the pointer itself (a single tracking
// area with mouse-moved events), so hover and clicks always match the icon
// under the pointer, even right after the icons were re-laid out.

import AppKit

let stripLevel = NSWindow.Level(rawValue: 26)    // above MenuBarAgent (25) and the menu bar (24)
let tooltipLevel = NSWindow.Level(rawValue: 26)
let iconSize: CGFloat = 20
let slotWidth: CGFloat = 30
let minSlotWidth: CGFloat = 18
let groupGap: CGFloat = 6
let leadingInset: CGFloat = 14
/// Browser windows show up to three site icons, smaller than app icons
/// (site icons fill their square; app icons have a margin built in).
let tabIconSize: CGFloat = 16
let tabIconGap: CGFloat = 3

/// The width of a slot showing `count` site icons.
func tabSlotWidth(_ count: Int) -> CGFloat {
    count <= 1 ? slotWidth : CGFloat(count) * tabIconSize + CGFloat(count - 1) * tabIconGap + 12
}

struct WinInfo: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let appKey: String
    let display: CGDirectDisplayID
}

struct Slot {
    let info: WinInfo
    let frame: NSRect     // in the strip view
    /// The app's icon, or a browser window's site icons.
    let icons: [NSImage]
    let tabs: Bool
    /// Changes whenever the icons do, so the view knows to redraw.
    let iconKey: String
}

final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

protocol StripViewDelegate: AnyObject {
    func hoverChanged(to slot: Slot?, in view: StripView)
    func clicked(_ slot: Slot, in view: StripView)
}

final class StripView: NSView {
    weak var delegate: StripViewDelegate?
    let display: CGDirectDisplayID

    private(set) var slots: [Slot] = []
    private(set) var frontID: CGWindowID?
    private(set) var hoveredID: CGWindowID?

    /// The desktop-switch slide: layers over the drawing while it runs.
    private var slideLayers: [CALayer] = []
    private var slideSeq = 0

    init(frame: NSRect, display: CGDirectDisplayID) {
        self.display = display
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// `slide` is +1 or -1 when a desktop switch brought these slots (+1: the
    /// new desktop is further right). Returns whether the icons slid.
    @discardableResult
    func update(slots: [Slot], front: CGWindowID?, slide: Int = 0) -> Bool {
        let newWindows = slots.map(\.info.id) != self.slots.map(\.info.id)
        let changed = newWindows || slots.map(\.frame) != self.slots.map(\.frame) || front != frontID
            || slots.map(\.iconKey) != self.slots.map(\.iconKey)
        let before = slide != 0 && newWindows ? image() : nil
        self.slots = slots
        frontID = front
        if changed { needsDisplay = true }
        followPointer()
        if let before { return slideIn(from: before, direction: slide) }
        // A change during a slide (the front window settling): show it in
        // the arriving icons.
        if changed, let arriving = slideLayers.last {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arriving.contents = image()
            CATransaction.commit()
        }
        return false
    }

    /// The old icons drift toward the side the old desktop left by while
    /// the new ones fade in from the other side, in a quarter second (a
    /// plain crossfade with Reduce Motion). Two snapshots the window server
    /// animates: nothing here runs per frame.
    private func slideIn(from old: CGImage, direction: Int) -> Bool {
        endSlide()
        guard let host = layer, let new = image() else { return false }
        let scale = window?.backingScaleFactor ?? 2
        let shift = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 24 * CGFloat(direction)
        func plate(_ image: CGImage?, dx: CGFloat) -> CALayer {
            let l = CALayer()
            l.frame = host.bounds.offsetBy(dx: dx, dy: 0)
            l.contents = image
            l.contentsScale = scale
            l.backgroundColor = NSColor.black.cgColor
            return l
        }
        // The first plate hides the live drawing (already the new icons)
        // until the end; the old icons end up `shift` toward the old side.
        let layers = [plate(nil, dx: 0), plate(old, dx: -shift), plate(new, dx: 0)]
        slideSeq += 1
        let seq = slideSeq
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            if self?.slideSeq == seq { self?.endSlide() }
        }
        layers.forEach(host.addSublayer)
        slideLayers = layers
        func animate(_ l: CALayer, _ key: String, from: CGFloat, to: CGFloat) {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = 0.24
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            l.add(a, forKey: key)
        }
        animate(layers[1], "position.x", from: host.bounds.midX, to: host.bounds.midX - shift)
        animate(layers[2], "position.x", from: host.bounds.midX + shift, to: host.bounds.midX)
        animate(layers[2], "opacity", from: 0, to: 1)
        CATransaction.commit()
        return true
    }

    private func endSlide() {
        guard !slideLayers.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slideLayers.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
        slideLayers = []
    }

    /// What the strip shows now, drawn into a bitmap; nil while it's hidden.
    private func image() -> CGImage? {
        guard let window, window.isVisible, window.alphaValue > 0, !bounds.isEmpty, let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }

    func setFront(_ id: CGWindowID?) {
        guard id != frontID else { return }
        frontID = id
        needsDisplay = true
    }

    /// Re-derives the hovered icon from where the pointer really is, so a
    /// re-layout under a resting pointer updates hover and tooltip at once.
    func followPointer() {
        // A strip hidden for a full-screen app has no hover: its tooltip
        // would show over that app.
        guard let window, window.isVisible, window.alphaValue > 0 else { setHover(nil); return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHover(bounds.contains(point) ? slot(at: point) : nil)
    }

    func slot(at point: NSPoint) -> Slot? {
        slots.first { point.x >= $0.frame.minX && point.x < $0.frame.maxX }
    }

    private func setHover(_ slot: Slot?) {
        let id = slot?.info.id
        guard id != hoveredID else { return }
        hoveredID = id
        needsDisplay = true
        delegate?.hoverChanged(to: slot, in: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { setHover(slot(at: convert(event.locationInWindow, from: nil))) }
    override func mouseMoved(with event: NSEvent) { setHover(slot(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHover(nil) }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        Log.debug("click", "mouseDown at x=\(Int(point.x)) on display \(display)")
        if let slot = slot(at: point) { delegate?.clicked(slot, in: self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let start = uptimeNs()
        NSColor.black.setFill()
        bounds.fill()
        for slot in slots {
            let isFront = slot.info.id == frontID, isHovered = slot.info.id == hoveredID
            if isFront || isHovered {
                NSColor.white.withAlphaComponent(isFront ? (isHovered ? 0.30 : 0.24) : 0.13).setFill()
                NSBezierPath(roundedRect: slot.frame.insetBy(dx: 2, dy: 3), xRadius: 6, yRadius: 6).fill()
            }
            let side = min(slot.tabs ? tabIconSize : iconSize, slot.frame.width - 6)
            let total = CGFloat(slot.icons.count) * side + CGFloat(slot.icons.count - 1) * tabIconGap
            var x = slot.frame.midX - total / 2
            for icon in slot.icons {
                icon.draw(in: NSRect(x: x, y: slot.frame.midY - side / 2, width: side, height: side),
                          from: .zero, operation: .sourceOver, fraction: 1)
                x += side + tabIconGap
            }
        }
        let took = msSince(start)
        if took >= 8 { Log.info("slow", "drawing \(slots.count) icons took \(ms(took))") }
    }
}

/// A dark label below the strip. Drawn by hand so the live snapshot captures it.
final class Tooltip {
    private let panel: NSPanel
    private let view = TooltipView()
    private(set) var windowID: CGWindowID?

    /// It stays on screen once shown and is only made transparent: showing
    /// it never orders a window in, which during a Space change could leave
    /// it on one desktop (Controller.applyFullScreen).
    var isVisible: Bool { panel.isVisible && panel.alphaValue > 0 }
    var text: String { view.text }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = tooltipLevel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = view
    }

    /// Shows `text` just below `anchor` (a rect in AppKit screen coordinates).
    func show(_ text: String, for id: CGWindowID, below anchor: NSRect) {
        windowID = id
        view.text = text
        let size = view.fittingSize
        var x = anchor.minX - 4
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }) {
            x = max(screen.frame.minX + 6, min(x, screen.frame.maxX - size.width - 6))
        }
        panel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 5, width: size.width, height: size.height), display: true)
        view.needsDisplay = true
        if !panel.isVisible { panel.orderFrontRegardless() }
        panel.alphaValue = 1
    }

    /// The first call (when the panels are built) puts it on screen,
    /// transparent.
    func hide() {
        windowID = nil
        panel.alphaValue = 0
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func snapshot() -> NSBitmapImageRep? {
        guard isVisible, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}

final class TooltipView: NSView {
    var text = "" { didSet { needsDisplay = true } }
    private let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white,
    ]
    private let maxTextWidth: CGFloat = 460

    override var fittingSize: NSSize {
        let width = min(maxTextWidth, ceil((text as NSString).size(withAttributes: attributes).width))
        return NSSize(width: width + 20, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7)
        NSColor(white: 0.13, alpha: 0.97).setFill()
        path.fill()
        NSColor(white: 1, alpha: 0.18).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        let textHeight = (text as NSString).size(withAttributes: attributes).height
        let rect = NSRect(x: 10, y: (bounds.height - textHeight) / 2, width: bounds.width - 20, height: textHeight)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        var attrs = attributes
        attrs[.paragraphStyle] = style
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }
}
