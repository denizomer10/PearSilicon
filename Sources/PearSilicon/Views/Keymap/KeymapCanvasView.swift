import SwiftUI

/// Visual preview of a keymap laid out over a normalized 0...1 canvas.
/// Markers can be dragged; the bound keymap is updated in place.
struct KeymapCanvasView: View {
    @Binding var keymap: Keymap

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black.opacity(0.30))

                grid(size: geo.size)

                ForEach(keymap.bindings) { binding in
                    if case .joystick(let center, let radius) = binding.action {
                        // Show the area the finger sweeps: radius is normalized, so
                        // the on-screen shape is an ellipse on non-square canvases.
                        Ellipse()
                            .stroke(
                                Color.accentColor.opacity(0.55),
                                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                            )
                            .frame(width: radius * 2 * geo.size.width,
                                   height: radius * 2 * geo.size.height)
                            .position(x: center.x * geo.size.width,
                                      y: center.y * geo.size.height)
                            .allowsHitTesting(false)
                    }
                    if let point = Self.position(of: binding.action) {
                        marker(for: binding, at: point, size: geo.size)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.12))
            )
        }
    }

    // MARK: - Grid

    private func grid(size: CGSize) -> some View {
        Path { path in
            for step in 1..<10 {
                let x = size.width * CGFloat(step) / 10
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                let y = size.height * CGFloat(step) / 10
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(.white.opacity(0.06), lineWidth: 1)
    }

    // MARK: - Marker

    private func marker(for binding: KeymapBinding, at point: NormalizedPoint, size: CGSize) -> some View {
        let x = point.x * size.width
        let y = point.y * size.height

        return Text(binding.displayKey)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .glassEffect(.regular.tint(.accentColor).interactive(), in: Capsule())
            .position(x: x, y: y)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let nx = min(max(value.location.x / size.width, 0), 1)
                        let ny = min(max(value.location.y / size.height, 0), 1)
                        update(binding.id, to: NormalizedPoint(nx, ny))
                    }
            )
    }

    private func update(_ id: KeymapBinding.ID, to point: NormalizedPoint) {
        guard let index = keymap.bindings.firstIndex(where: { $0.id == id }) else { return }
        keymap.bindings[index].action = Self.moved(keymap.bindings[index].action, to: point)
    }

    // MARK: - Action geometry

    static func position(of action: KeymapAction) -> NormalizedPoint? {
        switch action {
        case .tap(let p), .hold(let p):
            return p
        case .joystick(let center, _):
            return center
        case .mouseLook(let rect, _):
            return NormalizedPoint(rect.x + rect.width / 2, rect.y + rect.height / 2)
        case .swipe(let from, _, _):
            return from
        }
    }

    static func moved(_ action: KeymapAction, to point: NormalizedPoint) -> KeymapAction {
        switch action {
        case .tap:
            return .tap(point)
        case .hold:
            return .hold(point)
        case .joystick(_, let radius):
            return .joystick(center: point, radius: radius)
        case .mouseLook(let rect, let sensitivity):
            let newRect = NormalizedRect(
                x: min(max(point.x - rect.width / 2, 0), 1 - rect.width),
                y: min(max(point.y - rect.height / 2, 0), 1 - rect.height),
                width: rect.width,
                height: rect.height
            )
            return .mouseLook(region: newRect, sensitivity: sensitivity)
        case .swipe(_, let to, let duration):
            return .swipe(from: point, to: to, duration: duration)
        }
    }
}
