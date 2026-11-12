import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 8)
            if let track = player.current {
                BigArtwork(url: track.artworkURL)
                    .padding(.horizontal, 28)

                VStack(spacing: 6) {
                    Text(track.title)
                        .font(.system(.title2, design: .serif).weight(.bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(track.artist)
                        .font(.body)
                        .foregroundColor(Color.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 28)

                SeekBar(playhead: player.playhead, onSeek: { player.seek(to: $0) })

                controls

                if let message = player.errorText {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(Color.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.top, 12)
    }

    private var controls: some View {
        HStack(spacing: 44) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            .accessibilityLabel("Anterior")

            Button { player.togglePlay() } label: {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 72, height: 72)
                    if player.isBuffering {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .foregroundColor(Color.white)
                    }
                }
            }
            .accessibilityLabel(player.isPlaying ? "Pausar" : "Reproducir")

            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
            .accessibilityLabel("Siguiente")
        }
        .foregroundColor(Color.primary)
    }
}

/// Barra para adelantar o retroceder, con los tiempos abajo.
struct SeekBar: View {
    @ObservedObject var playhead: Playhead
    let onSeek: (Double) -> Void
    @State var dragging = false
    @State var dragValue: Double = 0

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: sliderValue, in: 0...max(playhead.duration, 1), onEditingChanged: editingChanged)
            HStack {
                Text(Fmt.time(dragging ? dragValue : playhead.position))
                Spacer()
                Text(Fmt.time(playhead.duration))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundColor(Color.secondary)
        }
        .padding(.horizontal, 28)
    }

    private var sliderValue: Binding<Double> {
        Binding<Double>(
            get: { dragging ? dragValue : playhead.position },
            set: { dragValue = $0 }
        )
    }

    private func editingChanged(_ editing: Bool) {
        if editing {
            dragging = true
            dragValue = playhead.position
        } else {
            dragging = false
            onSeek(dragValue)
        }
    }
}
