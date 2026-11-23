import SwiftUI

/// A content surface. Interactive controls supply their own Liquid Glass.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat
    var content: Content

    init(cornerRadius: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.08))
                    .allowsHitTesting(false)
            }
    }
}

/// A compact section title used inside glass cards.
struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.headline)
    }
}

/// Small tinted capsule for state such as "Running" or "Automatic".
struct StatusPill: View {
    enum Tone {
        case positive
        case warning
        case neutral

        var color: Color {
            switch self {
            case .positive: .green
            case .warning: .orange
            case .neutral: .secondary
            }
        }
    }

    let text: String
    var tone: Tone = .neutral
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .bold))
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(tone.color.opacity(0.14)))
        .overlay(Capsule().strokeBorder(tone.color.opacity(0.28), lineWidth: 1))
        .fixedSize()
    }
}
