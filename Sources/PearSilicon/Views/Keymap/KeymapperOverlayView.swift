import SwiftUI

/// The keymapper editor rendered by PearSilicon over the game window.
///
/// It is a translucent scrim with one draggable chip per binding; the game stays
/// visible underneath (the host window is transparent). Dragging a chip moves
/// where the runtime synthesizes that touch. Coordinates are stored normalized
/// (0...1), so the on-screen window size and the game's internal point size do
/// not matter.
struct KeymapperOverlayView: View {
    @State private var keymap: Keymap
    let onSave: (Keymap) -> Void
    let onCancel: () -> Void

    init(keymap: Keymap, onSave: @escaping (Keymap) -> Void, onCancel: @escaping () -> Void) {
        _keymap = State(initialValue: keymap)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.opacity(0.22)

                hint
                    .padding(.top, 14)

                ForEach(keymap.bindings.indices, id: \.self) { index in
                    if let point = KeymapCanvasView.position(of: keymap.bindings[index].action) {
                        chip(for: keymap.bindings[index], at: point, size: geo.size)
                    }
                }

                toolbar
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .ignoresSafeArea()
    }

    private var hint: some View {
        Text("Drag each key onto the control it should tap in the game")
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.black.opacity(0.45), in: Capsule())
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .tint(.white)
            Button("Done") { onSave(keymap) }
                .buttonStyle(.borderedProminent)
        }
    }

    private func chip(for binding: KeymapBinding, at point: NormalizedPoint, size: CGSize) -> some View {
        let color = Self.color(for: binding.action)
        return VStack(spacing: 1) {
            Text(binding.displayKey).font(.caption.weight(.bold))
            Text(binding.actionKind).font(.system(size: 8))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 1.4))
        .shadow(radius: 2)
        .position(x: point.x * size.width, y: point.y * size.height)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let nx = min(max(value.location.x / size.width, 0), 1)
                    let ny = min(max(value.location.y / size.height, 0), 1)
                    move(binding.id, to: NormalizedPoint(nx, ny))
                }
        )
    }

    private func move(_ id: KeymapBinding.ID, to point: NormalizedPoint) {
        guard let index = keymap.bindings.firstIndex(where: { $0.id == id }) else { return }
        keymap.bindings[index].action = KeymapCanvasView.moved(keymap.bindings[index].action, to: point)
    }

    private static func color(for action: KeymapAction) -> Color {
        switch action {
        case .tap: return .blue
        case .hold: return .orange
        case .joystick: return .purple
        case .mouseLook: return .gray
        case .swipe: return .teal
        }
    }
}
