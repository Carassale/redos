import AppKit
import SwiftUI

/// The camera housing of the screen RedOS shows on; screens without one get a virtual notch as tall as the menu bar.
struct NotchGeometry: Equatable {
    var width: CGFloat = 190
    var height: CGFloat = 32

    init() {}

    init(screen: NSScreen) {
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            width = screen.frame.width - left.width - right.width
            height = screen.safeAreaInsets.top
        } else {
            height = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        }
    }

    @MainActor static var screen: NSScreen? { NSScreen.main ?? NSScreen.screens.first }
}

enum NotchMotion {
    static var open: Animation { .spring(response: 0.42, dampingFraction: 0.78) }
    static var close: Animation { .easeIn(duration: 0.18) }
    /// Panels are ordered out once the island has shrunk back into the notch.
    static let closeDelay = Duration.milliseconds(200)
}

extension NSWindow.Level {
    /// Above the menu bar, so the island can cover the notch.
    static let notch = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
}

extension NSWindow {
    /// Top centre of the screen, where the notch is.
    func pinToNotch(of screen: NSScreen) {
        setFrameOrigin(NSPoint(x: screen.frame.midX - frame.width / 2, y: screen.frame.maxY - frame.height))
    }
}

/// The notch grown down: concave shoulders where it meets the top edge, rounded bottom corners.
struct NotchShape: Shape {
    var shoulder: CGFloat
    var corner: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, corner) }
        set { (shoulder, corner) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + shoulder, right = rect.maxX - shoulder
        let corner = min(corner, (right - left) / 2, rect.height - shoulder)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + shoulder), control: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - corner))
        path.addQuadCurve(to: CGPoint(x: left + corner, y: rect.maxY), control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - corner, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.maxY - corner), control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: right, y: rect.minY + shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Black like the notch and grown out of it: `leading` and `trailing` flank the camera, `content` hangs below.
struct NotchIsland<Leading: View, Trailing: View, Content: View>: View {
    let notch: NotchGeometry
    let isOpen: Bool
    let width: CGFloat
    /// False for a compact island: only the wings beside the camera.
    var showsContent = true
    let leading: Leading
    let trailing: Trailing
    let content: Content

    init(
        notch: NotchGeometry, isOpen: Bool, width: CGFloat, showsContent: Bool = true,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.notch = notch
        self.isOpen = isOpen
        self.width = width
        self.showsContent = showsContent
        self.leading = leading()
        self.trailing = trailing()
        self.content = content()
    }

    private var shoulder: CGFloat { isOpen ? 14 : 6 }
    private var corner: CGFloat { isOpen && showsContent ? 28 : 12 }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static var grow: AnyTransition { .opacity.combined(with: .scale(scale: 0.92, anchor: .top)) }

    var body: some View {
        VStack(spacing: 0) {
            if isOpen {
                HStack(spacing: 0) {
                    leading.frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: notch.width)
                    trailing.frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(height: notch.height)
                .transition(.opacity)
                if showsContent {
                    content
                        .padding(.top, 8)
                        .padding(.bottom, 18)
                        .transition(reduceMotion ? .opacity : Self.grow)
                }
            }
        }
        .padding(.horizontal, shoulder + 16)
        .frame(width: isOpen ? width : notch.width + 2 * shoulder, alignment: .top)
        .frame(minHeight: notch.height, alignment: .top)
        .background(.black, in: NotchShape(shoulder: shoulder, corner: corner))
        .clipShape(NotchShape(shoulder: shoulder, corner: corner))
        .shadow(color: .black.opacity(isOpen && showsContent ? 0.5 : 0), radius: 20, y: 10)
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : isOpen ? NotchMotion.open : NotchMotion.close, value: isOpen)
        .animation(reduceMotion ? nil : NotchMotion.open, value: showsContent)
    }
}
