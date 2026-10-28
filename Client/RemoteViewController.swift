import AVFoundation
import UIKit
import UniformTypeIdentifiers

/// The remote screen and every way of driving it.
///
/// Touch is a trackpad by default: one finger moves the Mac cursor relatively,
/// tap clicks, two-finger tap right-clicks, two fingers scroll, and
/// touch-hold-then-drag drags. "Direct" mode instead clicks where you touch.
/// An iPad trackpad or mouse maps absolutely: hovering puts the Mac cursor
/// under it, and the iPad's own pointer is hidden.
///
/// Three-finger swipes are the Mac's trackpad gestures: sideways changes
/// desktop, up is Mission Control, down is App Exposé.
///
/// Window mode, the default on a phone, streams one Mac window instead of the
/// whole display, resized on the Mac to the shape of this screen (see
/// WindowSizing). Folding or rotating resizes it again. There, three fingers
/// sideways move to the next or previous window and three fingers up list them.
///
/// Pinch zooms (a 32:9 display on a 4:3 iPad is unreadable otherwise), moving
/// the pinch pans, and while zoomed the view follows the Mac cursor. Zoom is a
/// transform on the video view, so `location(in: video)` still returns
/// unzoomed coordinates and none of the input mapping has to know about it.
final class RemoteViewController: UIViewController, UIPointerInteractionDelegate, UIGestureRecognizerDelegate {
    enum TouchMode { case trackpad, direct }

    let session: RemoteSession
    var onClose: (() -> Void)?

    private let video = VideoView()
    private let keys = KeyboardInputView()
    private let toolbar = UIStackView()
    private var mode = TouchMode.trackpad
    private var modeButton: UIButton!
    private var stickyButtons: [UInt16: UIButton] = [:]
    private var sticky = Set<UInt16>()
    private var dragging = false
    private var accel = PointerAcceleration()
    private var remapper = KeyRemapper()
    private var commandHeld = false
    private var leftWithCommandHeld = false
    private var scrolling = false
    private var momentum: ScrollMomentum?
    private var momentumLink: CADisplayLink?
    private var momentumStarted = false
    private var momentumLast: CFTimeInterval = 0

    private var viewport = Viewport(viewSize: .zero, content: .zero)
    private var zoom: CGFloat { viewport.zoom }
    private var pinchStart: (viewport: Viewport, centroid: CGPoint)?
    private var pinching = false
    private var swipe = SwipeTracker()
    private var zoomButton: UIButton!
    private var displayButton: UIButton!

    /// One Mac window rather than the whole display. Remembered between launches.
    /// (bool(forKey:), not `as? Bool`: a `-windowMode YES` launch argument is the string "YES".)
    private var windowMode = UserDefaults.standard.object(forKey: "windowMode") != nil
        ? UserDefaults.standard.bool(forKey: "windowMode") : DeviceKind.current.prefersWindowMode
    /// Bigger or smaller Mac text in window mode. Remembered between launches.
    private var textScale = UserDefaults.standard.object(forKey: "windowTextScale") != nil
        ? CGFloat(UserDefaults.standard.double(forKey: "windowTextScale")) : 1
    private var sentWindowRequest: WindowRequest?
    private var windowResize: DispatchWorkItem?
    private var shownWindow: UInt32?
#if DUO
    /// The hinge; nil until the first update.
    private var hinge: UIHinge.Status?
#endif

    init(session: RemoteSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        video.layer.anchorPoint = .zero
        // UI tests find the screen by this and read its state from the value.
        video.isAccessibilityElement = true
        video.accessibilityIdentifier = "remote-screen"
        video.accessibilityLabel = "Mac screen"
        video.accessibilityTraits = .allowsDirectInteraction
        video.accessibilityValue = "connecting"
        video.needKeyframe = { [weak session] in session?.requestKeyframe() }
        view.addSubview(video)
        session.video = video
        session.onCursor = { [weak self] x, y in self?.follow(x, y) }
        session.onScreen = { [weak self] info in
            guard let self else { return }
            self.announceWindow(info)
            self.viewport = Viewport(viewSize: self.view.bounds.size, content: self.videoRect)
            self.viewport.area = self.contentSpace
            self.video.contentRect = self.videoRect
            self.updateDisplayMenu()
            // Test hook: `-zoomFill YES` starts zoomed, for simulator screenshots.
            if UserDefaults.standard.bool(forKey: "zoomFill") {
                self.viewport.set(zoom: self.viewport.fillZoom, offset: .zero)
            }
            self.applyZoom()
        }

        keys.frame = .zero
        keys.onKey = { [weak self] code, down in self?.hardwareKey(code, down) }
        keys.onText = { [weak self] in self?.typeSoft($0) }
        keys.onDelete = { [weak self] in self?.tapKey(51) }
        keys.accessory = makeAccessoryBar()
        view.addSubview(keys)

#if DUO
        // Called with the initial state and on every change. Folding changes the
        // division region, which the next layout reads.
        view.addInteraction(UIHingeInteraction { [weak self] _, update in
            guard let self, self.hinge != update.hinge?.status else { return }
            self.hinge = update.hinge?.status
            self.updateAccessibilityValue()
            self.view.setNeedsLayout()
        })
#endif

        installTouchGestures()
        installPointerGestures()
        installToolbar()

        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.leftWithCommandHeld else { return }
            self.leftWithCommandHeld = false
            self.flash("iPadOS keeps ⌘Tab and ⌘Space. Use ⌥Tab and ⌥Space for the Mac's.", seconds: 4)
        }

        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // Keys held when the app lost focus would otherwise stay down on the Mac.
            guard let self else { return }
            // ⌘ down as the app loses focus is almost always ⌘Tab or ⌘Space taken by iPadOS.
            self.leftWithCommandHeld = self.commandHeld
            self.commandHeld = false
            self.remapper.reset()
            self.stopMomentum()
            self.session.send(.releaseAll)
            self.clearSticky()
        }
    }

    private func hardwareKey(_ code: UInt16, _ down: Bool) {
        if code == 55 || code == 54 { commandHeld = down }
        for k in remapper.handle(code, down: down) { session.send(.key(code: k.code, down: k.down)) }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // Before the Hello goes out, so the first stream is already the right one.
        updateWindowRequest()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        keys.becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        video.bounds = CGRect(origin: .zero, size: view.bounds.size)
        viewport.viewSize = view.bounds.size
        viewport.content = videoRect
        viewport.area = contentSpace
        video.contentRect = videoRect
        viewport.set(zoom: viewport.zoom, offset: viewport.offset) // re-clamp after rotation
        applyZoom()
        updateWindowRequest()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    // MARK: Geometry

    /// Where the Mac screen is drawn inside the view (aspect-fit). A window
    /// stays out of the camera cutout and corners; the whole display uses
    /// every point, since it rarely has the screen's shape anyway.
    private var videoRect: CGRect {
        let space = contentSpace
        guard let s = session.screen else { return space }
        return AVMakeRect(aspectRatio: CGSize(width: s.screenWidth, height: s.screenHeight), insideRect: space)
    }

    private var contentSpace: CGRect {
        windowMode ? windowSpace : view.bounds
    }

    private var windowSpace: CGRect {
#if DUO
        let fold = view.reservedRegions(kind: .division).first(where: \.isActive)?.frame
#else
        let fold: CGRect? = nil
#endif
        return WindowSizing.space(safe: view.bounds.inset(by: view.safeAreaInsets), division: fold)
    }

    // MARK: Window mode

    /// Tell the Mac what size the window should be, when that changed. A fold
    /// lays out several times as it animates; only the size it settles on is sent.
    private func updateWindowRequest() {
        let want = windowMode ? WindowSizing.request(for: windowSpace.size, textScale: textScale) : nil
        // In window mode a nil size is a view not laid out yet, not a request for the whole display.
        guard !(windowMode && want == nil), want != sentWindowRequest else { return }
        windowResize?.cancel()
        let send = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sentWindowRequest = want
            self.session.setWindowMode(want)
        }
        windowResize = send
        // The first one goes at once: it may still make it into the Hello.
        if sentWindowRequest == nil && session.screen == nil { send.perform() } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: send)
        }
    }

    private func setWindowMode(_ on: Bool) {
        windowMode = on
        UserDefaults.standard.set(on, forKey: "windowMode")
        windowResize?.cancel()
        sentWindowRequest = nil
        shownWindow = nil
        if !on { session.setWindowMode(nil) }
        viewDidLayoutSubviews() // new video rect, and in window mode sends the size
        updateDisplayMenu()
        flash(on ? "One window, sized for this screen" : "Whole Mac display")
    }

    private func setTextScale(_ k: CGFloat) {
        textScale = k
        UserDefaults.standard.set(Double(k), forKey: "windowTextScale")
        updateWindowRequest()
    }

    private func announceWindow(_ info: ScreenInfo) {
        guard windowMode else { return }
        guard let w = info.window else {
            shownWindow = nil
            return flash("No windows on the Mac's current desktop. Showing the whole screen.", seconds: 3)
        }
        if w.id != shownWindow { flash(w.title.isEmpty ? w.app : "\(w.app) — \(w.title)") }
        shownWindow = w.id
    }

    private func windowActions() -> [UIAction] {
        let current = session.screen?.window?.id
        return (session.screen?.windows ?? []).map { w in
            UIAction(title: w.title.isEmpty ? w.app : w.title, subtitle: w.title.isEmpty ? nil : w.app,
                     state: w.id == current ? .on : .off) { [weak self] _ in self?.session.showWindow(w.id) }
        }
    }

    /// Three fingers up in window mode: every window, to pick one.
    private func presentWindowPicker() {
        let sheet = UIAlertController(title: "Mac windows", message: nil, preferredStyle: .actionSheet)
        for a in windowActions() {
            sheet.addAction(UIAlertAction(title: a.subtitle.map { "\(a.title) — \($0)" } ?? a.title, style: .default) { _ in
                a.performWithSender(nil, target: nil)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(sheet, animated: true)
    }

    private func normalized(_ p: CGPoint) -> (Double, Double) {
        let r = videoRect
        return (Double(min(max((p.x - r.minX) / r.width, 0), 1)), Double(min(max((p.y - r.minY) / r.height, 0), 1)))
    }

    /// iPad points per Mac point as currently drawn, zoom included.
    private var onScreenScale: Double {
        guard let s = session.screen, s.screenWidth > 0 else { return 1 }
        return Double(videoRect.width * zoom) / s.screenWidth
    }

    /// Relative cursor movement for a finger movement, through the acceleration curve.
    private func moveCursor(by d: CGPoint) {
        let m = accel.macDelta(d, at: CACurrentMediaTime(), onScreenScale: onScreenScale)
        if m.x != 0 || m.y != 0 { session.send(.moveBy(dx: Double(m.x), dy: Double(m.y))) }
    }

    // Touching the screen stops a coasting scroll, as touching a trackpad does.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopMomentum()
        super.touchesBegan(touches, with: event)
    }

    // MARK: Touch

    private func installTouchGestures() {
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        let pan = UIPanGestureRecognizer(target: self, action: #selector(onePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = direct

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.allowedTouchTypes = direct

        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        tap.allowedTouchTypes = direct

        let twoTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTap(_:)))
        twoTap.numberOfTouchesRequired = 2
        twoTap.allowedTouchTypes = direct

        let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdDrag(_:)))
        hold.minimumPressDuration = 0.3
        hold.allowableMovement = 12
        hold.allowedTouchTypes = direct
        hold.delegate = self

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))

        let threePan = UIPanGestureRecognizer(target: self, action: #selector(threeFingerSwipe(_:)))
        threePan.minimumNumberOfTouches = 3
        threePan.maximumNumberOfTouches = 3
        threePan.allowedTouchTypes = direct

        for g in [pan, scroll, tap, twoTap, hold, pinch, threePan] as [UIGestureRecognizer] {
            g.delegate = self
            view.addGestureRecognizer(g)
        }
    }

    @objc private func onePan(_ g: UIPanGestureRecognizer) {
        guard !dragging else { return }
        switch mode {
        case .trackpad:
            if g.state == .began { accel.reset() }
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            moveCursor(by: t)
        case .direct:
            let (x, y) = normalized(g.location(in: video))
            switch g.state {
            case .began:
                session.send(.moveTo(x: x, y: y))
                session.send(.button(.left, down: true))
            case .changed:
                session.send(.moveTo(x: x, y: y))
            default:
                session.send(.moveTo(x: x, y: y))
                session.send(.button(.left, down: false))
            }
        }
    }

    /// Two-finger scrolling, with the phases a Mac trackpad sends and momentum
    /// after lift-off. Content moves 1:1 with the fingers as seen on the iPad.
    @objc private func scroll(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view)
        g.setTranslation(.zero, in: view)
        let k = 1 / onScreenScale
        switch g.state {
        case .began:
            stopMomentum()
            guard !pinching else { return }
            scrolling = true
            session.send(.scroll(dx: Double(t.x) * k, dy: Double(t.y) * k, phase: .began))
        case .changed:
            // A two-finger gesture that turned into a pinch stops scrolling the Mac.
            guard scrolling, !pinching else { return endScroll(cancelled: true) }
            session.send(.scroll(dx: Double(t.x) * k, dy: Double(t.y) * k, phase: .changed))
        case .ended:
            guard scrolling else { return }
            endScroll(cancelled: false)
            let v = g.velocity(in: view)
            if let m = ScrollMomentum(velocity: CGVector(dx: Double(v.x) * k, dy: Double(v.y) * k)) { startMomentum(m) }
        default:
            endScroll(cancelled: true)
        }
    }

    private func endScroll(cancelled: Bool) {
        guard scrolling else { return }
        scrolling = false
        session.send(.scroll(dx: 0, dy: 0, phase: cancelled ? .cancelled : .ended))
    }

    private func startMomentum(_ m: ScrollMomentum) {
        momentum = m
        momentumStarted = false
        momentumLast = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(momentumTick(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    @objc private func momentumTick(_ link: CADisplayLink) {
        guard var m = momentum else { return stopMomentum() }
        let now = link.targetTimestamp
        let (d, done) = m.step(max(0, now - momentumLast))
        momentumLast = now
        momentum = m
        session.send(.scroll(dx: Double(d.dx), dy: Double(d.dy), momentum: momentumStarted ? .changed : .began))
        momentumStarted = true
        if done { stopMomentum() }
    }

    private func stopMomentum() {
        guard let link = momentumLink else { return }
        link.invalidate()
        momentumLink = nil
        momentum = nil
        if momentumStarted { session.send(.scroll(dx: 0, dy: 0, momentum: .ended)) }
        momentumStarted = false
    }

    @objc private func tap(_ g: UITapGestureRecognizer) {
        if mode == .direct {
            let (x, y) = normalized(g.location(in: video))
            session.send(.moveTo(x: x, y: y))
        }
        click(.left)
    }

    @objc private func twoFingerTap(_ g: UITapGestureRecognizer) {
        if mode == .direct {
            let (x, y) = normalized(g.location(in: video))
            session.send(.moveTo(x: x, y: y))
        }
        click(.right)
    }

    /// Trackpad mode: hold, then drag with the button down.
    @objc private func holdDrag(_ g: UILongPressGestureRecognizer) {
        guard mode == .trackpad else { return }
        switch g.state {
        case .began:
            dragging = true
            accel.reset()
            lastHold = g.location(in: view)
            session.send(.button(.left, down: true))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            // Same curve as moving: a drag should feel like a move with the button down.
            let p = g.location(in: view)
            moveCursor(by: CGPoint(x: p.x - lastHold.x, y: p.y - lastHold.y))
            lastHold = p
        default:
            dragging = false
            session.send(.button(.left, down: false))
        }
    }
    private var lastHold = CGPoint.zero

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // The hold must be able to take over from a pan that has barely started,
        // and a two-finger gesture is a scroll until it proves to be a pinch.
        (g is UILongPressGestureRecognizer && other is UIPanGestureRecognizer)
            || g is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Toolbar buttons must not also click on the Mac.
        !(touch.view?.isDescendant(of: toolbar) ?? false)
    }

    // MARK: Zoom

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchStart = (viewport, g.location(in: view))
            pinching = false
        case .changed:
            // Three fingers are a Mac swipe, even if they happen to spread a little.
            guard let start = pinchStart, g.numberOfTouches == 2 else { return }
            if !pinching && abs(g.scale - 1) > 0.08 { pinching = true }
            guard pinching else { return }
            viewport.pinch(from: start.viewport, startCentroid: start.centroid, scale: g.scale, centroid: g.location(in: view))
            applyZoom()
        default:
            pinchStart = nil
            pinching = false
        }
    }

    @objc private func threeFingerSwipe(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view), size = view.bounds.size
        if windowMode { return windowSwipe(g, t, size) }
        switch g.state {
        case .began, .changed:
            if let e = swipe.update(translation: t, in: size) { session.send(e) }
        case .ended:
            swipe.end(translation: t, in: size).forEach(session.send)
        default:
            swipe.end(translation: t, in: size, cancelled: true).forEach(session.send)
        }
    }

    /// Window mode: the picture follows the fingers sideways, and letting go
    /// far or fast enough moves to the next window (fingers left) or the previous.
    private func windowSwipe(_ g: UIPanGestureRecognizer, _ t: CGPoint, _ size: CGSize) {
        switch g.state {
        case .began, .changed:
            _ = swipe.update(translation: t, in: size)
            if swipe.axis == .horizontal {
                video.transform = viewport.transform.concatenating(CGAffineTransform(translationX: t.x * 0.6, y: 0))
            }
        default:
            let axis = swipe.axis
            let distance = swipe.end(translation: t, in: size).last.flatMap { e -> Double? in
                if case .swipe(_, _, let d) = e { return d } else { return nil }
            } ?? 0
            UIView.animate(withDuration: 0.2) { self.applyZoom() }
            guard g.state == .ended else { return }
            let v = g.velocity(in: view)
            switch axis {
            case .horizontal:
                let step = SwipeTracker.windowStep(distance: distance, velocity: Double(v.x / max(size.width, 1)))
                if step != 0 { session.switchWindow(step: step) }
            case .vertical where distance < -0.15 || v.y < -800:
                presentWindowPicker()
            default: break
            }
        }
    }

    // iPadOS's three-finger undo/redo swipes and copy/paste pinches would fight the Mac's gestures.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    private func applyZoom() {
        video.center = .zero
        video.transform = viewport.transform
        zoomButton?.configuration?.image = UIImage(systemName: viewport.isZoomed ? "minus.magnifyingglass" : "plus.magnifyingglass")
        updateAccessibilityValue()
    }

    private func updateAccessibilityValue() {
        guard session.screen != nil else { return }
#if DUO
        let fold: String = switch hinge {
        case nil: "none"
        case .closed: "closed"
        case .partiallyOpen: "partiallyOpen"
        case .fullyOpen: "fullyOpen"
        default: "unknown"
        }
#else
        let fold = "none"
#endif
        // content: where the Mac picture is, as fractions of the screen element, for UI tests to aim at.
        let r = videoRect, b = view.bounds
        video.accessibilityValue = String(format: "streaming zoom=%.2f mode=%@ window=%@ hinge=%@ content=%.4f,%.4f,%.4f,%.4f",
                                          viewport.zoom, mode == .trackpad ? "trackpad" : "direct", windowMode ? "on" : "off", fold,
                                          r.minX / b.width, r.minY / b.height, r.width / b.width, r.height / b.height)
    }

    /// While zoomed, keep the Mac cursor inside the middle of the iPad screen.
    private func follow(_ x: Double, _ y: Double) {
        guard pinchStart == nil else { return }
        let before = viewport
        viewport.follow(x: x, y: y)
        if viewport != before { applyZoom() }
    }

    private func click(_ b: MouseButton) {
        session.send(.button(b, down: true))
        session.send(.button(b, down: false))
    }

    // MARK: iPad trackpad / mouse

    private func installPointerGestures() {
        let pointer = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]

        view.addInteraction(UIPointerInteraction(delegate: self))
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hover(_:)))
        hover.delegate = self
        view.addGestureRecognizer(hover)

        let click = UITapGestureRecognizer(target: self, action: #selector(pointerClick(_:)))
        click.allowedTouchTypes = pointer
        click.buttonMaskRequired = .primary
        click.delegate = self
        view.addGestureRecognizer(click)

        let secondary = UITapGestureRecognizer(target: self, action: #selector(pointerSecondary(_:)))
        secondary.allowedTouchTypes = pointer
        secondary.buttonMaskRequired = .secondary
        secondary.delegate = self
        view.addGestureRecognizer(secondary)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(pointerDrag(_:)))
        drag.allowedTouchTypes = pointer
        drag.delegate = self
        view.addGestureRecognizer(drag)

        // Two-finger scrolling on a trackpad / mouse wheel arrives as touchless pans.
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        wheel.delegate = self
        view.addGestureRecognizer(wheel)
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden() // the Mac's cursor is in the video
    }

    @objc private func hover(_ g: UIHoverGestureRecognizer) {
        guard g.state == .began || g.state == .changed else { return }
        let (x, y) = normalized(g.location(in: video))
        session.send(.moveTo(x: x, y: y))
    }

    @objc private func pointerClick(_ g: UITapGestureRecognizer) {
        let (x, y) = normalized(g.location(in: video))
        session.send(.moveTo(x: x, y: y))
        click(.left)
    }

    @objc private func pointerSecondary(_ g: UITapGestureRecognizer) {
        let (x, y) = normalized(g.location(in: video))
        session.send(.moveTo(x: x, y: y))
        click(.right)
    }

    @objc private func pointerDrag(_ g: UIPanGestureRecognizer) {
        let (x, y) = normalized(g.location(in: video))
        let button: MouseButton = g.buttonMask.contains(.secondary) ? .right : .left
        switch g.state {
        case .began:
            session.send(.moveTo(x: x, y: y))
            session.send(.button(button, down: true))
        case .changed:
            session.send(.moveTo(x: x, y: y))
        default:
            session.send(.button(.left, down: false))
            session.send(.button(.right, down: false))
        }
    }

    // MARK: Keyboard

    private func tapKey(_ code: UInt16, shift: Bool = false) {
        if shift { session.send(.key(code: 56, down: true)) }
        session.send(.key(code: code, down: true))
        session.send(.key(code: code, down: false))
        if shift { session.send(.key(code: 56, down: false)) }
        clearSticky()
    }

    private func typeSoft(_ text: String) {
        if text == "\n" { return tapKey(36) }
        if text == "\t" { return tapKey(48) }
        if !sticky.isEmpty, text.count == 1, let k = KeyMap.keyFor(character: text.first!) {
            return tapKey(k.code, shift: k.shift)
        }
        session.send(.text(text))
        clearSticky()
    }

    private func toggleSticky(_ code: UInt16) {
        if sticky.remove(code) != nil {
            session.send(.key(code: code, down: false))
        } else {
            sticky.insert(code)
            session.send(.key(code: code, down: true))
        }
        stickyButtons[code]?.isSelected = sticky.contains(code)
    }

    private func clearSticky() {
        for code in sticky {
            session.send(.key(code: code, down: false))
            stickyButtons[code]?.isSelected = false
        }
        sticky.removeAll()
    }

    private func makeAccessoryBar() -> UIView {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -6),
        ])

        func key(_ title: String, _ action: @escaping () -> Void) -> UIButton {
            var c = UIButton.Configuration.gray()
            c.title = title
            let b = UIButton(configuration: c, primaryAction: UIAction { _ in action() })
            stack.addArrangedSubview(b)
            return b
        }
        func stickyKey(_ title: String, _ code: UInt16) {
            let b = key(title) { [weak self] in self?.toggleSticky(code) }
            b.configurationUpdateHandler = { b in
                var c = b.isSelected ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
                c.title = title
                b.configuration = c
            }
            b.changesSelectionAsPrimaryAction = false
            stickyButtons[code] = b
        }

        _ = key("esc") { [weak self] in self?.tapKey(53) }
        _ = key("tab") { [weak self] in self?.tapKey(48) }
        stickyKey("⌃", 59)
        stickyKey("⌥", 58)
        stickyKey("⌘", 55)
        stickyKey("⇧", 56)
        _ = key("←") { [weak self] in self?.tapKey(123) }
        _ = key("↑") { [weak self] in self?.tapKey(126) }
        _ = key("↓") { [weak self] in self?.tapKey(125) }
        _ = key("→") { [weak self] in self?.tapKey(124) }
        _ = key("⌨︎↓") { [weak self] in self?.setSoftKeyboard(false) }
        return bar
    }

    private func setSoftKeyboard(_ on: Bool) {
        keys.softKeyboard = on
        keys.becomeFirstResponder()
    }

    // MARK: Toolbar

    private func installToolbar() {
        toolbar.axis = .horizontal
        toolbar.spacing = 4
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        toolbar.layer.cornerRadius = 18
        toolbar.isLayoutMarginsRelativeArrangement = true
        toolbar.directionalLayoutMargins = .init(top: 2, leading: 6, bottom: 2, trailing: 6)
        view.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            toolbar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            // A folded iPhone Duo is ~420pt wide: never let the buttons run off the left.
            toolbar.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
        ])

        func button(_ symbol: String, _ label: String, _ action: @escaping (UIButton) -> Void) -> UIButton {
            var c = UIButton.Configuration.plain()
            c.image = UIImage(systemName: symbol)
            c.baseForegroundColor = .white
            // The default 14pt sides made nine buttons 500pt wide, more than a phone has.
            c.contentInsets = .init(top: 8, leading: 7, bottom: 8, trailing: 7)
            let b = UIButton(configuration: c)
            b.addAction(UIAction { a in action(a.sender as! UIButton) }, for: .primaryActionTriggered)
            b.accessibilityLabel = label
            b.alpha = 0.8
            toolbar.addArrangedSubview(b)
            return b
        }

        _ = button("keyboard", "Keyboard") { [weak self] _ in
            guard let self else { return }
            self.setSoftKeyboard(!self.keys.softKeyboard)
        }
        zoomButton = button("plus.magnifyingglass", "Zoom") { [weak self] _ in
            guard let self else { return }
            // Toggle between the whole display and filling the iPad's short side, centred on the cursor's area.
            if self.viewport.isZoomed {
                self.viewport.set(zoom: 1, offset: .zero)
            } else {
                let z = self.viewport.fillZoom > 1.01 ? self.viewport.fillZoom : 2
                self.viewport.zoom(to: z, keeping: CGPoint(x: self.view.bounds.midX, y: self.view.bounds.midY))
            }
            self.applyZoom()
        }
        let windows = button("macwindow.on.rectangle", "Windows") { _ in }
        windows.showsMenuAsPrimaryAction = true
        // Built when opened: the window list is the one from the latest switch.
        windows.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            guard let self else { return done([]) }
            let mode = UIAction(title: self.windowMode ? "Show whole display" : "Show one window",
                                image: UIImage(systemName: self.windowMode ? "display" : "macwindow")) { [weak self] _ in
                guard let self else { return }
                self.setWindowMode(!self.windowMode)
            }
            guard self.windowMode else { return done([mode]) }
            let sizes: [(String, CGFloat)] = [("Larger", 1.25), ("Default", 1), ("Smaller", 0.8)]
            let text = UIMenu(title: "Mac text size", image: UIImage(systemName: "textformat.size"), children: sizes.map { name, k in
                UIAction(title: name, state: abs(self.textScale - k) < 0.01 ? .on : .off) { [weak self] _ in self?.setTextScale(k) }
            })
            done([UIMenu(title: "Swipe three fingers sideways to change window", options: .displayInline, children: self.windowActions()),
                  UIMenu(options: .displayInline, children: [text, mode])])
        }])
        displayButton = button("display.2", "Display") { _ in }
        displayButton.showsMenuAsPrimaryAction = true
        displayButton.isHidden = true

        var pasteConfig = UIPasteControl.Configuration()
        pasteConfig.displayMode = .iconOnly
        pasteConfig.cornerStyle = .capsule
        pasteConfig.baseBackgroundColor = .clear
        pasteConfig.baseForegroundColor = .white
        let paste = UIPasteControl(configuration: pasteConfig)
        paste.target = self
        paste.accessibilityLabel = "Paste iPad clipboard on the Mac"
        toolbar.addArrangedSubview(paste)

        let quality = button("gauge.with.dots.needle.67percent", "Stream quality") { _ in }
        quality.showsMenuAsPrimaryAction = true
        // Built when opened, so the numbers are current.
        quality.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            guard let self else { return done([]) }
            let s = self.session.linkStats()
            let reading = String(format: "Now: %.1f Mbit/s video, %.0f fps · %.1f Mbit/s total", s.videoMbps, s.fps, s.totalMbps)
            let choices = StreamQuality.allCases.map { q in
                let limit = q.maxWidth.map { "\($0) wide" } ?? "native"
                return UIAction(title: q.title,
                                subtitle: String(format: "%@, up to %g Mbit/s, %d fps", limit, Double(q.maxBitrate) / 1e6, q.framesPerSecond),
                                state: q == self.session.quality ? .on : .off) { [weak self] _ in
                    self?.session.setQuality(q)
                    self?.flash("Quality: \(q.title)")
                }
            }
            done([UIMenu(title: reading, options: .displayInline, children: choices)])
        }])

        let speaker = { (on: Bool) in on ? "speaker.wave.2" : "speaker.slash" }
        _ = button(speaker(session.audioEnabled), "Sound") { [weak self] b in
            guard let self else { return }
            self.session.setAudio(!self.session.audioEnabled)
            b.configuration?.image = UIImage(systemName: speaker(self.session.audioEnabled))
            self.flash(self.session.audioEnabled ? "Mac sound on" : "Mac sound off")
        }
        modeButton = button("hand.point.up.left", "Touch mode") { [weak self] b in
            guard let self else { return }
            self.mode = self.mode == .trackpad ? .direct : .trackpad
            self.updateAccessibilityValue()
            b.configuration?.image = UIImage(systemName: self.mode == .trackpad ? "hand.point.up.left" : "hand.tap")
            self.flash(self.mode == .trackpad ? "Trackpad: drag moves the cursor" : "Direct: tap where you want to click")
        }
        _ = button("xmark", "Disconnect") { [weak self] _ in
            self?.session.stop()
            self?.onClose?()
        }
    }

    private func updateDisplayMenu() {
        guard let info = session.screen else { return }
        displayButton.isHidden = info.displays.count < 2 || windowMode
        displayButton.menu = UIMenu(title: "Show display", children: info.displays.map { d in
            UIAction(title: d.name, subtitle: "\(Int(d.width)) × \(Int(d.height))", state: d.id == info.displayID ? .on : .off) { [weak self] _ in
                self?.session.selectDisplay(d.id)
            }
        })
    }

    // MARK: Paste (UIPasteControl reads the iPad clipboard without a permission prompt)

    override var pasteConfiguration: UIPasteConfiguration? {
        get { UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.image.identifier, UTType.plainText.identifier]) }
        set {}
    }

    /// Put the iPad's clipboard on the Mac's, then press ⌘V where the Mac's focus is.
    /// An image wins over text, as on the Mac side.
    override func paste(itemProviders: [NSItemProvider]) {
        if let image = itemProviders.first(where: { $0.canLoadObject(ofClass: UIImage.self) }) {
            _ = image.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                guard let png = (object as? UIImage)?.pngData() else { return }
                DispatchQueue.main.async { self?.pasteOnMac(.image(png)) }
            }
        } else if let text = itemProviders.first(where: { $0.canLoadObject(ofClass: String.self) }) {
            _ = text.loadObject(ofClass: String.self) { [weak self] string, _ in
                guard let string else { return }
                DispatchQueue.main.async { self?.pasteOnMac(.text(string)) }
            }
        }
    }

    private enum Clip { case text(String), image(Data) }

    private func pasteOnMac(_ clip: Clip) {
        switch clip {
        case .text(let t): session.sendClipboard(t)
        case .image(let png):
            guard png.count <= 16 << 20 else { return flash("Image too large to send (over 16 MB)") }
            session.sendClipboardImage(png)
        }
        session.send(.key(code: 55, down: true))
        tapKey(9) // V
        session.send(.key(code: 55, down: false))
        flash("Pasted on the Mac")
    }

    private func flash(_ text: String, seconds: TimeInterval = 1.5) {
        let label = UILabel()
        label.text = "  \(text)  "
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            label.heightAnchor.constraint(equalToConstant: 36),
        ])
        UIView.animate(withDuration: 0.3, delay: seconds, options: []) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
    }
}
