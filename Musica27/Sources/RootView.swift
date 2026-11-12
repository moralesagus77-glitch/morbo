import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: PlayerManager
    @StateObject private var model = SearchModel()
    @State private var query = ""
    @State private var showPlayer = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Música")
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Canciones o artistas")
                .onSubmit(of: .search) { model.search(query) }
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Ajustes")
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if player.current != nil {
                        MiniPlayer(showPlayer: $showPlayer)
                    }
                }
        }
        .sheet(isPresented: $showPlayer) {
            NowPlayingView().environmentObject(player)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.loading {
            ProgressView("Buscando…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.results.isEmpty {
            emptyState
        } else {
            resultsList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 44))
                .foregroundColor(Color.secondary)
            Text(model.message ?? "Buscá una canción o un artista")
                .font(.system(.title3, design: .serif))
                .multilineTextAlignment(.center)
                .foregroundColor(model.message == nil ? Color.primary : Color.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsList: some View {
        List {
            ForEach(Array(model.results.enumerated()), id: \.element.id) { i, track in
                Button {
                    player.play(model.results, at: i)
                } label: {
                    TrackRow(
                        track: track,
                        isCurrent: player.current?.id == track.id,
                        isPlaying: player.isPlaying
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
    }
}

/// Reproductor chico que queda abajo mientras navegás.
struct MiniPlayer: View {
    @EnvironmentObject var player: PlayerManager
    @Binding var showPlayer: Bool

    var body: some View {
        if let track = player.current {
            VStack(spacing: 0) {
                ProgressLine(playhead: player.playhead)
                HStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Artwork(url: track.artworkURL, size: 44, radius: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title)
                                .font(.system(.subheadline, design: .serif).weight(.semibold))
                                .lineLimit(1)
                            Text(player.errorText ?? track.artist)
                                .font(.caption)
                                .foregroundColor(player.errorText == nil ? Color.secondary : Color.red)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { showPlayer = true }

                    Button { player.togglePlay() } label: {
                        if player.isBuffering {
                            ProgressView()
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                        }
                    }
                    .frame(width: 32)
                    .accessibilityLabel(player.isPlaying ? "Pausar" : "Reproducir")

                    Button { player.next() } label: {
                        Image(systemName: "forward.fill").font(.title3)
                    }
                    .accessibilityLabel("Siguiente")
                }
                .foregroundColor(Color.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }
}
