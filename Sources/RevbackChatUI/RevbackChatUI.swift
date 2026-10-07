import Foundation
import RevbackChatCore
import UIKit

/// Публичный API UI-слоя — спека §3, строки 44–49.
public enum RevbackChatUI {

    private static weak var presented: RevbackChatViewController?

    /// Экран показан фасадом и не убран. Экран, убранный мимо фасада (хост закрыл свой контроллер, под которым
    /// лежал чат), сообщает об уходе сам (`viewDidDisappear`); на главном потоке состояние дополнительно сверяется
    /// с UIKit, чтобы `isPresented` не врал и в промежутке до этого сообщения.
    public static var isPresented: Bool {
        guard let vc = presented else { return false }
        guard Thread.isMainThread else { return true }
        return !isGone(vc)
    }

    /// Презентовать готовый экран модально во весь экран (крестик закрывает).
    /// До `RevbackChat.shared.configure` экран открывается и показывает «чат недоступен»;
    /// беседа встанет сразу после `configure` (core-спека §18 п. 250).
    public static func present(over presenter: UIViewController, animated: Bool = true) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { present(over: presenter, animated: animated) }
            return
        }
        // Кнопка «Поддержка», нажатая до `configure`, обязана что-то показать. Экран покажет §4 «Чат временно
        // недоступен» с кнопкой «Обновить» (§12 пп. 47 и 48) и оживёт сам, как только хост позовёт
        // `configure`: открытие беседы запоминает фасад ядра (core-спека §18 п. 250).
        if !RevbackChat.shared.isConfigured {
            NSLog("[RevbackChatUI] present до RevbackChat.shared.configure — экран покажет «чат недоступен» и оживёт после configure")
        }
        if let vc = presented, isGone(vc) { presented = nil }
        guard presented == nil else {
            NSLog("[RevbackChatUI] present: экран уже показан — no-op")
            return
        }

        // `presented` — слабая ссылка, и между закрытием экрана и его `dealloc` (ARC освобождает
        // контейнер не в момент `dismiss`, а позже — авторелиз-пул, анимация, ссылки UIKit)
        // `isPresented` оставался бы `true`, а следующий `present` молча выходил. Поэтому крестик
        // закрывает экран через фасад (`close`), который обнуляет `presented` до анимации, а уход
        // мимо фасада экран сообщает сам (`onLeftScreen`). Замыкания держат контейнер слабо —
        // цикла удержания нет.
        let vc = RevbackChatViewController(onCloseSelf: { close($0, animated: true) })
        vc.onLeftScreen = { [weak vc] in
            if let vc, presented === vc { presented = nil }
        }
        presented = vc
        presenter.present(vc, animated: animated)
    }

    /// Закрывает экран вместе со всем, что открыто поверх него (меню скрепки, выбор файла, просмотр файла).
    public static func dismiss(animated: Bool = true) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { dismiss(animated: animated) }
            return
        }
        guard let vc = presented else { return }
        close(vc, animated: animated)
    }

    /// Снимает экран `vc` и весь стек над ним. `dismiss` у самого экрана при открытом поверх листе закрыл бы
    /// только лист (так устроен UIKit): чат остался бы на экране, а фасад считал бы его закрытым. Поэтому
    /// закрывает тот, кто экран показал: у него `dismiss` снимает показанный контроллер со всем стеком над ним.
    /// Крестик зовёт это же для СВОЕГО контейнера, поэтому закрывает экран, даже если ссылку фасад уже потерял.
    static func close(_ vc: RevbackChatViewController, animated: Bool) {
        if presented === vc { presented = nil }
        dismissTarget(of: vc).dismiss(animated: animated)
    }

    /// Кому звать `dismiss`, чтобы снять экран целиком: показавшему его контроллеру; не показан — самому экрану
    /// (у не показанного контроллера `dismiss` ничего не делает).
    static func dismissTarget(of vc: UIViewController) -> UIViewController {
        vc.presentingViewController ?? vc
    }

    /// Экран больше не в стеке показа: показавшего нет, и показ не идёт прямо сейчас. Только главный поток.
    static func isGone(_ vc: UIViewController) -> Bool {
        vc.presentingViewController == nil && !vc.isBeingPresented
    }
}
