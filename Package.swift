// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RevbackChat",
    defaultLocalization: "ru",
    platforms: [.iOS(.v15)],
    products: [
        // Ядро входит в продукт вместе с UI: его типы нужны и хосту (`RevbackChat.shared.configure`,
        // `RevbackChatConfig`), поэтому `import RevbackChatCore` у потребителя пакета собирается сразу.
        .library(name: "RevbackChatUI", targets: ["RevbackChatUI", "RevbackChatCore"]),
        // Только ядро — для тех, кто рисует экран сам (паритет с Android-координатой revback-chat-core).
        // `RevbackChatCoreLink` здесь обязателен: один `binaryTarget` не несёт настроек линковщика,
        // и без заглушки продукт не отдавал бы `-lsqlite3` — линковка приложения падала бы на `sqlite3_*`.
        .library(name: "RevbackChatCore", targets: ["RevbackChatCore", "RevbackChatCoreLink"])
    ],
    targets: [
        // Бинарный XCFramework ядра — из GitHub Release тега, соответствующего версии пакета.
        // Адрес и checksum подставляет релизный скрипт монорепо revback-chat-sdk.
        .binaryTarget(
            name: "RevbackChatCore",
            url: "https://github.com/revback-ai/revback-chat-ios/releases/download/0.1.1/RevbackChatCore.xcframework.zip",
            checksum: "8d7102cb85e775f1fd86294683c8046dd9891c8c66dfdcd8996f5e92b026d312"
        ),
        // Заглушка без кода: доносит системную libsqlite3 до продукта «только ядро»
        // (подробности — в комментарии Sources/RevbackChatCoreLink/RevbackChatCoreLink.swift).
        // Зависимости от `RevbackChatCore` нет намеренно: импортировать здесь нечего, а в продукте
        // оба таргета перечислены явно. В продукт `RevbackChatUI` заглушка не входит — тот линкует
        // libsqlite3 своим таргетом, и второй `-lsqlite3` был бы лишним.
        // Privacy manifest — второй экземпляр рядом с тем, что лежит в каждом слайсе XCFramework:
        // манифест внутри СТАТИЧЕСКОГО binaryTarget SPM и App Store могли не учитывать
        // (swift-package-manager#7317, firebase-ios-sdk#12557), а ресурс исходного таргета SPM
        // кладёт в приложение и с продуктом «только ядро». У `RevbackChatUI`
        // такой же экземпляр лежит в `Resources`. Содержимое всех копий идентично.
        .target(
            name: "RevbackChatCoreLink",
            resources: [.process("PrivacyInfo.xcprivacy")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "RevbackChatUI",
            dependencies: ["RevbackChatCore"],
            resources: [.process("Resources")],
            // Ядро статическое: кэш беседы на SQLDelight/SQLiter оставляет неразрешёнными
            // символы `sqlite3_*`, и всё, что линкует `RevbackChatCore`, обязано подтянуть
            // системную libsqlite3. Мест, где она прописана, в пакете два, по одному на продукт:
            // этот таргет — за продукт с готовым экраном, заглушка `RevbackChatCoreLink` — за
            // продукт «только ядро». Настройка отсюда достаётся и хосту.
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
