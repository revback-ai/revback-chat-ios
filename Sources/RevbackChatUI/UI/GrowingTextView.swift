import SwiftUI
import UIKit

/// Поле композера. `TextField(axis: .vertical)` — iOS 16, а минимум у пакета iOS 15
/// (спека §2), поэтому `UITextView`: он же даёт точную высоту 34 и цвет плейсхолдера
/// #9aa1ad из §4 строка 79.
struct GrowingTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    let fontSize: CGFloat
    let minHeight: CGFloat
    let maxLines: Int
    let paddingVertical: CGFloat
    let paddingHorizontal: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .systemFont(ofSize: fontSize)
        view.textColor = UIColor(Theme.ink)
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        // Тап по статус-бару принимает прокси ленты — UIKit зовёт `scrollsToTop`, только
        // если такой вид в окне ОДИН; поле ввода (тоже `UIScrollView`) иначе отнимало бы тап у ленты.
        view.scrollsToTop = false
        view.textContainerInset = UIEdgeInsets(top: paddingVertical, left: paddingHorizontal,
                                               bottom: paddingVertical, right: paddingHorizontal)
        view.textContainer.lineFragmentPadding = 0
        // §5 п. 5: Enter — перенос строки, отправка кнопкой
        view.returnKeyType = .default
        // Как в любом мессенджере — заглавная в начале предложения (спека UI §12 п. 82). Значение
        // совпадает с умолчанием `UITextView`, но задано явно — как часть контракта поля.
        // Автозамену и подсказки не трогаем.
        view.autocapitalizationType = .sentences
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // §9: у поля должен быть ярлык. Плейсхолдер — обычный `UILabel` внутри `UITextView`,
        // VoiceOver его не читает (текстовое поле сливает потомков), и поле объявлялось бы
        // безымянным «Текстовое поле». Ярлык = та же подпись, что видит глаз.
        view.accessibilityLabel = placeholder

        let label = UILabel()
        label.text = placeholder
        label.font = .systemFont(ofSize: fontSize)
        label.textColor = UIColor(Theme.controlGlyph)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: paddingHorizontal),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: paddingVertical)
        ])
        context.coordinator.placeholderLabel = label
        label.isHidden = !text.isEmpty
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self       // Binding после перерисовки — свежий
        if uiView.text != text { uiView.text = text }
        if uiView.accessibilityLabel != placeholder { uiView.accessibilityLabel = placeholder }
        context.coordinator.placeholderLabel?.isHidden = !text.isEmpty
        recalculate(uiView)
    }

    fileprivate func recalculate(_ view: UITextView) {
        let width = view.bounds.width
        guard width > 0 else { return }
        let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let lineHeight = (view.font ?? .systemFont(ofSize: fontSize)).lineHeight
        let maxHeight = lineHeight * CGFloat(maxLines) + 2 * paddingVertical
        let clamped = min(max(fitting, minHeight), maxHeight)
        // §4 строка 79: до 4 строк, дальше поле прокручивается
        view.isScrollEnabled = fitting > maxHeight
        if abs(clamped - height) > 0.5 {
            DispatchQueue.main.async { height = clamped }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: GrowingTextView
        weak var placeholderLabel: UILabel?

        init(parent: GrowingTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            placeholderLabel?.isHidden = !textView.text.isEmpty
            parent.recalculate(textView)
        }
    }
}
