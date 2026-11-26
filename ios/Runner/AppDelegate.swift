import AVFoundation
import MediaPlayer
import Flutter
import Security
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    SecureKeyBridge.register(messenger: messenger)
    FanqieLoginBridge.register(messenger: messenger)
    IosFilesBridge.register(messenger: messenger)
    SystemTtsBridge.register(messenger: messenger)
    AudioSessionBridge.register(messenger: messenger)
  }
}

/// 本机密钥库（iOS）：Keychain 通用密码项。
///
/// 取代 `flutter_secure_storage`（它在 Windows 端把 `win32` 钉在 5.x，挡住了
/// `wakelock_plus` / `package_info_plus` 的 Built-in Kotlin 版本，见 #205）。
///
/// - 每个条目 = 一个 account，service 固定为 `<bundle id>.secure_keys`；
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：后台朗读/播放需要
///   设备首次解锁后即可读取，且绝不随备份恢复到另一台设备；
/// - 查询失败必须区分 `errSecItemNotFound`（真的没有）与其他错误：后者抛给
///   Dart，让 `SecureKeyProvider` 失败关闭，而不是当成“没有密钥”另建一把。
final class SecureKeyBridge {
  private static let service = "\(Bundle.main.bundleIdentifier ?? "com.fanrenxiuxianguanyingchuan").secure_keys"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "fqapp/secure_keys", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard let arguments = call.arguments as? [String: Any],
        let key = arguments["key"] as? String,
        !key.isEmpty
      else {
        result(FlutterError(code: "BAD_ARGUMENT", message: "缺少 key", details: nil))
        return
      }
      do {
        switch call.method {
        case "read":
          result(try read(key))
        case "write":
          guard let value = arguments["value"] as? String else {
            result(FlutterError(code: "BAD_ARGUMENT", message: "缺少 value", details: nil))
            return
          }
          try write(key, value)
          result(nil)
        case "delete":
          try delete(key)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(code: "KEYCHAIN", message: error.localizedDescription, details: nil))
      }
    }
  }

  private static func query(_ key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
  }

  private static func read(_ key: String) throws -> String? {
    var lookup = query(key)
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError(status) }
    guard let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func write(_ key: String, _ value: String) throws {
    let data = Data(value.utf8)
    let update = [kSecValueData as String: data]
    let updated = SecItemUpdate(query(key) as CFDictionary, update as CFDictionary)
    if updated == errSecSuccess { return }
    if updated != errSecItemNotFound { throw KeychainError(updated) }
    var insert = query(key)
    insert[kSecValueData as String] = data
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let added = SecItemAdd(insert as CFDictionary, nil)
    guard added == errSecSuccess else { throw KeychainError(added) }
  }

  private static func delete(_ key: String) throws {
    let status = SecItemDelete(query(key) as CFDictionary)
    if status == errSecSuccess || status == errSecItemNotFound { return }
    throw KeychainError(status)
  }
}

struct KeychainError: LocalizedError {
  init(_ status: OSStatus) {
    self.status = status
  }

  let status: OSStatus

  var errorDescription: String? {
    SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 错误 \(status)"
  }
}

// MARK: - 番茄登录窗口(iOS)

/// 番茄书架采集的登录入口。
///
/// Android 有原生登录页,Windows/Linux 用 `webview_windows`;iOS 上两者都没有,
/// 这里用 `WKWebView` 打开官方登录页,用户完成登录后点「读取书架」,把
/// `fanqienovel.com` 的 cookie 交回 Dart(`FanqieLibraryCaptureService.collect`
/// 拿到 cookie 后由 Rust/Dart 侧直接请求采集接口)。
///
/// 与桌面版同一套约束:只允许官方域名(离开就拦下并提示),读取时要求存在
/// `sessionid` / `sessionid_ss` / `sid_tt` 之一且非空,整串不超过 12 KB。
///
/// 回调恰好一次:`login` 的 result 由实例持有,按钮取消、下滑关闭、`cancelLogin`
/// 与读取成功都走同一个 [finish]。`cancelLogin` 不丢弃持有的 result(否则 Dart
/// 的 `await login()` 会永远挂起),而是用 nil 把它正常收口。
final class FanqieLoginBridge: NSObject {
  private static let allowedHosts = [
    "fanqienovel.com", "snssdk.com", "bytedance.com", "zijieapi.com",
  ]
  private static let loginURL = URL(string: "https://fanqienovel.com/main/writer/login")!
  private static var active: FanqieLoginBridge?

  private let result: FlutterResult
  private let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
  private let controller = UIViewController()
  private var finished = false

  private init(result: @escaping FlutterResult) {
    self.result = result
    super.init()
  }

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "fqapp/fanqie_account", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      // active 状态与所有 UIKit 操作都在主线程上串行处理,避免并发双开。
      DispatchQueue.main.async {
        switch call.method {
        case "login":
          let arguments = call.arguments as? [String: Any] ?? [:]
          login(dark: arguments["dark"] as? Bool ?? false, result: result)
        case "cancelLogin":
          active?.finish(nil)
          result(nil)
        case "clearSession":
          clearSession { result(nil) }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  private static func login(dark: Bool, result: @escaping FlutterResult) {
    guard active == nil else {
      result(FlutterError(code: "BUSY", message: "登录窗口已打开", details: nil))
      return
    }
    guard let host = topViewController() else {
      result(FlutterError(code: "NO_WINDOW", message: "窗口尚未就绪", details: nil))
      return
    }
    let bridge = FanqieLoginBridge(result: result)
    active = bridge
    bridge.present(from: host, dark: dark)
  }

  private func present(from host: UIViewController, dark: Bool) {
    controller.view.backgroundColor = .systemBackground
    controller.title = "番茄登录"
    controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: "取消", style: .plain, target: self, action: #selector(cancelTapped))
    controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "读取书架", style: .done, target: self, action: #selector(readTapped))

    webView.translatesAutoresizingMaskIntoConstraints = false
    webView.navigationDelegate = self
    webView.allowsBackForwardNavigationGestures = false
    controller.view.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor),
      webView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
    ])
    if dark {
      controller.overrideUserInterfaceStyle = .dark
      webView.overrideUserInterfaceStyle = .dark
    }
    let navigation = UINavigationController(rootViewController: controller)
    navigation.modalPresentationStyle = .pageSheet
    host.present(navigation, animated: true)
    // 下滑关闭(交互式)也必须把待决的 result 收口,否则 Dart 会一直等。
    // presentationController 在 present 返回后才存在,不能在 present 之前取。
    navigation.presentationController?.delegate = self
    webView.load(URLRequest(url: Self.loginURL))
  }

  @objc private func cancelTapped() {
    finish(nil)
  }

  @objc private func readTapped() {
    // 先等一次 JS 执行,确保 cookie 已写进 WKWebsiteDataStore 再读取。
    webView.evaluateJavaScript("document.title") { [weak self] _, _ in
      self?.readCookies()
    }
  }

  private func readCookies() {
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
      guard let self else { return }
      // 用户在读取途中点了取消:不再弹提示,也不再交回结果。
      guard !self.finished else { return }
      let scoped = cookies.filter { cookie in
        let domain = cookie.domain.hasPrefix(".")
          ? String(cookie.domain.dropFirst()) : cookie.domain
        return domain == "fanqienovel.com" || domain.hasSuffix(".fanqienovel.com")
      }
      let names = ["sessionid", "sessionid_ss", "sid_tt"]
      let hasLogin = scoped.contains { cookie in
        names.contains(cookie.name) && !cookie.value.isEmpty
      }
      guard hasLogin else {
        DispatchQueue.main.async { self.alert("尚未取得登录态", "请先在官方页面完成登录与验证,再点「读取书架」。") }
        return
      }
      let value = scoped.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      guard value.utf8.count <= 12 * 1024 else {
        DispatchQueue.main.async { self.alert("登录态过大", "读取失败,请重试。") }
        return
      }
      DispatchQueue.main.async { self.finish(value) }
    }
  }

  private func alert(_ title: String, _ message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "好", style: .default))
    controller.present(alert, animated: true)
  }

  /// 关闭窗口并把 result 恰好交回一次;[value] 为 nil 表示取消。
  ///
  /// [active] 要等关闭动画结束再清:若在 dismiss 还在跑时就放行下一次 login,
  /// 新的 present 会落在还没消失的旧窗口上,UIKit 可能拒绝,Dart 的 await 悬空。
  private func finish(_ value: String?) {
    guard !finished else { return }
    finished = true
    let complete = {
      if Self.active === self { Self.active = nil }
      self.result(value)
    }
    if let navigation = controller.navigationController,
      navigation.presentingViewController != nil
    {
      navigation.dismiss(animated: true, completion: complete)
    } else {
      // 交互式下滑已经关掉了窗口:直接交回结果,不再重复 dismiss。
      complete()
    }
  }

  private static func clearSession(completion: @escaping () -> Void) {
    let store = WKWebsiteDataStore.default()
    store.httpCookieStore.getAllCookies { cookies in
      let targets = cookies.filter { cookie in
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return domain == "fanqienovel.com" || domain.hasSuffix(".fanqienovel.com")
      }
      let group = DispatchGroup()
      for cookie in targets {
        group.enter()
        store.httpCookieStore.delete(cookie) { group.leave() }
      }
      group.notify(queue: .main) { completion() }
    }
  }

  static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
      ?? scene?.windows.first?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}

extension FanqieLoginBridge: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    if url.scheme != "https" || url.user != nil || url.password != nil {
      decisionHandler(.cancel)
      return
    }
    let host = url.host ?? ""
    let allowed = FanqieLoginBridge.allowedHosts.contains { entry in
      host == entry || host.hasSuffix(".\(entry)")
    }
    if allowed {
      decisionHandler(.allow)
    } else {
      decisionHandler(.cancel)
      alert("已拦截跳转", "请留在番茄官方登录页面完成登录。")
    }
  }
}

extension FanqieLoginBridge: UIAdaptivePresentationControllerDelegate {
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    // 下滑关闭:login 必须收到 nil,而不是无限等待。
    finish(nil)
  }
}

// MARK: - 文件导出(iOS 分享面板)

/// `saveBackup` / `exportFanqieCapture` / `saveText` 在桌面上弹「另存为」,
/// iOS 没有等价的选择器,改为写临时文件再弹系统分享面板(存储到「文件」、
/// 发出去、AirDrop 都行)。Dart 侧拿到的是应用私有临时目录里的路径。
final class IosFilesBridge {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "fqapp/ios_files", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "saveFile" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let arguments = call.arguments as? [String: Any],
        let name = arguments["name"] as? String,
        let data = arguments["bytes"] as? FlutterStandardTypedData
      else {
        result(FlutterError(code: "BAD_ARGUMENT", message: "缺少文件内容", details: nil))
        return
      }
      presentShare(name: name, data: data.data, result: result)
    }
  }

  private static func presentShare(
    name: String, data: Data, result: @escaping FlutterResult
  ) {
    // 每次导出用独立子目录:同名的两次导出不会互相覆盖尚未分享完的文件。
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fqapp-share", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(sanitize(name))
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      result(FlutterError(code: "WRITE", message: error.localizedDescription, details: nil))
      return
    }
    DispatchQueue.main.async {
      guard let host = FanqieLoginBridge.topViewController() else {
        result(FlutterError(code: "NO_WINDOW", message: "窗口尚未就绪", details: nil))
        return
      }
      let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      if let popover = activity.popoverPresentationController,
        UIDevice.current.userInterfaceIdiom == .pad
      {
        popover.sourceView = host.view
        popover.sourceRect = CGRect(
          x: host.view.bounds.midX, y: host.view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
      }
      // 分享面板的完成回调:Dart 侧约定「返回 nil = 取消」(见
      // desktop_platform.dart 的 _save)。取消要回 nil、失败要回错误,只有真正
      // 完成才把临时文件路径交回去——原实现无视完成标志,取消也报成功。
      var reported = false
      activity.completionWithItemsHandler = { _, completed, _, error in
        guard !reported else { return }
        reported = true
        if let error {
          result(FlutterError(code: "SHARE", message: error.localizedDescription, details: nil))
        } else if completed {
          result(url.path)
        } else {
          result(nil)
        }
      }
      host.present(activity, animated: true)
    }
  }

  private static func sanitize(_ name: String) -> String {
    let cleaned = name.replacingOccurrences(
      of: "[\\\\/:*?\"<>|]", with: "_", options: .regularExpression)
    let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "fqapp-export" : trimmed
  }
}

// MARK: - 系统朗读

final class SystemTtsBridge: NSObject, FlutterStreamHandler, AVSpeechSynthesizerDelegate {
  private static var instance: SystemTtsBridge?
  private lazy var synthesizer: AVSpeechSynthesizer = {
    let synthesizer = AVSpeechSynthesizer()
    synthesizer.delegate = self
    synthesizer.usesApplicationAudioSession = true
    return synthesizer
  }()
  private var sink: FlutterEventSink?
  private var utterances: [ObjectIdentifier: String] = [:]
  private var voice: AVSpeechSynthesisVoice?
  private var rate = AVSpeechUtteranceDefaultSpeechRate
  private var volume: Float = 1

  static func register(messenger: FlutterBinaryMessenger) {
    let bridge = SystemTtsBridge()
    instance = bridge
    let events = FlutterEventChannel(name: "fqapp/system_tts_events", binaryMessenger: messenger)
    events.setStreamHandler(bridge)
    let methods = FlutterMethodChannel(name: "fqapp/system_tts", binaryMessenger: messenger)
    methods.setMethodCallHandler { call, result in bridge.handle(call, result: result) }
  }

  private func stop() {
    // Clear identities before cancellation: late delegate callbacks belong to old speech.
    utterances.removeAll()
    synthesizer.stopSpeaking(at: .immediate)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "engines":
      let voices: [[String: String]] = AVSpeechSynthesisVoice.speechVoices().compactMap { voice in
        guard let data = try? JSONSerialization.data(withJSONObject: ["name": voice.name, "locale": voice.language]),
              let package = String(data: data, encoding: .utf8) else { return nil }
        return ["package": package, "label": "\(voice.name) (\(voice.language))"]
      }
      result(["defaultEngine": "ios", "engines": [["package": "ios", "label": "系统默认语音"]] + voices])
    case "initialize":
      stop()
      if let engine = args["engine"] as? String, engine.hasPrefix("{"),
         let data = engine.data(using: .utf8),
         let selection = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
        voice = AVSpeechSynthesisVoice.speechVoices().first {
          $0.name == selection["name"] && $0.language == selection["locale"]
        }
      } else {
        voice = AVSpeechSynthesisVoice(language: "zh-CN")
      }
      guard voice != nil else {
        result(FlutterError(code: "tts_failed", message: "系统语音不可用，请在设置中安装中文语音", details: nil))
        return
      }
      let requestedRate = (args["rate"] as? NSNumber)?.floatValue ?? 1
      rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, requestedRate * 0.5))
      result(300)
    case "speak":
      guard let text = args["text"] as? String, let id = args["id"] as? String,
            !text.isEmpty, !id.isEmpty, let voice else {
        result(FlutterError(code: "tts_failed", message: "缺少朗读内容或系统语音", details: nil))
        return
      }
      if args["queue"] as? Bool != true { stop() }
      let utterance = AVSpeechUtterance(string: text)
      utterance.voice = voice
      utterance.rate = rate
      utterance.volume = volume
      utterances[ObjectIdentifier(utterance)] = id
      synthesizer.speak(utterance)
      result(nil)
    case "setVolume":
      volume = min(1, max(0, (args["volume"] as? NSNumber)?.floatValue ?? 1))
      result(nil)
    case "pause", "stop", "shutdown":
      stop()
      result(nil)
    case "settings":
      result(FlutterError(code: "unsupported_platform", message: "请在「设置 › 辅助功能 › 朗读内容」里调整系统语音", details: nil))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    guard let id = utterances[ObjectIdentifier(utterance)] else { return }
    sink?(["type": "start", "id": id])
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
    guard let id = utterances[ObjectIdentifier(utterance)] else { return }
    sink?(["type": "range", "id": id, "start": range.location, "end": NSMaxRange(range)])
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    guard let id = utterances.removeValue(forKey: ObjectIdentifier(utterance)) else { return }
    sink?(["type": "done", "id": id])
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    guard let id = utterances.removeValue(forKey: ObjectIdentifier(utterance)) else { return }
    sink?(["type": "error", "id": id])
  }
}

// MARK: - 锁屏 / 控制中心 / 耳机键（iOS 的媒体会话）
//
// 安卓侧由 `ListenKeepAliveService` 提供前台服务 + MediaSessionCompat；iOS 没有
// 等价物，必须自己组合 AVAudioSession（让音频在后台继续）+ MPNowPlayingInfoCenter
// （锁屏与任务切换器里的卡片）+ MPRemoteCommandCenter（锁屏按钮、耳机线控、
// 车机与蓝牙按键）。Dart 侧只在播放状态变化时推一次元数据，收到的远端命令
// 复用安卓那套 `_handleRemoteAction`，两端行为因此一致。
//
//   MethodChannel `fqapp/audio_session`        "update" / "stop"
//   EventChannel  `fqapp/audio_session/events` play / pause / playPause / next / prev / seek / stop
final class AudioSessionBridge: NSObject {
  private static let methodName = "fqapp/audio_session"
  private static let eventName = "fqapp/audio_session/events"

  private static var sink: FlutterEventSink?
  private static var owner: String?
  private static var sessionID = 0
  private static var intent = 0
  private static var interruptedSession: Int?
  private static var interrupted = false
  private static var configured = false
  private static var sessionActive = false
  private static var playing = false
  private static var backgroundWindows: [Int: UIBackgroundTaskIdentifier] = [:]
  private static var nextBackgroundWindow = 0
  private static var artwork: MPMediaItemArtwork?
  private static var artworkKey: String?
  private static var artworkTask: URLSessionDataTask?

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: methodName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
#if DEBUG
      case "debugSnapshot":
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        result([
          "owner": owner as Any? ?? NSNull(),
          "session": sessionID,
          "playing": playing,
          "title": info[MPMediaItemPropertyTitle] ?? NSNull(),
          "category": AVAudioSession.sharedInstance().category.rawValue,
          "mode": AVAudioSession.sharedInstance().mode.rawValue,
        ])
#endif
      case "claim":
        guard let args = call.arguments as? [String: Any],
              let newOwner = args["owner"] as? String,
              let newSession = args["session"] as? Int,
              newSession > sessionID else { result(nil); return }
        clearMedia()
        owner = newOwner
        sessionID = newSession
        intent = args["intent"] as? Int ?? 0
        result(nil)
      case "cancelInterruption":
        if let args = call.arguments as? [String: Any], matches(args),
           (args["intent"] as? Int ?? -1) >= intent {
          intent = args["intent"] as? Int ?? intent
          interruptedSession = nil
        }
        result(nil)
      case "prepare":
        if let args = call.arguments as? [String: Any], matches(args) {
          configureSession(args["mode"] as? String ?? "audio")
          activateSession()
        }
        result(nil)
      case "setPlaying":
        if let args = call.arguments as? [String: Any], matches(args),
           (args["intent"] as? Int ?? -1) >= intent {
          playing = args["playing"] as? Bool ?? false
          let center = MPNowPlayingInfoCenter.default()
          if center.nowPlayingInfo != nil {
            center.playbackState = playing ? .playing : .paused
            if !playing { center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = 0.0 }
          }
        }
        result(nil)
      case "releaseIfIdle":
        if let args = call.arguments as? [String: Any], owner == nil,
           args["session"] as? Int == sessionID {
          deactivateSession()
        }
        result(nil)
      case "update":
        guard let arguments = call.arguments as? [String: Any] else {
          result(FlutterError(code: "BAD_ARGUMENT", message: "缺少媒体元数据", details: nil))
          return
        }
        if matches(arguments), (arguments["intent"] as? Int ?? -1) >= intent {
          intent = arguments["intent"] as? Int ?? intent
          apply(arguments)
        }
        result(nil)
      case "beginBackgroundWindow":
        guard let args = call.arguments as? [String: Any], matches(args) else {
          result(nil)
          return
        }
        nextBackgroundWindow += 1
        let token = nextBackgroundWindow
        let task = UIApplication.shared.beginBackgroundTask(withName: "fqapp-chapter-switch") {
          endBackgroundWindow(token)
        }
        if task == .invalid { result(nil); return }
        backgroundWindows[token] = task
        result(token)
      case "endBackgroundWindow":
        if let args = call.arguments as? [String: Any], let token = args["token"] as? Int {
          endBackgroundWindow(token)
        }
        result(nil)
      case "stop":
        if let args = call.arguments as? [String: Any], matches(args) {
          teardown()
          owner = nil
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    FlutterEventChannel(name: eventName, binaryMessenger: messenger)
      .setStreamHandler(Events())
    // 冷启动不主动激活音频会话：没有音频在播时抢会话既没必要，在 CI 的
    // 无声模拟器上还可能拖慢启动。第一次 update 会按 mode 配置并激活。
    registerCommands()
    observeInterruptions()
  }

  private static func endBackgroundWindow(_ token: Int) {
    guard let task = backgroundWindows.removeValue(forKey: token) else { return }
    UIApplication.shared.endBackgroundTask(task)
  }

  private static func matches(_ arguments: [String: Any]) -> Bool {
    owner != nil && arguments["owner"] as? String == owner &&
      arguments["session"] as? Int == sessionID
  }

  // MARK: - 会话

  /// 当前音频会话的用途：`audio` 是听书（长语音），`video` 是影视。
  private static var sessionMode = ""

  private static func configureSession(_ mode: String = "audio") {
    let session = AVAudioSession.sharedInstance()
    // 听书是长语音，走 spokenAudio：静音键不打断，也不会启用系统为音乐准备的
    // 空间音频；影视要走 moviePlayback，否则 AirPods 的语音优化会压到音轨上。
    let wanted = mode == "video" ? AVAudioSession.Mode.moviePlayback
                                 : AVAudioSession.Mode.spokenAudio
    let changed = !configured || sessionMode != mode
    guard changed else { return }
    do {
      try session.setCategory(.playback, mode: wanted, options: [])
      configured = true
      sessionMode = mode
    } catch {
      configured = false
      NSLog("audio session category failed: \(error.localizedDescription)")
    }
  }

  private static func activateSession() {
    guard configured, !interrupted else { return }
    do {
      try AVAudioSession.sharedInstance().setActive(true, options: [])
      sessionActive = true
    } catch {
      sessionActive = false
      NSLog("audio session activate failed: \(error.localizedDescription)")
    }
  }

  private static func apply(_ arguments: [String: Any]) {
    configureSession(arguments["mode"] as? String ?? "audio")
    // 只有 playing 为真才强行激活：暂停时保持会话，让锁屏卡片留在原地。
    let nowPlaying = arguments["playing"] as? Bool ?? false
    if nowPlaying { activateSession() }
    playing = nowPlaying

    let title = arguments["title"] as? String ?? ""
    let episode = arguments["episode"] as? String ?? ""
    let positionMs = arguments["positionMs"] as? Int ?? 0
    let durationMs = arguments["durationMs"] as? Int ?? 0
    let rate = arguments["rate"] as? Double ?? 1
    let hasPrev = arguments["hasPrev"] as? Bool ?? false
    let hasNext = arguments["hasNext"] as? Bool ?? false
    let cover = arguments["cover"] as? String ?? ""

    var info: [String: Any] = [
      MPMediaItemPropertyTitle: title.isEmpty ? "什锦铺" : title,
      MPMediaItemPropertyAlbumTitle: episode,
      MPMediaItemPropertyPlaybackDuration: Double(durationMs) / 1000.0,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(positionMs) / 1000.0,
      MPNowPlayingInfoPropertyPlaybackRate: nowPlaying ? rate : 0.0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
      MPNowPlayingInfoPropertyIsLiveStream: false,
      MPMediaItemPropertyAlbumTrackNumber: 1,
    ]
    if cover != artworkKey {
      artwork = nil
      artworkKey = nil
      artworkTask?.cancel()
    }
    if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    MPNowPlayingInfoCenter.default().playbackState = nowPlaying ? .playing : .paused

    MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] = episode

    commands(enabled: true, hasPrev: hasPrev, hasNext: hasNext)
    if !cover.isEmpty { loadArtwork(coverURL: cover) }
  }

  private static func loadArtwork(coverURL: String) {
    guard coverURL != artworkKey else { return }
    artworkKey = coverURL
    artworkTask?.cancel()
    guard let url = URL(string: coverURL) else { return }
    // 封面来自 CDN，下载失败只是没有大图，不影响播放。
    let artworkSession = sessionID
    artworkTask = URLSession.shared.dataTask(with: url) { data, _, _ in
      guard let data, let image = UIImage(data: data) else { return }
      let cover = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      DispatchQueue.main.async {
        guard coverURL == artworkKey, artworkSession == sessionID, owner != nil else { return }
        artwork = cover
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = cover
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
      }
    }
    artworkTask?.resume()
  }

  private static func clearMedia() {
    for token in Array(backgroundWindows.keys) { endBackgroundWindow(token) }
    playing = false
    interruptedSession = nil
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MPNowPlayingInfoCenter.default().playbackState = .stopped
    commands(enabled: false, hasPrev: false, hasNext: false)
    artwork = nil
    artworkKey = nil
    artworkTask?.cancel()
    artworkTask = nil
  }

  private static func teardown() {
    clearMedia()
    deactivateSession()
  }

  private static func deactivateSession() {
    guard sessionActive else { return }
    do {
      // notifyOthersOnDeactivation：让别的 App（音乐、播客）能接着播。
      try AVAudioSession.sharedInstance().setActive(
        false, options: [.notifyOthersOnDeactivation])
      sessionActive = false
    } catch {
      NSLog("audio session deactivate failed: \(error.localizedDescription)")
    }
  }

  // MARK: - 远端命令

  private static func commands(enabled: Bool, hasPrev: Bool, hasNext: Bool) {
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.isEnabled = enabled
    center.pauseCommand.isEnabled = enabled
    center.togglePlayPauseCommand.isEnabled = enabled
    center.stopCommand.isEnabled = enabled
    center.changePlaybackPositionCommand.isEnabled = enabled
    center.previousTrackCommand.isEnabled = enabled && hasPrev
    center.nextTrackCommand.isEnabled = enabled && hasNext
    center.skipForwardCommand.isEnabled = false
    center.skipBackwardCommand.isEnabled = false
  }

  private static func registerCommands() {
    let center = MPRemoteCommandCenter.shared()

    func handler(_ action: String) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
      return { _ in
        if action == "pause" || action == "stop" || action == "playPause" ||
           action == "next" || action == "prev" {
          interruptedSession = nil
        }
        emit(["action": action])
        return .success
      }
    }

    center.playCommand.addTarget { handler("play")($0) }
    center.pauseCommand.addTarget { handler("pause")($0) }
    center.togglePlayPauseCommand.addTarget { handler("playPause")($0) }
    center.stopCommand.addTarget { handler("stop")($0) }
    center.nextTrackCommand.addTarget { handler("next")($0) }
    center.previousTrackCommand.addTarget { handler("prev")($0) }
    center.changePlaybackPositionCommand.addTarget { event in
      guard let seek = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      emit(["action": "seek", "positionMs": Int(seek.positionTime * 1000)])
      return .success
    }
    commands(enabled: false, hasPrev: false, hasNext: false)
  }

  // MARK: - 中断与路由变化

  private static func observeInterruptions() {
    let center = NotificationCenter.default
    center.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { note in
      guard
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: raw)
      else { return }
      switch type {
      case .began:
        guard !interrupted else { return }
        interrupted = true
        sessionActive = false
        interruptedSession = playing && owner != nil ? sessionID : nil
        if interruptedSession != nil { emit(["action": "interruptionPause"]) }
      case .ended:
        let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
          .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
        interrupted = false
        let resume = interruptedSession == sessionID && owner != nil &&
          options.contains(.shouldResume)
        interruptedSession = nil
        if resume {
          activateSession()
          if sessionActive { emit(["action": "interruptionResume"]) }
        }
      @unknown default:
        break
      }
    }
    center.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { note in
      guard
        let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
      else { return }
      // 拔耳机时 iOS 会把音频切到外放，听书场景里这是打扰，直接暂停。
      if reason == .oldDeviceUnavailable {
        interruptedSession = nil
        if playing { emit(["action": "pause"]) }
      }
    }
  }

  private static func emit(_ payload: [String: Any]) {
    guard let sink, let eventOwner = owner else { return }
    // 先固定事件身份再交给主线程，不能把旧命令重新标为新会话。
    var event = payload
    event["owner"] = eventOwner
    event["session"] = sessionID
    event["intent"] = intent
    let captured = event
    if Thread.isMainThread {
      sink(captured)
    } else {
      DispatchQueue.main.async { sink(captured) }
    }
  }

  private final class Events: NSObject, FlutterStreamHandler {
    func onListen(
      withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
      AudioSessionBridge.sink = events
      return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
      AudioSessionBridge.sink = nil
      return nil
    }
  }
}
