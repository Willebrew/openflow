import SwiftUI
import AppKit

struct FloatingPillView: View {
    @ObservedObject var viewModel: FloatingPillViewModel
    let startContinuous: () -> Void
    let stopRecording: () -> Void
    let openSettings: () -> Void
    var forceDarkBase = false
    @State private var animate = false
    @State private var isHovering = false
    var body: some View {
        ZStack {
            NativeGlassCapsule(cornerRadius: pillHeight / 2,
                               tintHex: activeTintHex,
                               tintOpacity: glassTintOpacity)
                .frame(width: pillWidth, height: pillHeight)

            if forceDarkBase {
                Capsule()
                    .fill(.black.opacity(0.78))
                    .frame(width: pillWidth, height: pillHeight)
            }

            HStack(spacing: contentSpacing) {
                statusContent

                if isHovering && viewModel.state == .idle {
                    Divider()
                        .frame(height: 26)
                        .overlay(.white.opacity(0.22))
                    pillActionButton("record.circle", "Record", action: startContinuous)
                    pillActionButton("gearshape", "Settings", action: openSettings)
                }

                if viewModel.state == .recording {
                    Button(action: stopRecording) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.92))
                            .frame(width: 31, height: 31)
                            .background(.white.opacity(0.72), in: Circle())
                            .glassEffect(.regular.tint(.white.opacity(0.20)).interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop recording")
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(width: pillWidth, height: pillHeight)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(pillStroke, lineWidth: 1))
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
            .shadow(color: .black.opacity(viewModel.state == .idle && !isHovering ? 0.10 : 0.24),
                    radius: viewModel.state == .idle && !isHovering ? 5 : 11,
                    x: 0,
                    y: 4)
        }
        .frame(width: 380, height: 64)
        .animation(.easeOut(duration: viewModel.state == .recording ? 0.06 : 0.12), value: viewModel.state)
        .animation(.spring(response: 0.18, dampingFraction: 0.86), value: isHovering)
        .onAppear { animate = true }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch viewModel.state {
        case .idle:
            if isHovering {
                FlowMiniMark()
                    .offset(x: 5)
                    .frame(width: 34)
            } else {
                Color.clear
            }
        case .recording:
            WaveformBars(level: effectiveLevel)
                .frame(width: 84, height: 19)
        case .processing:
            ProcessingDots()
                .frame(width: 92, height: 20)
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
        case .resultClearing:
            Color.clear
        case .error(let message):
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Text(compactErrorLabel(message))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .help(message)
            .accessibilityLabel(message)
        }
    }

    private var pillWidth: CGFloat {
        switch viewModel.state {
        case .idle: isHovering ? 252 : 68
        case .recording: 138
        case .processing: 148
        case .success, .resultClearing: 42
        case .error: 118
        }
    }

    private var pillHeight: CGFloat {
        switch viewModel.state {
        case .idle: isHovering ? 42 : 22
        case .recording, .processing: 42
        case .success, .resultClearing, .error: 42
        }
    }

    private var horizontalPadding: CGFloat {
        if viewModel.state == .idle && !isHovering { return 0 }
        if viewModel.state == .recording { return 8 }
        if viewModel.state == .idle && isHovering { return 7 }
        return 9
    }

    private var verticalPadding: CGFloat {
        if viewModel.state == .recording { return 5 }
        if viewModel.state == .idle && isHovering { return 3 }
        return 8
    }

    private var contentSpacing: CGFloat {
        if viewModel.state == .idle && !isHovering { return 0 }
        if viewModel.state == .recording { return 6 }
        return 8
    }

    private var pillStroke: Color {
        if viewModel.state == .idle && !isHovering {
            return .white.opacity(0.18 + 0.22 * clampedGlass)
        }
        return .white.opacity(0.12 + 0.20 * clampedGlass)
    }

    private var glassTintOpacity: Double {
        let active = 0.34 * clampedTint
        let idle = 0.18 * clampedTint * clampedInactiveOpacity
        return viewModel.state == .idle && !isHovering ? idle : active
    }

    private var activeTintHex: String {
        viewModel.tintColorHex
    }

    private var clampedGlass: Double {
        min(max(viewModel.glassIntensity, 0), 1)
    }

    private var clampedTint: Double {
        min(max(viewModel.tintStrength, 0), 1)
    }

    private var clampedInactiveOpacity: Double {
        min(max(viewModel.inactiveOpacity, 0.25), 1)
    }

    private var effectiveLevel: Float {
        switch viewModel.state {
        case .recording: max(viewModel.level, 0.03)
        default: 0.03
        }
    }

    private func compactErrorLabel(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("empty transcript") { return "Empty" }
        if lower.contains("too short") { return "Too short" }
        if lower.contains("empty after recording") { return "Empty file" }
        if lower.contains("microphone") || lower.contains("no audio") { return "Mic" }
        if lower.contains("network") || lower.contains("offline") { return "Network" }
        if lower.contains("insert") { return "Insert" }
        if lower.contains("transcri") { return "Failed" }
        return "Failed"
    }

    private func pillActionButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                Text(label)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(width: label == "Settings" ? 96 : 88, height: 34)
            .background(.ultraThinMaterial, in: Capsule())
            .background(.white.opacity(0.06 + 0.08 * clampedGlass), in: Capsule())
            .glassEffect(.regular.tint(.white.opacity(0.04 + 0.12 * clampedGlass)).interactive(), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.08 + 0.14 * clampedGlass), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

struct NativeGlassCapsule: NSViewRepresentable {
    let cornerRadius: CGFloat
    let tintHex: String
    let tintOpacity: Double

    func makeNSView(context: Context) -> LiveBackdropCapsuleView {
        let view = LiveBackdropCapsuleView()
        view.update(cornerRadius: cornerRadius,
                    tintColor: glassTintColor)
        return view
    }

    func updateNSView(_ view: LiveBackdropCapsuleView, context: Context) {
        view.update(cornerRadius: cornerRadius,
                    tintColor: glassTintColor)
    }

    private var glassTintColor: NSColor? {
        guard tintOpacity > 0.001 else { return nil }
        return NSColor.openflowHex(tintHex).withAlphaComponent(tintOpacity)
    }
}

final class LiveBackdropCapsuleView: NSView {
    private let effectView = NSVisualEffectView()
    private let tintLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isEmphasized = true
        effectView.autoresizingMask = [.width, .height]
        effectView.frame = bounds
        addSubview(effectView)

        tintLayer.masksToBounds = true
        layer?.addSublayer(tintLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        effectView.frame = bounds
        tintLayer.frame = bounds
        var ancestor: NSView? = superview
        while let view = ancestor {
            if let host = view as? CapsuleHitTarget {
                host.interactiveCapsule = view.convert(bounds, from: self)
                break
            }
            ancestor = view.superview
        }
    }

    func update(cornerRadius: CGFloat, tintColor: NSColor?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = cornerRadius
        effectView.layer?.cornerRadius = cornerRadius
        tintLayer.cornerRadius = cornerRadius
        tintLayer.backgroundColor = tintColor?.cgColor
        CATransaction.commit()
        needsLayout = true
        needsDisplay = true
        layer?.setNeedsDisplay()
    }
}

private extension NSColor {
    static func openflowHex(_ value: String) -> NSColor {
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6,
              let intValue = Int(hex, radix: 16) else {
            return .black
        }
        let red = CGFloat((intValue >> 16) & 0xff) / 255
        let green = CGFloat((intValue >> 8) & 0xff) / 255
        let blue = CGFloat(intValue & 0xff) / 255
        return NSColor(red: red, green: green, blue: blue, alpha: 1)
    }
}

struct ProcessingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.11, paused: false)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.11) % 7
            HStack(spacing: 5) {
                ForEach(0..<7) { index in
                    Circle()
                        .fill(.white.opacity(0.92))
                        .frame(width: 5, height: 5)
                        .scaleEffect(phase == index ? 1.65 : 0.8)
                        .opacity(phase == index ? 1 : 0.48)
                }
            }
        }
    }
}

struct FlowMiniMark: View {
    var body: some View {
        OpenflowGlyph()
            .frame(width: 28, height: 26)
    }
}

struct CircleButton: View {
    let symbol: String
    let fill: Color
    let foreground: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(foreground)
            .frame(width: 22, height: 22)
            .background(fill, in: Circle())
    }
}

struct WaveformBars: View {
    let level: Float

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<9) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white.opacity(0.82))
                    .frame(width: 4, height: barHeight(index))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let pattern = [0.35, 0.65, 0.95, 0.55, 1.0, 0.75, 0.45, 0.7, 0.38]
        let amplitude = CGFloat(max(0.03, min(level, 1)))
        let scaled = amplitude * CGFloat(pattern[index % pattern.count])
        return min(22, max(3, 4 + scaled * 22))
    }
}
