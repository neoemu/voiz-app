import AVFoundation
import Combine
import Foundation

/// Estado de alta frequência observado exclusivamente pelas barras do player. Mantê-lo separado
/// evita que o `@StateObject` de `MeetingReviewView` invalide a árvore inteira a cada 200 ms.
@MainActor
final class MeetingPlayerPlaybackState: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    func setPlaying(_ value: Bool) {
        guard isPlaying != value else { return }
        isPlaying = value
    }

    func setCurrentTime(_ value: TimeInterval) {
        guard currentTime != value else { return }
        currentTime = value
    }

    func setDuration(_ value: TimeInterval) {
        guard duration != value else { return }
        duration = value
    }
}

/// Player de revisão de reunião. Combina os dois arquivos (`microphone.caf` + `system-audio.caf`),
/// que compartilham a mesma origem de tempo (início da sessão), num único timeline via
/// `AVMutableComposition` — assim a reprodução já sai mixada (você + participantes) e o seek por
/// `turn.startTime` cai no ponto certo.
@MainActor
final class MeetingAudioPlayer: ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var isLoading = false

    let playbackState = MeetingPlayerPlaybackState()
    let turnPlaybackState = MeetingTurnPlaybackState()

    var isPlaying: Bool { playbackState.isPlaying }
    var currentTime: TimeInterval { playbackState.currentTime }
    var duration: TimeInterval { playbackState.duration }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadedKey: String?

    /// Carrega o áudio de uma sessão. `key` evita recarregar a mesma sessão repetidamente.
    func load(micURL: URL?, systemURL: URL?, key: String, turns: [MeetingTurn]) async {
        if loadedKey == key, isAvailable {
            updateTurns(turns)
            return
        }
        teardown()
        updateTurns(turns)
        loadedKey = key
        isLoading = true

        let urls = [micURL, systemURL]
            .compactMap { $0 }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        guard !urls.isEmpty else {
            isLoading = false
            isAvailable = false
            return
        }

        let composition = AVMutableComposition()
        var maxDuration = CMTime.zero

        for url in urls {
            let asset = AVURLAsset(url: url)
            do {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard let sourceTrack = tracks.first else { continue }
                let assetDuration = try await asset.load(.duration)
                guard let compTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { continue }
                try compTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: assetDuration),
                    of: sourceTrack,
                    at: .zero
                )
                if assetDuration > maxDuration { maxDuration = assetDuration }
            } catch {
                print("⚠️ Player: falha ao carregar \(url.lastPathComponent): \(error)")
            }
        }

        guard maxDuration > .zero else {
            isLoading = false
            isAvailable = false
            return
        }

        let item = AVPlayerItem(asset: composition)
        let player = AVPlayer(playerItem: item)
        self.player = player
        playbackState.setDuration(maxDuration.seconds)
        addObservers(to: player)
        isAvailable = true
        updateCurrentTime(0)
        isLoading = false
    }

    func playFrom(_ time: TimeInterval) {
        guard let player else { return }
        seek(to: time)
        player.play()
        playbackState.setPlaying(true)
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            playbackState.setPlaying(false)
        } else {
            if currentTime >= duration - 0.1 { seek(to: 0) }
            player.play()
            playbackState.setPlaying(true)
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(time, duration))
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        updateCurrentTime(clamped)
    }

    /// Reindexa sem recarregar o áudio. O transcript pode ser substituído enquanto esta mesma
    /// sessão está aberta (reprocessamento/Qualidade), portanto `load` não é a única origem de
    /// atualizações dos turnos.
    func updateTurns(_ turns: [MeetingTurn]) {
        turnPlaybackState.updateTurns(turns, at: currentTime)
    }

    private func addObservers(to player: AVPlayer) {
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.updateCurrentTime(time.seconds)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.playbackState.setPlaying(false)
            }
        }
    }

    private func updateCurrentTime(_ seconds: TimeInterval) {
        playbackState.setCurrentTime(seconds)
        turnPlaybackState.updateCurrentTime(seconds)
    }

    private func teardown() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        playbackState.setPlaying(false)
        playbackState.setCurrentTime(0)
        playbackState.setDuration(0)
        turnPlaybackState.updateTurns([], at: 0)
        isAvailable = false
    }
}
