import SwiftUI

/// Carátula cuadrada chica.
struct Artwork: View {
    let url: URL?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "music.note").foregroundColor(Color.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Carátula grande de la pantalla de reproducción.
struct BigArtwork: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "music.note")
                        .font(.system(size: 54))
                        .foregroundColor(Color.secondary)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.25), radius: 16, x: 0, y: 8)
    }
}

struct TrackRow: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: track.artworkURL, size: 52, radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(.body, design: .serif).weight(.semibold))
                    .foregroundColor(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundColor(Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var trailing: some View {
        if isCurrent {
            Image(systemName: isPlaying ? "waveform" : "pause.fill")
                .foregroundColor(Color.accentColor)
        } else if let d = track.duration {
            Text(Fmt.time(d))
                .font(.footnote)
                .monospacedDigit()
                .foregroundColor(Color.secondary)
        }
    }
}

/// Línea finita de progreso sobre el reproductor chico.
struct ProgressLine: View {
    @ObservedObject var playhead: Playhead

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.2))
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 2)
    }

    private var fraction: CGFloat {
        guard playhead.duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, playhead.position / playhead.duration)))
    }
}
