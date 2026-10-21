import Foundation
import Network
import Testing
@testable import PianoLink

@MainActor
private final class DiscoveryBrowserStub: BridgeDiscoveryBrowsing {
    var stateUpdateHandler: (@MainActor @Sendable (NWBrowser.State) -> Void)?
    var resultsUpdateHandler: (@MainActor @Sendable ([NWEndpoint]) -> Void)?
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    func start() { startCount += 1 }
    func cancel() {
        cancelCount += 1
        // Exercise synchronous cancellation as well as delayed callbacks after cancellation.
        stateUpdateHandler?(.cancelled)
    }

    func discover(_ names: [String]) {
        resultsUpdateHandler?(names.map {
            .service(name: $0, type: "_pianovision._tcp", domain: "local.", interface: nil)
        })
    }

    func fail() { stateUpdateHandler?(.failed(.posix(.ENETDOWN))) }
}

@MainActor
private final class DiscoveryBrowserFactory {
    private(set) var browsers: [DiscoveryBrowserStub] = []

    func makeBrowser() -> any BridgeDiscoveryBrowsing {
        let browser = DiscoveryBrowserStub()
        browsers.append(browser)
        return browser
    }
}

@Suite(.serialized)
struct BridgeDiscoveryTests {
    @Test @MainActor func failedDiscoveryClearsResultsAndCanStartAgain() {
        let factory = DiscoveryBrowserFactory()
        let client = BridgeClient(discoveryBrowserFactory: { factory.makeBrowser() })
        client.startBrowsing()
        let first = factory.browsers[0]
        first.discover(["Old Mac"])
        #expect(client.services.map(\.name) == ["Old Mac"])
        first.fail()
        #expect(first.cancelCount == 1)
        #expect(client.services.isEmpty)
        #expect(client.status.contains("发现服务失败"))

        // A failed instance must release both its result list and its endpoint lookup.
        client.connect(to: BridgeService(id: "Old Mac._pianovision._tcp.local.", name: "Old Mac"))
        #expect(client.status.contains("已离线"))
        client.startBrowsing()
        #expect(factory.browsers.count == 2)
        #expect(factory.browsers[1].startCount == 1)
        #expect(!client.status.contains("失败"))
        factory.browsers[1].discover(["New Mac"])
        #expect(client.services.map(\.name) == ["New Mac"])
    }

    @Test @MainActor func restartRejectsLateResultsAndFailureFromPreviousBrowser() {
        let factory = DiscoveryBrowserFactory()
        let client = BridgeClient(discoveryBrowserFactory: { factory.makeBrowser() })
        client.startBrowsing()
        let first = factory.browsers[0]
        first.discover(["Old Mac"])
        client.restartBrowsing()
        #expect(first.cancelCount == 1)
        #expect(client.services.isEmpty)
        let second = factory.browsers[1]
        second.discover(["Current Mac"])
        let currentStatus = client.status

        first.discover(["Stale Mac"])
        first.fail()
        #expect(client.services.map(\.name) == ["Current Mac"])
        #expect(client.status == currentStatus)
        #expect(second.cancelCount == 0)
        client.startBrowsing()
        #expect(factory.browsers.count == 2)
    }

    @Test @MainActor func failedBrowserCannotRepopulateResultsBeforeRetry() {
        let factory = DiscoveryBrowserFactory()
        let client = BridgeClient(discoveryBrowserFactory: { factory.makeBrowser() })
        client.startBrowsing()
        client.startBrowsing()
        #expect(factory.browsers.count == 1)
        let first = factory.browsers[0]
        first.fail()
        first.discover(["Late Mac"])
        #expect(client.services.isEmpty)
        #expect(client.status.contains("失败"))
        client.restartBrowsing()
        #expect(factory.browsers.count == 2)
    }

    @Test @MainActor func discoveryFailureAndRestartPreserveLiveMIDIConnection() async throws {
        let factory = DiscoveryBrowserFactory()
        let client = BridgeClient(discoveryBrowserFactory: { factory.makeBrowser() })
        let server = BridgeServer()
        var events: [LinkMIDIEvent] = []
        var resets = 0
        client.onEvent = { events.append($0) }
        client.onReset = { resets += 1 }
        defer { client.disconnect(); server.stop() }
        server.start()
        try await waitForDiscoveryFixture("server listening") { server.port != 0 }
        client.connect(host: "127.0.0.1", port: server.port)
        try await waitForDiscoveryFixture("synchronized MIDI connection") {
            client.isConnected && client.latencyMilliseconds != nil
        }
        let connectedStatus = client.status
        let previousResets = resets
        client.startBrowsing()
        factory.browsers[0].fail()
        client.restartBrowsing()
        #expect(client.isConnected)
        #expect(client.status == connectedStatus)
        #expect(resets == previousResets)
        server.send(.init(kind: .noteOn, note: 60, velocity: 100))
        server.send(.init(kind: .noteOff, note: 60))
        try await waitForDiscoveryFixture("MIDI after restarting discovery") { events.count == 2 }
        #expect(events.map(\.kind) == [.noteOn, .noteOff])
        #expect(events.map(\.note) == [60, 60])
        #expect(resets == previousResets)
    }
}

private enum DiscoveryTestError: Error { case timedOut(String) }

@MainActor
private func waitForDiscoveryFixture(_ description: String, _ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !condition() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw DiscoveryTestError.timedOut(description) }
        try await Task.sleep(for: .milliseconds(20))
    }
}
