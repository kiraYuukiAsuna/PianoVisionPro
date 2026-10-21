import Foundation
import simd

// A controllable ARKit boundary for the host-side regression harness. The production
// SpatialCalibration source is compiled unchanged apart from its framework imports.
enum DataProviderState: Sendable { case initialized, running, paused, stopped }

@MainActor
protocol DataProvider: AnyObject, Sendable {
    var state: DataProviderState { get set }
}

@MainActor
struct WorldAnchor {
    let id = UUID()
    let originFromAnchorTransform: simd_float4x4
    var isTracked = true
}

@MainActor
final class WorldTrackingProvider: DataProvider {
    typealias State = DataProviderState
    enum AnchorEvent { case added, updated, removed }
    struct AnchorUpdate {
        let anchor: WorldAnchor
        let event: AnchorEvent
    }
    struct DeviceAnchor {
        let isTracked: Bool
        let originFromAnchorTransform: simd_float4x4
    }

    static var isSupported: Bool { true }
    static var requiredAuthorizations: [ARKitSession.AuthorizationType] { [] }
    var state = State.running
    var deviceAnchor: DeviceAnchor? = DeviceAnchor(isTracked: true, originFromAnchorTransform: matrix_identity_float4x4)
    let anchorUpdates = AsyncStream<AnchorUpdate> { _ in }
    var anchors: [WorldAnchor] = []
    var pendingAnchor: WorldAnchor?
    var removedIDs: [UUID] = []
    var failRemoval = false
    var suspendRemovals = false
    var removalIsSuspended = false
    var suspendReads = false
    var readIsSuspended = false
    private var addContinuation: CheckedContinuation<Void, Error>?
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var removalContinuation: CheckedContinuation<Void, Never>?

    var allAnchors: [WorldAnchor]? {
        get async {
            if suspendReads {
                await withCheckedContinuation { continuation in
                    readIsSuspended = true
                    readContinuation = continuation
                }
            }
            return anchors
        }
    }

    func addAnchor(_ anchor: WorldAnchor) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pendingAnchor = anchor
            addContinuation = continuation
        }
    }

    func finishAdd(failing: Bool = false) {
        let continuation = addContinuation
        addContinuation = nil
        if failing {
            continuation?.resume(throwing: MockFailure.operationFailed)
        } else {
            if let pendingAnchor { anchors.append(pendingAnchor) }
            continuation?.resume()
        }
        pendingAnchor = nil
    }

    func finishRead() {
        suspendReads = false
        let continuation = readContinuation
        readContinuation = nil
        continuation?.resume()
    }

    func removeAnchor(forID id: UUID) async throws {
        if failRemoval { throw MockFailure.operationFailed }
        if suspendRemovals {
            await withCheckedContinuation { continuation in
                removalIsSuspended = true
                removalContinuation = continuation
            }
        }
        removedIDs.append(id)
        anchors.removeAll { $0.id == id }
    }

    func finishRemoval() {
        suspendRemovals = false
        let continuation = removalContinuation
        removalContinuation = nil
        continuation?.resume()
    }

    func queryDeviceAnchor(atTimestamp: Double) -> DeviceAnchor? {
        deviceAnchor
    }
}

@MainActor
struct HandSkeleton {
    enum JointName: Hashable { case indexFingerTip }
    struct Joint {
        var isTracked = true
        var anchorFromJointTransform: simd_float4x4
    }
    var indexFingerTip: Joint

    func joint(_ name: JointName) -> Joint { indexFingerTip }
}

@MainActor
struct HandAnchor {
    enum Chirality { case left, right }
    var chirality: Chirality = .right
    var isTracked = true
    var originFromAnchorTransform: simd_float4x4
    var handSkeleton: HandSkeleton?
}

@MainActor
final class HandTrackingProvider: DataProvider {
    typealias State = DataProviderState
    static var isSupported = true
    static var requiredAuthorizations: [ARKitSession.AuthorizationType] { [.handTracking] }
    static var instances: [HandTrackingProvider] = []
    var state = DataProviderState.initialized
    private var latest: (leftHand: HandAnchor?, rightHand: HandAnchor?) = (nil, nil)
    private(set) var latestAnchorsReadCount = 0

    init() { Self.instances.append(self) }

    /// Match ARKit's consume-on-read contract. A production sample that reads
    /// left/right via two getter calls must not silently receive the same frame.
    var latestAnchors: (leftHand: HandAnchor?, rightHand: HandAnchor?) {
        latestAnchorsReadCount += 1
        let result = latest
        latest = (nil, nil)
        return result
    }

    func publish(left: HandAnchor? = nil, right: HandAnchor? = nil) {
        latest = (left, right)
    }
}

@MainActor
final class ARKitSession {
    enum AuthorizationType: Hashable, Sendable { case worldSensing, handTracking }
    enum AuthorizationStatus: Sendable { case allowed, denied }
    enum Event: Sendable {
        case authorizationChanged(AuthorizationType, AuthorizationStatus)
        case dataProviderStateChanged([any DataProvider], DataProviderState, Error?)
    }
    let events: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation
    var authorizationStatuses: [AuthorizationType: AuthorizationStatus] = [.worldSensing: .allowed, .handTracking: .allowed]
    var suspendAuthorization = false
    private(set) var authorizationIsSuspended = false
    private(set) var requestedAuthorizations: [[AuthorizationType]] = []
    var suspendRuns = false
    private(set) var runIsSuspended = false
    var failNextRun = false
    private(set) var runRequests: [[any DataProvider]] = []
    private(set) var runningProviders: [any DataProvider] = []
    private(set) var stopCount = 0
    private var authorizationContinuation: CheckedContinuation<Void, Never>?
    private var runContinuation: CheckedContinuation<Void, Never>?

    init() {
        let stream = AsyncStream<Event>.makeStream()
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func emit(_ event: Event) { eventContinuation.yield(event) }

    func requestAuthorization(for types: [AuthorizationType]) async -> [AuthorizationType: AuthorizationStatus] {
        requestedAuthorizations.append(types)
        if suspendAuthorization {
            await withCheckedContinuation { continuation in
                authorizationIsSuspended = true
                authorizationContinuation = continuation
            }
        }
        return Dictionary(uniqueKeysWithValues: types.map { ($0, authorizationStatuses[$0] ?? .allowed) })
    }
    func finishAuthorization() {
        suspendAuthorization = false
        authorizationIsSuspended = false
        let continuation = authorizationContinuation
        authorizationContinuation = nil
        continuation?.resume()
    }
    func run(_ providers: [any DataProvider]) async throws {
        runRequests.append(providers)
        if suspendRuns {
            await withCheckedContinuation { continuation in
                runIsSuspended = true
                runContinuation = continuation
            }
        }
        if failNextRun {
            failNextRun = false
            throw MockFailure.operationFailed
        }
        for previous in runningProviders where !providers.contains(where: { $0 === previous }) {
            previous.state = .stopped
        }
        runningProviders = providers
        for provider in providers { provider.state = .running }
    }
    func finishRun() {
        suspendRuns = false
        runIsSuspended = false
        let continuation = runContinuation
        runContinuation = nil
        continuation?.resume()
    }
    func stop() {
        stopCount += 1
        for provider in runningProviders { provider.state = .stopped }
        runningProviders.removeAll()
    }
}

enum MockFailure: Error { case operationFailed }
