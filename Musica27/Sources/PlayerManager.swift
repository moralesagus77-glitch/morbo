import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

/// Posición y duración, separadas para que la lista no se redibuje cada medio segundo.
final class Playhead: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
}

final class PlayerManager: NSObject, ObservableObject {
    @Published var queue: [Track] = []
    @Published var index: Int = 0
    @Published var current: Track?
    @Published var isPlaying = false
    @Published var isBuffering = false
    @Published var errorText: String?

    let playhead = Playhead()

    private let player = AVPlayer()
    private var bag = Set<AnyCancellable>()
    private var itemBag = Set<AnyCancellable>()
    private var timeObserver: Any?
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var failures = 0
    private var triedDownload = false
    private var tempFile: URL?
    private var artwork: MPMediaItemArtwork?
    private var artworkID: String?

    override init() {
        super.init()
        configureSession()
        observePlayer()
        configureRemoteCommands()
    }

    // MARK: - Control

    func play(_ tracks: [Track], at i: Int) {
        queue = tracks
        failures = 0
        start(i)
    }

    func togglePlay() {
        guard current != nil else { return }
        if player.timeControlStatus == .paused {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
        } else {
            player.pause()
        }
    }

    func next(auto: Bool = false) {
        if index + 1 < queue.count {
            start(index + 1)
            return
        }
        let radioOn = (UserDefaults.standard.object(forKey: "autoRadio") as? Bool) ?? true
        guard radioOn, let last = current else { return }
        Task { [weak self] in
            let more = await Backend.shared.radio(for: last.id)
            await MainActor.run {
                guard let me = self, me.current?.id == last.id else { return }
                let known = Set(me.queue.map { $0.id })
                let fresh = more.filter { !known.contains($0.id) }
                if fresh.isEmpty { return }
                me.queue.append(contentsOf: fresh)
                me.start(me.index + 1)
            }
        }
    }

    func previous() {
        if playhead.position > 3 || index == 0 {
            seek(to: 0)
        } else {
            start(index - 1)
        }
    }

    func seek(to seconds: Double) {
        let target = max(0, seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            DispatchQueue.main.async {
                self?.playhead.position = target
                self?.updateNowPlaying()
            }
        }
    }

    // MARK: - Carga de una canción

    private func start(_ i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        let track = queue[i]
        current = track
        playhead.position = 0
        playhead.duration = track.duration ?? 0
        errorText = nil
        isBuffering = true
        triedDownload = false
        generation += 1
        let gen = generation

        itemBag.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
        cleanupTemp()
        artwork = nil
        artworkID = nil

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let me = self else { return }
            await me.load(track, generation: gen)
        }
        updateNowPlaying()
        loadArtwork(for: track)
    }

    private func load(_ track: Track, generation gen: Int) async {
        do {
            let src = try await Backend.shared.resolveAudio(for: track)
            if Task.isCancelled { return }
            await MainActor.run {
                guard gen == self.generation else { return }
                self.begin(src, for: track)
            }
        } catch {
            if Task.isCancelled { return }
            let message = error.localizedDescription
            await MainActor.run {
                guard gen == self.generation else { return }
                self.fail("No se pudo reproducir. " + message)
            }
        }
    }

    private func begin(_ src: AudioSource, for track: Track) {
        AppLog.shared.add("[play] \(track.title) <- \(src.label)")
        var options: [String: Any]?
        if !src.headers.isEmpty {
            options = ["AVURLAssetHTTPHeaderFieldsKey": src.headers]
        }
        let asset = AVURLAsset(url: src.url, options: options)
        attach(AVPlayerItem(asset: asset), source: src)
    }

    private func attach(_ item: AVPlayerItem, source: AudioSource?) {
        itemBag.removeAll()

        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self = self, let item = item else { return }
                switch status {
                case .readyToPlay:
                    self.failures = 0
                    self.errorText = nil
                    let d = item.duration.seconds
                    if d.isFinite && d > 0 { self.playhead.duration = d }
                    self.updateNowPlaying()
                case .failed:
                    self.itemFailed(item, source: source)
                default:
                    break
                }
            }
            .store(in: &itemBag)

        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.next(auto: true) }
            .store(in: &itemBag)

        player.replaceCurrentItem(with: item)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    private func itemFailed(_ item: AVPlayerItem, source: AudioSource?) {
        let reason = item.error?.localizedDescription ?? "error desconocido"
        AppLog.shared.add("[play] el reproductor falló: \(reason)")
        if let src = source, !triedDownload {
            triedDownload = true
            AppLog.shared.add("[play] probando bajar el archivo completo")
            downloadAndPlay(src)
        } else {
            fail("No se pudo reproducir. " + reason)
        }
    }

    /// Plan B: bajar el archivo entero y reproducirlo desde el disco.
    private func downloadAndPlay(_ src: AudioSource) {
        let gen = generation
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            do {
                var req = URLRequest(url: src.url)
                req.timeoutInterval = 60
                for (k, v) in src.headers { req.setValue(v, forHTTPHeaderField: k) }
                let (tmp, resp) = try await URLSession.shared.download(for: req)
                if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw BackendError.message("HTTP \(http.statusCode)")
                }
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("musica27-\(UUID().uuidString).m4a")
                try FileManager.default.moveItem(at: tmp, to: dest)
                await MainActor.run {
                    guard let me = self, gen == me.generation else {
                        try? FileManager.default.removeItem(at: dest)
                        return
                    }
                    me.tempFile = dest
                    me.attach(AVPlayerItem(url: dest), source: nil)
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    guard let me = self, gen == me.generation else { return }
                    me.fail("No se pudo reproducir. " + message)
                }
            }
        }
    }

    private func fail(_ message: String) {
        AppLog.shared.add("[error] " + message)
        isBuffering = false
        failures += 1
        if failures < 3, index + 1 < queue.count {
            errorText = message + " Paso a la siguiente."
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self, gen == self.generation else { return }
                self.start(self.index + 1)
            }
        } else {
            errorText = message
        }
    }

    private func cleanupTemp() {
        if let t = tempFile {
            try? FileManager.default.removeItem(at: t)
            tempFile = nil
        }
    }

    // MARK: - Sesión de audio y observadores

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
        } catch {
            AppLog.shared.add("[audio] no se pudo configurar la sesión: \(error.localizedDescription)")
        }
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] note in self?.handleInterruption(note) }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
                DispatchQueue.main.async { self?.player.pause() }
            }
            .store(in: &bag)
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended {
            let optRaw = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {
                DispatchQueue.main.async { [weak self] in self?.player.play() }
            }
        }
    }

    private func observePlayer() {
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                switch status {
                case .playing:
                    self.isPlaying = true
                    self.isBuffering = false
                case .waitingToPlayAtSpecifiedRate:
                    self.isPlaying = false
                    self.isBuffering = true
                default:
                    self.isPlaying = false
                }
                self.updateNowPlaying()
            }
            .store(in: &bag)

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let t = time.seconds
            if t.isFinite { self.playhead.position = t }
            if let item = self.player.currentItem {
                let d = item.duration.seconds
                if d.isFinite && d > 0 && abs(d - self.playhead.duration) > 0.5 {
                    self.playhead.duration = d
                }
            }
        }
    }

    // MARK: - Pantalla de bloqueo

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.isEnabled = true
        c.pauseCommand.isEnabled = true
        c.togglePlayPauseCommand.isEnabled = true
        c.nextTrackCommand.isEnabled = true
        c.previousTrackCommand.isEnabled = true
        c.changePlaybackPositionCommand.isEnabled = true

        _ = c.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.player.play() }
            return .success
        }
        _ = c.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.player.pause() }
            return .success
        }
        _ = c.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.togglePlay() }
            return .success
        }
        _ = c.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.next() }
            return .success
        }
        _ = c.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.previous() }
            return .success
        }
        _ = c.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                let t = e.positionTime
                DispatchQueue.main.async { self?.seek(to: t) }
            }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let t = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playhead.position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if playhead.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = playhead.duration }
        if let art = artwork, artworkID == t.id { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for track: Track) {
        guard let url = track.artworkURL else { return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = UIImage(data: data) else { return }
            let art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            await MainActor.run {
                guard let me = self, me.current?.id == track.id else { return }
                me.artwork = art
                me.artworkID = track.id
                me.updateNowPlaying()
            }
        }
    }
}
