import SwiftUI
import AVKit
import CoreImage
import ObjectiveC
import VLCKit

/// Where libVLC draws, and the hand-off points for Picture in Picture and a TV.
///
/// libVLC adds its own video view inside `view`; `view` is then moved between the player screen and an
/// AirPlay/external display window as needed. libVLC needs a non-zero size when its output starts, so `view`
/// begins at the screen's size.
///
/// Inside `view`, libVLC 4's display (modules/video_output/apple/VLCSampleBufferDisplay.m) puts one view backed
/// by an `AVSampleBufferDisplayLayer` for the picture, and a sibling view it draws subtitles into. Picture in
/// Picture only ever takes the display layer, so subtitles are burned into its frames here while PiP is up.
final class VideoOutput: NSObject, VLCDrawable, VLCPictureInPictureDrawable {
    let view: UIView
    private let controls: PiPMediaControls
    private(set) weak var pip: (any VLCPictureInPictureWindowControlling)?
    /// Called on the main thread when PiP becomes available, and when it starts or stops.
    var onPiPReady: (() -> Void)?
    var onPiPChange: ((Bool) -> Void)?
    /// Called on the main thread just before the picture flies back from PiP, so the screen can make room for it.
    var onPiPRestore: (() -> Void)?
    /// What PiP's own play and pause buttons do.
    var onPlay: (() -> Void)? {
        get { controls.onPlay }
        set { controls.onPlay = newValue }
    }
    var onPause: (() -> Void)? {
        get { controls.onPause }
        set { controls.onPause = newValue }
    }

    private weak var inlineHost: UIView?
    private weak var externalHost: UIView?

    /// libVLC's AVKit controller, reached through its `avPipController` property.
    private weak var avPip: AVPictureInPictureController?
    private var pipDelegate: PiPDelegateProxy?
    /// From the moment PiP starts to start until it has stopped, so nothing switches the video off meanwhile.
    private(set) var isPiPEngaged = false
    private var engagedAt = Date.distantPast
    /// Layers that had a mask before PiP; any other mask found afterwards was left by the PiP animation.
    private var masksBeforePiP: Set<ObjectIdentifier>?
    private let burner = PiPSubtitleBurner()
    private weak var burnerLayer: AVSampleBufferDisplayLayer?
    private var overlayTimer: Timer?
    private var overlaySignature = ""
    private var overlayBuiltAt = Date.distantPast
    private var secondaryText: String?

    init(player: VLCMediaPlayer) {
        view = UIView(frame: UIScreen.main.bounds)
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.autoresizesSubviews = true
        controls = PiPMediaControls(player: player)
        super.init()
    }

    func shutdown() {
        uncover(animated: false)
        stopOverlay()
        burner.setActive(false)
        detachBurner()
    }

    // MARK: VLCDrawable

    func addSubview(_ subview: UIView!) {
        guard let subview else { return }
        view.addSubview(subview)
        subview.frame = view.bounds
        subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let cover { view.bringSubviewToFront(cover) }
    }

    func bounds() -> CGRect { view.bounds }

    // MARK: VLCPictureInPictureDrawable

    func mediaController() -> (any VLCPictureInPictureMediaControlling)! { controls }

    /// libVLC calls this once per video output it opens: at the start, and again whenever the picture is rebuilt
    /// (the video track switched back on, the stream reopened), each time with a new layer and PiP controller.
    func pictureInPictureReady() -> (((any VLCPictureInPictureWindowControlling)?) -> Void)! {
        { [weak self] controller in
            DispatchQueue.main.async {
                guard let self, let controller else { return }
                self.adopt(controller)
            }
        }
    }

    func startPictureInPicture() { pip?.startPictureInPicture() }
    func stopPictureInPicture() { pip?.stopPictureInPicture() }
    func invalidatePlaybackState() { pip?.invalidatePlaybackState() }

    private func adopt(_ controller: any VLCPictureInPictureWindowControlling) {
        pip = controller
        controller.stateChangeEventHandler = { [weak self] started in
            DispatchQueue.main.async { self?.pipStateChanged(started) }
        }
        // libVLC's controller keeps AVKit's controller in `avPipController` (VLCPictureInPictureController.m) and is
        // its delegate, without the restore and failure callbacks. Put a delegate in front that adds them and
        // passes everything else on.
        let key = "avPipController"
        if let object = controller as? NSObject, object.responds(to: NSSelectorFromString(key)),
           let av = object.value(forKey: key) as? AVPictureInPictureController {
            let proxy = PiPDelegateProxy(forwardingTo: av.delegate, owner: self)
            av.delegate = proxy
            pipDelegate = proxy
            avPip = av
        } else {
            PlaybackTrace.shared.mark("pip: libVLC's AVKit controller isn't reachable; restore and subtitles fall back")
            pipDelegate = nil
            avPip = nil
        }
        // A new output while PiP was up means the old one closed, and its PiP window with it.
        if isPiPEngaged, avPip?.isPictureInPictureActive != true {
            PlaybackTrace.shared.mark("pip: ended with the old video output")
            pipEnded()
            onPiPChange?(false)
        }
        if burnerLayer != nil { attachBurner() }
        onPiPReady?()
    }

    // MARK: PiP lifecycle

    fileprivate func pipWillStart() {
        PlaybackTrace.shared.mark("pip: starting")
        isPiPEngaged = true
        engagedAt = Date()
        masksBeforePiP = Set(allLayers().filter { $0.mask != nil }.map(ObjectIdentifier.init))
        attachBurner()
        burner.setActive(true)
        startOverlay()
    }

    private func pipStateChanged(_ started: Bool) {
        if started {
            if !isPiPEngaged { pipWillStart() }
            PlaybackTrace.shared.mark("pip: started")
            onPiPChange?(true)
        } else {
            PlaybackTrace.shared.mark("pip: stopped")
            pipEnded()
            onPiPChange?(false)
            tidyAfterPiP()
        }
    }

    fileprivate func pipWillStop() {
        // Frames from here on show in the player again, where libVLC draws subtitles itself.
        burner.setActive(false)
        stopOverlay()
    }

    fileprivate func pipFailed(_ error: Error) {
        PlaybackTrace.shared.mark("pip: failed to start: \(error.localizedDescription)")
        pipEnded()
        onPiPChange?(false)
    }

    private func pipEnded() {
        isPiPEngaged = false
        burner.setActive(false)
        stopOverlay()
    }

    /// AVKit asks for the player to be ready before animating the picture back into it. Without this libVLC lets
    /// the animation land on whatever is on screen, and leaves the layer as the animation left it.
    fileprivate func restoreForPiPStop(_ done: @escaping @Sendable (Bool) -> Void) {
        PlaybackTrace.shared.mark("pip: restoring the player")
        pipWillStop()
        onPiPRestore?()
        place()
        fitToHost()
        squareCorners()
        // One turn of the run loop lets SwiftUI take the placeholder down before the picture lands.
        DispatchQueue.main.async { done(true) }
    }

    /// AVKit's return animation rounds the corners of the layers it animates into and doesn't always put them
    /// back; they stayed until something else redrew them. Square them after it, and again once it has settled.
    private func tidyAfterPiP() {
        fitToHost()
        squareCorners()
        for delay in [0.35, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isPiPEngaged else { return }
                self.squareCorners()
            }
        }
    }

    /// Called about once a second: PiP can end without a word, e.g. when its video output closes.
    func reconcilePiP() {
        guard isPiPEngaged, Date().timeIntervalSince(engagedAt) > 3 else { return }
        // Without AVKit's controller in reach, all that's known is whether libVLC's controller still exists.
        let active = avPip.map(\.isPictureInPictureActive) ?? (pip != nil)
        if !active {
            PlaybackTrace.shared.mark("pip: no longer active")
            pipEnded()
            onPiPChange?(false)
            tidyAfterPiP()
        }
    }

    // MARK: geometry

    /// libVLC's own view (VLCVideoUIView), which holds the display and subtitle views.
    private var vlcView: UIView? { view.subviews.last }

    /// Lays the video out for the host's current size at once, rather than when libVLC next places it.
    private func fitToHost() {
        if let host = view.superview, view.frame != host.bounds { view.frame = host.bounds }
        view.layoutIfNeeded()
        guard let window = vlcView else { return }
        window.setNeedsLayout()
        window.layoutIfNeeded()
        // libVLC sizes the display view to the picture's rectangle after its next layout pass. The layer fits the
        // picture itself (videoGravity defaults to resizeAspect), so filling the window shows the same picture
        // now, at the right size.
        if let display = displayLayer?.delegate as? UIView, display.superview === window, display.frame != window.bounds {
            display.frame = window.bounds
        }
    }

    private func squareCorners() {
        let before = masksBeforePiP
        var fixed = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in allLayers() {
            if layer.cornerRadius != 0 {
                layer.cornerRadius = 0
                fixed += 1
            }
            if let before, layer.mask != nil, !before.contains(ObjectIdentifier(layer)) {
                layer.mask = nil
                fixed += 1
            }
        }
        CATransaction.commit()
        if fixed > 0 { PlaybackTrace.shared.mark("pip: squared \(fixed) rounded corners left on the video") }
    }

    /// The host's layer, `view`'s layer and everything inside it.
    private func allLayers() -> [CALayer] {
        var out: [CALayer] = []
        if let host = view.superview { out.append(host.layer) }
        var stack = [view.layer]
        while let layer = stack.popLast() {
            out.append(layer)
            stack.append(contentsOf: layer.sublayers ?? [])
        }
        return out
    }

    // MARK: display layer health

    enum LayerHealth {
        case fine
        /// The layer had lost its decoder and was flushed to get it back.
        case flushed
        /// The layer has failed for good and shows no new frames.
        case failed(String)
    }

    /// libVLC's current display layer: the one PiP uses, else the newest in the view tree.
    private var displayLayer: AVSampleBufferDisplayLayer? {
        if let layer = avPip?.contentSource?.sampleBufferDisplayLayer, layer.superlayer != nil { return layer }
        return Self.lastDisplayLayer(in: view)
    }

    /// The last display layer in drawing order: views added later sit on top, and libVLC adds its newest last.
    private static func lastDisplayLayer(in root: UIView) -> AVSampleBufferDisplayLayer? {
        var found = root.layer as? AVSampleBufferDisplayLayer
        for subview in root.subviews {
            if let layer = lastDisplayLayer(in: subview) { found = layer }
        }
        return found
    }

    /// A failed layer drops every frame libVLC hands it (RenderPicture returns early while the status is failed),
    /// so the picture freezes while the sound plays on. libVLC flushes it when the app becomes active, but only if
    /// the layer says a flush will help; this checks again later and reports a layer that stays failed.
    func checkDisplayLayer() -> LayerHealth {
        guard let layer = displayLayer else { return .fine }
        let renderer = layer.sampleBufferRenderer
        guard renderer.status == .failed else { return .fine }
        // The lock libVLC holds (@synchronized) around enqueueing and flushing.
        objc_sync_enter(layer)
        defer { objc_sync_exit(layer) }
        guard renderer.status == .failed else { return .fine }
        if renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            return .flushed
        }
        return .failed(renderer.error?.localizedDescription ?? "no error given")
    }

    // MARK: holding the picture

    private var cover: UIView?

    /// Holds the picture as it is now above the video, so switching the video off and on again (leaving the app
    /// and coming back) shows the last picture instead of black while libVLC builds a new output.
    func coverPicture() {
        guard cover == nil else { return }
        let source = (displayLayer?.delegate as? UIView) ?? view
        guard source.window != nil, let snapshot = source.snapshotView(afterScreenUpdates: false) else { return }
        snapshot.frame = view.convert(source.bounds, from: source)
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        snapshot.isUserInteractionEnabled = false
        view.addSubview(snapshot)
        cover = snapshot
    }

    func uncover(animated: Bool = true) {
        guard let c = cover else { return }
        cover = nil
        guard animated else {
            c.removeFromSuperview()
            return
        }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction],
                       animations: { c.alpha = 0 }, completion: { _ in c.removeFromSuperview() })
    }

    // MARK: subtitles in PiP

    /// The app's own second subtitle line, burned into PiP above the picture like it shows on the screen.
    func setSecondarySubtitle(_ text: String?) {
        secondaryText = text
    }

    private func attachBurner() {
        guard PiPSubtitleBurner.installHook(), let layer = displayLayer else { return }
        guard layer !== burnerLayer else { return }
        detachBurner()
        burner.attach(to: layer)
        burnerLayer = layer
    }

    private func detachBurner() {
        if let old = burnerLayer { PiPSubtitleBurner.detach(from: old) }
        burnerLayer = nil
    }

    private func startOverlay() {
        guard overlayTimer == nil else { return }
        overlaySignature = ""
        refreshOverlay()
        overlayTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshOverlay()
        }
    }

    private func stopOverlay() {
        overlayTimer?.invalidate()
        overlayTimer = nil
        overlaySignature = ""
        burner.setOverlay([])
    }

    /// Collects what libVLC's subtitle view shows now, plus the second subtitle line, as images placed relative to
    /// the picture. Cheap when nothing changed: libVLC replaces its region list whenever the subtitle does.
    private func refreshOverlay() {
        guard isPiPEngaged else { return }
        if burnerLayer == nil || burnerLayer?.superlayer == nil || burnerLayer !== displayLayer { attachBurner() }
        guard let layer = burnerLayer, let display = layer.delegate as? UIView, let window = display.superview else {
            burner.setOverlay([])
            return
        }
        // Where the picture sits in libVLC's window. The display view may fill the window (fitToHost), with the
        // layer fitting the picture inside it, so place it from the frames' own aspect when known.
        let frame = burner.pictureSize().map { AVMakeRect(aspectRatio: $0, insideRect: window.bounds) } ?? display.frame
        guard frame.width > 1, frame.height > 1 else { return }
        let spu = window.subviews.last { NSStringFromClass(type(of: $0)).hasSuffix("SubpictureView") }
        let regions = spu.flatMap(Self.pendingRegions) ?? []

        var signature = "\(frame)|\(window.bounds)|\(secondaryText ?? "")|"
        if let list = spu.flatMap(Self.pendingRegionList) { signature += "\(ObjectIdentifier(list))" }
        for r in regions { signature += ",\(ObjectIdentifier(r.image))" }
        let stale = Date().timeIntervalSince(overlayBuiltAt) > 1
        guard signature != overlaySignature || stale else { return }
        overlaySignature = signature
        overlayBuiltAt = Date()

        // libVLC's regions are in the subtitle view's pixels, y up from the bottom (RegionBackingFrame); the
        // picture sits at the display view's frame within it.
        let scale = window.contentScaleFactor
        let place = CGRect(x: frame.minX * scale, y: (window.bounds.height - frame.maxY) * scale,
                           width: frame.width * scale, height: frame.height * scale)
        var out: [PiPSubtitleBurner.Region] = []
        for r in regions {
            let unit = CGRect(x: (r.frame.minX - place.minX) / place.width, y: (r.frame.minY - place.minY) / place.height,
                              width: r.frame.width / place.width, height: r.frame.height / place.height)
            out.append(PiPSubtitleBurner.Region(image: CIImage(cgImage: r.image), alpha: r.alpha, unit: unit))
        }
        if let text = secondaryText, !text.isEmpty,
           let image = Self.secondaryImage(text, picture: frame.size, scale: scale) {
            let w = CGFloat(image.width) / scale, h = CGFloat(image.height) / scale
            let margin = frame.height * 0.04
            let unit = CGRect(x: (frame.width - w) / 2 / frame.width, y: 1 - (margin + h) / frame.height,
                              width: w / frame.width, height: h / frame.height)
            out.append(PiPSubtitleBurner.Region(image: CIImage(cgImage: image), alpha: 1, unit: unit))
        }
        burner.setOverlay(out)
    }

    private struct SubtitleRegion {
        let frame: CGRect
        let image: CGImage
        let alpha: CGFloat
    }

    private typealias RectGetter = @convention(c) (AnyObject, Selector) -> CGRect
    private typealias ImageGetter = @convention(c) (AnyObject, Selector) -> Unmanaged<CGImage>?
    private typealias FloatGetter = @convention(c) (AnyObject, Selector) -> CGFloat

    /// `VLCSampleBufferSubpictureView._pendingSubpicture.regions`: what its drawRect: draws. Read on the main
    /// thread, where libVLC sets it (drawSubpicture:) and draws it.
    private static func pendingRegionList(_ spu: UIView) -> NSArray? {
        guard let ivar = class_getInstanceVariable(type(of: spu), "_pendingSubpicture"),
              let subpicture = object_getIvar(spu, ivar) as? NSObject,
              subpicture.responds(to: NSSelectorFromString("regions")) else { return nil }
        return subpicture.value(forKey: "regions") as? NSArray
    }

    private static func pendingRegions(_ spu: UIView) -> [SubtitleRegion]? {
        guard let list = pendingRegionList(spu) else { return nil }
        let frameSel = NSSelectorFromString("backingFrame")
        let imageSel = NSSelectorFromString("image")
        let alphaSel = NSSelectorFromString("alpha")
        return list.compactMap { item -> SubtitleRegion? in
            guard let region = item as? NSObject,
                  region.responds(to: frameSel), region.responds(to: imageSel), region.responds(to: alphaSel),
                  let frameIMP = region.method(for: frameSel), let imageIMP = region.method(for: imageSel),
                  let alphaIMP = region.method(for: alphaSel) else { return nil }
            let frame = unsafeBitCast(frameIMP, to: RectGetter.self)(region, frameSel)
            guard let image = unsafeBitCast(imageIMP, to: ImageGetter.self)(region, imageSel)?.takeUnretainedValue(),
                  frame.width > 0, frame.height > 0 else { return nil }
            let alpha = unsafeBitCast(alphaIMP, to: FloatGetter.self)(region, alphaSel)
            return SubtitleRegion(frame: frame, image: image, alpha: alpha)
        }
    }

    /// The second subtitle as it looks on the screen: medium white text on a soft dark plate, sized to the picture.
    private static func secondaryImage(_ text: String, picture: CGSize, scale: CGFloat) -> CGImage? {
        let size = max(12, picture.height * 0.05)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
        ])
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let bounds = string.boundingRect(with: CGSize(width: picture.width * 0.86, height: .greatestFiniteMagnitude),
                                         options: options, context: nil).integral
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let padX = size * 0.5, padY = size * 0.2
        let box = CGSize(width: bounds.width + padX * 2, height: bounds.height + padY * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: box, format: format).image { _ in
            UIColor.black.withAlphaComponent(0.45).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: box), cornerRadius: size * 0.3).fill()
            string.draw(with: CGRect(x: padX, y: padY, width: bounds.width, height: bounds.height), options: options, context: nil)
        }
        return image.cgImage
    }

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

/// Stands in as the delegate of libVLC's `AVPictureInPictureController`, adding what libVLC leaves out (getting
/// the player ready before the picture comes back, PiP failing to start, PiP about to stop) and passing every
/// callback on to libVLC's own controller, which relies on will-start, did-start and did-stop.
private final class PiPDelegateProxy: NSObject, AVPictureInPictureControllerDelegate {
    private weak var original: (any AVPictureInPictureControllerDelegate)?
    private weak var owner: VideoOutput?

    init(forwardingTo original: (any AVPictureInPictureControllerDelegate)?, owner: VideoOutput) {
        self.original = original
        self.owner = owner
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        owner?.pipWillStart()
        original?.pictureInPictureControllerWillStartPictureInPicture?(controller)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        original?.pictureInPictureControllerDidStartPictureInPicture?(controller)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: any Error) {
        owner?.pipFailed(error)
        original?.pictureInPictureController?(controller, failedToStartPictureInPictureWithError: error)
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        owner?.pipWillStop()
        original?.pictureInPictureControllerWillStopPictureInPicture?(controller)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        original?.pictureInPictureControllerDidStopPictureInPicture?(controller)
    }

    @objc(pictureInPictureController:restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:)
    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void) {
        guard let owner else { completionHandler(true); return }
        owner.restoreForPiPStop(completionHandler)
    }
}

/// The key the burner hangs off libVLC's display layer under.
private nonisolated(unsafe) var burnerKey: UInt8 = 0

/// Burns subtitle images into the frames libVLC hands its display layer while Picture in Picture is up.
///
/// libVLC 4.0.0a26 composes subtitles in a separate view (its display asks the core for display-side blending,
/// VLCSampleBufferDisplay.m Open), and PiP shows only the `AVSampleBufferDisplayLayer`'s frames, so PiP has none.
/// This follows the fix proposed upstream (VLC merge request 10761): only while PiP is active, copy each frame and
/// draw the subtitle regions over it with Core Image, rendering only where they are. The frames are caught on
/// their way into the layer, by replacing `-[AVSampleBufferDisplayLayer enqueueSampleBuffer:]`, which libVLC calls
/// on its video output thread; layers without a burner attached pass straight through.
private final class PiPSubtitleBurner: @unchecked Sendable {
    struct Region {
        let image: CIImage
        /// Where the image goes, as fractions of the picture, y up from the bottom.
        let unit: CGRect

        init(image: CIImage, alpha: CGFloat, unit: CGRect) {
            self.image = alpha < 1
                ? image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
                : image
            self.unit = unit
        }
    }

    private let lock = NSLock()
    private var active = false
    private var regions: [Region] = []
    /// The display size of the latest frame seen while active (pixel aspect ratio applied).
    private var lastPictureSize: CGSize?
    /// Touched only on libVLC's video output thread.
    private var context: CIContext?
    private var pool: CVPixelBufferPool?
    private var poolShape: (format: OSType, width: Int, height: Int)?
    private var failures = 0

    func setActive(_ on: Bool) {
        lock.lock()
        active = on
        lastPictureSize = nil
        if !on { regions = [] }
        lock.unlock()
    }

    func pictureSize() -> CGSize? {
        lock.withLock { lastPictureSize }
    }

    func setOverlay(_ new: [Region]) {
        lock.lock()
        regions = active ? new : []
        lock.unlock()
    }

    func attach(to layer: AVSampleBufferDisplayLayer) {
        objc_setAssociatedObject(layer, &burnerKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func detach(from layer: AVSampleBufferDisplayLayer) {
        objc_setAssociatedObject(layer, &burnerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private typealias Enqueue = @convention(c) (AnyObject, Selector, CMSampleBuffer) -> Void

    /// Replaces `enqueueSampleBuffer:` once, on first use; false if the method isn't there to replace.
    static func installHook() -> Bool { hookInstalled }

    private static let hookInstalled: Bool = {
        let cls: AnyClass = AVSampleBufferDisplayLayer.self
        let selector = NSSelectorFromString("enqueueSampleBuffer:")
        guard let method = class_getInstanceMethod(cls, selector) else {
            PlaybackTrace.shared.mark("pip: can't reach the display layer's frames; no subtitles in PiP")
            return false
        }
        let original = unsafeBitCast(method_getImplementation(method), to: Enqueue.self)
        let replacement: @convention(block) (AnyObject, CMSampleBuffer) -> Void = { layer, sample in
            if let burner = objc_getAssociatedObject(layer, &burnerKey) as? PiPSubtitleBurner,
               let burned = burner.burn(sample) {
                original(layer, selector, burned)
            } else {
                original(layer, selector, sample)
            }
        }
        let imp = imp_implementationWithBlock(replacement)
        // Added on the class itself if it only inherits the method, so its superclass is left alone.
        if !class_addMethod(cls, selector, imp, method_getTypeEncoding(method)) {
            method_setImplementation(method, imp)
        }
        return true
    }()

    private static let formats: Set<OSType> = [
        kCVPixelFormatType_32BGRA,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
    ]

    /// A copy of the frame with the subtitles drawn in, or nil to show the frame as it is.
    fileprivate func burn(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        lock.lock()
        let active = self.active
        let regions = active ? self.regions : []
        lock.unlock()
        guard active else { return nil }
        if let description = CMSampleBufferGetFormatDescription(sample) {
            let shown = CMVideoFormatDescriptionGetPresentationDimensions(description, usePixelAspectRatio: true,
                                                                          useCleanAperture: false)
            if shown.width > 0, shown.height > 0 { lock.withLock { lastPictureSize = shown } }
        }
        guard !regions.isEmpty, failures < 30, let source = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let format = CVPixelBufferGetPixelFormatType(source)
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        guard Self.formats.contains(format), width > 1, height > 1 else { return nil }
        let size = CGSize(width: width, height: height)
        let canvas = CGRect(origin: .zero, size: size)

        // Subtitles are made for SDR; in HDR video, white sits at the reference level, not at peak.
        let white = Self.referenceWhite(source)
        var composition = CIImage(cvPixelBuffer: source)
        var dirty: [CGRect] = []
        for region in regions {
            let dest = CGRect(x: region.unit.minX * size.width, y: region.unit.minY * size.height,
                              width: region.unit.width * size.width, height: region.unit.height * size.height)
            let extent = region.image.extent
            guard dest.width >= 1, dest.height >= 1, !extent.isEmpty, !extent.isInfinite,
                  dest.intersects(canvas) else { continue }
            var image = region.image
            if white < 1 {
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: white, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: white, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: white, w: 0),
                ])
            }
            let transform = CGAffineTransform(translationX: dest.minX, y: dest.minY)
                .scaledBy(x: dest.width / extent.width, y: dest.height / extent.height)
                .translatedBy(x: -extent.minX, y: -extent.minY)
            composition = image.transformed(by: transform).composited(over: composition)
            let bounds = Self.alignedToChroma(dest.intersection(canvas), in: size)
            if bounds.width > 0, bounds.height > 0 { dirty.append(bounds) }
        }
        guard !dirty.isEmpty, let target = makeBuffer(like: source, format: format, width: width, height: height),
              Self.copy(source, to: target) else {
            failures += 1
            return nil
        }
        // No colour management: the frame's own values pass through untouched outside the subtitles.
        let context = self.context ?? CIContext(options: [.workingColorSpace: NSNull()])
        self.context = context
        for bounds in dirty {
            context.render(composition, to: target, bounds: bounds, colorSpace: nil)
        }

        var timing = CMSampleTimingInfo()
        var description: CMVideoFormatDescription?
        var burned: CMSampleBuffer?
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr,
              CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: target,
                                                           formatDescriptionOut: &description) == noErr,
              let description,
              CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: target,
                                                       formatDescription: description, sampleTiming: &timing,
                                                       sampleBufferOut: &burned) == noErr else {
            failures += 1
            return nil
        }
        failures = 0
        return burned
    }

    private func makeBuffer(like source: CVPixelBuffer, format: OSType, width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolShape?.format != format || poolShape?.width != width || poolShape?.height != height {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created) == kCVReturnSuccess,
                  let created else { return nil }
            pool = created
            poolShape = (format, width, height)
        }
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        // Colour space, transfer function, pixel aspect ratio and HDR metadata, as libVLC attached them.
        if let attachments = CVBufferCopyAttachments(source, .shouldPropagate) {
            CVBufferSetAttachments(buffer, attachments, .shouldPropagate)
        }
        return buffer
    }

    private static func copy(_ source: CVPixelBuffer, to target: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(target, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(target, []) }
        let planes = CVPixelBufferGetPlaneCount(source)
        if planes == 0 {
            guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(target) else { return false }
            copyRows(from, CVPixelBufferGetBytesPerRow(source), to, CVPixelBufferGetBytesPerRow(target),
                     CVPixelBufferGetHeight(source))
            return true
        }
        guard CVPixelBufferGetPlaneCount(target) == planes else { return false }
        for plane in 0..<planes {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let to = CVPixelBufferGetBaseAddressOfPlane(target, plane) else { return false }
            copyRows(from, CVPixelBufferGetBytesPerRowOfPlane(source, plane), to,
                     CVPixelBufferGetBytesPerRowOfPlane(target, plane), CVPixelBufferGetHeightOfPlane(source, plane))
        }
        return true
    }

    private static func copyRows(_ from: UnsafeMutableRawPointer, _ fromStride: Int,
                                 _ to: UnsafeMutableRawPointer, _ toStride: Int, _ rows: Int) {
        if fromStride == toStride {
            to.copyMemory(from: from, byteCount: fromStride * rows)
            return
        }
        let length = min(fromStride, toStride)
        for row in 0..<rows {
            (to + row * toStride).copyMemory(from: from + row * fromStride, byteCount: length)
        }
    }

    /// 4:2:0 chroma covers 2×2 pixels; render whole blocks so no chroma sample is half-updated.
    static func alignedToChroma(_ rect: CGRect, in size: CGSize) -> CGRect {
        guard !rect.isNull, !rect.isEmpty else { return .zero }
        let minX = max((rect.minX / 2).rounded(.down) * 2, 0)
        let minY = max((rect.minY / 2).rounded(.down) * 2, 0)
        let maxX = min((rect.maxX / 2).rounded(.up) * 2, size.width)
        let maxY = min((rect.maxY / 2).rounded(.up) * 2, size.height)
        guard maxX > minX, maxY > minY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func referenceWhite(_ buffer: CVPixelBuffer) -> CGFloat {
        guard let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) else { return 1 }
        if CFEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) { return 0.58 }
        if CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG) { return 0.75 }
        return 1
    }
}

/// What Picture in Picture's own play, pause and skip buttons drive.
private final class PiPMediaControls: NSObject, VLCPictureInPictureMediaControlling {
    private weak var player: VLCMediaPlayer?
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?

    init(player: VLCMediaPlayer) { self.player = player }

    func play() {
        if let onPlay { onPlay() } else { player?.play() }
    }

    func pause() {
        if let onPause { onPause() } else { player?.pause() }
    }

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
        // A fresh configuration with no delegate class, so SwiftUI installs its own scene delegate. Returning
        // `connectingSceneSession.configuration` crashes on iOS 27: it already names SwiftUI's AppSceneDelegate as
        // the delegate class, so SwiftUI wraps its own delegate in itself and recurses until the stack overflows.
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }
}
