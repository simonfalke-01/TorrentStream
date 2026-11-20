import SwiftUI
import AVKit
import VLCKit

/// Where libVLC draws, and the hand-off points for Picture in Picture and a TV.
///
/// libVLC adds its own video view inside `view`; `view` is then moved between the player screen and an
/// AirPlay/external display window as needed. libVLC needs a non-zero size when its output starts, so `view`
/// begins at the screen's size.
final class VideoOutput: NSObject, VLCDrawable, VLCPictureInPictureDrawable {
    let view: UIView
    private let controls: PiPMediaControls
    private(set) weak var pip: (any VLCPictureInPictureWindowControlling)?
    /// Called on the main thread when PiP becomes available, and when it starts or stops.
    var onPiPReady: (() -> Void)?
    var onPiPChange: ((Bool) -> Void)?

    private weak var inlineHost: UIView?
    private weak var externalHost: UIView?

    init(player: VLCMediaPlayer) {
        view = UIView(frame: UIScreen.main.bounds)
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.autoresizesSubviews = true
        controls = PiPMediaControls(player: player)
        super.init()
    }

    // MARK: VLCDrawable

    func addSubview(_ subview: UIView!) {
        guard let subview else { return }
        view.addSubview(subview)
        subview.frame = view.bounds
        subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    func bounds() -> CGRect { view.bounds }

    // MARK: VLCPictureInPictureDrawable

    func mediaController() -> (any VLCPictureInPictureMediaControlling)! { controls }

    func pictureInPictureReady() -> (((any VLCPictureInPictureWindowControlling)?) -> Void)! {
        { [weak self] controller in
            DispatchQueue.main.async {
                guard let self, let controller else { return }
                self.pip = controller
                controller.stateChangeEventHandler = { [weak self] started in
                    DispatchQueue.main.async { self?.onPiPChange?(started) }
                }
                self.onPiPReady?()
            }
        }
    }

    func startPictureInPicture() { pip?.startPictureInPicture() }
    func stopPictureInPicture() { pip?.stopPictureInPicture() }
    func invalidatePlaybackState() { pip?.invalidatePlaybackState() }

    // MARK: placement

    /// The player screen's video area.
    func attach(inline host: UIView) {
        inlineHost = host
        place()
    }

    /// A TV's window, or nil to come back to the phone.
    func attach(external host: UIView?) {
        externalHost = host
        place()
    }

    private func place() {
        guard let target = externalHost ?? inlineHost, view.superview !== target else { return }
        view.removeFromSuperview()
        view.frame = target.bounds
        target.addSubview(view)
    }
}

/// What Picture in Picture's own play, pause and skip buttons drive.
private final class PiPMediaControls: NSObject, VLCPictureInPictureMediaControlling {
    private weak var player: VLCMediaPlayer?

    init(player: VLCMediaPlayer) { self.player = player }

    func play() { player?.play() }
    func pause() { player?.pause() }

    func seek(by offset: Int64, completion: (() -> Void)!) {
        guard let player else { completion?(); return }
        _ = player.jump(withOffset: Int32(offset), completion: completion)
    }

    func mediaLength() -> Int64 { player?.media?.length.value?.int64Value ?? 0 }
    func mediaTime() -> Int64 { player?.time.value?.int64Value ?? 0 }
    func isMediaSeekable() -> Bool { player?.isSeekable ?? false }
    func isMediaPlaying() -> Bool { player?.isPlaying ?? false }
}

/// The video area on the player screen. The video itself lives in `VideoOutput.view`, which can be away on a TV.
struct VideoSurface: UIViewRepresentable {
    let output: VideoOutput

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .black
        host.isUserInteractionEnabled = false
        host.clipsToBounds = true
        output.attach(inline: host)
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - AirPlay

/// The system AirPlay picker. Choosing an Apple TV for screen mirroring puts the video on the TV full screen
/// while the controls stay on the phone.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = .white
        picker.activeTintColor = .tintColor
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - External display

/// A connected TV (AirPlay mirroring or a cable). While a video plays, the TV shows only the video; otherwise it
/// mirrors the phone as usual.
@MainActor
final class ExternalDisplay: ObservableObject {
    static let shared = ExternalDisplay()

    @Published private(set) var isConnected = false
    private weak var scene: UIWindowScene?
    /// Exists only while a video is on the TV; without a window the system mirrors the phone.
    private var window: UIWindow?

    func connect(_ scene: UIWindowScene) {
        self.scene = scene
        isConnected = true
    }

    func disconnect() {
        window?.isHidden = true
        window = nil
        scene = nil
        isConnected = false
    }

    /// The view a video should move into, shown on the TV from now on; nil when no TV is connected.
    func claim() -> UIView? {
        guard let scene else { return nil }
        if window == nil {
            let window = UIWindow(windowScene: scene)
            let root = UIViewController()
            root.view.backgroundColor = .black
            window.rootViewController = root
            self.window = window
        }
        window?.isHidden = false
        return window?.rootViewController?.view
    }

    /// Back to mirroring the phone.
    func release() {
        window?.isHidden = true
        window = nil
    }
}

final class ExternalSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        MainActor.assumeIsolated { ExternalDisplay.shared.connect(scene) }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        MainActor.assumeIsolated { ExternalDisplay.shared.disconnect() }
    }
}

/// Routes a TV's scene to `ExternalSceneDelegate`; everything else gets SwiftUI's usual scene.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            let config = UISceneConfiguration(name: "External Display", sessionRole: connectingSceneSession.role)
            config.delegateClass = ExternalSceneDelegate.self
            return config
        }
        return connectingSceneSession.configuration
    }
}
