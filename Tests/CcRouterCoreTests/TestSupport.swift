import NIOConcurrencyHelpers

/// Minimal single-value promise used to wait for a server's bound port.
/// Mirrors the pattern in HummingbirdTesting's TestApplication.
final class PortPromise: @unchecked Sendable {
    private enum State {
        case blocked([CheckedContinuation<Int, Error>])
        case ready(Int)
        case failed(Error)
    }

    private let state = NIOLockedValueBox<State>(.blocked([]))

    func wait() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<Int, Error>? = self.state.withLockedValue { state in
                switch state {
                case .blocked(var waiters):
                    waiters.append(continuation)
                    state = .blocked(waiters)
                    return nil
                case .ready(let port):
                    return .success(port)
                case .failed(let error):
                    return .failure(error)
                }
            }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    func complete(_ port: Int) {
        let waiters = self.state.withLockedValue { state -> [CheckedContinuation<Int, Error>] in
            guard case .blocked(let waiters) = state else { return [] }
            state = .ready(port)
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: port)
        }
    }

    func fail(_ error: Error) {
        let waiters = self.state.withLockedValue { state -> [CheckedContinuation<Int, Error>] in
            guard case .blocked(let waiters) = state else { return [] }
            state = .failed(error)
            return waiters
        }
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }
}
