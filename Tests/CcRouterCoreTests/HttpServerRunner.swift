import AsyncHTTPClient
import Hummingbird
import NIOCore
import NIOHTTP1
import ServiceLifecycle

/// In-process Hummingbird server with start/stop and a caller-supplied port
/// (0 lets the OS pick an ephemeral port, surfaced by `start()`).
actor HttpServerRunner {
    private let app: Application<RouterResponder<BasicRequestContext>>
    private let serviceGroup: ServiceGroup
    private let portPromise = PortPromise()
    private var runTask: Task<Void, Error>?

    init(router: Router<BasicRequestContext>, address: String, port: Int) {
        let configuration = ApplicationConfiguration(address: .hostname(address, port: port))
        let portPromise = self.portPromise
        self.app = Application(
            router: router,
            configuration: configuration,
            onServerRunning: { channel in
                portPromise.complete(channel.localAddress?.port ?? port)
            }
        )
        self.serviceGroup = ServiceGroup(services: [self.app], logger: self.app.logger)
    }

    /// Start the server and wait until it is accepting connections.
    /// Returns the actually bound port (useful when initialized with port 0).
    func start() async throws -> Int {
        guard self.runTask == nil else { throw TestSupportError("server already started") }

        let serviceGroup = self.serviceGroup
        let portPromise = self.portPromise
        let task = Task<Void, Error> {
            do {
                try await serviceGroup.run()
            } catch {
                portPromise.fail(error)
                throw error
            }
        }
        self.runTask = task
        do {
            return try await portPromise.wait()
        } catch {
            _ = try? await task.value
            self.runTask = nil
            throw error
        }
    }

    /// Gracefully stop the server and wait for it to finish.
    func stop() async throws {
        guard let task = self.runTask else { return }
        self.runTask = nil
        await self.serviceGroup.triggerGracefulShutdown()
        // Surface only cancellation; run failures (e.g. bind errors) were
        // already surfaced by `start` and a repeated stop must stay benign.
        do {
            try await task.value
        } catch let error as CancellationError {
            throw error
        } catch {}
    }
}

struct TestSupportError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
