import Foundation
import CryptoKit
import Darwin
import Security

enum CodexError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Incremental RFC 6455 decoder. Codex's local control socket is WebSocket, not JSON-lines.
final class CodexWebSocketDecoder {
    enum Event: Equatable { case message(Data), ping(Data), closed }
    private var buffer = Data(), fragmented = Data()
    private var inMessage = false
    let limit: Int
    init(limit: Int = 64 * 1024 * 1024) { self.limit = limit }
    func feed(_ data: Data) throws -> [Event] {
        buffer.append(data)
        var result: [Event] = []
        while buffer.count >= 2 {
            let b = [UInt8](buffer.prefix(10)), fin = b[0] & 128 != 0, opcode = b[0] & 15
            guard b[0] & 112 == 0, b[1] & 128 == 0 else { throw CodexError.message("Invalid Codex WebSocket frame") }
            var length = UInt64(b[1] & 127), header = 2
            if length == 126 {
                guard b.count >= 4 else { break }; header = 4
                length = UInt64(b[2]) << 8 | UInt64(b[3])
            } else if length == 127 {
                guard b.count >= 10 else { break }; header = 10
                length = b[2..<10].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            }
            guard length <= UInt64(limit), opcode < 8 || (fin && length <= 125) else { throw CodexError.message("Codex message exceeds limit") }
            guard buffer.count >= header + Int(length) else { break }
            let payload = buffer.subdata(in: header..<(header + Int(length)))
            buffer = Data(buffer.dropFirst(header + Int(length)))
            switch opcode {
            case 0, 1, 2:
                guard (opcode == 0) == inMessage else { throw CodexError.message("Unexpected Codex continuation") }
                guard fragmented.count + payload.count <= limit else { throw CodexError.message("Codex message exceeds limit") }
                fragmented.append(payload); inMessage = !fin
                if fin { result.append(.message(fragmented)); fragmented = Data() }
            case 8: result.append(.closed)
            case 9: result.append(.ping(payload))
            case 10: break
            default: throw CodexError.message("Unsupported Codex frame")
            }
        }
        return result
    }
    static func clientFrame(_ data: Data, opcode: UInt8, mask: [UInt8]) -> Data {
        precondition(mask.count == 4)
        var out = Data([0x80 | opcode])
        if data.count < 126 { out.append(0x80 | UInt8(data.count)) }
        else if data.count <= 65535 {
            out.append(contentsOf: [0xfe, UInt8(data.count >> 8), UInt8(data.count & 255)])
        } else {
            out.append(0xff)
            let length = UInt64(data.count)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((length >> shift) & 255)) }
        }
        out.append(contentsOf: mask)
        out.append(contentsOf: data.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return out
    }
}

/// One connection, owned by Xpromptvs. Closing it never signals or stops the shared daemon.
private final class CodexLocalWebSocket: @unchecked Sendable {
    let path: String
    private let lock = NSLock(), writeLock = NSLock()
    private var fd: Int32 = -1
    private var stopped = false
    var onOpen: () -> Void = {}
    var onMessage: (Data) -> Void = { _ in }
    var onClose: (Error) -> Void = { _ in }
    init(path: String) { self.path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
    func start() { DispatchQueue(label: "rdev.codex.read").async { self.run() } }
    func close() {
        lock.lock(); stopped = true; let socket = fd; lock.unlock()
        if socket >= 0 { lock.withLock { if fd == socket { _ = Darwin.shutdown(socket, SHUT_RDWR) } } }
    }
    private func write(_ data: Data, socket: Int32) throws {
        try writeLock.withLock {
            guard lock.withLock({ !stopped && fd == socket }) else { throw CodexError.message("Codex socket was closed") }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                let deadline = Date().addingTimeInterval(8)
                while offset < bytes.count {
                    guard Date() < deadline else { throw CodexError.message("Codex socket write timed out") }
                    var poller = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
                    guard Darwin.poll(&poller, 1, 1000) >= 0 else { throw CodexError.message("Codex socket unavailable") }
                    if poller.revents & Int16(POLLOUT) == 0 { continue }
                    let n = Darwin.send(socket, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                    if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                    guard n > 0 else { throw CodexError.message("Codex socket closed while sending") }
                    offset += n
                }
            }
        }
    }
    func send(_ data: Data, opcode: UInt8 = 1) throws {
        let socket = lock.withLock { stopped ? -1 : fd }
        guard socket >= 0 else { throw CodexError.message("Codex disconnected") }
        var mask = [UInt8](repeating: 0, count: 4)
        guard SecRandomCopyBytes(kSecRandomDefault, 4, &mask) == errSecSuccess else { throw CodexError.message("Cannot create WebSocket mask") }
        try write(CodexWebSocketDecoder.clientFrame(data, opcode: opcode, mask: mask), socket: socket)
    }
    private func run() {
        var socket: Int32 = -1
        defer { writeLock.withLock { lock.withLock { fd = -1; if socket >= 0 { Darwin.close(socket) } } } }
        do {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
                throw CodexError.message("Codex service socket is unavailable or not owned by this user")
            }
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw CodexError.message("Codex socket path is too long") }
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.initializeMemory(as: UInt8.self, repeating: 0); _ = path.utf8CString.withUnsafeBytes { bytes.copyBytes(from: $0) } }
            socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard socket >= 0 else { throw CodexError.message("Cannot open Codex socket") }
            var noSignal: Int32 = 1
            _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(socket, F_SETFL, O_NONBLOCK)
            let connected = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            if connected != 0 {
                guard errno == EINPROGRESS else { throw CodexError.message("Cannot connect to Codex service") }
                var poller = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
                guard Darwin.poll(&poller, 1, 8000) > 0 else { throw CodexError.message("Codex connection timed out") }
                var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw CodexError.message("Codex connection failed") }
            }
            guard lock.withLock({ if stopped { return false }; fd = socket; return true }) else { return }
            let key = UUID().uuidString.data(using: .utf8)!.prefix(16).base64EncodedString()
            try write(Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8), socket: socket)
            var header = Data(), upgraded = false
            let decoder = CodexWebSocketDecoder()
            let deadline = Date().addingTimeInterval(8)
            var bytes = [UInt8](repeating: 0, count: 65536)
            while !lock.withLock({ stopped }) {
                if !upgraded && Date() > deadline { throw CodexError.message("Codex WebSocket handshake timed out") }
                var poller = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
                let count = Darwin.poll(&poller, 1, 500)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw CodexError.message("Codex socket read failed") }
                if count == 0 { continue }
                let n = Darwin.recv(socket, &bytes, bytes.count, 0)
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard n > 0 else { throw CodexError.message("Codex service disconnected") }
                var data = Data(bytes.prefix(n))
                if !upgraded {
                    header.append(data)
                    guard let end = header.range(of: Data("\r\n\r\n".utf8)) else {
                        guard header.count <= 16384 else { throw CodexError.message("Invalid Codex upgrade response") }; continue
                    }
                    let text = String(decoding: header[..<end.lowerBound], as: UTF8.self)
                    let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                    let lines = text.components(separatedBy: "\r\n")
                    guard lines.first?.hasPrefix("HTTP/1.1 101 ") == true,
                          lines.contains(where: { $0.lowercased().hasPrefix("sec-websocket-accept:") && $0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) == expected }) else { throw CodexError.message("Codex WebSocket upgrade refused") }
                    data = Data(header[end.upperBound...]); header = Data(); upgraded = true; onOpen()
                }
                for event in try decoder.feed(data) {
                    switch event {
                    case .message(let message): onMessage(message)
                    case .ping(let payload): try send(payload, opcode: 10)
                    case .closed: throw CodexError.message("Codex service closed the connection")
                    }
                }
            }
        } catch { if !lock.withLock({ stopped }) { onClose(error) } }
    }
}

protocol CodexRPC: AnyObject {
    var onNotification: ([String: Any]) -> Void { get set }
    var onRequest: ([String: Any]) -> Void { get set }
    var onDisconnect: () -> Void { get set }
    func connect(completion: @escaping CodexSocket.Reply)
    func call(method: String, params: [String: Any], authorized: @escaping () -> Bool, completion: @escaping CodexSocket.Reply)
    func answer(id: Any, result: [String: Any], authorized: @escaping () -> Bool, completion: @escaping CodexSocket.Reply)
    func close()
}

final class CodexSocket: CodexRPC, @unchecked Sendable {
    typealias Reply = (Result<[String: Any], Error>) -> Void
    private let queue = DispatchQueue(label: "rdev.codex.rpc")
    private let path: String
    private var wire: CodexLocalWebSocket?
    private var serial = 0
    private var generation = 0
    private var ready = false
    private var pending: [Int: Reply] = [:]
    private var connecting: [Reply] = []
    var onNotification: ([String: Any]) -> Void = { _ in }
    var onRequest: ([String: Any]) -> Void = { _ in }
    var onDisconnect: () -> Void = {}
    init(path: String) { self.path = path }
    func connect(completion: @escaping Reply) {
        queue.async {
            if self.ready { completion(.success([:])); return }
            self.connecting.append(completion)
            guard self.wire == nil else { return }
            self.generation += 1; let generation = self.generation
            let wire = CodexLocalWebSocket(path: self.path); self.wire = wire
            wire.onOpen = { [weak self] in
                self?.call(method: "initialize", params: ["clientInfo": ["name": "xpromptvs", "title": "Xpromptvs", "version": "1"], "capabilities": ["experimentalApi": true, "requestAttestation": false]]) { result in
                    guard let self, self.generation == generation else { return }
                    if case .success = result {
                        do { try self.send(["method": "initialized"]); self.ready = true
                            let callbacks = self.connecting; self.connecting.removeAll(); callbacks.forEach { $0(result) }
                        } catch { self.failed(error) }
                    } else if case .failure(let error) = result { self.failed(error) }
                }
            }
            wire.onMessage = { [weak self] bytes in self?.queue.async { [weak self] in
                guard let self, self.generation == generation,
                      let message = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
                if let id = message["id"] as? Int, message["method"] == nil, let callback = self.pending.removeValue(forKey: id) {
                    if let error = message["error"] as? [String: Any] { callback(.failure(CodexError.message(error["message"] as? String ?? "Codex request failed"))) }
                    else { callback(.success(message["result"] as? [String: Any] ?? [:])) }
                } else if message["method"] != nil {
                    if message["id"] != nil { self.onRequest(message) } else { self.onNotification(message) }
                }
            } }
            wire.onClose = { [weak self] error in self?.queue.async { [weak self] in if self?.generation == generation { self?.failed(error) } } }
            wire.start()
            self.queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                if let self, self.generation == generation, !self.ready { self.failed(CodexError.message("Codex initialization timed out")) }
            }
        }
    }
    func call(method: String, params: [String: Any], authorized: @escaping () -> Bool = { true }, completion: @escaping Reply) {
        queue.async {
            guard authorized() else { completion(.failure(CodexError.message("Control changed; action was not sent"))); return }
            guard self.wire != nil, self.pending.count < 32 else { completion(.failure(CodexError.message("Codex disconnected or busy"))); return }
            self.serial += 1; let id = self.serial
            self.pending[id] = completion
            do { try self.send(["id": id, "method": method, "params": params]) }
            catch { self.pending.removeValue(forKey: id)?(.failure(error)); return }
            self.queue.asyncAfter(deadline: .now() + 20) { [weak self] in
                self?.pending.removeValue(forKey: id)?(.failure(CodexError.message("Codex request timed out; its outcome is unknown")))
            }
        }
    }
    func answer(id: Any, result: [String: Any], authorized: @escaping () -> Bool, completion: @escaping Reply) {
        queue.async {
            guard authorized() else { completion(.failure(CodexError.message("Control changed"))); return }
            do { try self.send(["id": id, "result": result]); completion(.success([:])) }
            catch { completion(.failure(error)) }
        }
    }
    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= 64 * 1024 * 1024, let wire else { throw CodexError.message("Codex disconnected or message too large") }
        try wire.send(data)
    }
    private func failed(_ error: Error) {
        generation += 1; ready = false; wire?.close(); wire = nil
        let calls = pending.values.map { $0 } + connecting; pending.removeAll(); connecting.removeAll()
        calls.forEach { $0(.failure(error)) }; onDisconnect()
    }
    func close() { queue.async { self.failed(CodexError.message("Codex client closed")) } }
}
