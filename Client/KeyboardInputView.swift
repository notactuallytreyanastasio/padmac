import UIKit

/// Hardware keys, and the on-screen keyboard when it is shown.
///
/// Hardware presses are handled in pressesBegan and not passed to super, which
/// keeps UIKit from also turning them into insertText calls.
final class KeyboardInputView: UIView, UIKeyInput {
    var onKey: ((UInt16, Bool) -> Void)?
    var onText: ((String) -> Void)?
    var onDelete: (() -> Void)?

    /// When false the view still takes hardware keys but shows no on-screen keyboard.
    var softKeyboard = false {
        didSet { reloadInputViews() }
    }
    var accessory: UIView?

    private let empty = UIView(frame: .zero)
    private var repeatTimer: Timer?

    override var canBecomeFirstResponder: Bool { true }
    override var inputView: UIView? { softKeyboard ? nil : empty }
    override var inputAccessoryView: UIView? { softKeyboard ? accessory : nil }

    // UITextInputTraits: literal typing, nothing clever.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    var hasText: Bool { true } // so backspace is always delivered
    func insertText(_ text: String) { onText?(text) }
    func deleteBackward() { onDelete?() }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for p in presses {
            guard let key = p.key, let code = KeyMap.hidToMac[key.keyCode.rawValue] else { unhandled.insert(p); continue }
            onKey?(code, true)
            startRepeat(code)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        release(presses, event) { super.pressesEnded($0, with: $1) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        release(presses, event) { super.pressesCancelled($0, with: $1) }
    }

    private func release(_ presses: Set<UIPress>, _ event: UIPressesEvent?, _ forward: (Set<UIPress>, UIPressesEvent?) -> Void) {
        var unhandled = Set<UIPress>()
        for p in presses {
            guard let key = p.key, let code = KeyMap.hidToMac[key.keyCode.rawValue] else { unhandled.insert(p); continue }
            stopRepeat()
            onKey?(code, false)
        }
        if !unhandled.isEmpty { forward(unhandled, event) }
    }

    /// Synthesized key-downs do not auto-repeat on the Mac, so held keys are repeated from here.
    private func startRepeat(_ code: UInt16) {
        stopRepeat()
        guard !KeyMap.modifiers.contains(code) else { return }
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 25, repeats: true) { _ in
                self?.onKey?(code, true)
            }
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}
