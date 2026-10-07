import SwiftUI
import UIKit

/// UIKit-контейнер готового экрана (спека §3, строка 51): `UIHostingController`
/// над `RevbackChatView`, `modalPresentationStyle = .fullScreen`, статус-бар светлый.
public final class RevbackChatViewController: UIViewController {

    private let onClose: (() -> Void)?
    /// Крестик фасада: получает сам контейнер, чтобы закрыть именно его (`RevbackChatUI.close`).
    private let onCloseSelf: ((RevbackChatViewController) -> Void)?
    /// Экран ушёл из стека показа (закрыт, в том числе мимо фасада). Не зовётся, когда экран лишь накрыт
    /// листом или другим экраном.
    var onLeftScreen: (() -> Void)?
    /// Модель держит контейнер, а не вьюха: иначе `viewWillAppear`/`viewDidDisappear`
    /// не до кого дозваться.
    private let model = ChatModel(backend: LiveChatBackend())

    /// `onClose == nil` — контейнер закрывает себя сам (крестик = `dismiss`, §5 п. 10).
    public init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onCloseSelf = nil
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalPresentationCapturesStatusBarAppearance = true
    }

    /// Контейнер фасада `RevbackChatUI.present`.
    init(onCloseSelf: @escaping (RevbackChatViewController) -> Void) {
        self.onClose = nil
        self.onCloseSelf = onCloseSelf
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    /// §4 строка 65: статус-бар на primary, глифы светлые.
    public override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    public override var childForStatusBarStyle: UIViewController? { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        let close: () -> Void = { [weak self] in
            guard let self else { return }
            if let onClose = self.onClose {
                onClose()
            } else if let onCloseSelf = self.onCloseSelf {
                onCloseSelf(self)
            } else {
                self.dismiss(animated: true)
            }
        }
        let host = UIHostingController(rootView: RevbackChatView(onClose: close, model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)
    }

    /// §5 п. 1: у UIKit-контейнера жизненный цикл ведёт САМ контейнер.
    /// `onAppear`/`onDisappear` SwiftUI внутри `UIHostingController` при модальном показе
    /// поверх экрана срабатывают не всегда — без этих переопределений `open()`/`close()`
    /// могли не прийти вовсе. Двойной вызов безопасен: `open()`/`close()` у ядра
    /// идемпотентны (§5 п. 1), а `markReadSoon()` дебаунсится.
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.screenAppeared()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.screenDisappeared()
        if Self.hasLeftScreen(isBeingDismissed: isBeingDismissed, hasPresenter: presentingViewController != nil) {
            onLeftScreen?()
        }
    }

    /// Исчез ли экран совсем, а не накрыт: закрывается он сам или его уже некому показывать (снят вместе с
    /// контроллером хоста, поверх которого лежал). Накрытый листом экран сохраняет показавшего и не закрывается.
    static func hasLeftScreen(isBeingDismissed: Bool, hasPresenter: Bool) -> Bool {
        isBeingDismissed || !hasPresenter
    }
}
