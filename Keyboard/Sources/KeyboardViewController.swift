import HexMobileCore
import SwiftUI
import UIKit

/// The Hex Mobile keyboard: a microphone key that drives dictation in the
/// app's flow session, plus the few keys needed around it.
///
/// The SwiftUI hosting controller and the model exist only between
/// `viewWillAppear` and `viewDidDisappear`. iOS loads controllers it never
/// shows and keeps some of them until the host app's connection ends (phone
/// log of 2 Nov 2026: `keyboard load` with no `appear`, no `deinit`; on the
/// simulator the SwiftUI graph of such a controller, held by its display link,
/// weighed about 2 MB each and the controllers stayed). A controller that was
/// loaded and never shown is now a bare view and weighs almost nothing,
/// whoever holds it.
final class KeyboardViewController: UIInputViewController {
    private var model: KeyboardModel?
    private var hostingController: UIHostingController<KeyboardRoot>?
    /// `viewDidLoad` ran and the controller was counted (`KeyboardDiagnostics`).
    private var counted = false
    /// `viewWillAppear` ran at least once: the keyboard was shown.
    private var hasAppeared = false

    /// iOS drops a keyboard without telling the controller (the host app was
    /// killed, the keyboard was switched): `viewDidDisappear` does not always
    /// come. The SwiftUI graph and the model it holds then outlived the
    /// controller, with the graph's display link as the only owner (heap and
    /// leaks on the simulator, 1 Nov 2026), so the controller lets go of both
    /// here, whatever came before.
    isolated deinit {
        tearDown(detachingFromParent: false)
        if counted { KeyboardDiagnostics.controllerDeallocated(unshown: !hasAppeared) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        counted = true
        KeyboardDiagnostics.controllerLoaded()
        // A new `process started` line without a crash report before it means
        // iOS ended the previous process (see `KeyboardDiagnostics`).
        KeyboardDiagnostics.noteProcessStart()
        // Before any SwiftUI exists: the footprint this keyboard starts from.
        KeyboardDiagnostics.record("keyboard load pid=\(getpid()) \(KeyboardDiagnostics.memorySummary)")
        // Nothing heavy here: no model, no SwiftUI (see the type's comment).
        // Dark-first like the app; the keyboard cannot read the app's
        // appearance setting (no shared container). The height sits on the
        // view itself so the keyboard has its size before the hosting view
        // exists, and nothing flashes or jumps when it arrives.
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        let height = view.heightAnchor.constraint(equalToConstant: KeyboardView<GlobeKey>.preferredHeight)
        height.priority = UILayoutPriority(999)
        height.isActive = true
    }

    /// Builds the model and the SwiftUI hosting controller, once per
    /// appearance. Reads nothing from the text document.
    private func build() {
        guard hostingController == nil else { return }
        let model = KeyboardModel()
        model.actions = KeyboardActions(
            insertText: { [weak self] text in self?.textDocumentProxy.insertText(text) },
            deleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            moveCursor: { [weak self] chars in
                self?.textDocumentProxy.adjustTextPosition(byCharacterOffset: chars)
            },
            openHostApp: { [weak self] url in self?.openURLFromExtension(url) ?? false },
            hasFullAccess: { [weak self] in self?.hasFullAccess ?? false }
        )
        model.documentContextBeforeInput = { [weak self] in self?.textDocumentProxy.documentContextBeforeInput }
        self.model = model

        let hosting = UIHostingController(rootView: KeyboardRoot(model: model, controller: self))
        hosting.view.backgroundColor = .black
        hosting.sizingOptions = []
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        hostingController = hosting
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasAppeared = true
        build()
        // Nothing here may read the text document (`needsInputModeSwitchKey`,
        // `textDocumentProxy`): when the extension process has just launched,
        // the connection to the host is not up yet, and UIKit raised an
        // unrecognized selector (`-[_UITextDocumentInterface _controllerState]`
        // from `needsInputModeSwitchKey`) 0.5 s after launch, killing the
        // keyboard with SIGABRT (crash of 1 Nov 2026, iOS 27.2). `appear()`
        // only starts listening and pings the app.
        model?.appear()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let model else { return }
        // The host drives this call, so its connection is up: the reads that
        // crashed in `viewWillAppear` are safe here.
        model.needsGlobeKey = needsInputModeSwitchKey
        refreshTypingState()
        // The footprint once the view is laid out (the `appear` line comes
        // before the first layout).
        KeyboardDiagnostics.record("appeared pid=\(getpid()) \(KeyboardDiagnostics.memorySummary)")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model?.disappear()
        // The graph and the model go now, not when iOS lets the controller go
        // (it may keep it; a later `viewWillAppear` builds them again).
        tearDown(detachingFromParent: true)
    }

    /// Empties the SwiftUI root (so the graph holds neither the model nor the
    /// blob's display link), takes the hosting view out of the hierarchy and
    /// stops the model. Safe to call twice. From `deinit` the hosting
    /// controller is not detached from its parent (the parent is going away).
    private func tearDown(detachingFromParent: Bool) {
        if let hosting = hostingController {
            hosting.rootView = KeyboardRoot(model: nil, controller: nil)
            if detachingFromParent { hosting.willMove(toParent: nil) }
            hosting.view.removeFromSuperview()
            if detachingFromParent { hosting.removeFromParent() }
            hostingController = nil
        }
        model?.shutdown()
        model = nil
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        KeyboardDiagnostics.record("keyboard memory warning pid=\(getpid()) \(KeyboardDiagnostics.memorySummary)")
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        refreshTypingState()
    }

    /// Copies the return key label and the shift state from the text document
    /// into the model. Call it only after the view appeared (see
    /// `viewWillAppear`) or from the host-driven `textDidChange`.
    private func refreshTypingState() {
        // No model: the keyboard is not showing (nothing to update, and the
        // text document is not read).
        guard let model else { return }
        model.returnKeyTitle = Self.returnTitle(for: textDocumentProxy.returnKeyType)
        model.autoCapitalize()
    }

    private static func returnTitle(for type: UIReturnKeyType?) -> KeyboardModel.ReturnTitle {
        switch type {
        case .go: .go
        case .search, .google, .yahoo: .search
        case .send: .send
        case .done: .done
        case .next: .next
        default: .return
        }
    }

    /// Best-effort deep link to the app from a keyboard extension.
    ///
    /// `extensionContext.open(_:)` only works for Today widgets, and
    /// `UIApplication.shared` is unavailable to extensions. This walks the
    /// responder chain to the host's `UIApplication` and calls
    /// `open(_:options:completionHandler:)` dynamically, which keeps
    /// `APPLICATION_EXTENSION_API_ONLY = YES`. iOS may ignore the call; the
    /// keyboard then shows instructions instead.
    private func openURLFromExtension(_ url: URL) -> Bool {
        // Only the host's UIApplication accepts this selector with an options
        // dictionary. UIScene declares a selector with the same name but
        // forwards it to an object that does not implement it inside an
        // extension, which raised an Objective-C exception and killed the
        // keyboard (crash of 1 Nov 2026). Never call it on anything else.
        guard let applicationClass = NSClassFromString("UIApplication") else { return false }
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.isKind(of: applicationClass),
               current.responds(to: selector),
               let method = current.method(for: selector) {
                typealias OpenURL = @convention(c) (AnyObject, Selector, URL, NSDictionary, Any?) -> Void
                let open = unsafeBitCast(method, to: OpenURL.self)
                open(current, selector, url, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }
}

/// What the hosting controller shows: the keyboard, or nothing once the
/// controller has let go of its model (see `KeyboardViewController.tearDown`).
struct KeyboardRoot: View {
    var model: KeyboardModel?
    weak var controller: UIInputViewController?

    var body: some View {
        if let model {
            KeyboardView(model: model) { GlobeKey(controller: controller) }
        } else {
            Color.clear
        }
    }
}

/// The system globe key (switches keyboards, long-press shows the list).
struct GlobeKey: UIViewRepresentable {
    weak var controller: UIInputViewController?

    func makeUIView(context: Context) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "globe")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .title3)
        configuration.baseForegroundColor = .label
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = String(localized: "Next keyboard")
        if let controller {
            button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}
