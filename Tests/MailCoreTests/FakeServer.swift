import Foundation
import Network

/// 줄 단위 프로토콜용 로컬 평문 가짜 서버. 받은 줄마다 handler가 돌려준 바이트를 그대로 응답한다.
final class FakeServer {
    typealias Handler = (_ line: String, _ state: inout [String: String]) -> Data

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-server")
    private let greeting: String
    private let handler: Handler
    private(set) var received: [String] = []
    private var state: [String: String] = [:]

    var port: Int { Int(listener.port?.rawValue ?? 0) }

    init(greeting: String, handler: @escaping Handler) throws {
        self.greeting = greeting
        self.handler = handler
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() {
        listener.cancel()
    }

    func lines() -> [String] {
        queue.sync { received }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.send(content: Data(greeting.utf8), completion: .contentProcessed { _ in })
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, let data, error == nil else { return }
            var pending = buffer + data
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                pending = Data(pending[(newline + 1)...])
                self.received.append(line)
                let reply = self.handler(line, &self.state)
                if !reply.isEmpty {
                    connection.send(content: reply, completion: .contentProcessed { _ in })
                }
            }
            if !isComplete { self.receive(connection, buffer: pending) }
        }
    }
}
