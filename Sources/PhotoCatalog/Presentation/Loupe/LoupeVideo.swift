// ============================================================
//  Loupe video — a video plays where a photo would show
// ============================================================
import AVKit
import SwiftUI

/// AVKit's player with its inline controls, paused until asked. A new video replaces the
/// player, and leaving the loupe pauses and lets it go, so no sound plays on behind the grid
/// and the file isn't held open. `toggle` changing (Space) plays or pauses.
struct LoupeVideo: NSViewRepresentable {
    let url: URL
    let toggle: Int

    final class Coordinator {
        var toggle = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        context.coordinator.toggle = toggle
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player?.pause()
            view.player = AVPlayer(url: url)
        }
        if context.coordinator.toggle != toggle, let player = view.player {
            context.coordinator.toggle = toggle
            if player.timeControlStatus == .playing {
                player.pause()
            } else {
                // at the end, start over
                if let item = player.currentItem, item.currentTime() >= item.duration { player.seek(to: .zero) }
                player.play()
            }
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        view.player = nil
    }
}
