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
        session.onScreen = { [weak self] _ in
            guard let self else { return }
            self.viewport = Viewport(viewSize: self.view.bounds.size, content: self.videoRect)
            self.updateDisplayMenu()
            // Test hook: `-zoomFill YES` starts zoomed, for simulator screenshots.
            if UserDefaults.standard.bool(forKey: "zoomFill") {
                self.viewport.set(zoom: self.viewport.fillZoom, offset: .zero)
            }
            self.applyZoom()
        }

        keys.frame = .zero
        keys.onKey = { [weak self] code, down in self?.session.send(.key(code: code, down: down)) }
        keys.onText = { [weak self] in self?.typeSoft($0) }
        keys.onDelete = { [weak self] in self?.tapKey(51) }
        keys.accessory = makeAccessoryBar()
        view.addSubview(keys)

        installTouchGestures()
        installPointerGestures()
        installToolbar()

        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // Keys held when the app lost focus would otherwise stay down on the Mac.
            self?.stopMomentum()
            self?.session.send(.releaseAll)
            self?.clearSticky()
        }
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
        viewport.set(zoom: viewport.zoom, offset: viewport.offset) // re-clamp after rotation
        applyZoom()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    // MARK: Geometry

    /// Where the Mac screen is drawn inside the view (aspect-fit).
    private var videoRect: CGRect {
        guard let s = session.screen else { return view.bounds }
        return AVMakeRect(aspectRatio: CGSize(width: s.screenWidth, height: s.screenHeight), insideRect: view.bounds)
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
        switch g.state {
        case .began, .changed:
            if let e = swipe.update(translation: t, in: size) { session.send(e) }
        case .ended:
            swipe.end(translation: t, in: size).forEach(session.send)
        default:
            swipe.end(translation: t, in: size, cancelled: true).forEach(session.send)
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
        video.accessibilityValue = String(format: "streaming zoom=%.2f mode=%@", viewport.zoom, mode == .trackpad ? "trackpad" : "direct")
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
        ])

        func button(_ symbol: String, _ label: String, _ action: @escaping (UIButton) -> Void) -> UIButton {
            var c = UIButton.Configuration.plain()
            c.image = UIImage(systemName: symbol)
            c.baseForegroundColor = .white
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
        displayButton.isHidden = info.displays.count < 2
        displayButton.menu = UIMenu(title: "Show display", children: info.displays.map { d in
            UIAction(title: d.name, subtitle: "\(Int(d.width)) × \(Int(d.height))", state: d.id == info.displayID ? .on : .off) { [weak self] _ in
                self?.session.selectDisplay(d.id)
            }
        })
    }

    // MARK: Paste (UIPasteControl reads the iPad clipboard without a permission prompt)

    override var pasteConfiguration: UIPasteConfiguration? {
        get { UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.plainText.identifier]) }
        set {}
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return }
        _ = provider.loadObject(ofClass: String.self) { [weak self] text, _ in
            guard let text else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                // Put it on the Mac's clipboard, then paste it where the Mac's focus is.
                self.session.sendClipboard(text)
                self.session.send(.key(code: 55, down: true))
                self.tapKey(9) // V
                self.session.send(.key(code: 55, down: false))
                self.flash("Pasted on the Mac")
            }
        }
    }

    private func flash(_ text: String) {
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
        UIView.animate(withDuration: 0.3, delay: 1.5, options: []) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
    }
}
