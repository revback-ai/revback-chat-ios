# RevBack Chat SDK for iOS

[Документация на русском](./README.md)

**RevBack Chat SDK** embeds the RevBack support chat into your mobile app: conversations with a human
operator and an AI assistant, history, attachments, an unread counter and push notifications. The Swift
package has two products — a core with no UI at all (`RevbackChatCore`) and a ready-made SwiftUI chat screen
on top of it (`RevbackChatUI`). Take the ready-made screen if you would rather not build a chat UI, or the
core alone if the interface is yours.

The core is written in Kotlin Multiplatform and ships as a binary static XCFramework; from Swift its API looks
native: `async` functions and data streams as `AsyncSequence`. The iOS part is distributed through Swift
Package Manager from this repository; the matching Android version is on Maven Central, repository
[revback-chat-android](https://github.com/revback-ai/revback-chat-android).

## Features

- Conversations with an operator and an AI assistant, plus system messages.
- Conversation history with paging upwards; a local cache speeds up a cold start.
- Attachments both ways: upload and send your own files, download both the operator's files and your
  own; videos carry a cover frame, duration and size.
- Outgoing message states: sending, sent (accepted by the server), read by operator, failed (with retry).
- A durable send queue: unsent messages survive a process restart (while history is stored on disk,
  which is the default).
- An unread counter outside the chat screen — for a badge on your "Support" button.
- Push notifications over Firebase Cloud Messaging: the show-or-not decision while the app is in the
  foreground, and a deep link to the conversation on tap.
- Linking a visitor to your app's user (`identify`) with a token issued by your backend.
- User attributes visible to the operator (`setAttributes`).
- A ready-made SwiftUI chat screen as a separate product; the core works without it.
- SDK telemetry for integration diagnostics (no visitor ids and no tokens inside).

## Requirements

| Item | Value |
|---|---|
| Minimum iOS version | 15.0 |
| Swift Package Manager | `swift-tools-version` 5.9 |
| Swift | checked on Xcode 26.3 (Swift 6.2.4). The core is built in Swift 5 language mode (`-swift-version 5` in the module's `.swiftinterface`). The package and all examples in this guide build in Swift 5 language mode, including with default `MainActor` isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION`) — the example from "Attachments and previews" then produces isolation warnings. In Swift 6 language mode some of the examples do not build: strict data-race checking requires changes to them. Older Xcode versions have not been checked |
| Firebase Cloud Messaging | added by your app — the SDK package does not pull Firebase in |
| Permissions | the ready-made screen needs no `NS…UsageDescription` strings; the notification permission is requested by your app |
| Keychain | the SDK keeps its identifiers in the Keychain, so the build must be signed — simulator builds included (ad hoc is enough). Without a signature the Keychain answers `errSecMissingEntitlement` and the conversation never opens |

## Dependencies and compatibility

The SDK does not make you rework your app's networking and adds no third-party package to your project:
the Swift package has no external dependencies. The core is a static `RevbackChatCore.xcframework` with its
third-party libraries compiled inside; the only outside requirement is the system `libsqlite3`, which the
package links by itself (see "Installation").

| Inside `RevbackChatCore.xcframework` | Version | What it means for your app |
|---|---|---|
| Kotlin/Native (runtime and standard library) | 2.2.21 | your app does not need Kotlin |
| Ktor, Darwin engine (`NSURLSession`) | 3.3.3 | the SDK's networking; it does not configure your app's networking or `URLSession` |
| kotlinx.coroutines | 1.10.2 | `suspend` functions appear in Swift as `async throws` |
| kotlinx.serialization | 1.9.0 | — |
| SQLDelight / SQLiter | 2.2.1 / 1.3.3 | the conversation cache, on the system `libsqlite3` |
| SKIE (runtime) | 0.10.14 | the Swift bridge: `async` functions, streams as `AsyncSequence` |
| kotlinx-atomicfu, kotlinx-io, Stately | 0.29.0 / 0.8.0 / 2.1.0 | — |

The full list of third-party components and their licenses is in `THIRD-PARTY-NOTICES`. If your app is itself
written in Kotlin Multiplatform, see "Apps built with Kotlin Multiplatform".

## Installation

In Xcode: **File → Add Package Dependencies…** → the address of this repository
(`https://github.com/revback-ai/revback-chat-ios`) → pick the `RevbackChatUI` product.

The core (`RevbackChatCore`) comes with `RevbackChatUI` automatically — there is no need to add it
separately. If you build the chat screen yourself, pick the `RevbackChatCore` product instead (the core
alone, without the ready-made screen). The system `libsqlite3` (required by the conversation cache inside
the core) is linked by the package itself — **with either product**; you do not need to add
`libsqlite3.tbd` to your project by hand.

The same in your own `Package.swift`. While the version is `0.x`, breaking changes are possible in a minor
release (see "Compatibility and versioning"), so take updates within the minor version only:

```swift
dependencies: [
    .package(url: "https://github.com/revback-ai/revback-chat-ios", .upToNextMinor(from: "0.1.1"))
],
targets: [
    .target(
        name: "App",
        dependencies: [
            // the ready-made chat screen; the core comes with it
            .product(name: "RevbackChatUI", package: "revback-chat-ios")
            // or the core alone — if you build the screen yourself:
            // .product(name: "RevbackChatCore", package: "revback-chat-ios")
        ]
    )
]
```

```swift
import RevbackChatCore
import RevbackChatUI
```

If an SDK type name matches a type of your app or of another library (`Message`, `Attachment`,
`Conversation` and so on), qualify it with the module: `RevbackChatCore.Message`.

The third module in the package's target list, `RevbackChatCoreLink`, is internal: it contains no code
and only tells the linker about `libsqlite3` for the core-only product. You do not need to import it.

**If your app still fails to link** with `Undefined symbols: _sqlite3_…`, add `libsqlite3.tbd` to your app
target (Build Phases → Link Binary With Libraries → `libsqlite3.tbd`) and let us know. This is a safety net
for unusual project setups: with a regular Swift Package Manager integration the step is not needed with
either product.

The channel key (`widgetKey`) comes from your RevBack dashboard (the dashboard is in Russian), channel type
"In-app chat" («Чат в приложении»). The key is
public by design — it can be extracted from the app build and is not a secret. The channel secret your
backend uses to sign a user's identity token never goes into the app and stays on your backend.

## Getting started

Configure once at process start: in `application(_:didFinishLaunchingWithOptions:)` or in your `App`'s
`init()`. If the app uses Firebase — after `FirebaseApp.configure()`.

```swift
import RevbackChatCore
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // telemetry before configure: the SDK remembers the listener; events arrive on any thread
        RevbackChat.shared.setTelemetryListener { event in
            NSLog("RevBack: %@", String(describing: event))
        }
        // the initializer takes only the channel key; everything optional goes through a with… chain
        RevbackChat.shared.configure(config: RevbackChatConfig(widgetKey: "wk_…"))
        return true
    }
}
```

- A repeated `configure` with the same key is a no-op: the module keeps the configuration it was built with
  (`persistHistory` included). With another key the SDK rebuilds the module for the new channel and the new
  configuration. An invalid config (an empty key) is logged and rejected, without an exception.
- Any call made before `configure` is safe: a no-op with a log line. Some calls are not lost either: the SDK
  remembers `setPushToken`, `conversation.open()` and `close()`, as well as the listeners
  (`setTelemetryListener`, `setUnreadListener`, `setTokenSyncListener`, `setDelegate`), and applies them right
  after `configure`. `markRead()` before `configure` is remembered too, but it is sent after `configure` only
  if the screen is open at that moment (`conversation.open()` called and not closed with `close()`); otherwise
  it is dropped. `identify` before `configure` is not remembered — call it afterwards.
- The core's `suspend` functions are `async throws` in Swift. They throw no business errors (failures arrive
  as states and events), so `try?` is enough.
- Kotlin default parameter values are not visible from Swift: pass every parameter
  (`setPushToken(token:provider:)`, `markRead(upTo: nil)`, all five `MediaPreview` parameters).
- `RevbackChat.shared.isConfigured` tells whether the module is configured; `RevbackChat.shared.config` is
  the configuration it runs with (`nil` until `configure`).

## The ready-made screen

The `RevbackChatUI` product. One call opens it on top of your app:

```swift
import RevbackChatUI
import UIKit

final class SupportEntryController: UIViewController {

    // for example, when "Support" is tapped
    @objc func supportTapped() {
        RevbackChatUI.present(over: self)
    }

    // close it from code — for example, when the user logs out; does nothing if the screen is not shown
    func closeSupportChat() {
        RevbackChatUI.dismiss()
    }
}
```

Or present it yourself — the SwiftUI view `RevbackChatView` or the UIKit container `RevbackChatViewController`:

```swift
import RevbackChatUI
import SwiftUI
import UIKit

struct SupportButton: View {
    @State private var chatOpen = false

    var body: some View {
        Button("Support") { chatOpen = true }
            .fullScreenCover(isPresented: $chatOpen) {
                RevbackChatView(onClose: { chatOpen = false })
            }
    }
}

final class SupportHostController: UIViewController {
    func openSupportChat() {
        let chat = RevbackChatViewController(onClose: { [weak self] in
            self?.dismiss(animated: true)
        })
        present(chat, animated: true)
    }
}
```

- The screen mirrors the RevBack website widget: a header in the channel colour, incoming messages
  with the sender's name, your own messages with delivery states, attachments and a composer.
- `RevbackChatUI.present(over:)` shows the screen modally, full screen; the close button in the header
  closes it. A repeated `present` while the screen is shown is a no-op. It can be called from any thread.
- `RevbackChatUI.dismiss()` closes the screen together with everything open on top of it (the paperclip menu,
  a file picker, an attachment preview): it dismisses through the controller that presented the screen.
  `RevbackChatUI.isPresented` tells whether the screen is shown; if the screen went away without `dismiss()`
  (say, you dismissed the controller it was presented over), `isPresented` returns `false` and the next
  `present` opens the screen again. Read `isPresented` on the main thread: off it the property does not check
  with UIKit and returns `true` while the facade still holds the screen, even one already removed without
  `dismiss()`, and `present` and `dismiss` called off the main thread run on it later, asynchronously — until
  then `isPresented` does not reflect them.
- `RevbackChatViewController` is a modal container (`modalPresentationStyle = .fullScreen`, light status
  bar): it is meant for `present`, not for `pushViewController`. With `onClose: nil` the close button
  dismisses the container itself. If you do push it onto a navigation stack, hide your navigation bar
  yourself, otherwise a second header stays above the chat header.
- `RevbackChatView(onClose: nil)` has no close button in the header — the host closes the screen.
- The screen opens and closes the conversation on its own — when it is shown and hidden, and when the app
  goes to the background and comes back — so you do not call `conversation.open()` / `close()` next to it.
- A screen opened before `RevbackChat.shared.configure` shows "Chat is temporarily unavailable" with a
  "Refresh" button and comes alive on its own as soon as you call `configure`. If `configure` never happens,
  the screen simply stays in that state.
- Attachments: the paperclip opens a menu with "Photo or Video" (`PHPickerViewController`) and "File"
  (`UIDocumentPickerViewController`). Both pickers run outside the app process and hand over only the
  selected files — no permissions and no `NS…UsageDescription` strings are needed. Up to 10 files per
  message; the file size cap is set by the channel. Received files open in the system `QLPreviewController`.
- HEIC photos from an iPhone and other images in formats the server does not display as images are
  re-encoded by the screen to JPEG with the correct orientation before sending — they go out as photos, not
  as files. The image is scaled down to 4096 pixels on its longer side; one with real transparency becomes a
  PNG, and if that PNG exceeds the file size cap — a JPEG on a white background. A photo goes out the same
  whether it was picked in "Photo or Video" or in "File". Images in formats the server displays as images go
  out as they are, at any pixel size, as long as the file fits the file size cap. A still image over the cap
  (JPEG, PNG, HEIC and others) is scaled down to 4096 pixels and sent if the result fits; animated and
  multi-frame images over the cap are not sent. The screen takes the cover frame and the duration of a video by itself.
- Your own attachment is rendered from a local copy of the picked file in the app cache (the copies take
  up to 50 MB), and without a copy it is downloaded from the server as soon as the server confirms the send.
- The screen's strings are English when the system language is English, and Russian otherwise.
- While shown, the screen holds the `RevbackChatDelegate` (the core has a single delegate): do not set your
  own delegate next to the ready-made screen — follow the data through streams instead (see "Observing data
  from Swift").

## Your own screen on top of the core

Everything a custom screen needs lives in `RevbackChat.shared.conversation` — a persistent object: you can
take it before `configure`, and it keeps working after the key changes. Models and states come from
`RevbackChatCore`.

### Feed and sending

```swift
import Combine
import Foundation
import RevbackChatCore

/// Conversation Failed reasons on which the chat is stopped: before configure and after a terminal stop.
/// Any other Failed is a network or server glitch: the next open() or a return from the background reloads the feed.
let supportChatStopReasons: Set<String> = ["not_configured", "widget_not_found", "sdk_outdated", "cache_unavailable"]

@MainActor
final class SupportChatModel: ObservableObject {
    @Published private(set) var messages: [Message] = []
    @Published private(set) var hasMore = false
    @Published private(set) var unavailable = false
    /// text the SDK did not accept (see send); put it back into the input field
    @Published private(set) var rejectedDraft: String?

    private var tasks: [Task<Void, Never>] = []

    /// the screen is shown
    func screenAppeared() {
        let conversation = RevbackChat.shared.conversation
        conversation.open()   // the chat socket is live, new-message pushes are not shown as banners
        tasks.append(Task { [weak self] in
            // the current feed comes first, then every change
            for await messages in conversation.messages {
                guard let self else { return }
                self.messages = messages
                self.hasMore = (conversation.hasMore.value as? Bool) ?? false
                self.markRead()
            }
        })
        tasks.append(Task { [weak self] in
            for await state in conversation.state {
                // on a stop reason — "chat unavailable" without an input field; on any other Failed the field stays
                let reason = (state as? ConversationState.Failed)?.reason
                self?.unavailable = reason.map { supportChatStopReasons.contains($0) } ?? false
            }
        })
    }

    /// the screen is hidden: the matching close() is mandatory, otherwise new-message pushes stay muted
    func screenDisappeared() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        RevbackChat.shared.conversation.close()
    }

    func send(_ text: String) {
        // optimistic: the message appears in the feed at once with status Sending
        Task { [weak self] in
            guard let message = try? await RevbackChat.shared.conversation.send(text: text, attachments: []) else { return }
            // before configure and with the conversation cache unavailable a rejected message never reaches
            // the feed: the result of send is the only place the rejection shows up
            if let failed = message.status as? MessageStatus.Failed,
               failed.reason == "not_configured" || failed.reason == "cache_unavailable" {
                self?.rejectedDraft = text
            }
        }
    }

    func retry(_ message: Message) {
        // retry your own Failed message
        Task { _ = try? await RevbackChat.shared.conversation.retry(messageId: message.id) }
    }

    func loadMore() {
        // one more page of history
        Task { _ = try? await RevbackChat.shared.conversation.loadMore() }
    }

    private func markRead() {
        // nil means everything up to now is read; the core limits the rate itself (at most once per 2 s)
        Task { _ = try? await RevbackChat.shared.conversation.markRead(upTo: nil) }
    }
}

/// Message Failed reasons for which retry will not help (see "Failures and retries").
let supportRetryUseless: Set<String> = ["empty", "bad_attachment", "sdk_outdated", "widget_not_found"]

/// A label for your own message's state. The set of cases grows — an "otherwise" branch is mandatory.
func statusLabel(_ message: Message) -> String {
    let status = message.status
    if status is MessageStatus.Sending { return "sending" }
    if status is MessageStatus.Sent { return "sent" }
    if status is MessageStatus.ReadByOperator { return "read" }
    if let failed = status as? MessageStatus.Failed {
        return supportRetryUseless.contains(failed.reason) ? "not sent" : "not sent — tap to retry"
    }
    return ""   // Received (other people's messages) and future cases
}
```

- The feed holds the last ≤ 200 messages, everything loaded by `loadMore()` and new ones; your own
  `Sending`/`Failed` messages sit at the tail. The first subscription to `messages` (or `open()`) starts
  syncing the feed; reading `.value` without a subscription does not.
- `deleted == true` is a deleted message: it stays in the feed; render a placeholder in its place.
- The sender of someone else's message is `message.sender`: `Sender.Agent`, `Sender.Assistant`,
  `Sender.System`, `Sender.Other` (a kind this SDK version does not know) or `nil`; check with `as?`, and keep
  an "otherwise" branch.
- `conversation.cancel(messageId:)` removes your own `Sending`/`Failed` message from the feed;
  `conversation.events` carries feed events (`ChatEvent.Added`, `Updated`, `Deleted`, `ReadByOperator`,
  `OperatorTyping`, `Reset`).
- Typing: `conversation.setTyping(draft:)` tells the server the visitor is typing (`nil` — stopped). It is sent
  only when the channel has `features.typing` switched on and the conversation is open, at most once every 3 s.
  Whether the operator is typing comes from the `conversation.operatorTyping` stream (`TypingState?`: `sender`,
  `until`; `nil` — not typing).
- `conversation.unreadInConversation` is a stream with the number of unread incoming messages inside the
  conversation.

### Failures and retries

A failure reason is the string in `Failed(reason)`. The set of reasons is open: treat an unknown reason as a
temporary failure.

**A message** — `MessageStatus.Failed(reason)`; retry with `conversation.retry(messageId:)`:

| Reason | Meaning | Does `retry` help |
|---|---|---|
| `network` | the network or the server did not answer: the SDK kept trying for about a minute (up to 5 minutes for a message that never reached the network) | yes |
| `rejected` | the server accepted the request but did not store the message (for example, sending is switched off on the channel). If it was a race between two identical requests, the state turns into `Sent` by itself once the message arrives from the server | a retry sends it again; if the server does not store such messages, it fails the same way |
| the server's response text or `HTTP <code>` | the server rejected the message itself (a 4xx response) | usually not: the same message is rejected again |
| `empty` | neither text nor attachments | no |
| `bad_attachment` | an attachment that is not an `upload` result (no reference to an uploaded file) | no |
| `sdk_outdated`, `widget_not_found` | the chat is stopped (see below) | no |
| `not_configured`, `cache_unavailable` | `send` before `configure` or with the conversation cache unavailable: the message never reaches the feed, the rejection shows up only in the result of `send` | no — it is not in the feed; send the text again once the chat works |
| `logout`, `identity_changed`, `identity_lost` | the queue was dropped by a logout, an identity switch or a lost identity: unsent messages disappear from the feed with it, and each one produces the telemetry event `TelemetryEvent.SendFailed(messageId, reason)` | no — the message is no longer in the feed |

**An attachment upload** — `UploadResult.Failed(reason)`; retry with a new `upload` of the same file:

| Reason | Meaning | Does a retry help |
|---|---|---|
| `too_large` | the file exceeds `branding.value?.maxFileSize`, rejected without a network call | no |
| `network` | no network | yes |
| `session` | no visitor session could be obtained, or the user logged out or changed while the file was uploading | yes, if the user is the same; after a logout do not send the previous user's file |
| the server's response text or `HTTP <code>` | the server rejected the file | for a 5xx response — yes, for a 4xx — usually not |
| `not_configured`, `sdk_outdated`, `widget_not_found`, `cache_unavailable` | the module is not configured or the chat is stopped | no |

`Upload.progress` is a stream that holds `0` until the upload finishes and `1` on `Done`: there are no values in
between.

**The conversation** — `ConversationState.Failed(reason)`:

| Reason | Meaning | What to do |
|---|---|---|
| `not_configured` | `configure` has not happened yet | a "chat unavailable" screen without an input field; the conversation comes alive by itself after `configure` |
| `widget_not_found`, `sdk_outdated`, `cache_unavailable` | the chat is stopped | a "chat unavailable" screen without an input field |
| `session`, `history HTTP <code>`, `changes HTTP <code>` | a network or server failure while loading the feed | keep the input field: the next `open()` or the app returning from the background reloads the feed |

**The connection** — `RevbackChat.shared.connection`: `Offline(since)` — no connection, the SDK reconnects by
itself; `Failed(reason)` happens only when the chat is stopped — `widget_not_found`, `sdk_outdated`,
`cache_unavailable`.

**A stopped chat.** The server may declare the SDK version outdated: the telemetry event
`TelemetryEvent.SdkOutdated(minSdkVersion)` arrives, the conversation and the connection switch to
`Failed("sdk_outdated")`, sending and uploads fail with the same reason, and the chat stays stopped until the app
is updated to a version with a newer SDK. `widget_not_found` means the server does not know the channel key (a
typo in the key, or the channel was deleted): the chat stays stopped until `configure` with a valid key.
`cache_unavailable` means the conversation cache could not be opened on the device: the chat stays stopped until
the app restarts. On all three the ready-made screen shows "Chat is temporarily unavailable". Watch for
`SdkOutdated` in telemetry — it is your signal to ship an app update.

### Attachments and previews

An attachment is uploaded first and sent afterwards — `send` only accepts the result of `upload`. Bytes in
the core API are `KotlinByteArray`, not `Data`. The conversion goes one byte at a time (from Swift the core's
array gives no access to its memory as a whole): a 10 MB file means about 10 million calls each way. So convert
off the main thread — in `Task.detached`, which does not inherit the caller's actor (your screen's
`@MainActor`, for example):

```swift
import Foundation
import RevbackChatCore

/// Data → KotlinByteArray: one byte at a time, off the main thread only
func kotlinBytes(_ data: Data) -> KotlinByteArray {
    let bytes = [UInt8](data)
    return KotlinByteArray(size: Int32(bytes.count)) { index in
        KotlinByte(char: Int8(bitPattern: bytes[Int(truncating: index)]))
    }
}

/// KotlinByteArray → Data: one byte at a time, off the main thread only
func swiftData(_ array: KotlinByteArray) -> Data {
    var bytes = [UInt8](repeating: 0, count: Int(array.size))
    for i in bytes.indices {
        bytes[i] = UInt8(bitPattern: array.get(index: Int32(i)))
    }
    return Data(bytes)
}

/// A photo: localCopy is your copy of the file, your screen shows your own attachment from it without network
func sendPhoto(jpeg: Data, localCopy: URL?) async {
    await Task.detached {
        let conversation = RevbackChat.shared.conversation
        let source = FileSource(fileName: "photo.jpg", mime: "image/jpeg", bytes: kotlinBytes(jpeg))
            .withLocalUri(localUri: localCopy?.absoluteString)
        guard let result = try? await conversation.upload(file: source).await() else { return }
        if let done = result as? UploadResult.Done {
            _ = try? await conversation.send(text: "", attachments: [done.attachment])
        } else if let failed = result as? UploadResult.Failed {
            NSLog("attachment upload failed: %@", failed.reason)   // reasons — see "Failures and retries"
        }   // Cancelled and future cases
    }.value
}

/// A video with a cover: your screen takes the frame, duration and size when the file is picked
func sendVideo(mp4: Data, coverJpeg: Data?, durationMs: Int64, width: Int32, height: Int32) async {
    await Task.detached {
        let conversation = RevbackChat.shared.conversation
        var preview = MediaPreview()
            .withDurationMs(ms: durationMs)
            .withSize(width: width, height: height)              // as displayed
        if let coverJpeg {                                       // a frame from the first second; JPEG or WebP, up to 640 px and 200 KB
            preview = preview.withThumbnail(bytes: kotlinBytes(coverJpeg), mime: "image/jpeg")
        }
        let source = FileSource(fileName: "clip.mp4", mime: "video/mp4", bytes: kotlinBytes(mp4))
            .withPreview(preview: preview)
        guard let result = try? await conversation.upload(file: source).await() else { return }
        if let done = result as? UploadResult.Done {
            _ = try? await conversation.send(text: "", attachments: [done.attachment])
        }
    }.value
}

/// Attachment bytes — the operator's and your own; nil means unavailable
func attachmentData(message: Message, index: Int) async -> Data? {
    let messageId = message.id
    return await Task.detached { () -> Data? in
        guard let bytes = try? await RevbackChat.shared.conversation
            .attachmentBytes(messageId: messageId, index: Int32(index)) else { return nil }
        return swiftData(bytes)
    }.value
}

/// A video cover; nil means there is no cover: show a link to the file instead
func videoCover(message: Message, index: Int) async -> Data? {
    let attachment = message.attachments[index]
    // attachment.width, attachment.height, attachment.durationMs — nil when unknown
    guard attachment.thumbnailBlobRef != nil else { return nil }
    let messageId = message.id
    return await Task.detached { () -> Data? in
        guard let bytes = try? await RevbackChat.shared.conversation
            .attachmentThumbnail(messageId: messageId, index: Int32(index)) else { return nil }
        return swiftData(bytes)
    }.value
}
```

- Show your own attachment from your own file (`Attachment.localUri` — whatever you passed to
  `FileSource.withLocalUri`), and once that file is gone, through `attachmentBytes`, just like an operator's
  attachment: the service hands your own files back too, for example after a reinstall or on another
  device. The exception is your own message the server has not confirmed yet (`Sending`, `Failed`): for it
  `attachmentBytes` returns `nil` at once, without a request. For your own video the server has not confirmed
  yet, the server has no cover to give either — show the frame you took when the file was picked.
- The cover goes up as a separate upload, and if that fails the send still goes through — the video just has
  no cover. For a photo the size is enough. The preview is built as a chain: `MediaPreview()` plus
  `withThumbnail(bytes:mime:)`, `withDurationMs(ms:)`, `withSize(width:height:)` — the cover is set together
  with its type, the width together with the height. Values outside the allowed bounds (duration, size) are
  dropped by the core before any network call.
- The server displays only PNG, JPEG, GIF, WebP, AVIF and BMP as images; anything else (an iPhone HEIC, for
  example) becomes a file. The ready-made screen re-encodes such images itself; a custom screen has to do it
  on its own.
- The file size cap is `RevbackChat.shared.branding.value?.maxFileSize` (10 MB by default); `upload` rejects
  a larger file without a network call, with the reason `too_large`. `upload` returns an upload handle:
  `cancel()` cancels it.
- An attachment this SDK version could not parse arrives with kind `AttachmentKind.companion.Other` and no
  name, MIME type or links — label it "This file type is not supported" (see "Compatibility and versioning").

### The unread counter outside the chat screen

```swift
import RevbackChatCore
import UIKit

final class SupportBadge {
    private weak var label: UILabel?

    init(label: UILabel) {
        self.label = label
        // a new listener gets the current count right away (once it is known), then every change;
        // the callback does not come on the main thread
        RevbackChat.shared.setUnreadListener { [weak self] unread in
            let count = unread.count
            DispatchQueue.main.async {
                // empty at zero, "99+" above that — the same as in the stream example below
                self?.label?.text = count > 99 ? "99+" : (count > 0 ? String(count) : nil)
            }
        }
    }
}
```

- The SDK keeps a single listener: a new `setUnreadListener` replaces the previous one, `nil` unsubscribes
  (remove it where the badge is no longer needed, not in an object's `deinit`: by then the listener may already
  belong to someone else). The SDK holds the listener until it is replaced or removed; `[weak self]` in the
  closure keeps it from holding on to the badge. Without a listener, use the `RevbackChat.shared.unreadCount`
  stream (see "Observing data from Swift").
- The count is available right after a cold start (saved from the previous run); the server, the live
  subscription and pushes refine it afterwards. `RevbackChat.shared.refreshUnread()` asks again.
- The SDK does not touch the app icon badge.

## Observing data from Swift

The core's streams — `conversation.messages`, `conversation.state`, `conversation.events`,
`RevbackChat.shared.unreadCount`, `connection`, `branding` — are `AsyncSequence` in Swift: subscribe with
`for await`; the current value comes first (for `events`, only new events), then every change. A
subscription lives as long as its task; cancel the task when you no longer need the data. The current value
without a subscription is `.value` (`RevbackChat.shared.conversation.messages.value` is a `[Message]`).

```swift
import RevbackChatCore
import UIKit

@MainActor
final class SupportObservers {
    private var tasks: [Task<Void, Never>] = []

    func start(badge: UILabel, onReset: @escaping () -> Void) {
        tasks.append(Task {
            for await unread in RevbackChat.shared.unreadCount {
                let count = unread.count
                badge.text = count > 99 ? "99+" : (count > 0 ? String(count) : nil)
            }
        })
        tasks.append(Task {
            for await event in RevbackChat.shared.conversation.events {
                if event is ChatEvent.Reset { onReset() }   // logout or a user switch
            }
        })
    }

    // unsubscribe
    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }
}
```

While shown, the ready-made screen holds the `RevbackChatDelegate` (the core has a single delegate), so next
to it follow the feed, events and the counter through streams — you can have any number of subscriptions,
and they do not get in the screen's way.

The delegate is a fallback for code without `async`. `RevbackChatDelegate` is an `@objc` protocol: the class
inherits from `NSObject` and implements all six methods. Callbacks do not come on the main thread;
`setDelegate(delegate: nil)` unsubscribes, and a new delegate replaces the previous one. The core holds the
delegate with a **strong reference** until it is removed with `setDelegate(delegate: nil)` or replaced: without
`detach()` the object is never released.

```swift
import Foundation
import RevbackChatCore

final class ChatDelegateBridge: NSObject, RevbackChatDelegate {
    var onMessages: (([Message]) -> Void)?

    // the core holds the delegate strongly — the matching detach() is mandatory
    func attach() { RevbackChat.shared.setDelegate(delegate: self) }
    func detach() { RevbackChat.shared.setDelegate(delegate: nil) }

    func onMessagesChanged(messages: [Message]) {
        DispatchQueue.main.async { self.onMessages?(messages) }
    }
    func onConversationStateChanged(state: ConversationState) {}
    func onConnectionChanged(state: ConnectionState) {}
    func onEvent(event: ChatEvent) {}
    func onUnreadChanged(unread: UnreadCount) {}
    func onBrandingChanged(branding: Branding?) {}
}
```

## Push notifications

Pushes arrive through Firebase Cloud Messaging (on an iPhone — via APNs). Your app brings the FCM SDK; the
RevBack SDK takes the token, decides whether to show a notification while the app is in the foreground and
finds the conversation on tap. While the chat screen is open, new-message notifications are not shown.

```swift
import RevbackChatCore
import RevbackChatUI
import UIKit
import UserNotifications

final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // FirebaseApp.configure() — before the SDK's configure
        RevbackChat.shared.configure(config: RevbackChatConfig(widgetKey: "wk_…"))
        // the notification delegate — before didFinishLaunching returns, otherwise a cold-start tap is lost
        UNUserNotificationCenter.current().delegate = self
        // Messaging.messaging().delegate = self
        return true
    }

    /// The FCM token: call from MessagingDelegate.messaging(_:didReceiveRegistrationToken:)
    /// and from Messaging.messaging().token { … } on every start. Request Messaging.messaging().token
    /// after the app has received its APNs token (didRegisterForRemoteNotificationsWithDeviceToken):
    /// on an iPhone there is no FCM token without an APNs token
    func fcmTokenReceived(_ token: String) {
        // always pass the provider: Kotlin default values are not visible from Swift
        RevbackChat.shared.setPushToken(token: token, provider: PushProvider.companion.Fcm)
    }

    // the app is in the foreground: show the notification or not
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let data = Self.stringData(notification.request.content.userInfo)
        // not idempotent for ShowMessage (the SDK remembers the display) — one call per notification
        let action = RevbackChat.shared.handlePush(data: data)
        if action is PushAction.ShowMessage || action is PushAction.TestPush {
            completionHandler([.banner, .list, .sound])
        } else if action is PushAction.NotOurs {
            completionHandler([.banner, .list, .sound])   // your own pushes — your way
        } else {
            completionHandler([])   // Suppress (chat open), Ignore and future cases
        }
    }

    // a tap on the notification
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let data = Self.stringData(response.notification.request.content.userInfo)
        if RevbackChat.shared.conversationId(data: data) != nil {
            DispatchQueue.main.async { self.openSupportChat(attemptsLeft: 10) }
        }
        completionHandler()
    }

    /// On a cold start the tap arrives while the window is still coming up: wait for a controller in a window (up to ~3 s)
    private func openSupportChat(attemptsLeft: Int) {
        if let top = Self.topViewController(), top.view.window != nil {
            RevbackChatUI.present(over: top)   // already shown — no-op
            return
        }
        guard attemptsLeft > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.openSupportChat(attemptsLeft: attemptsLeft - 1)
        }
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// our data keys are strings at the top level of userInfo; aps and non-strings are dropped
    static func stringData(_ userInfo: [AnyHashable: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in userInfo {
            if let key = key as? String, let value = value as? String {
                out[key] = value
            }
        }
        return out
    }
}
```

- `PushAction` is the decision on a push: `ShowMessage` and `TestPush` — show it; `Suppress` — do not
  show it (the chat is open, or a duplicate); `Ignore` — ours, but nothing to show (another channel's key, an
  unknown type, a push for the RevBack operator side, the module not configured); `NotOurs` — your app's own
  push. The set of cases grows — an "otherwise" branch is mandatory.
- `RevbackChat.shared.isRevbackPush(data:)` tells a RevBack push of any kind apart — handy for branching in a
  shared handler.
- `conversationId(data:)` answers even before `configure`, so a cold-start tap is not lost. `nil` means it is
  not a RevBack conversation push (yours, a test push, or another channel's).
- If your chat screen is your own, open it on tap yourself; the SDK learns that the screen is open from
  `conversation.open()` / `close()`.
- `setPushToken` may be called before `configure`: the SDK holds the token and sends it after setup. After
  `reset()` the SDK re-announces the previous token by itself.

Pushes carry no conversation text: iOS takes the notification title and body by keys from the
`Localizable.strings` of **your app's main bundle** (package resources are not visible for them; a missing key
is shown by iOS literally). Add the four keys to every language of your app:

```
/* en.lproj/Localizable.strings */
"revback.push.visitor.new_message.title_brand" = "%@";
"revback.push.visitor.new_message.body_contentless" = "New message from support";
"revback.push.visitor.test.title" = "Notification test";
"revback.push.visitor.test.body" = "Support chat notifications are working";
```

```
/* ru.lproj/Localizable.strings */
"revback.push.visitor.new_message.title_brand" = "%@";
"revback.push.visitor.new_message.body_contentless" = "Новое сообщение от поддержки";
"revback.push.visitor.test.title" = "Тест уведомлений";
"revback.push.visitor.test.body" = "Пуши из чата поддержки доходят";
```

What it takes for pushes to be delivered:

- the Firebase console of your project holds an **APNs Auth Key (`.p8`)** (Project settings → Cloud
  Messaging) — without it FCM answers `THIRD_PARTY_AUTH_ERROR`; the `.p8` key is not uploaded to RevBack;
- the "In-app chat" («Чат в приложении») channel in the RevBack dashboard holds a service account of your
  Firebase project with the `cloudmessaging.messages.create` permission (the "Firebase key" («Ключ Firebase»)
  row in the channel settings).

`try await RevbackChat.shared.sendTestPush()` checks delivery to the current device — the outcome is a
`TestPushResult` case (`Accepted`, `Rejected` with a `TestPushRejection` reason, `TooManyRequests`,
`PushUnavailable`, `Failed`); the test can be repeated at most once a minute. `RevbackChat.shared.debugInfo`
(`nil` until `configure`) and `RevbackChat.shared.setTokenSyncListener { … }` report how the integration is
doing. The table of test outcomes is on the documentation page.

## Notification permission

The SDK neither requests the notification permission nor calls `registerForRemoteNotifications()` — your
app does that, as it does for its own pushes. A support reply does not come instantly, and a push is the only
way to learn about it, so a good moment to ask is right after the user has sent their first message in the
chat:

- send the message first, without holding it back, then show a short explanation on top of the chat
  (for example, "We'll let you know when support replies") with a single button that opens the system prompt;
- show it only if the permission has not been granted yet; if the user declined earlier, the system prompt
  will not appear again — the button should lead to Settings;
- once the user has declined, do not ask again with every message.

The first sent message is visible in the feed stream (see "Observing data from Swift"): your new message
appears in `conversation.messages` at once with status `MessageStatus.Sending`. To show the explanation on top
of the ready-made screen, present the chat yourself — `present(RevbackChatViewController(onClose: { … }), animated: true)` —
and present your own screen above it with the `.overFullScreen` style. With a full-screen presentation the chat
screen gets `viewDidDisappear`, considers itself closed and closes the conversation. A chat presented this way
is invisible to `RevbackChatUI.isPresented` and `RevbackChatUI.dismiss()` — close it yourself.

## User identity and logout

`identify` links a visitor to a user of your app. The token is issued by **your backend**: a JWT
signed with HS256, the key is the channel secret from the dashboard as is, and the lifetime is up to
you (1–5 minutes is recommended). The token carries the user id (`sub`); everything else is optional.
One token, one sign-in: issue a new token with a random `jti` for every SDK request and do not cache
it (replaying a token from another session gets `410`). Optional claims use OpenID Connect names
(identify token format v2): `name`, `email`, `phone_number` — E.164 (`+79001234567`; the server strips
spaces, dashes and parentheses itself; it ignores the former `phone` claim — rename it);
`email_verified`, `phone_number_verified` — whether your backend has verified the email and phone;
`amr`, `idp`, `auth_time` — how and when the user signed in; `ids` — your own user identifiers as a
"key → string" object (e.g. `{"crm_id": "…"}`; they reach the assistant's tools and are never
shown to the model); `attributes` — signed attributes. A malformed field does not fail the sign-in:
the server simply does not store it and `identify` succeeds without an error — a `422` happens only
for token security problems. The SDK does not parse the token, so moving to v2 is a change on your
backend only. The exact rules, ready-made snippets for Node, PHP, Python and Go, and a test vector are
in the description of the identify operation in the RevBack OpenAPI
(`https://api.revback.ai/v1/widget/openapi.json`). The app asks its backend for a token and hands it
to the SDK as is:

```swift
import Foundation
import RevbackChatCore

/// IdentityTokenProvider is an @objc protocol, not a closure: it needs an NSObject subclass
final class RevbackTokenProvider: NSObject, IdentityTokenProvider {
    private let fetchToken: (@escaping (String?) -> Void) -> Void

    /// fetchToken asks your backend for a token; it calls back once, nil means no token
    init(fetchToken: @escaping (@escaping (String?) -> Void) -> Void) {
        self.fetchToken = fetchToken
    }

    // the SDK calls this off the main thread; onResult may be called from any thread, the first call wins
    func provideIdentityToken(onResult: @escaping (String?) -> Void) {
        fetchToken(onResult)
    }
}

// on every process start, after configure (see below for why)
func identifySupportUser(fetchToken: @escaping (@escaping (String?) -> Void) -> Void) {
    RevbackChat.shared.identify(provider: RevbackTokenProvider(fetchToken: fetchToken))
}
```

Request the token from your backend with a separate HTTP client — one without the shared `401` handler that
refreshes the session, retries the request or signs the user out:

- a failure of this endpoint simply means "no token": hand `nil` to the SDK and the chat stays anonymous.
  Through a shared handler, a spurious `401` from this auxiliary endpoint would sign the user out, and an
  auto-refresh could replay the request under a different (guest) session;
- no retries are needed: the SDK asks for a fresh token itself when one has expired, and waits no longer than
  10 seconds for an answer;
- the user is not signed in — do not call the endpoint, answer `onResult(nil)` right away;
- the user signed out or changed while the request was in flight — do not hand over the token that arrived,
  return `nil`.

Identity verification is enabled per channel (`RevbackChat.shared.branding.value?.features.identify`) and it
is the service, not the SDK, that validates the token: if the channel has it switched off, or the
token is not accepted, the visitor stays anonymous and the reason arrives as
`TelemetryEvent.IdentifyFailed(reason)`; when the service rejects the token because of its contents,
the reason names the field, for example `aud/mismatch`. Install
`RevbackChat.shared.setTelemetryListener { … }` before your first `identify` and run the scenario against
your own backend before relying on it in production.

Call `identify` on **every** process start. The verified identity lives in the visitor's saved session (its
lifetime is set by the server) and is lost together with it — when the session expires or the server revokes
it. Every successful `identify` issues a new session, so a call at start-up keeps the session from running out.
The SDK waits no longer than 10 seconds for the provider, the first `onResult` call wins, and `onResult(nil)`
means the host declined and the identity stays as it was. If the token has expired in the meantime, the SDK
asks the provider for a new one once by itself.

If a verified user's session is gone (it expired, for example), the server no longer issues an anonymous
session under that visitor. The SDK then creates a new anonymous visitor — as on logout: the send queue and the
feed are wiped, unsent messages disappear from the feed, and each one produces the telemetry event
`TelemetryEvent.SendFailed(messageId, "identity_lost")`; the feed receives `ChatEvent.Reset`, followed by
`TelemetryEvent.IdentityLost`. The SDK sends the user's attributes to the new visitor by itself. If the user is
still signed in to your app, call `identify` again. The SDK has a single telemetry listener — keep your logging
in it as well:

```swift
import Foundation
import RevbackChatCore

func installSupportTelemetry(isSignedIn: @escaping () -> Bool, makeProvider: @escaping () -> IdentityTokenProvider) {
    RevbackChat.shared.setTelemetryListener { event in
        NSLog("RevBack: %@", String(describing: event))
        if event is TelemetryEvent.IdentityLost {
            DispatchQueue.main.async {
                if isSignedIn() { RevbackChat.shared.identify(provider: makeProvider()) }
            }
        }
    }
}
```

When the user logs out, call `RevbackChat.shared.reset()` (`async throws`): a new visitor, the push
subscription dropped and the previous conversation no longer reachable. If the chat screen is open at that
moment, closing or redrawing it is up to the host — react to `ChatEvent.Reset`, which arrives in
`conversation.events` (and in `RevbackChatDelegate.onEvent`). The ready-made `RevbackChatUI` screen receives
this event itself (it holds the delegate while shown — do not set your own `RevbackChatDelegate` next to it,
follow events through the `conversation.events` stream, see "Observing data from Swift") and clears its draft
and attachments on it; close the screen with `RevbackChatUI.dismiss()`. The logout runs to completion even if
the calling task is cancelled. If the app is killed in the middle of a logout, the SDK finishes wiping the
previous user's data on the next start — there is no need to call `reset()` again. Likewise, a verified identity
does not survive a reinstall of the app: the SDK resets it on the first launch by itself, and `identify` after
sign-in brings the user's conversation back; an anonymous guest continues the conversation (see "Keeping the
conversation on the device").

Order when the user changes: `try await reset()`, and only **after** it returns — `identify()` and
`setAttributes()` for the new user, from the same task. If you call them without waiting for the logout
(`Task { try await RevbackChat.shared.reset() }` followed immediately by `identify(…)`), the SDK assigns
them to the **previous** user: the logout discards them, the new visitor stays anonymous and without
attributes, and telemetry reports `TelemetryEvent.IdentifyFailed(reason: "logging_out")` /
`TelemetryEvent.AttributesFailed(reason: "logging_out")`. Calls that arrive while `reset()` is already running
wait for it to finish and go to the new visitor.

```swift
import Foundation
import RevbackChatCore
import RevbackChatUI

func switchSupportUser(to provider: IdentityTokenProvider, name: String) {
    Task {
        // a new visitor; cancelling the task does not stop the logout; the previous FCM token is re-announced by itself
        _ = try? await RevbackChat.shared.reset()
        RevbackChat.shared.identify(provider: provider)            // the new user
        RevbackChat.shared.setAttributes(attributes: ["name": name])
    }
}

func logOutOfSupport() {
    // the ready-made screen opened with present(over:) — together with any sheets on top; not shown — a no-op
    RevbackChatUI.dismiss()
    Task { _ = try? await RevbackChat.shared.reset() }
}
```

### User attributes

`RevbackChat.shared.setAttributes(attributes:)` passes data about the user to the operator and the assistant.
In Swift the parameter is `[String: Any]`, but a value may only be a `String` or `NSNull()`. To remove a key, pass
`NSNull()` (that is `null` in the core). **Any other value — a number, a `Bool`, a date, a nested dictionary — is
dropped by the SDK together with its key:** the compiler accepts such a call, and the SDK logs the dropped keys and
reports `TelemetryEvent.AttributesTruncated` (dropped keys are counted in `droppedKeys`); string values of the same
call are saved. Convert numbers and flags to strings yourself (`String(age)`). A call is merged into the
previous snapshot: keys missing from the call stay.

```swift
import Foundation
import RevbackChatCore

func updateSupportAttributes(plan: String) {
    RevbackChat.shared.setAttributes(attributes: [
        "plan": plan,            // add or update
        "promo": NSNull(),       // remove the key
    ])
}
```

- Limits apply to the whole snapshot: at most 32 keys (the first 32 in alphabetical order of their names stay),
  a key up to 64 bytes in UTF-8 (a longer one is dropped), a value up to 512 bytes (a longer one is cut at a
  character boundary). What was dropped or cut is reported by the telemetry event
  `TelemetryEvent.AttributesTruncated(droppedKeys, truncatedValues)`.
- If the server does not accept attributes (`branding.value?.features.attributes == false`), the SDK keeps the
  snapshot on the device, sends nothing and reports `TelemetryEvent.AttributesUnavailable`.
- Attributes belong to the visitor current at the moment of the call; when the user changes, call
  `setAttributes` after `reset()` (see above).

## Keeping the conversation on the device

By default the SDK keeps the feed and the send queue in a cache on disk: the feed is visible right away on a
cold start, and unsent messages survive a process restart. The cache lives in the app's `Application Support`
and is excluded from backups — the SDK sets the flag itself.

The identifiers and the session are kept in the Keychain rather than in the cache, and deleting the app does
not erase them: after a reinstall an anonymous guest continues the conversation. A verified identity is reset
after a reinstall: if the user went through `identify` before the app was deleted, the SDK resets that session and
the data on the device on the first launch by itself, as `reset()` does (no `ChatEvent.Reset` is delivered) — the
chat opens as a new anonymous visitor, and the customer's conversation is never handed to the next guest. It stays
on the server and comes back after `identify`. The app does not need to do anything. The SDK can recognise a
reinstall only in the main app (app extensions do not check) and only once the app's files and the Keychain can be
read — from the device's first unlock after it is switched on, including while the screen is locked. If the system
launches the app earlier (after a restart, before the first unlock), the decision waits for the next launch, and
until then the SDK does not open the visitor session in that process: the chat and the unread counter wait. If the
app was not reinstalled, the session opens as soon as the device is unlocked; if it was, on the next launch. An
encrypted device backup includes the visitor
id and the visitor's saved data (the unread counter, attributes, the channel's look) — on a new iPhone restored
from that backup the visitor is the same. The visitor's session (and the verified identity with it) and the
installation id are bound to the device (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and are not part of
the backup: on a new device the SDK starts a new session, and `identify` links the verified user again. All of
this is wiped by `reset()`: a new visitor, a new installation id, the session removed.

If the conversation must not stay on the device (banking, healthcare), turn this off:

```swift
import RevbackChatCore

func configureSupportWithoutHistoryOnDisk() {
    RevbackChat.shared.configure(
        config: RevbackChatConfig(widgetKey: "wk_…").withPersistHistory(persistHistory: false)
    )
}
```

- The feed and the send queue live in process memory only: history comes from the server on every
  start, and unsent messages are lost on a process restart.
- The visitor id and the verified identity, the unread counter, user attributes and the channel's look
  stay on the device — without them the same conversation could not continue.
- The ready-made screen keeps no copies of picked files: it shows your own attachment by downloading it
  from the server (see "Known limitations").
- A custom screen decides for itself where to keep the files it passes to `FileSource.withLocalUri`: the
  SDK does not delete them.

When the user logs out (`reset()`) or another user signs in, the SDK deletes the `revback-chat` directories in
the app's `Caches` and `tmp` with every file the ready-made screen stored there — whatever `persistHistory` is
set to. With storage turned off, these directories are also cleared every time the SDK starts.

`persistHistory` is taken from the `configure` that built the module: a repeated `configure` with the same key
is a no-op and does not change it. A new setting takes effect with `configure` under another key or on the next
process start. The current setting can be read back: `RevbackChat.shared.config?.persistHistory` (`config` is
`nil` until `configure`).

## Apps built with Kotlin Multiplatform

The SDK is Kotlin Multiplatform too, and on iOS it ships as its own Kotlin framework, `RevbackChatCore`. If
your app already has a Kotlin framework of its own (a shared module), the app ends up with two. They build and
run together, but independently of each other. Hence three rules:

- **On iOS, call the SDK from Swift only.** Do not add `ai.revback:revback-chat-core` to the iOS part of your
  shared module: the core would then end up inside your framework as a separate copy, while the ready-made
  `RevbackChatUI` screen works with the core from `RevbackChatCore`. If shared code needs the chat, declare an
  interface in it, implement it in Swift on top of the SDK and pass the implementation to the shared module at
  start-up. On Android the same implementation can be written in Kotlin in the app module.
- **Do not import both frameworks into one Swift file.** They contain service types with the same names
  (`KotlinInt`, `KotlinBoolean`, coroutine types and others), and in a file with both imports those names are
  ambiguous. Keep SDK calls in files of their own, and pass only Swift types between them and the code that
  uses your framework — through a Swift protocol, for example.
- **In the interface exposed to Swift, avoid types that turn into Kotlin wrappers**: `Int?`, lambdas with
  `Int` parameters and the like. In Swift they become `KotlinInt`, a name present in both frameworks. For
  callbacks, use a `fun interface` with primitive parameters.

Your framework's Ktor and the Ktor inside the SDK do not clash: the SDK's networking is compiled into
`RevbackChatCore`. Running side by side has been checked with an app framework on Kotlin 2.2.21 — the same
version the SDK uses.

## Privacy manifest

The SDK ships its own privacy manifest (`PrivacyInfo.xcprivacy`), which Xcode takes into account in your
app's Privacy Report (Product → Archive → Generate Privacy Report). What it declares:

- **No tracking** (`NSPrivacyTracking = false`, no tracking domains).
- **No required-reason APIs** (`NSPrivacyAccessedAPITypes` is empty): the visitor, installation and session
  identifiers are kept in the Keychain, not in `UserDefaults`; the SDK neither reads nor writes file dates —
  the ready-made screen's cap on attachment copies tells a copy's age from its file name.
- **Collected data** goes only to the RevBack server to make the chat work (`App Functionality`), not
  for tracking, and is linked to the user (after `identify` — to your user):
  - message text — `Customer Support`;
  - photos and videos in attachments — `Photos or Videos`, other files — `Other User Content`;
  - the visitor and installation identifiers assigned by the SDK — `User ID`;
  - name, email, phone — `Name`, `Email Address`, `Phone Number`, your own user identifiers
    (the `ids` claim) — `User ID`: they live in the identity token issued by your backend, and the SDK
    passes that token to the server as is, without parsing it. The email and phone verification flags and
    the sign-in details (`amr`, `idp`, `auth_time`) are service data of the same identity; Apple has no
    separate data type for them;
  - the FCM push token — `Device ID`.

**What you declare yourself.** The attributes your app passes through `setAttributes` are arbitrary,
and the SDK's manifest cannot cover them: if they include data from Apple's list (purchase history or
location, for example), declare it in your own app's manifest and App Privacy questionnaire.

With Swift Package Manager there is nothing to do: the manifest arrives as a package resource with either
product. **When you add the XCFramework by hand** (without SPM), the manifest sits in every slice
(`RevbackChatCore.framework/PrivacyInfo.xcprivacy`) and reaches the app only if the framework is
embedded (**Embed & Sign** or **Embed Without Signing**); with "Do Not Embed", move `PrivacyInfo.xcprivacy`
into your app's resources.

## Capabilities your channel controls

Some capabilities depend on your channel settings and on the service version: identity verification,
attachments, the typing indicator, the unread counter, attributes, message edits and deletions. The current
set arrives as the `RevbackChat.shared.branding` stream: subscribe to it (`for await`) or read
`RevbackChat.shared.branding.value?.features`. The SDK raises a telemetry event for two switched-off
capabilities: `identify` with identity verification off — `TelemetryEvent.IdentifyFailed("identify_disabled")`,
and attributes the server does not accept — `TelemetryEvent.AttributesUnavailable`. For the rest (attachments,
typing, the unread counter, edits and deletions) the SDK reports nothing separately — check `features`
yourself: with `typing == false`, for example, `setTyping` sends nothing. The same object carries the channel's
look (`title`, `primaryColor`, `logoUrl`, `welcomeText`) and the attachment size cap (`maxFileSize`).

## Compatibility and versioning

Versions follow SemVer. While the version is `0.x`, breaking changes are possible in a minor release
(`0.1` → `0.2`) and are described in the release notes (`CHANGELOG.md` in this repository and the GitHub
Release text); patch releases (`0.1.0` → `0.1.1`) break nothing. The rules below apply from `0.1.0` on.

How the API is shaped so that updates do not break your build:

- **Only the SDK creates SDK models.** `Message`, `Attachment`, `Branding`, `Features` and the other data
  models have no initializer in Swift, so new fields arrive without breaking changes. New fields are only
  ever appended at the end; read the properties by name.
- **Tests and previews of your own screen.** The models for them are built by the core's fixtures — plain
  classes in Swift: `let f = MessageFixture()`, set the properties and call `f.build()`. Next to it are
  `AttachmentFixture`, `SenderFixture`, `FeaturesFixture`, `BrandingFixture`, `TypingStateFixture`,
  `UnreadCountFixture`; states and events carrying data come from `StateFixtures.shared` (for example
  `StateFixtures.shared.messageFailed(reason: "net")`). The exception is `SenderFixture`: it has no
  `build()`, and the sender case is picked with `agent()`, `assistant()` or `other(kind:)`. Do not use the
  fixtures in production code. The fixtures (the core's `ai.revback.chat.testing` package) are not production
  API: the rules of this section do not cover them, and they may change in regular releases, not only in
  breaking ones.
- **Configuration and files.** The initializers of `RevbackChatConfig` and `FileSource` take only what is
  mandatory, and `MediaPreview` has nothing mandatory (`MediaPreview()`); everything else is set through a
  `with…` chain: `RevbackChatConfig(widgetKey: "wk_…").withPersistHistory(persistHistory: false)`,
  `FileSource(fileName: name, mime: mime, bytes: bytes).withLocalUri(localUri: uri)`,
  `MediaPreview().withSize(width: 1080, height: 1920)`. A new setting means a
  new `with…` method, and your existing code stays as it is. `bytes` here is the core's `KotlinByteArray`,
  not `Data`: the ready-made screen converts `Data` into it byte by byte (`KotlinByteArray(size:)` with a
  closure) and does so off the main thread — a custom screen should do the same.
- **States and events** (`ConnectionState`, `ConversationState`, `MessageStatus`, `Sender`, `ChatEvent`,
  `UploadResult`, `PushAction`, `TelemetryEvent`, `TestPushResult`, `TestPushRejection`) are deliberately
  NOT `sealed`: the set of cases grows, and a new case must not break your build. In Swift they are plain
  classes — there are no Swift enums and no `onEnum(of:)` for them; check them with `is`/`as?`, and an
  "otherwise" branch is always there. Check a case by type (`is ConnectionState.Connected`) rather than by
  equality: a case without data may gain data later. Cases carrying data are created by the SDK alone; in
  tests use `StateFixtures.shared`.
- **Unknown server values are not lost.** `AttachmentKind` is not an enum: an unknown kind has
  `isKnown == false` while `wire` holds the raw server string; the known kinds are companion properties:
  `AttachmentKind.companion.Photo`. The server may already send an attachment kind outside the eight named
  ones (`unknown`, for example) — it arrives with `isKnown == false`. A sender of an unknown kind arrives as
  `Sender.Other` with the properties `kind`, `name`, `avatarUrl`.
- **A message of an unexpected shape does not break the feed.** If the content of a message arrives in a
  shape this version of the SDK does not know, the message still reaches the feed — as someone else's
  live message (`isMine == false`, `deleted == false`) with no text and no attachments: render a
  placeholder such as "Could not display the message" for it. A message of your own in the same shape is a
  rejected send instead: it has its own `MessageStatus.Failed` and needs no placeholder. An attachment
  that failed to parse arrives as an `Attachment` of kind `AttachmentKind.Other` with no file name, MIME
  type or links — its position in the list and the indexes of the neighbouring attachments are preserved;
  label it "This file type is not supported". The SDK's built-in screen does both by itself.
- **A screen embedded before setup comes alive on its own.** `conversation.open()` called BEFORE
  `configure` (the chat screen sits in a tab, say, while the app fetches the channel key over the network)
  is not lost: the SDK remembers it and opens the conversation as soon as the module is assembled — and
  reopens it on the new module in the same way when the key changes on a live process. Before setup the
  conversation answers `ConversationState.Failed("not_configured")` — render a "chat unavailable" screen
  without an input field for that state. The matching `close()` when the screen goes away is mandatory:
  while the conversation is open the SDK shows no push banners about new messages. The SDK's built-in
  screen does all of this by itself.
- **The enum** `UnreadSource`: no values are added to it in compatible versions.
- **`PushProvider` is not an enum** but an open set, like `AttachmentKind`: the known providers are
  companion properties (`PushProvider.companion.Fcm`, `Apns`, `Rustore`, `Hms`), and new ones arrive as new
  constants in compatible versions. Compare with equality (`==`), not with an exhaustive `switch`. A provider
  your SDK version does not know yet is set by its server string: `PushProvider.companion.fromWire(value: "…")`. An
  empty string yields `Fcm` — do not pass an unchecked value from your own config into `fromWire`.
- **`RevbackChatDelegate`:** no methods are added to it — in Swift every method of a protocol is
  required. New events arrive through `onEvent` or through dedicated listeners.
- **`Conversation` and `Upload` are implemented by the SDK only.** New methods may appear in them; in
  tests wrap them in a protocol of your own instead of implementing them directly.
- **Functions:** existing public functions never gain new parameters — Swift has no default values for them
  at all. A new capability means a new function or a new overload.
- **The cache's service types are not API.** The core's header exposes the conversation cache database types
  (`ChatDatabase`, `ChatDatabaseQueries`, `Messages`, `Outbox`, `Meta`, `Attachments` and others) and SQLDelight
  types prefixed with `Runtime` (`RuntimeSqlDriver`, `RuntimeTransacter` and others). They are internal, are
  not part of the SDK API and may change in any version — do not use them in your code.

## Known limitations

- **While shown, the ready-made screen holds the single `RevbackChatDelegate`** and releases it on close: a
  delegate your app sets next to the screen gets displaced. Next to the ready-made screen, follow the data
  through streams (`for await`) — the screen does not take those.
- **`RevbackChatUI.isPresented` and `RevbackChatUI.dismiss()` know only the screen opened with
  `RevbackChatUI.present(over:)`.** A screen you presented yourself (`RevbackChatViewController`,
  `RevbackChatView`) is yours to close — through the controller that presented it, so that any sheets open on
  top close along with it.
- **The minimum is iOS 15**, but the ready-made screen has not yet been checked on iOS 15 and 16: it has been
  checked on current iOS versions.
- **The ready-made screen has been checked on iPhone in portrait orientation**; it has not been checked on
  iPad or in landscape.
- **The screen does not follow the system text size** (Dynamic Type): text sizes are fixed.
- **The keyboard cannot be dismissed by swiping the feed or tapping outside the field**: it stays open until
  the screen closes.
- **The screen has no dark theme.** The ready-made screen's palette is fixed to the light one, matching the
  RevBack website widget; the SDK has no theme setting either.
- **Your own attachment the server has not confirmed yet is not shown without a local copy.** The screen
  renders your own attachment from a copy of the file in the app cache, and without one (the system cleared
  the cache, the app was reinstalled, the message was sent from another device, `persistHistory = false`) it
  downloads the file from the server. Until the server confirms the send (states `Sending` and `Failed`)
  there is nothing to download: such a message shows only the file name without a copy. Once the send is
  confirmed, the picture and the video cover appear by themselves.
- **Sets of cases gain new members** between versions: the public state and event hierarchies are not
  `sealed`, so checking them with `is`/`as?` always keeps an "otherwise" branch — the full list of the
  hierarchies and the rules are in "Compatibility and versioning".
- SDK callbacks (`RevbackChatDelegate`, listeners) arrive from the core's coroutines, **not on the main
  thread**: hopping to the main thread is up to you.

## Documentation and Android

- Integration documentation: <https://revback.ai/docs/mobile-app>
- The Android version: [revback-ai/revback-chat-android](https://github.com/revback-ai/revback-chat-android)

## Reporting a problem

Open an issue in this repository. It helps to attach:

- the SDK version (`RevbackChat.shared.debugInfo?.sdkVersion`), the iOS version and the device model;
- reproduction steps and the behaviour you expected;
- the `RevbackChat.shared.setTelemetryListener { … }` events captured while the problem happened.

**Do not post** your channel key, push token or visitor id in an issue — they are all in
`RevbackChat.shared.debugInfo`; if they are needed for the investigation, send them through the RevBack
dashboard.

Questions about the channel, the plan or the account belong in the dashboard at <https://revback.ai>,
not here.

## About this repository

This repository is the Swift Package Manager distribution: `Package.swift`, the Swift sources of the
ready-made screen (`Sources/`) and the documents. The core arrives as a binary `RevbackChatCore.xcframework`
from the GitHub Release of the matching version; its (Kotlin) sources live in the Android version's
repository. SDK development happens in a private monorepo, and its content is synced here with every new
release.

**We do not merge pull requests here**: the branch is overwritten by that sync, so any commit on top of it
would disappear with the next release. Found a bug, or wrote a patch? Open an issue and attach the diff (or a
link to your branch): we carry the change into the internal repository and reply in the issue telling you
which version it lands in.

## License

Apache License 2.0 — see [LICENSE](./LICENSE).

Third-party components compiled into `RevbackChatCore.xcframework`, and their licenses, are listed in
[THIRD-PARTY-NOTICES](./THIRD-PARTY-NOTICES). If you ship an app, carry their contents over to your app's
licenses screen along with your own notices: our code reaches your users inside your build.

The license covers the SDK code. Access to the RevBack service (channel, operators, conversation history)
is governed by your plan.
