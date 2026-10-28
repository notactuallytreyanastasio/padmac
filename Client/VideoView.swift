import AVFoundation
import UIKit

/// Displays the H.264 stream with the hardware decoder behind AVSampleBufferDisplayLayer.
///
/// The picture is drawn in `contentRect`, the same rect input is mapped
/// through, not aspect-fit to the whole view: in window mode the picture keeps
/// to the safe area, and drawing it anywhere else put taps off by the inset.
final class VideoView: UIView, VideoSink {
    private let displayLayer = AVSampleBufferDisplayLayer()

    var contentRect: CGRect = .zero {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer.frame = contentRect
            CATransaction.commit()
        }
    }

    /// Asked for a keyframe when decoding cannot continue from here.
    var needKeyframe: (() -> Void)?

    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var waitingForKeyframe = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(displayLayer)
        backgroundColor = .black
        // The layer stops rendering after the app is backgrounded.
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.resync()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func videoFormat(_ format: CMVideoFormatDescription) {
        lock.lock()
        let changed = self.format.map { !CMFormatDescriptionEqual($0, otherFormatDescription: format) } ?? true
        self.format = format
        if changed { waitingForKeyframe = true }
        lock.unlock()
        // New size or codec (display switch, resolution change): drop the old picture's decoder state.
        if changed { displayLayer.sampleBufferRenderer.flush() }
    }

    func videoFrame(_ data: Data, keyframe: Bool) {
        lock.lock()
        let format = self.format
        if keyframe { waitingForKeyframe = false }
        let skip = waitingForKeyframe
        lock.unlock()
        guard !skip, let format,
              let sample = VideoFormat.sampleBuffer(data, format: format, displayImmediately: true) else { return }

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
