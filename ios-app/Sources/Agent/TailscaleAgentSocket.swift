import Foundation
import Network

/// One request to the note-agent gateway (`router_gateway.py` on the server, reached over Tailscale).
struct AgentRequest: Encodable, Sendable {
    var requestID = UUID().uuidString
    var transcript: String
    var canvasImageBase64: String?
    var cursor: CGPoint
    var pageText: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id", transcript, canvasImageBase64 = "canvas_image_b64"
        case cursorX = "cursor_x", cursorY = "cursor_y", pageText = "page_text"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestID, forKey: .requestID); try c.encode(transcript, forKey: .transcript)
        try c.encodeIfPresent(canvasImageBase64, forKey: .canvasImageBase64)
        try c.encode(Double(cursor.x), forKey: .cursorX); try c.encode(Double(cursor.y), forKey: .cursorY)
        try c.encode(pageText, forKey: .pageText)
    }
}

/// Server messages for one request, in order: status*, route, token*, then done or failed.
enum AgentEvent: Equatable, Sendable {
    case status(String)
    case route(route: String, backend: String, reason: String, triageMs: Int)
    case token(String)
    case done(backend: String, anchor: CGPoint, elapsedMs: Int)
    case failed(String)

    /// Parses one gateway frame. Returns the request it belongs to (nil for connection-level errors).
    static func parse(_ text: String) -> (requestID: String?, event: AgentEvent)? {
        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        let id = json["request_id"] as? String
        func string(_ key: String) -> String { json[key] as? String ?? "" }
        func int(_ key: String) -> Int { (json[key] as? NSNumber)?.intValue ?? 0 }
        switch type {
        case "status": return (id, .status(string("message")))
        case "route": return (id, .route(route: string("route"), backend: string("backend"), reason: string("reason"), triageMs: int("triage_ms")))
        case "token": return (id, .token(string("text")))
        case "done":
            let anchor = json["anchor"] as? [String: Any]
            let x = (anchor?["x"] as? NSNumber)?.doubleValue ?? 0, y = (anchor?["y"] as? NSNumber)?.doubleValue ?? 0
            return (id, .done(backend: string("backend"), anchor: CGPoint(x: x, y: y), elapsedMs: int("elapsed_ms")))
        case "error": return (id, .failed(string("message")))
        default: return nil
        }
    }
}

enum AgentSocketError: LocalizedError, Equatable {
    case invalidAddress, notConnected, disconnected, rejectedToken
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Die Adresse des Notiz-Agenten ist ungültig. Prüfe sie unter Verbindungen."
        case .notConnected: return "Der Notiz-Agent ist nicht erreichbar. Läuft Tailscale auf diesem iPad?"
        case .disconnected: return "Die Verbindung zum Notiz-Agenten wurde unterbrochen."
        case .rejectedToken: return "Der Server hat das Agent-Token abgelehnt. Trage es unter Verbindungen ein."
        }
    }
}

/// Where the gateway lives. Host and port in UserDefaults, the token in the keychain.
struct AgentSettings: Equatable {
    static let hostKey = "agentHost", portKey = "agentPort", tokenKey = "agentToken"
    static let defaultHost = "100.95.154.45"   // the server's Tailscale IP
    var host: String
    var port: Int
    var token: String

    static func load() -> AgentSettings {
        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: hostKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultHost
        let port = defaults.integer(forKey: portKey)
        return AgentSettings(host: host, port: port == 0 ? 8000 : port, token: SecureStore.get(tokenKey))
    }
    /// Plain ws:// is fine here: Tailscale already encrypts the link end to end (WireGuard).
    var url: URL? {
        var c = URLComponents(); c.scheme = "ws"; c.host = host.trimmingCharacters(in: .whitespaces); c.port = port; c.path = "/ws/note-agent"
        guard let host = c.host, !host.isEmpty else { return nil }
        return c.url
    }
}

/// Persistent WebSocket to the gateway with automatic reconnect.
/// - Reconnects with exponential backoff (1 s … 30 s) and immediately when the network comes back.
/// - A ping every 15 s detects dead links (Wi-Fi handover, Tailscale reconnect, iPad sleep).
/// - A rejected token (handshake answered with HTTP 403) stops retrying until settings change.
/// - Requests in flight when the link drops fail with `.disconnected`: the gateway cancels them on its side too.
@MainActor final class TailscaleAgentSocket: ObservableObject {
    enum State: Equatable {
        case idle, connecting, connected
        case waiting(retryIn: Int)
        case failed(String)
    }
    @Published private(set) var state: State = .idle

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var loops: [Task<Void, Never>] = []
    private var reconnect: Task<Void, Never>?
    private var attempts = 0
    private var wanted = false
    private var streams: [String: AsyncThrowingStream<AgentEvent, Error>.Continuation] = [:]
    private var settings = AgentSettings.load()
    private let monitor = NWPathMonitor()

    init() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "studio.nullmini.agent.path"))
    }
    deinit { monitor.cancel() }

    func connect() {
        wanted = true
        let latest = AgentSettings.load()
        if latest != settings { settings = latest; attempts = 0; if case .failed = state { state = .idle } }
        open()
    }

    func disconnect() {
        wanted = false
        reconnect?.cancel(); reconnect = nil
        teardown(failing: AgentSocketError.disconnected)
        state = .idle
    }

    /// Sends a request and streams its events. Cancelling the consuming task cancels the request on the server.
    func send(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AgentEvent.self, throwing: Error.self)
        streams[request.requestID] = continuation
        let id = request.requestID
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { @MainActor in self?.cancel(id) }
        }
        Task { await transmit(request) }
        return stream
    }

    func cancel(_ requestID: String) {
        guard let continuation = streams.removeValue(forKey: requestID) else { return }
        continuation.finish()
        sendRaw(["type": "cancel", "request_id": requestID])
    }

    // MARK: Connection

    private func open() {
        guard wanted, task == nil else { return }
        guard let url = settings.url else { state = .failed(AgentSocketError.invalidAddress.localizedDescription); return }
        var request = URLRequest(url: url)
        if !settings.token.isEmpty { request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization") }
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 8 << 20
        task = socket
        state = .connecting
        socket.resume()
        loops = [
            Task { [weak self] in await self?.receive(on: socket) },
            Task { [weak self] in await self?.keepAlive(socket) },
        ]
    }

    private func receive(on socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do { message = try await socket.receive() } catch { linkFailed(socket); return }
            guard socket === task else { return }
            markConnected()
            let text: String?
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(data: d, encoding: .utf8)
            @unknown default: text = nil
            }
            guard let text, let parsed = AgentEvent.parse(text), let id = parsed.requestID,
                  let continuation = streams[id] else { continue }
            let event = parsed.event
            switch event {
            case .done:
                continuation.yield(event); continuation.finish(); streams[id] = nil
            case .failed(let message):
                continuation.finish(throwing: NotebookError.invalid(message)); streams[id] = nil
            default:
                continuation.yield(event)
            }
        }
    }

    /// The first successful ping marks the link usable; later failures trigger a reconnect.
    private func keepAlive(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled, socket === task {
            let ok = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                socket.sendPing { error in done.resume(returning: error == nil) }
            }
            guard socket === task else { return }
            if !ok { linkFailed(socket); return }
            markConnected()
            try? await Task.sleep(for: .seconds(15))
        }
    }

    private func markConnected() {
        guard state != .connected else { return }
        state = .connected; attempts = 0
    }

    private func linkFailed(_ socket: URLSessionWebSocketTask) {
        guard socket === task else { return }
        // The gateway rejects a bad token or a foreign address before accepting, which the
        // handshake reports as HTTP 403 (CloseCode cannot represent its custom 4401/4403 codes).
        let rejected = (socket.response as? HTTPURLResponse)?.statusCode == 403
        teardown(failing: AgentSocketError.disconnected)
        if rejected {
            wanted = false
            state = .failed(AgentSocketError.rejectedToken.localizedDescription)
            return
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard wanted else { state = .idle; return }
        attempts += 1
        let delay = min(30, 1 << min(attempts - 1, 5))
        state = .waiting(retryIn: delay)
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(delay) + Double.random(in: 0 ... 0.5)))
            guard !Task.isCancelled else { return }
            self?.reconnect = nil
            self?.open()
        }
    }

    private func networkChanged(online: Bool) {
        guard wanted, online, case .waiting = state else { return }
        reconnect?.cancel(); reconnect = nil
        open()
    }

    private func teardown(failing error: Error) {
        loops.forEach { $0.cancel() }; loops = []
        task?.cancel(with: .goingAway, reason: nil); task = nil
        let pending = streams; streams = [:]
        for continuation in pending.values { continuation.finish(throwing: error) }
    }

    // MARK: Sending

    private func transmit(_ request: AgentRequest) async {
        let id = request.requestID
        connect()
        // Wait up to 6 s for the link (covers a reconnect after the iPad woke up).
        let deadline = Date().addingTimeInterval(6)
        while state != .connected, Date() < deadline, streams[id] != nil {
            if case .failed(let message) = state { streams.removeValue(forKey: id)?.finish(throwing: NotebookError.invalid(message)); return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard streams[id] != nil else { return }
        guard state == .connected, let socket = task else {
            streams.removeValue(forKey: id)?.finish(throwing: AgentSocketError.notConnected); return
        }
        do {
            let data = try JSONEncoder().encode(request)
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            streams.removeValue(forKey: id)?.finish(throwing: AgentSocketError.disconnected)
        }
    }

    private func sendRaw(_ object: [String: String]) {
        guard let socket = task, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        socket.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }
}
