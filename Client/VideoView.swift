import AVFoundation
import UIKit

/// Displays the H.264 stream with the hardware decoder behind AVSampleBufferDisplayLayer.
final class VideoView: UIView, VideoSink {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    /// Asked for a keyframe when decoding cannot continue from here.
    var needKeyframe: (() -> Void)?

    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var waitingForKeyframe = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        backgroundColor = .black
        // The layer stops rendering after the app is backgrounded.
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.resync()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func videoFormat(_ format: CMVideoFormatDescription) {
        lock.lock(); self.format = format; lock.unlock()
    }

    func videoFrame(_ avcc: Data, keyframe: Bool) {
        lock.lock()
        let format = self.format
        if keyframe { waitingForKeyframe = false }
        let skip = waitingForKeyframe
        lock.unlock()
        guard !skip, let format,
              let sample = H264.sampleBuffer(avcc: avcc, format: format, displayImmediately: true) else { return }

        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            NSLog("RemoteMac: renderer failed: \(String(describing: renderer.error)); resyncing")
            resync()
            return
        }
        renderer.enqueue(sample)
    }

    private func resync() {
        lock.lock(); waitingForKeyframe = true; lock.unlock()
        displayLayer.sampleBufferRenderer.flush()
        needKeyframe?()
    }
}
