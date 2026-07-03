// WalletConnect relay transport (ADR-0049).
//
// Reown's Networking layer needs a WebSocketFactory; the SDK ships none, and
// its example uses Starscream. We implement WebSocketConnecting over the
// platform URLSessionWebSocketTask instead, so we add no third-party WebSocket
// dependency. The protocol (from WalletConnectRelay, re-exported by
// ReownWalletKit) is small: connect / disconnect / write(string:) plus
// onConnect / onDisconnect / onText callbacks and a mutable request.
//
// Two hard-won correctness rules live here:
//
//  1. ALWAYS report a disconnect on any receive/ping failure, even if the
//     socket never finished opening. Reown's AutomaticSocketConnectionHandler
//     only schedules a reconnect when it gets an onDisconnect. Swallowing a
//     connect-time failure (the old behaviour: fire onDisconnect only when
//     already connected) wedged the relay forever, so a single transient
//     failure meant "can't connect to any site" until reinstall.
//
//  2. Keepalive ping. URLSessionWebSocketTask does not ping on its own, so the
//     relay drops an idle socket after roughly a minute. Without a ping the
//     connection silently dies mid-session ("connects, then stops working").

import Foundation
import ReownWalletKit

final class WCWebSocket: NSObject, WebSocketConnecting, URLSessionWebSocketDelegate {
    var request: URLRequest
    var onConnect: (() -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var onText: ((String) -> Void)?

    // Serializes all task lifecycle work; `isConnected` is read from SDK
    // threads so it gets its own lock to avoid a re-entrant queue deadlock.
    private let queue = DispatchQueue(label: "com.elabify.app.maknoon.wcsocket")
    private let stateLock = NSLock()
    private var _isConnected = false
    private var task: URLSessionWebSocketTask?
    private var keepaliveTimer: DispatchSourceTimer?
    private let keepaliveInterval: TimeInterval = 15

    private lazy var session: URLSession = URLSession(
        configuration: .default, delegate: self, delegateQueue: nil
    )

    var isConnected: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isConnected
    }
    private func setConnected(_ value: Bool) {
        stateLock.lock(); _isConnected = value; stateLock.unlock()
    }

    init(request: URLRequest) {
        self.request = request
        super.init()
    }

    func connect() {
        queue.async { [weak self] in
            guard let self else { return }
            // Drop any prior task before starting fresh. Its late callbacks are
            // ignored because they no longer match `self.task`.
            self.task?.cancel(with: .goingAway, reason: nil)
            let task = self.session.webSocketTask(with: self.request)
            self.task = task
            task.resume()
            self.receiveNext(on: task)
            self.startKeepalive()
            LogStore.shared.info("walletconnect", "relay socket: connecting")
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.task?.cancel(with: .goingAway, reason: nil)
            self.reportClosed(nil)
        }
    }

    func write(string: String, completion: (() -> Void)?) {
        queue.async { [weak self] in
            self?.task?.send(.string(string)) { _ in completion?() }
        }
    }

    // MARK: internal (all on `queue`)

    private func receiveNext(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                // Ignore callbacks from a task we already replaced.
                guard task === self.task else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.onText?(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self.onText?(text) }
                    @unknown default: break
                    }
                    self.receiveNext(on: task)
                case .failure(let error):
                    // Dead socket. Report unconditionally so the SDK reconnects.
                    LogStore.shared.warn("walletconnect", "relay socket failure: \(error.localizedDescription)")
                    self.reportClosed(error)
                }
            }
        }
    }

    /// Fire onDisconnect at most once per live task, regardless of whether the
    /// socket ever finished opening, then clear state so a later connect() is clean.
    private func reportClosed(_ error: Error?) {
        let wasActive = (task != nil) || isConnected
        stopKeepalive()
        task = nil
        setConnected(false)
        guard wasActive else { return }
        onDisconnect?(error)
    }

    private func startKeepalive() {
        stopKeepalive()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + keepaliveInterval, repeating: keepaliveInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let task = self.task else { return }
            task.sendPing { [weak self] error in
                guard let error else { return }
                self?.queue.async {
                    LogStore.shared.warn("walletconnect", "relay keepalive ping failed: \(error.localizedDescription)")
                    self?.reportClosed(error)
                }
            }
        }
        timer.resume()
        keepaliveTimer = timer
    }

    private func stopKeepalive() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        queue.async { [weak self] in
            guard let self, webSocketTask === self.task else { return }
            self.setConnected(true)
            LogStore.shared.info("walletconnect", "relay socket: open")
            self.onConnect?()
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        queue.async { [weak self] in
            guard let self, webSocketTask === self.task else { return }
            LogStore.shared.info("walletconnect", "relay socket: closed (code \(closeCode.rawValue))")
            self.reportClosed(nil)
        }
    }
}

struct WCSocketFactory: WebSocketFactory {
    func create(with url: URL) -> WebSocketConnecting {
        WCWebSocket(request: URLRequest(url: url))
    }
}
