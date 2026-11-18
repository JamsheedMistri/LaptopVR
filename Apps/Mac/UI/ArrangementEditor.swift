import SwiftUI

/// A miniature of the display arrangement. Dragging a monitor moves it in macOS, which is what
/// decides where it appears in the headset.
struct ArrangementEditor: View {
    let model: AppModel

    @State private var draggedDisplay: CGDirectDisplayID?
    @State private var dragTranslation = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            let displays = model.displays
            let extent = displays.reduce(CGRect.null) { $0.union($1.bounds) }
            // Leave room around the arrangement to drag a monitor to any side.
            let scale = min(
                geometry.size.width / max(extent.width * 1.5, 1),
                geometry.size.height / max(extent.height * 1.7, 1)
            )
            let origin = CGPoint(
                x: (geometry.size.width - extent.width * scale) / 2 - extent.minX * scale,
                y: (geometry.size.height - extent.height * scale) / 2 - extent.minY * scale
            )

            ZStack(alignment: .topLeading) {
                ForEach(displays) { display in
                    let isDragged = draggedDisplay == display.id
                    DisplayTile(display: display, isShown: model.shownDisplays.contains(display))
                        .frame(width: display.bounds.width * scale, height: display.bounds.height * scale)
                        .offset(
                            x: origin.x + display.bounds.minX * scale + (isDragged ? dragTranslation.width : 0),
                            y: origin.y + display.bounds.minY * scale + (isDragged ? dragTranslation.height : 0)
                        )
                        .zIndex(isDragged ? 1 : 0)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    draggedDisplay = display.id
                                    dragTranslation = value.translation
                                }
                                .onEnded { value in
                                    draggedDisplay = nil
                                    dragTranslation = .zero
                                    model.moveDisplay(display.id, to: CGPoint(
                                        x: display.bounds.minX + value.translation.width / scale,
                                        y: display.bounds.minY + value.translation.height / scale
                                    ))
                                },
                            // The main display is the origin; arrange the others around it.
                            isEnabled: !display.isMain
                        )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }
}

private struct DisplayTile: View {
    let display: DisplayInfo
    let isShown: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(display.isMain ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(isShown ? 0.3 : 0.12))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.secondary.opacity(0.6))
            }
            .overlay {
                Text(display.name)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .padding(4)
            }
    }
}
