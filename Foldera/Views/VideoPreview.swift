import AVFoundation
import SwiftUI

/// Plays one video for the Details pane. Clicking the picture plays it; clicking again pauses it.
@Observable
final class VideoPlayback {
    let player: AVPlayer
    private(set) var isPlaying = false
    /// Seconds played and in total, for the timeline. Zero until the video has loaded.
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// While the timeline is dragged, playback doesn't move its knob.
    var isScrubbing = false
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var timeObserver: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        if let item = player.currentItem {
            Task { [weak self] in
                guard let duration = try? await item.asset.load(.duration), duration.isNumeric else { return }
                self?.duration = duration.seconds
            }
        }
        // At the end, go back to the first frame and show the play button again.
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished() }
        }
    }

    isolated deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        player.pause()
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func finished() {
        pause()
        seek(to: 0)
    }

    /// Jumps to `seconds`, showing that frame even while paused.
    func seek(to seconds: Double) {
        currentTime = max(0, duration > 0 ? min(seconds, duration) : seconds)
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func tick(_ time: CMTime) {
        guard !isScrubbing, time.isNumeric else { return }
        currentTime = time.seconds
    }

    /// "0:07" or "1:02:03".
    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.isFinite ? max(0, seconds.rounded(.down)) : 0)
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

/// A video's first frame with a play button; clicking the picture plays and pauses it.
struct VideoPreview: View {
    @State private var playback: VideoPlayback
    private let autostarts: Bool

    init(url: URL, autostarts: Bool = false) {
        self.init(playback: VideoPlayback(url: url), autostarts: autostarts)
    }

    init(playback: VideoPlayback, autostarts: Bool = false) {
        _playback = State(initialValue: playback)
        self.autostarts = autostarts
    }

    var body: some View {
        VStack(spacing: 6) {
            picture
            timeline
        }
        .onAppear { if autostarts { playback.play() } }
        .onDisappear { playback.pause() }
    }

    private var picture: some View {
        ZStack {
            PlayerLayerView(player: playback.player)
            if !playback.isPlaying {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 48))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .shadow(radius: 4)
                    .allowsHitTesting(false)
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { playback.toggle() }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(L10n.text(playback.isPlaying ? "Pause video" : "Play video"))
        .accessibilityIdentifier("video-preview")
        .accessibilityAction { playback.toggle() }
    }

    /// Elapsed time, a draggable position and the length.
    private var timeline: some View {
        HStack(spacing: 8) {
            Text(VideoPlayback.format(playback.currentTime))
            Slider(value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }),
                   in: 0...max(playback.duration, 0.1)) { editing in
                playback.isScrubbing = editing
            }
            .controlSize(.small)
            .disabled(playback.duration <= 0)
            .accessibilityLabel(L10n.text("Timeline"))
            .accessibilityIdentifier("video-timeline")
            Text(VideoPlayback.format(playback.duration))
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Theme.secondaryText.swiftUI)
    }
}

/// Shows an `AVPlayer`'s picture, without the system's playback controls.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}
