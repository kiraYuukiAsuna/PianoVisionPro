import ARKit
import Foundation
import Observation
import PianoCore
import QuartzCore
import RealityKit
import simd

/// The piano's local origin is the centre of the white-key front edge.
/// Positive X follows ascending pitches; +Y is above the keys; -Z is toward the fallboard.
@MainActor
@Observable
final class SpatialCalibration {
    var translationX: Float = 0 { didSet { placementDidChange() } }
    var translationY: Float = 0.72 { didSet { placementDidChange() } }
    var translationZ: Float = -0.65 { didSet { placementDidChange() } }
    var yawDegrees: Float = 0 { didSet { placementDidChange() } }
    var pitchDegrees: Float = 0 { didSet { placementDidChange() } }
    var rollDegrees: Float = 0 { didSet { placementDidChange() } }
    var whiteKeyWidth: Float = 0.0235 { didSet { placementDidChange() } }
    var whiteKeyDepth: Float = 0.145 { didSet { placementDidChange() } }
    var isCalibrating = false { didSet { placementDidChange() } }

    private(set) var anchorID: UUID?
    private(set) var isTracked = false
    private(set) var trackingStatus = "尚未进入空间模式"
    private(set) var errorMessage: String?
    private(set) var isSavingAnchor = false

    var hasSavedAnchor: Bool { anchorID != nil }
    private(set) var isFingerCalibrationActive = false
    private(set) var fingerCalibrationStatus = "先采左端 A0，再采右端 C8。"
    private(set) var fingerCalibrationLeftPoint: SIMD3<Float>?
    var hasFingerCalibrationFirstPoint: Bool { fingerCalibrationLeftPoint != nil }
    var isFingerCalibrationBusy: Bool { fingerCaptureInFlight }
    var canStartFingerCalibration: Bool {
        isRunning && isTracked && !isSavingAnchor && !fingerCaptureInFlight && fingerTrackingProvider == nil
    }

    @ObservationIgnored private var fingerTrackingProvider: HandTrackingProvider?
    @ObservationIgnored private var fingerCaptureID: UUID?
    private var fingerCaptureInFlight = false
    @ObservationIgnored private var fingerFirstPointRunID: UUID?
    @ObservationIgnored private var fingerFirstPointCapturedAt: Double?
    @ObservationIgnored private var fingerCountdownSeconds = 3.0
    @ObservationIgnored private var fingerCaptureTimeoutSeconds = 10.0

    @ObservationIgnored var onTrackingChanged: ((Bool) -> Void)?
    @ObservationIgnored private var arSession: ARKitSession?
    @ObservationIgnored private var worldProvider: WorldTrackingProvider?
    @ObservationIgnored private var anchorTransform = matrix_identity_float4x4
    @ObservationIgnored private var anchorIsTracked = false
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var activeRunID: UUID?
    @ObservationIgnored private var placementRevision = UUID()
    @ObservationIgnored private var pendingRemovalIDs: Set<UUID> = []
    @ObservationIgnored private var restoringSettings = false
    @ObservationIgnored private var dragStartWorldPosition: SIMD3<Float>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let settingsKey = "piano.spatial-calibration.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: settingsKey),
           let saved = try? JSONDecoder().decode(SavedCalibration.self, from: data) {
            restoringSettings = true
            translationX = saved.translationX
            translationY = saved.translationY
            translationZ = saved.translationZ
            yawDegrees = saved.yawDegrees
            pitchDegrees = saved.pitchDegrees
            rollDegrees = saved.rollDegrees
            whiteKeyWidth = saved.whiteKeyWidth
            whiteKeyDepth = saved.whiteKeyDepth
            anchorID = saved.anchorID
            pendingRemovalIDs = Set(saved.pendingRemovalIDs ?? [])
            isCalibrating = false
            restoringSettings = false
        }
    }

    /// One explicit, cancellable capture per endpoint. Hand motion is never
    /// connected to keyboard motion; only two accepted stable samples commit.
    func startFingerCalibration() async {
        guard canStartFingerCalibration, let runID = activeRunID,
              let session = arSession, let world = worldProvider, world.state == .running else {
            fingerCalibrationStatus = "请先打开空间练习，等待定位恢复。"
            return
        }
        #if targetEnvironment(simulator)
        fingerCalibrationStatus = "模拟器没有真实手部追踪，请在 Vision Pro 上取点。"
        return
        #else
        guard HandTrackingProvider.isSupported else {
            fingerCalibrationStatus = "当前设备不支持手部取点，请使用按钮校准。"
            return
        }
        if hasFingerCalibrationFirstPoint,
           fingerFirstPointRunID != runID || CACurrentMediaTime() - (fingerFirstPointCapturedAt ?? 0) > 120 {
            cancelFingerCalibration()
            fingerCalibrationStatus = "左端取点已过期，请重新取左端。"
            return
        }
        let capturingRight = hasFingerCalibrationFirstPoint
        if !isCalibrating { isCalibrating = true }
        let expectedRevision = placementRevision
        let captureID = UUID()
        fingerCaptureID = captureID
        fingerCaptureInFlight = true
        isFingerCalibrationActive = true
        errorMessage = nil
        let hand = HandTrackingProvider()
        fingerTrackingProvider = hand
        var handStarted = false
        do {
            fingerCalibrationStatus = "正在开启手部追踪…"
            let authorization = await session.requestAuthorization(for: HandTrackingProvider.requiredAuthorizations)
            guard isCurrentFingerCapture(captureID, revision: expectedRevision, runID: runID, provider: world) else {
                throw CancellationError()
            }
            guard authorization.values.allSatisfy({ $0 == .allowed }) else {
                throw FingerCaptureError.message("手部追踪未授权。可到系统设置允许，或继续使用按钮校准。")
            }
            // Re-running with the same world provider retains it. Each hand
            // provider is fresh because stopped providers cannot be restarted.
            try await session.run([world, hand])
            handStarted = true
            guard isCurrentFingerCapture(captureID, revision: expectedRevision, runID: runID, provider: world) else {
                throw CancellationError()
            }
            let side = capturingRight ? "右手食指 / C8" : "左手食指 / A0"
            let countdownEnd = CACurrentMediaTime() + max(0, fingerCountdownSeconds)
            while CACurrentMediaTime() < countdownEnd {
                guard isCurrentFingerCapture(captureID, revision: expectedRevision, runID: runID, provider: world) else {
                    throw CancellationError()
                }
                let remaining = max(1, Int(ceil(countdownEnd - CACurrentMediaTime())))
                fingerCalibrationStatus = "\(remaining) 秒后采样：\(side)，轻触白键前缘中心并保持。"
                try await Task.sleep(for: .milliseconds(100))
            }
            let point = try await captureStableFinger(hand, right: capturingRight,
                captureID: captureID, revision: expectedRevision, runID: runID, world: world)
            guard isCurrentFingerCapture(captureID, revision: expectedRevision, runID: runID, provider: world) else {
                throw CancellationError()
            }
            if capturingRight, let left = fingerCalibrationLeftPoint {
                let solution = try FingerKeyboardCalibration.solve(leftFrontCenter: left, rightFrontCenter: point)
                if await commitFingerCalibration(solution, captureID: captureID, expectedRevision: expectedRevision,
                                                  runID: runID, provider: world), fingerCaptureID == captureID {
                    fingerCalibrationStatus = "两端取点完成。请检查 C4、高度和黑键，微调后保存并固定琴位。"
                }
            } else {
                fingerCalibrationLeftPoint = point
                fingerFirstPointRunID = runID
                fingerFirstPointCapturedAt = CACurrentMediaTime()
                fingerCalibrationStatus = "左端已记录。现在点击采右端，把右手食指轻放在 C8 白键前缘中心。"
            }
        } catch is CancellationError {
            if fingerCaptureID == captureID { fingerCalibrationStatus = "取点已取消，原琴位保留。" }
        } catch {
            if fingerCaptureID == captureID { fingerCalibrationStatus = error.localizedDescription }
        }
        // Stopping just the hand provider must not stop the world anchor. A
        // cancelled capture remains in-flight until this cleanup has finished.
        if handStarted {
            await cleanUpFingerProvider(hand, session: session, world: world)
        } else if fingerTrackingProvider === hand {
            fingerTrackingProvider = nil
        }
        if fingerCaptureID == captureID { fingerCaptureID = nil }
        isFingerCalibrationActive = false
        fingerCaptureInFlight = false
        #endif
    }

    func cancelFingerCalibration() {
        let wasPending = isFingerCalibrationActive || hasFingerCalibrationFirstPoint
        fingerCaptureID = nil
        isFingerCalibrationActive = false
        fingerCalibrationLeftPoint = nil
        fingerFirstPointRunID = nil
        fingerFirstPointCapturedAt = nil
        if wasPending { fingerCalibrationStatus = "取点已取消，原琴位保留。" }
    }

    private func cleanUpFingerProvider(_ hand: HandTrackingProvider, session: ARKitSession,
                                        world: WorldTrackingProvider) async {
        guard arSession === session, worldProvider === world, fingerTrackingProvider === hand else { return }
        if world.state == .stopped {
            // A stopped world provider cannot be supplied to run again. Stop
            // its remaining hand provider; reopening creates fresh providers.
            session.stop()
            fingerTrackingProvider = nil
            return
        }
        guard world.state == .running else {
            // Retain the pending provider while the session is interrupted.
            // monitorTracking removes it before accepting another capture.
            return
        }
        do {
            try await session.run([world])
            if fingerTrackingProvider === hand { fingerTrackingProvider = nil }
        } catch {
            if arSession === session, worldProvider === world {
                session.stop()
                fingerTrackingProvider = nil
                errorMessage = "结束手部追踪失败，请重新打开空间练习：\(error.localizedDescription)"
            }
        }
    }

    private func isCurrentFingerCapture(_ captureID: UUID, revision: UUID, runID: UUID,
                                       provider: WorldTrackingProvider) -> Bool {
        fingerCaptureID == captureID && isFingerCalibrationActive && placementRevision == revision
            && isTracked && provider.state == .running && isCurrentRun(runID, provider: provider)
    }

    private func captureStableFinger(_ hand: HandTrackingProvider, right: Bool, captureID: UUID,
                                     revision: UUID, runID: UUID, world: WorldTrackingProvider) async throws -> SIMD3<Float> {
        var sampler = StableFingerPointSampler()
        let deadline = CACurrentMediaTime() + max(0.1, fingerCaptureTimeoutSeconds)
        var lastFresh = CACurrentMediaTime()
        while CACurrentMediaTime() < deadline {
            guard isCurrentFingerCapture(captureID, revision: revision, runID: runID, provider: world) else {
                throw CancellationError()
            }
            guard hand.state == .running else { throw FingerCaptureError.message("手部追踪已暂停，请重试取点。") }
            let anchors = hand.latestAnchors // Consuming getter: read exactly once per poll.
            let anchor = right ? anchors.rightHand : anchors.leftHand
            let now = CACurrentMediaTime()
            if let anchor {
                if anchor.isTracked, let skeleton = anchor.handSkeleton,
                   skeleton.joint(.indexFingerTip).isTracked {
                    let tip = skeleton.joint(.indexFingerTip)
                    let transform = anchor.originFromAnchorTransform * tip.anchorFromJointTransform
                    let point = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
                    lastFresh = now
                    fingerCalibrationStatus = "正在采\(right ? "右" : "左")端：食指轻触前缘中心，保持稳定…"
                    if let stable = sampler.add(timestamp: now, position: point) { return stable }
                } else {
                    // An explicit tracking loss invalidates the whole window.
                    // A nil consuming getter, by contrast, can mean no new frame.
                    sampler.reset()
                    fingerCalibrationStatus = "食指追踪暂时丢失，请看向目标并重新保持稳定。"
                }
            }
            if now - lastFresh > 0.15 {
                sampler.reset()
                fingerCalibrationStatus = "暂未看清\(right ? "右" : "左")食指，请看向该端，轻放指尖并保持。"
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FingerCaptureError.message("指尖未能稳定取点。请看向目标琴键、保持手指可见后重试。")
    }

    /// Commit only after both points passed geometry and capture-generation
    /// checks. Until this boundary, cancellation never changes the saved pose.
    private func commitFingerCalibration(_ solution: FingerKeyboardCalibration, captureID: UUID,
                                         expectedRevision: UUID, runID: UUID,
                                         provider: WorldTrackingProvider) async -> Bool {
        guard isCurrentFingerCapture(captureID, revision: expectedRevision, runID: runID, provider: provider),
              !isSavingAnchor else { return false }
        let previousID = anchorID
        restoringSettings = true
        anchorID = nil
        anchorTransform = matrix_identity_float4x4
        anchorIsTracked = false
        translationX = solution.translation.x
        translationY = solution.translation.y
        translationZ = solution.translation.z
        yawDegrees = solution.yawDegrees
        pitchDegrees = solution.pitchDegrees
        rollDegrees = solution.rollDegrees
        whiteKeyWidth = solution.whiteKeyWidth
        isCalibrating = true
        restoringSettings = false
        placementRevision = UUID()
        fingerCalibrationLeftPoint = nil
        fingerFirstPointRunID = nil
        fingerFirstPointCapturedAt = nil
        persist()
        // The pose is now committed. Remove the Cancel action while retiring
        // the old anchor, and keep controls locked until provider cleanup ends.
        isFingerCalibrationActive = false
        fingerCalibrationStatus = "两端取点完成。请检查 C4、高度和黑键，微调后保存并固定琴位。"
        // Retire the old anchor after the new provisional pose is durable.
        let committedRevision = placementRevision
        if let previousID, let error = await removeOrQueueAnchor(previousID, using: provider),
           placementRevision == committedRevision {
            errorMessage = "旧定位点未能移除，稍后会重试：\(error.localizedDescription)"
        }
        return true
    }

    /// Applied every rendering frame, including ARKit updates after an origin recenter.
    var worldFromKeyboard: simd_float4x4 {
        let radians = Float.pi / 180
        let rotation = simd_quatf(angle: yawDegrees * radians, axis: [0, 1, 0])
            * simd_quatf(angle: pitchDegrees * radians, axis: [1, 0, 0])
            * simd_quatf(angle: rollDegrees * radians, axis: [0, 0, 1])
        let offset = Transform(scale: .one, rotation: rotation,
                               translation: [translationX, translationY, translationZ]).matrix
        return anchorID == nil ? offset : anchorTransform * offset
    }

    /// Move by a world-space delta, preserving an existing anchor and its relative offsets.
    func applyDragTranslation(_ worldDelta: SIMD3<Float>) {
        guard !isSavingAnchor, worldDelta.x.isFinite, worldDelta.y.isFinite, worldDelta.z.isFinite,
              simd_length_squared(worldDelta) > 0 else { return }
        let relative = anchorID == nil ? SIMD4(worldDelta, 0)
            : simd_inverse(anchorTransform) * SIMD4(worldDelta, 0)
        guard relative.x.isFinite, relative.y.isFinite, relative.z.isFinite else { return }
        restoringSettings = true
        translationX += relative.x
        translationY += relative.y
        translationZ += relative.z
        restoringSettings = false
        placementRevision = UUID()
        if dragStartWorldPosition == nil { persist() }
    }

    /// Direction buttons follow the keyboard's horizontal axes; height always follows gravity.
    func nudgePlacement(right: Float = 0, up: Float = 0, towardPlayer: Float = 0) {
        guard !isSavingAnchor, !isFingerCalibrationActive else { return }
        cancelFingerCalibration()
        endDirectPlacementDrag()
        let pose = worldFromKeyboard
        let rightAxis = SIMD3<Float>(pose.columns.0.x, 0, pose.columns.0.z)
        let playerAxis = SIMD3<Float>(pose.columns.2.x, 0, pose.columns.2.z)
        guard simd_length_squared(rightAxis) > 0.0001,
              simd_length_squared(playerAxis) > 0.0001 else { return }
        applyDragTranslation(simd_normalize(rightAxis) * right
            + SIMD3(0, up, 0) + simd_normalize(playerAxis) * towardPlayer)
    }

    @discardableResult
    func beginDirectPlacementDrag() -> Bool {
        guard isCalibrating, isTracked, !isSavingAnchor else { return false }
        endDirectPlacementDrag()
        let origin = worldFromKeyboard.columns.3
        dragStartWorldPosition = [origin.x, origin.y, origin.z]
        return true
    }

    /// Translation is cumulative from the gesture's beginning, in world/scene metres.
    func updateDirectPlacementDrag(worldTranslation: SIMD3<Float>) {
        guard let start = dragStartWorldPosition, isCalibrating, !isSavingAnchor else { return }
        let origin = worldFromKeyboard.columns.3
        let current = SIMD3<Float>(origin.x, origin.y, origin.z)
        applyDragTranslation(start + worldTranslation - current)
    }

    func endDirectPlacementDrag() {
        guard dragStartWorldPosition != nil else { return }
        dragStartWorldPosition = nil
        persist()
    }

    /// This is a convenient manual starting pose, not detection of the physical piano.
    func placeTemplateInFront() async {
        guard !isSavingAnchor, !fingerCaptureInFlight else { return }
        cancelFingerCalibration()
        errorMessage = nil
        guard isRunning else {
            errorMessage = "请先打开空间练习，再把模板放到面前。"
            return
        }
        let devicePose: simd_float4x4
        #if targetEnvironment(simulator)
        devicePose = matrix_identity_float4x4
        #else
        guard let provider = worldProvider, provider.state == .running,
              let device = provider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), device.isTracked else {
            errorMessage = "暂时无法确定头显位置，请等待空间追踪恢复。"
            return
        }
        devicePose = device.originFromAnchorTransform
        #endif
        let horizontalForward = SIMD3<Float>(-devicePose.columns.2.x, 0, -devicePose.columns.2.z)
        guard horizontalForward.x.isFinite, horizontalForward.z.isFinite,
              simd_length_squared(horizontalForward) > 0.01 else {
            errorMessage = "请抬头朝向钢琴方向，再把模板放到面前。"
            return
        }
        let forward = simd_normalize(horizontalForward)
        let previousID = anchorID
        let removalProvider = worldProvider
        endDirectPlacementDrag()
        placementRevision = UUID()
        restoringSettings = true
        anchorID = nil
        anchorTransform = matrix_identity_float4x4
        anchorIsTracked = false
        translationX = devicePose.columns.3.x + forward.x * 0.65
        translationY = 0.72
        translationZ = devicePose.columns.3.z + forward.z * 0.65
        yawDegrees = atan2(-forward.x, -forward.z) * 180 / .pi
        pitchDegrees = 0
        rollDegrees = 0
        isCalibrating = true
        restoringSettings = false
        persist()
        setTracked(true)
        trackingStatus = "模板已放到面前 · 请与实体琴键手动对齐"
        let revision = placementRevision
        if let previousID, let error = await removeOrQueueAnchor(previousID, using: removalProvider),
           placementRevision == revision {
            errorMessage = "旧定位点未能移除：\(error.localizedDescription)"
        }
    }

    /// Called for the lifetime of the mixed immersive space, never from a window alone.
    func run() async {
        guard !isRunning else { return }
        isRunning = true
        let runID = UUID()
        activeRunID = runID
        defer {
            if activeRunID == runID { stop() }
        }
        errorMessage = nil

        #if targetEnvironment(simulator)
        trackingStatus = "模拟器预览 · 真机才能验证空间定位"
        setTracked(true)
        while !Task.isCancelled && activeRunID == runID {
            try? await Task.sleep(for: .milliseconds(200))
        }
        #else
        guard WorldTrackingProvider.isSupported else {
            trackingStatus = "此设备不支持空间追踪"
            errorMessage = trackingStatus
            isRunning = false
            return
        }
        let session = ARKitSession()
        let provider = WorldTrackingProvider()
        arSession = session
        worldProvider = provider
        trackingStatus = hasSavedAnchor ? "正在恢复琴键定位点…" : "正在启动空间追踪…"

        do {
            let required = WorldTrackingProvider.requiredAuthorizations
            if !required.isEmpty {
                let result = await session.requestAuthorization(for: required)
                guard isCurrentRun(runID, provider: provider) else { return }
                guard result.values.allSatisfy({ $0 == .allowed }) else {
                    errorMessage = "请在系统设置中允许空间感知，再重新进入空间模式。"
                    trackingStatus = "空间权限未开启"
                    stop()
                    return
                }
            }
            try await session.run([provider])
            guard isCurrentRun(runID, provider: provider) else {
                session.stop()
                return
            }
            for id in pendingRemovalIDs {
                await removeOrQueueAnchor(id, using: provider)
                guard isCurrentRun(runID, provider: provider) else { return }
            }
            // allAnchors includes previously persisted anchors. The update sequence also supplies
            // restored anchors and remains the source of truth as their origin transforms change.
            if let savedID = anchorID,
               let restored = await provider.allAnchors?.first(where: { $0.id == savedID }) {
                guard isCurrentRun(runID, provider: provider) else { return }
                if anchorID == savedID { apply(restored) }
            }
            guard isCurrentRun(runID, provider: provider) else { return }
            await withTaskCancellationHandler {
                async let updates: Void = consumeAnchors(provider)
                async let events: Void = consumeEvents(session)
                async let tracking: Void = monitorTracking(provider)
                _ = await (updates, events, tracking)
            } onCancel: {
                Task { @MainActor [weak self] in
                    if self?.activeRunID == runID { self?.stop() }
                }
            }
        } catch {
            guard isCurrentRun(runID, provider: provider) else { return }
            errorMessage = "空间追踪启动失败：\(error.localizedDescription)"
            trackingStatus = "空间追踪不可用"
        }
        #endif
    }

    func stop() {
        cancelFingerCalibration()
        endDirectPlacementDrag()
        placementRevision = UUID()
        arSession?.stop()
        arSession = nil
        worldProvider = nil
        fingerTrackingProvider = nil
        isRunning = false
        activeRunID = nil
        anchorIsTracked = false
        setTracked(false)
        trackingStatus = "空间模式已关闭"
    }

    /// Saves the displayed keyboard pose as a room-fixed anchor. It is not attached to the piano.
    func saveAnchor() async {
        guard !isSavingAnchor, !fingerCaptureInFlight, !hasFingerCalibrationFirstPoint else { return }
        endDirectPlacementDrag()
        errorMessage = nil
        #if targetEnvironment(simulator)
        errorMessage = "模拟器仅用于预览，请在 Vision Pro 上保存空间定位点。"
        return
        #else
        guard let provider = worldProvider, let runID = activeRunID,
              provider.state == .running, isTracked else {
            errorMessage = "请先进入空间模式，等待定位恢复后再保存。"
            return
        }
        isSavingAnchor = true
        defer { isSavingAnchor = false }
        let revision = placementRevision
        let previousID = anchorID
        let newAnchor = WorldAnchor(originFromAnchorTransform: worldFromKeyboard)
        do {
            try await provider.addAnchor(newAnchor)
            guard isCurrentSave(revision, runID: runID, provider: provider) else {
                await removeOrQueueAnchor(newAnchor.id, using: provider)
                return
            }
            // The .added update may arrive while addAnchor is suspended. Read the latest pose,
            // then check again: this await also allows reset, stop or manual edits to run.
            let added = await provider.allAnchors?.first(where: { $0.id == newAnchor.id })
            guard isCurrentSave(revision, runID: runID, provider: provider) else {
                await removeOrQueueAnchor(newAnchor.id, using: provider)
                return
            }
            // Replace only after ARKit accepted the new anchor. Keep the old one on a failed save.
            restoringSettings = true
            apply(added ?? newAnchor)
            anchorID = newAnchor.id
            translationX = 0
            translationY = 0
            translationZ = 0
            yawDegrees = 0
            pitchDegrees = 0
            rollDegrees = 0
            isCalibrating = false
            restoringSettings = false
            persist()
            if let previousID {
                await removeOrQueueAnchor(previousID, using: provider)
            }
        } catch {
            guard isCurrentSave(revision, runID: runID, provider: provider) else { return }
            errorMessage = "定位点保存失败：\(error.localizedDescription)"
        }
        #endif
    }

    /// Call from "重新校准". A new room position is established through the manual controls.
    func clearAnchor() async {
        cancelFingerCalibration()
        errorMessage = nil
        let savedID = anchorID
        // Ignore the intentional .removed event; only unexpected removals invalidate calibration.
        resetPlacement()
        fingerCalibrationStatus = "琴位已重置，可重新取左端 A0。"
        guard let savedID else { return }
        let revision = placementRevision
        if let error = await removeOrQueueAnchor(savedID, using: worldProvider),
           placementRevision == revision {
            errorMessage = "旧定位点未能移除：\(error.localizedDescription)"
        }
    }

    private func resetPlacement() {
        cancelFingerCalibration()
        dragStartWorldPosition = nil
        placementRevision = UUID()
        restoringSettings = true
        anchorID = nil
        anchorTransform = matrix_identity_float4x4
        anchorIsTracked = false
        translationX = 0
        translationY = 0.72
        translationZ = -0.65
        yawDegrees = 0
        pitchDegrees = 0
        rollDegrees = 0
        isCalibrating = true
        restoringSettings = false
        persist()
    }

    private func isCurrentRun(_ runID: UUID, provider: WorldTrackingProvider) -> Bool {
        !Task.isCancelled && isRunning && activeRunID == runID && worldProvider === provider
    }

    private func isCurrentSave(_ revision: UUID, runID: UUID,
                               provider: WorldTrackingProvider) -> Bool {
        placementRevision == revision && isCurrentRun(runID, provider: provider)
            && provider.state == .running
    }

    /// Persist before awaiting removal so a stopped provider or interrupted cleanup can be retried.
    @discardableResult
    private func removeOrQueueAnchor(_ id: UUID, using provider: WorldTrackingProvider?) async -> Error? {
        pendingRemovalIDs.insert(id)
        persist()
        guard let provider, provider.state == .running else { return nil }
        do {
            try await provider.removeAnchor(forID: id)
            pendingRemovalIDs.remove(id)
            persist()
            return nil
        } catch {
            return error
        }
    }

    private func placementDidChange() {
        guard !restoringSettings else { return }
        cancelFingerCalibration()
        placementRevision = UUID()
        if dragStartWorldPosition == nil { persist() }
    }

    private func consumeAnchors(_ provider: WorldTrackingProvider) async {
        for await update in provider.anchorUpdates {
            guard !Task.isCancelled, worldProvider === provider else { return }
            guard update.anchor.id == anchorID else { continue }
            switch update.event {
            case .added, .updated:
                apply(update.anchor)
            case .removed:
                resetPlacement()
                setTracked(false)
                errorMessage = "保存的空间定位点已失效，请重新校准。"
            }
        }
    }

    private func apply(_ anchor: WorldAnchor) {
        anchorTransform = anchor.originFromAnchorTransform
        anchorIsTracked = anchor.isTracked
    }

    private func consumeEvents(_ session: ARKitSession) async {
        for await event in session.events {
            guard !Task.isCancelled, arSession === session else { return }
            switch event {
            case .authorizationChanged(let type, let status) where status == .denied:
                if type == .handTracking {
                    cancelFingerCalibration()
                    fingerCalibrationStatus = "手部追踪权限已关闭，可继续使用按钮校准。"
                } else if type == .worldSensing {
                    setTracked(false)
                    trackingStatus = "空间权限已关闭"
                    errorMessage = "请在系统设置中允许空间感知。"
                }
            case .dataProviderStateChanged(let providers, let state, let error):
                if providers.contains(where: { ($0 as? WorldTrackingProvider) === worldProvider }) {
                    if state != .running { setTracked(false) }
                    if let error { errorMessage = error.localizedDescription }
                }
            default:
                break
            }
        }
    }

    private func monitorTracking(_ provider: WorldTrackingProvider) async {
        while !Task.isCancelled && isRunning && worldProvider === provider {
            if provider.state == .running, !fingerCaptureInFlight,
               let hand = fingerTrackingProvider, let session = arSession {
                await cleanUpFingerProvider(hand, session: session, world: provider)
                guard !Task.isCancelled, isRunning, worldProvider === provider else { return }
            }
            let deviceTracked = provider.state == .running
                && provider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())?.isTracked == true
            let tracked = deviceTracked && (anchorID == nil || anchorIsTracked)
            setTracked(tracked)
            if tracked {
                trackingStatus = anchorID == nil ? "定位正常 · 请校准琴键" : "琴键定位已恢复"
            } else if anchorID != nil {
                trackingStatus = "正在寻找琴键定位点 · 练习已暂停"
            } else {
                trackingStatus = "空间追踪暂不可用 · 练习已暂停"
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func setTracked(_ tracked: Bool) {
        guard isTracked != tracked else { return }
        isTracked = tracked
        if !tracked { cancelFingerCalibration() }
        onTrackingChanged?(tracked)
    }

    private func persist() {
        guard !restoringSettings else { return }
        let saved = SavedCalibration(translationX: translationX, translationY: translationY,
                                     translationZ: translationZ, yawDegrees: yawDegrees,
                                     pitchDegrees: pitchDegrees, rollDegrees: rollDegrees,
                                     whiteKeyWidth: whiteKeyWidth, whiteKeyDepth: whiteKeyDepth,
                                     anchorID: anchorID, pendingRemovalIDs: Array(pendingRemovalIDs))
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: settingsKey)
        }
    }
}

private struct SavedCalibration: Codable {
    var translationX: Float
    var translationY: Float
    var translationZ: Float
    var yawDegrees: Float
    var pitchDegrees: Float
    var rollDegrees: Float
    var whiteKeyWidth: Float
    var whiteKeyDepth: Float
    var anchorID: UUID?
    var pendingRemovalIDs: [UUID]?
}

private enum FingerCaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}
