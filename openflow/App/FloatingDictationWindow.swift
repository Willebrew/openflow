import AppKit
import SwiftUI

/// Floating pill HUD. WindowServer hits the full panel, so AppKit `hitTest`
/// alone cannot click through. The panel stays a stable 380×64 slot so the
/// SwiftUI hover animation can run, and `ignoresMouseEvents` is true unless
/// the cursor is on the visible capsule.
final class FloatingDictationWindow {
    private static let panelSize = NSSize(width: 380, height: 64)

    private let window: NSPanel
    private let viewModel: FloatingPillViewModel
    private let host: CapsuleHitHostingView<FloatingPillView>
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isUpdatingPassthrough = false
    private var pendingHide: DispatchWorkItem?

    init(viewModel: FloatingPillViewModel) {
        self.viewModel = viewModel
        host = CapsuleHitHostingView(
            rootView: FloatingPillView(
                viewModel: viewModel,
                startContinuous: { viewModel.startContinuousRecording?() },
                stopRecording: { viewModel.stopRecording?() },
                openSettings: { viewModel.openSettings?() }
            )
        )
        window = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.becomesKeyOnlyIfNeeded = true
        window.ignoresMouseEvents = true
        host.onInteractiveCapsuleChange = { [weak self] in
            DispatchQueue.main.async {
                self?.syncMousePassthrough()
            }
        }
        installMonitors()
    }

    deinit {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    func show() {
        cancelPendingHide()
        positionBottomCenter()
        window.alphaValue = 1
        window.orderFrontRegardless()
        syncMousePassthrough()
    }

    func hide(after delay: TimeInterval = 0.45) {
        cancelPendingHide()
        window.ignoresMouseEvents = true
        if delay <= 0 {
            window.alphaValue = 0
            window.orderOut(nil)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                self.window.animator().alphaValue = 0
            } completionHandler: {
                self.window.alphaValue = 0
                self.window.orderOut(nil)
                self.window.ignoresMouseEvents = true
            }
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingHide() {
        pendingHide?.cancel()
        pendingHide = nil
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.syncMousePassthrough()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.syncMousePassthrough()
            return event
        }
    }

    private func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = Self.panelSize
        let x = frame.midX - size.width / 2
        let y = frame.minY - 6
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func syncMousePassthrough() {
        guard !isUpdatingPassthrough else { return }
        isUpdatingPassthrough = true
        defer { isUpdatingPassthrough = false }

        guard window.isVisible, window.alphaValue > 0.05 else {
            if !window.ignoresMouseEvents {
                window.ignoresMouseEvents = true
            }
            return
        }
        let shouldIgnore = !capsuleContainsScreenPoint(NSEvent.mouseLocation)
        if window.ignoresMouseEvents != shouldIgnore {
            window.ignoresMouseEvents = shouldIgnore
        }
    }

    private func capsuleContainsScreenPoint(_ point: NSPoint) -> Bool {
        let capsule = host.interactiveCapsule
        guard capsule.width > 0, capsule.height > 0 else { return false }
        let inWindow = host.convert(capsule, to: nil)
        let screenRect = window.convertToScreen(inWindow)
        return CapsuleHitTesting.contains(point, in: screenRect)
    }
}

protocol CapsuleHitTarget: AnyObject {
    var interactiveCapsule: CGRect { get set }
}

final class CapsuleHitHostingView<Content: View>: NSHostingView<Content>, CapsuleHitTarget {
    var onInteractiveCapsuleChange: (() -> Void)?
    var interactiveCapsule: CGRect = .zero {
        didSet {
            guard oldValue != interactiveCapsule else { return }
            onInteractiveCapsuleChange?()
        }
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard CapsuleHitTesting.contains(point, in: interactiveCapsule) else { return nil }
        return super.hitTest(point)
    }
}

enum CapsuleHitTesting {
    static func contains(_ point: NSPoint, in rect: CGRect) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        let radius = rect.height / 2
        let inner = CGRect(x: rect.minX + radius,
                           y: rect.minY,
                           width: max(0, rect.width - 2 * radius),
                           height: rect.height)
        if inner.contains(point) { return true }
        let left = CGPoint(x: rect.minX + radius, y: rect.midY)
        let right = CGPoint(x: rect.maxX - radius, y: rect.midY)
        return hypot(point.x - left.x, point.y - left.y) <= radius
            || hypot(point.x - right.x, point.y - right.y) <= radius
    }
}
