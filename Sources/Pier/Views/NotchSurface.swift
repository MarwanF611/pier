import SwiftUI

/// Pier hidden in the notch. Closed, it is a black shape exactly the size of the camera
/// housing, so nothing shows. Open, the same shape grows down into the panel, the way
/// the Dynamic Island grows out of the top of an iPhone.
struct NotchSurface: View {
    @Environment(AppModel.self) private var model

    /// How far the top corners flare outward to meet the menu bar.
    private static let flare: CGFloat = 10

    var body: some View {
        let dock = model.dock
        let notch = dock.notchSize
        let expanded = dock.isExpanded

        // The content decides the size; the black shape is drawn behind whatever that is.
        Group {
            if expanded {
                ExpandedPanel(maxHeight: .infinity, layout: .wide)
                    .padding(.top, notch.height - 6)
                    .padding(.horizontal, Self.flare + 4)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            } else {
                Color.clear.frame(width: notch.width + Self.flare * 2, height: notch.height)
            }
        }
        .background {
            NotchShape(flare: Self.flare, bottomRadius: expanded ? 32 : 10)
                // Without a camera housing there is nothing to blend into, so stay invisible.
                .fill(dock.screenHasNotch || expanded ? Color.black : Color.black.opacity(0.001))
                .overlay {
                    NotchShape(flare: Self.flare, bottomRadius: 32)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .opacity(dock.isDropTargeted && expanded ? 1 : 0)
                }
        }
        .fixedSize()
        .environment(\.colorScheme, .dark) // black surface, like the hardware it hangs from
        .shadow(color: .black.opacity(expanded ? 0.35 : 0), radius: 18, y: 8)
        .contentShape(NotchShape(flare: Self.flare, bottomRadius: 10))
        .onDrop(of: ShelfDrop.types, isTargeted: Binding(get: { dock.isDropTargeted }, set: { dock.isDropTargeted = $0 })) {
            ShelfDrop.accept($0, into: model.shelf)
        }
        .onTapGesture { if !expanded { dock.isExpanded = true } }
        .accessibilityElement(children: expanded ? .contain : .ignore)
        .accessibilityLabel("Pier")
    }
}

/// A rectangle hanging from the top edge, with rounded bottom corners and top corners that
/// curve outward into the menu bar like the MacBook notch itself.
struct NotchShape: Shape {
    var flare: CGFloat
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(bottomRadius, (rect.width - flare * 2) / 2, rect.height - flare)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + flare, y: rect.minY + flare),
                          control: CGPoint(x: rect.minX + flare, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + flare, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + flare + r, y: rect.maxY),
                          control: CGPoint(x: rect.minX + flare, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - flare - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - flare, y: rect.maxY - r),
                          control: CGPoint(x: rect.maxX - flare, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - flare, y: rect.minY + flare))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - flare, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
