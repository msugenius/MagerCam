import Foundation
import Network

/// The small HTTP/binary protocol shared with MagerCam's existing receivers.
enum MagerCamWire {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
    }

    enum ParseError: Error { case malformed }

    static func request(_ data: Data) throws -> Request {
        guard let text = String(data: data, encoding: .utf8),
              text.hasSuffix("\r\n\r\n") else { throw ParseError.malformed }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[1].first == "/",
              first[2] == "HTTP/1.0" || first[2] == "HTTP/1.1",
              let target = URLComponents(string: "http://localhost" + String(first[1])),
              target.host == "localhost", target.fragment == nil else { throw ParseError.malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw ParseError.malformed }
            let name = String(line[..<colon]).lowercased()
            guard name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  headers[name] == nil else { throw ParseError.malformed }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0" else { throw ParseError.malformed }
        var query: [String: String] = [:]
        for item in target.queryItems ?? [] {
            guard query[item.name] == nil else { throw ParseError.malformed }
            query[item.name] = item.value ?? ""
        }
        return Request(method: String(first[0]), path: target.path, query: query, headers: headers)
    }

    static func packet(type: UInt8, flags: UInt8 = 0, pts: Int64 = 0, payload: Data = Data()) -> Data {
        precondition(payload.count <= Int(UInt32.max))
        var result = Data([0x4d, 0x43, type, flags])
        var length = UInt32(payload.count).bigEndian
        var timestamp = UInt64(bitPattern: pts).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &timestamp) { result.append(contentsOf: $0) }
        result.append(payload)
        return result
    }
}

/// All callbacks run on the server queue. Dispatch UI updates to the main queue.
final class StreamServer {
    var onClientCount: ((Int) -> Void)?
    var onError: ((String) -> Void)?
    var onReady: (() -> Void)?
    var onKeyframeNeeded: (() -> Void)?

    private final class Client {
        let id = UUID()
        let connection: NWConnection
        var header = Data()
        var streaming = false
        var awaitingKeyframe = true
        var configuration: Data?
        var pendingBytes = 0
        var lastProgress = ProcessInfo.processInfo.systemUptime
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let port: UInt16
    private let discoveryPort: UInt16
    private let accessCode: String
    private let queue = DispatchQueue(label: "com.magercam.sender.network")
    private var tcp: NWListener?
    private var udp: NWListener?
    private var timer: DispatchSourceTimer?
    private var listenerTimeout: DispatchWorkItem?
    private var listenerReady = false
    private var listenerWaitingDetail: String?
    private var clients: [UUID: Client] = [:]
    private var discoveryConnections: [UUID: NWConnection] = [:]
    private var running = false
    private var generation = UUID()
    private var configuration: Data?
    private var status: [String: Any] = [
        "name": "Mac Camera", "ver": 2, "w": 1920, "h": 1080, "fps": 30,
        "bitrate": 16000, "bitrate_now": 16000, "camera": "mac", "front": true,
        "cameras": [["id": "mac", "front": true, "label": "Mac Camera"]],
        "orient": 0, "audio": false, "torch": false, "zoom": 1.0, "zoom_max": 1.0,
        "ev": 0.0, "ev_min": 0.0, "ev_max": 0.0, "focus": "continuous",
        "wb": "auto", "antibanding": "auto", "stab": false, "battery": 100,
        "charging": true, "temp": 0, "profile": "call", "codec": "h264",
        "codec_pref": "h264", "hevc": false, "abr": false, "lock": false,
        "framing": false, "framing_available": false, "faces": 0, "bg": "off",
        "bg_strength": 0, "bg_image": false, "rec": false, "rec_ms": 0,
        "hot": false, "heat_guard": false, "prototype": true, "settings_read_only": true
    ]
    private var failedAuthentication: [String: (count: Int, until: TimeInterval)] = [:]
    private let maximumClients = 8
    private let maximumPendingBytes = 2 * 1024 * 1024
    // Bound data retained before work reaches the network queue, as well as the
    // bytes queued to each socket. A gap must recover at a later IDR frame.
    private let videoIngressLock = NSLock()
    private var videoTasksPending = 0
    private var videoDroppedPTS: Int64?
    private var videoRecoveryRequested = false

    init(port: UInt16 = 4848, discoveryPort: UInt16 = 4849, accessCode: String) {
        self.port = port
        self.discoveryPort = discoveryPort
        self.accessCode = accessCode
    }

    func start() throws {
        try queue.sync {
            guard !running else { return }
            guard let endpointPort = NWEndpoint.Port(rawValue: port), port != 0 else {
                throw NSError(domain: "MagerCam", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid listening port."])
            }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: endpointPort)
            running = true
            generation = UUID()
            let token = generation
            listenerReady = false
            listenerWaitingDetail = nil
            tcp = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.running, self.generation == token else { return }
                switch state {
                case .ready:
                    self.listenerTimeout?.cancel()
                    self.listenerTimeout = nil
                    self.listenerWaitingDetail = nil
                    if !self.listenerReady {
                        self.listenerReady = true
                        self.onReady?()
                    }
                case .waiting(let error):
                    self.listenerWaitingDetail = error.localizedDescription
                    self.armListenerTimeout(token: token)
                case .failed(let error):
                    self.onError?("Cannot listen on TCP \(self.port): \(error.localizedDescription)")
                    self.stopOnQueue()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.running, self.generation == token else { connection.cancel(); return }
                self.accept(connection, token: token)
            }
            armListenerTimeout(token: token)
            listener.start(queue: queue)
            startDiscovery(token: token)
            let heartbeat = DispatchSource.makeTimerSource(queue: queue)
            heartbeat.schedule(deadline: .now() + 1, repeating: 1)
            heartbeat.setEventHandler { [weak self] in
                guard let self, self.running, self.generation == token else { return }
                self.heartbeat()
            }
            timer = heartbeat
            heartbeat.resume()
        }
    }

    func stop() { queue.async { self.stopOnQueue() } }

    private func stopOnQueue() {
        guard running else { return }
        running = false
        generation = UUID()
        listenerTimeout?.cancel()
        listenerTimeout = nil
        listenerReady = false
        listenerWaitingDetail = nil
        timer?.cancel()
        timer = nil
        tcp?.cancel()
        udp?.cancel()
        tcp = nil
        udp = nil
        let previous = Array(clients.values)
        clients.removeAll()
        previous.forEach { $0.connection.cancel() }
        discoveryConnections.values.forEach { $0.cancel() }
        discoveryConnections.removeAll()
        configuration = nil
        videoIngressLock.lock()
        videoDroppedPTS = nil
        videoRecoveryRequested = false
        videoIngressLock.unlock()
        failedAuthentication.removeAll()
        onClientCount?(0)
    }

    func updateStatus(_ status: [String: Any]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.status.merge(status) { _, new in new }
        }
    }

    func broadcastVideo(configuration: Data?, frame: Data, pts: Int64, keyframe: Bool) {
        videoIngressLock.lock()
        guard videoTasksPending < 4 else {
            videoDroppedPTS = max(videoDroppedPTS ?? pts, pts)
            videoIngressLock.unlock()
            return
        }
        videoTasksPending += 1
        videoIngressLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.videoIngressLock.lock()
                self.videoTasksPending -= 1
                self.videoIngressLock.unlock()
            }
            guard self.running else { return }
            if let configuration, !configuration.isEmpty { self.configuration = configuration }
            guard let currentConfiguration = self.configuration else { return }
            self.videoIngressLock.lock()
            let droppedPTS = self.videoDroppedPTS
            let recovered = droppedPTS.map { keyframe && pts > $0 } ?? true
            let requestKeyframe = droppedPTS != nil && !recovered && !self.videoRecoveryRequested
            if recovered {
                self.videoDroppedPTS = nil
                self.videoRecoveryRequested = false
            } else if requestKeyframe {
                self.videoRecoveryRequested = true
            }
            self.videoIngressLock.unlock()
            if droppedPTS != nil {
                for client in self.clients.values where client.streaming { client.awaitingKeyframe = true }
            }
            if requestKeyframe { self.onKeyframeNeeded?() }
            guard recovered else { return }
            guard self.streamingCount > 0 else { return }
            let framePacket = MagerCamWire.packet(type: 2, flags: keyframe ? 1 : 0, pts: pts, payload: frame)
            for client in Array(self.clients.values) where client.streaming {
                if client.configuration != currentConfiguration {
                    client.awaitingKeyframe = true
                }
                if client.awaitingKeyframe {
                    guard keyframe else { continue }
                    if client.configuration != currentConfiguration {
                        let configPacket = MagerCamWire.packet(type: 1, pts: pts, payload: currentConfiguration)
                        guard self.enqueue(configPacket, for: client) else { continue }
                        client.configuration = currentConfiguration
                    }
                    client.awaitingKeyframe = false
                }
                _ = self.enqueue(framePacket, for: client)
            }
        }
    }

    private func armListenerTimeout(token: UUID) {
        guard listenerTimeout == nil else { return }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.running, self.generation == token else { return }
            let detail = self.listenerWaitingDetail.map { " \($0)" } ?? ""
            self.onError?("Network listener did not become available within 15 seconds. Check Local Network permission and whether another sender is using TCP \(self.port).\(detail)")
            self.stopOnQueue()
        }
        listenerTimeout = timeout
        queue.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    private var streamingCount: Int { clients.values.filter(\.streaming).count }

    private func currentStatus() -> [String: Any] {
        var result = status
        result["clients"] = streamingCount
        result["auth"] = !accessCode.isEmpty
        result["port"] = Int(port)
        result["ver"] = 2
        result["audio"] = false
        result["codec"] = "h264"
        result["hevc"] = false
        return result
    }

    private func jsonStatus() -> Data {
        (try? JSONSerialization.data(withJSONObject: currentStatus(), options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private func accept(_ connection: NWConnection, token: UUID) {
        guard clients.count < maximumClients else { connection.cancel(); return }
        let client = Client(connection)
        clients[client.id] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client, self.generation == token, self.clients[client.id] === client else { return }
            switch state {
            case .ready: self.receiveHeader(client, token: token)
            case .failed, .cancelled: self.disconnect(client)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak client] in
            guard let self, let client, self.generation == token,
                  self.clients[client.id] === client, !client.streaming else { return }
            self.disconnect(client)
        }
    }

    private func receiveHeader(_ client: Client, token: UUID) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak client] data, _, complete, error in
            guard let self, let client, self.running, self.generation == token,
                  self.clients[client.id] === client else { return }
            if let data { client.header.append(data) }
            if client.header.count > 16 * 1024 {
                self.respond(client, code: "431 Request Header Fields Too Large", body: "Request too large.")
                return
            }
            if let end = client.header.range(of: Data("\r\n\r\n".utf8)) {
                do {
                    let request = try MagerCamWire.request(client.header.subdata(in: 0..<end.upperBound))
                    client.header.removeAll()
                    self.handle(request, client: client, token: token)
                } catch {
                    self.respond(client, code: "400 Bad Request", body: "Malformed request.")
                }
            } else if complete || error != nil {
                self.disconnect(client)
            } else {
                self.receiveHeader(client, token: token)
            }
        }
    }

    private func handle(_ request: MagerCamWire.Request, client: Client, token: UUID) {
        guard request.method == "GET" else {
            respond(client, code: "405 Method Not Allowed", body: "Only GET is supported.")
            return
        }
        let suppliedKey = request.headers["x-magercam-key"] ?? request.query["key"] ?? ""
        let authenticated = accessCode.isEmpty || suppliedKey == accessCode
        // The login form contains no camera information and is the only public HTTP resource.
        if request.path == "/", !authenticated, suppliedKey.isEmpty {
            respond(client, code: "200 OK", body: "<!doctype html><meta charset=utf-8><title>MagerCam Mac</title><h1>MagerCam Mac</h1><form><label>Access code <input name=key type=password inputmode=numeric required></label> <button>Connect</button></form>", contentType: "text/html; charset=utf-8")
            return
        }
        let peer = peerAddress(client.connection.endpoint)
        let now = ProcessInfo.processInfo.systemUptime
        if let failure = failedAuthentication[peer], failure.count >= 10, failure.until > now {
            respond(client, code: "429 Too Many Requests", body: "Too many incorrect access codes. Retry in one minute.")
            return
        }
        guard authenticated else {
            if failedAuthentication.count > 128 { failedAuthentication = failedAuthentication.filter { $0.value.until > now } }
            let previous = failedAuthentication[peer]
            let count = previous != nil && previous!.until > now ? previous!.count + 1 : 1
            failedAuthentication[peer] = (count, now + 60)
            respond(client, code: "401 Unauthorized", body: "Enter the access code shown in MagerCam Mac.")
            return
        }
        failedAuthentication.removeValue(forKey: peer)
        switch request.path {
        case "/api/status", "/api/set":
            respond(client, code: "200 OK", data: jsonStatus(), contentType: "application/json")
        case "/stream":
            client.streaming = true
            client.awaitingKeyframe = true
            let response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/x-magercam\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
            guard enqueue(response, for: client) else { return }
            _ = enqueue(MagerCamWire.packet(type: 5, payload: jsonStatus()), for: client)
            onClientCount?(streamingCount)
            onKeyframeNeeded?()
            monitorDisconnect(client, token: token)
        case "/":
            respond(client, code: "200 OK", body: "<!doctype html><meta charset=utf-8><title>MagerCam Mac</title><h1>MagerCam Mac is sending</h1><p>Connect using the Mac address and access code in your MagerCam receiver.</p><p>This prototype sends H.264 video. Microphone audio and remote camera settings are not included yet.</p>", contentType: "text/html; charset=utf-8")
        default:
            respond(client, code: "404 Not Found", body: "Endpoint not available in this prototype.")
        }
    }

    private func peerAddress(_ endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { return String(describing: host) }
        return String(describing: endpoint)
    }

    private func monitorDisconnect(_ client: Client, token: UUID) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self, weak client] _, _, _, _ in
            guard let self, let client, self.generation == token, self.clients[client.id] === client else { return }
            self.disconnect(client)
        }
    }

    @discardableResult private func enqueue(_ data: Data, for client: Client) -> Bool {
        guard clients[client.id] === client else { return false }
        guard data.count <= maximumPendingBytes,
              client.pendingBytes <= maximumPendingBytes - data.count else {
            disconnect(client)
            return false
        }
        if client.pendingBytes == 0 { client.lastProgress = ProcessInfo.processInfo.systemUptime }
        client.pendingBytes += data.count
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client, self.clients[client.id] === client else { return }
            client.pendingBytes = max(0, client.pendingBytes - data.count)
            client.lastProgress = ProcessInfo.processInfo.systemUptime
            if error != nil { self.disconnect(client) }
        })
        return true
    }

    private func respond(_ client: Client, code: String, body: String, contentType: String = "text/plain; charset=utf-8") {
        respond(client, code: code, data: Data(body.utf8), contentType: contentType)
    }

    private func respond(_ client: Client, code: String, data: Data, contentType: String) {
        var response = Data("HTTP/1.1 \(code)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(data)
        client.connection.send(content: response, completion: .contentProcessed { [weak self, weak client] _ in
            guard let self, let client else { return }
            self.disconnect(client)
        })
    }

    private func disconnect(_ client: Client) {
        guard clients.removeValue(forKey: client.id) != nil else { return }
        client.connection.cancel()
        if client.streaming { onClientCount?(streamingCount) }
    }

    private func heartbeat() {
        let now = ProcessInfo.processInfo.systemUptime
        let packet = MagerCamWire.packet(type: 5, payload: jsonStatus())
        for client in Array(clients.values) where client.streaming {
            if client.pendingBytes > 0 && now - client.lastProgress > 3 {
                disconnect(client)
            } else {
                _ = enqueue(packet, for: client)
            }
        }
    }

    private func startDiscovery(token: UUID) {
        do {
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            guard discoveryPort != 0, let endpointPort = NWEndpoint.Port(rawValue: discoveryPort) else {
                throw NSError(domain: "MagerCam", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid discovery port."])
            }
            let listener = try NWListener(using: parameters, on: endpointPort)
            udp = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.running, self.generation == token else { return }
                if case .failed(let error) = state {
                    // Manual-IP video remains usable if discovery is unavailable.
                    self.onError?("Discovery is unavailable (manual IP still works): \(error.localizedDescription)")
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.running, self.generation == token,
                      self.discoveryConnections.count < 32 else { connection.cancel(); return }
                let id = UUID()
                self.discoveryConnections[id] = connection
                connection.start(queue: self.queue)
                connection.receiveMessage { [weak self, weak connection] data, _, _, _ in
                    guard let self, let connection, self.running, self.generation == token else { connection?.cancel(); return }
                    guard let data, data.starts(with: Data("MAGERCAM_DISCOVER".utf8)) else {
                        self.discoveryConnections.removeValue(forKey: id)
                        connection.cancel()
                        return
                    }
                    let reply: [String: Any] = ["magercam": 1, "name": self.status["name"] as? String ?? "Mac Camera", "port": Int(self.port), "ver": 2, "auth": !self.accessCode.isEmpty]
                    let payload = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
                    connection.send(content: payload, completion: .contentProcessed { [weak self, weak connection] _ in
                        self?.discoveryConnections.removeValue(forKey: id)
                        connection?.cancel()
                    })
                }
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self, weak connection] in
                    guard let self, self.generation == token else { return }
                    self.discoveryConnections.removeValue(forKey: id)
                    connection?.cancel()
                }
            }
            listener.start(queue: queue)
        } catch {
            onError?("Discovery is unavailable (manual IP still works): \(error.localizedDescription)")
        }
    }

    static func selfTest() throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: "MagerCam.SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let frame = MagerCamWire.packet(type: 2, flags: 1, pts: 0x0102030405060708, payload: Data([0, 0, 0, 1, 0x65]))
        try check(frame == Data([0x4d, 0x43, 2, 1, 0, 0, 0, 5, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 1, 0x65]), "Binary packet layout or endianness is incorrect.")
        let ping = MagerCamWire.packet(type: 6)
        try check(ping.count == 16 && ping[2] == 6, "Empty heartbeat packet is incorrect.")
        let request = try MagerCamWire.request(Data("GET /stream?w=1920&h=1080&key=123456 HTTP/1.1\r\nHost: mac\r\nX-MagerCam-Key: 654321\r\n\r\n".utf8))
        try check(request.path == "/stream" && request.query["key"] == "123456" && request.headers["x-magercam-key"] == "654321", "Request parsing lost authentication or stream parameters.")
        let encoded = try MagerCamWire.request(Data("GET /api/status?key=12%2034 HTTP/1.0\r\n\r\n".utf8))
        try check(encoded.query["key"] == "12 34", "Percent-encoded query parameters are not decoded.")
        for bad in ["GET / HTTP/2\r\n\r\n", "GET http://evil/ HTTP/1.1\r\n\r\n", "GET / HTTP/1.1\r\nX-MagerCam-Key: a\r\nX-MagerCam-Key: b\r\n\r\n", "GET /?key=a&key=b HTTP/1.1\r\n\r\n", "GET / HTTP/1.1\r\nContent-Length: 5\r\n\r\n"] {
            do {
                _ = try MagerCamWire.request(Data(bad.utf8))
                throw NSError(domain: "MagerCam.SelfTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Malformed request was accepted."])
            } catch MagerCamWire.ParseError.malformed { /* expected */ }
        }
    }
}
