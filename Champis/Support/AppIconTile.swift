#if os(iOS)
import SwiftUI

/// Une icône de la grille : l'aperçu arrondi comme sur l'écran d'accueil, son nom dessous, un
/// anneau et une coche sur l'icône en service.
struct AppIconTile: View {
    let title: String
    let previewName: String
    let size: CGFloat
    let isSelected: Bool
    let isChanging: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(previewName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: size * 0.225, style: .continuous))
                    .padding(4)
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.225 + 4, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isChanging {
                            ProgressView()
                                .padding(4)
                                .background(.regularMaterial, in: .circle)
                        } else if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .font(.title2)
                                .background(.white, in: .circle)
                        }
                    }
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
