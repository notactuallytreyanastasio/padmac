import AVFoundation
import UIKit

/// The remote screen and every way of driving it.
///
/// Touch is a trackpad by default: one finger moves the Mac cursor relatively,
/// tap clicks, two-finger tap right-clicks, two fingers scroll, and
/// touch-hold-then-drag drags. "Direct" mode instead clicks where you touch.
/// An iPad trackpad or mouse maps absolutely: hovering puts the Mac cursor
/// under it, and the iPad's own pointer is hidden.
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

    init(session: RemoteSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        video.frame = view.bounds
        video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        video.needKeyframe = { [weak session] in session?.requestKeyframe() }
        view.addSubview(video)
        session.video = video

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
            self?.session.send(.releaseAll)
            self?.clearSticky()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        keys.becomeFirstResponder()
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

    /// iPad points to Mac points, with a little acceleration for fast swipes.
    private func macDelta(_ d: CGPoint, velocity: CGPoint) -> (Double, Double) {
        guard let s = session.screen else { return (0, 0) }
        let scale = s.screenWidth / videoRect.width
        let speed = hypot(velocity.x, velocity.y)
        let accel = 1.2 + min(speed / 900, 1.8)
        return (Double(d.x * scale * accel), Double(d.y * scale * accel))
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

        for g in [pan, scroll, tap, twoTap, hold] as [UIGestureRecognizer] { video.addGestureRecognizer(g) }
    }

    @objc private func onePan(_ g: UIPanGestureRecognizer) {
        guard !dragging else { return }
        switch mode {
        case .trackpad:
            let t = g.translation(in: video)
            g.setTranslation(.zero, in: video)
            let (dx, dy) = macDelta(t, velocity: g.velocity(in: video))
            if dx != 0 || dy != 0 { session.send(.moveBy(dx: dx, dy: dy)) }
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

    @objc private func scroll(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: video)
        g.setTranslation(.zero, in: video)
        let k = (session.screen?.screenWidth ?? videoRect.width) / videoRect.width
        session.send(.scroll(dx: Double(t.x * k), dy: Double(t.y * k)))
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
            lastHold = g.location(in: video)
            session.send(.button(.left, down: true))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            let p = g.location(in: video)
            let (dx, dy) = macDelta(CGPoint(x: p.x - lastHold.x, y: p.y - lastHold.y), velocity: .zero)
            lastHold = p
            session.send(.moveBy(dx: dx, dy: dy))
        default:
            dragging = false
            session.send(.button(.left, down: false))
        }
    }
    private var lastHold = CGPoint.zero

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // The hold must be able to take over from a pan that has barely started.
        g is UILongPressGestureRecognizer && other is UIPanGestureRecognizer
    }

    private func click(_ b: MouseButton) {
        session.send(.button(b, down: true))
        session.send(.button(b, down: false))
    }

    // MARK: iPad trackpad / mouse

    private func installPointerGestures() {
        let pointer = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]

        video.addInteraction(UIPointerInteraction(delegate: self))
        video.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))

        let click = UITapGestureRecognizer(target: self, action: #selector(pointerClick(_:)))
        click.allowedTouchTypes = pointer
        click.buttonMaskRequired = .primary
        video.addGestureRecognizer(click)

        let secondary = UITapGestureRecognizer(target: self, action: #selector(pointerSecondary(_:)))
        secondary.allowedTouchTypes = pointer
        secondary.buttonMaskRequired = .secondary
        video.addGestureRecognizer(secondary)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(pointerDrag(_:)))
        drag.allowedTouchTypes = pointer
        video.addGestureRecognizer(drag)

        // Two-finger scrolling on a trackpad / mouse wheel arrives as touchless pans.
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        video.addGestureRecognizer(wheel)
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
        modeButton = button("hand.point.up.left", "Touch mode") { [weak self] b in
            guard let self else { return }
            self.mode = self.mode == .trackpad ? .direct : .trackpad
            b.configuration?.image = UIImage(systemName: self.mode == .trackpad ? "hand.point.up.left" : "hand.tap")
            self.flash(self.mode == .trackpad ? "Trackpad: drag moves the cursor" : "Direct: tap where you want to click")
        }
        _ = button("xmark", "Disconnect") { [weak self] _ in
            self?.session.stop()
            self?.onClose?()
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
