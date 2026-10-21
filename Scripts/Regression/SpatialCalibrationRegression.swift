import Foundation

// This extension shares a generated source file with the actual implementation, so
// only test setup reaches private state; all actions and assertions exercise its API.
extension SpatialCalibration {
    func startForRegression(using provider: WorldTrackingProvider, editing: Bool = true) {
        isRunning = true
        activeRunID = UUID()
        worldProvider = provider
        arSession = ARKitSession()
        isCalibrating = editing
        fingerCountdownSeconds = 0
        fingerCaptureTimeoutSeconds = 0.8
        setTracked(true)
    }

    var sessionForRegression: ARKitSession { arSession! }

    func consumeEventsForRegression() async {
        guard let session = arSession else { return }
        await consumeEvents(session)
    }

    func setTrackingForRegression(_ tracked: Bool) { setTracked(tracked) }
    func setFingerTimeoutForRegression(_ seconds: Double) { fingerCaptureTimeoutSeconds = seconds }
    func monitorTrackingForRegression(using provider: WorldTrackingProvider) async { await monitorTracking(provider) }
}

@main
struct SpatialCalibrationRegression {
    @MainActor
    static func main() async throws {
        try await successfulSaveAndRestore()
        try await failedSaveKeepsPreviousPlacement()
        try await clearDuringAddDoesNotRestoreOldPlacement()
        try await manualEditDuringAddIsPreserved()
        try await stopAndNewRunDuringAddCannotCommit()
        try await cancelledSaveCannotCommit()
        try await clearDuringAnchorReadCannotCommit()
        try await failedStaleCleanupIsPersisted()
        try directDraggingIsCumulativeAndPersistsOnEnd()
        try await anchoredDragAndDirectionButtonsUseWorldCoordinates()
        try await pendingSaveRejectsDragAndFrontPlacement()
        try await frontPlacementFollowsHeadDirectionAndClearsPreviousAnchor()
        try await frontPlacementWithoutDeviceTrackingPreservesPlacement()
        try defaultCalibrationIsLockedUntilExplicitAction()
        try await twoFingerSamplesCommitOnlyAfterBothEndpoints()
        try await invalidRightEndpointPreservesSavedPose()
        try await handPermissionDenialAndEventsLeaveWorldTrackingIntact()
        try await cancelDuringPermissionRetainsExclusiveCaptureUntilCleanup()
        try await stopDuringPermissionCannotAffectANewRun()
        try await cancelDuringProviderRunRestoresOnlyWorldTracking()
        try await pausedWorldCleansUpHandWhenTrackingResumes()
        try await cancellationAndTrackingLossDuringSamplingCannotCommit()
        try await untrackedHandsAndJointsNeverBecomeSamplePoints()
        try await explicitTrackingLossRestartsTheFullStableWindow()
        try await pendingSaveAndFingerCaptureExcludeEachOther()
        try await failedFingerAnchorRetirementRemainsDurable()
        try await clearDuringFingerCommitCleanupDoesNotReportOldSuccess()
        print("SpatialCalibration regression: 27 scenarios passed")
    }

    @MainActor
    static func fixture() -> (SpatialCalibration, WorldTrackingProvider, UserDefaults, String) {
        let suite = "piano.spatial-regression.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let calibration = SpatialCalibration(defaults: defaults)
        let provider = WorldTrackingProvider()
        calibration.startForRegression(using: provider)
        return (calibration, provider, defaults, suite)
    }

    @MainActor
    static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<5_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw RegressionFailure.timedOut
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw RegressionFailure.assertion(message) }
    }

    static func samePose(_ lhs: simd_float4x4, _ rhs: simd_float4x4) -> Bool {
        simd_length(lhs.columns.0 - rhs.columns.0) < 0.0001
            && simd_length(lhs.columns.1 - rhs.columns.1) < 0.0001
            && simd_length(lhs.columns.2 - rhs.columns.2) < 0.0001
            && simd_length(lhs.columns.3 - rhs.columns.3) < 0.0001
    }

    @MainActor
    static func fingerAnchor(at point: SIMD3<Float>, right: Bool,
                             tracked: Bool = true, jointTracked: Bool = true) -> HandAnchor {
        // Non-identity hand origin ensures production multiplies both transforms
        // instead of treating a skeleton-local point as a world position.
        var origin = simd_float4x4(simd_quatf(angle: 0.4, axis: [0, 1, 0]))
        origin.columns.3 = [0.13, 0.08, -0.2, 1]
        var joint = matrix_identity_float4x4
        joint.columns.3 = simd_inverse(origin) * SIMD4(point, 1)
        return HandAnchor(chirality: right ? .right : .left, isTracked: tracked,
                          originFromAnchorTransform: origin,
                          handSkeleton: HandSkeleton(indexFingerTip: .init(isTracked: jointTracked,
                                                                          anchorFromJointTransform: joint)))
    }

    @MainActor
    static func startFingerPoint(_ calibration: SpatialCalibration, point: SIMD3<Float>,
                                 tracked: Bool = true, jointTracked: Bool = true) async throws
        -> (Task<Void, Never>, Task<Void, Never>, HandTrackingProvider) {
        let right = calibration.hasFingerCalibrationFirstPoint
        let previousCount = HandTrackingProvider.instances.count
        let capture = Task { await calibration.startFingerCalibration() }
        try await waitUntil { HandTrackingProvider.instances.count > previousCount
            && HandTrackingProvider.instances.last?.state == .running }
        let hand = HandTrackingProvider.instances.last!
        let target = fingerAnchor(at: point, right: right, tracked: tracked, jointTracked: jointTracked)
        let unrelated = fingerAnchor(at: [50, 10, 20], right: !right)
        let feed = Task { @MainActor in
            while !Task.isCancelled {
                hand.publish(left: right ? unrelated : target, right: right ? target : unrelated)
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        return (capture, feed, hand)
    }

    @MainActor
    @discardableResult
    static func captureFingerPoint(_ calibration: SpatialCalibration, point: SIMD3<Float>,
                                   tracked: Bool = true, jointTracked: Bool = true) async throws -> HandTrackingProvider {
        let (capture, feed, hand) = try await startFingerPoint(calibration, point: point,
                                                              tracked: tracked, jointTracked: jointTracked)
        await capture.value
        feed.cancel()
        await feed.value
        return hand
    }

    @MainActor
    static func successfulSaveAndRestore() async throws {
        let (calibration, provider, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        calibration.translationX = 0.3
        let firstSave = Task { await calibration.saveAnchor() }
        try await waitUntil { provider.pendingAnchor != nil }
        let originalID = provider.pendingAnchor!.id
        provider.finishAdd()
        await firstSave.value
        calibration.translationX = 0.1
        let save = Task { await calibration.saveAnchor() }
        try await waitUntil { provider.pendingAnchor != nil }
        let newID = provider.pendingAnchor!.id
        provider.finishAdd()
        await save.value
        try check(calibration.anchorID == newID, "Successful save did not install the new anchor")
        try check(calibration.translationX == 0 && !calibration.isCalibrating,
                  "Successful save did not normalize the displayed placement")
        try check(abs(calibration.worldFromKeyboard.columns.3.x - 0.4) < 0.0001,
                  "Saving changed the keyboard's world position")
        try check(provider.removedIDs.contains(originalID), "Replacing an anchor did not remove the old one")
        let restored = SpatialCalibration(defaults: defaults)
        try check(restored.anchorID == newID && !restored.isCalibrating,
                  "Successful save did not persist the anchor")
        try check(!calibration.isSavingAnchor, "Saving state remained active after completion")
    }

    @MainActor
    static func failedSaveKeepsPreviousPlacement() async throws {
        let (calibration, provider, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        calibration.translationX = 0.3
        let firstSave = Task { await calibration.saveAnchor() }
        try await waitUntil { provider.pendingAnchor != nil }
        let originalID = provider.pendingAnchor!.id
        provider.finishAdd()
        await firstSave.value
        calibration.translationX = 0.1
        let save = Task { await calibration.saveAnchor() }
        try await waitUntil { provider.pendingAnchor != nil }
        provider.finishAdd(failing: true)
        await save.value
        try check(calibration.anchorID == originalID && calibration.translationX == 0.1,
                  "A failed save changed the placement")
        try check(calibration.errorMessage != nil && !provider.removedIDs.contains(originalID),
                  "A failed save removed the old anchor or failed to report the failure")
        try check(!calibration.isSavingAnchor, "Failed save left saving state active")
    }

    @MainActor
    static func clearDuringAddDoesNotRestoreOldPlacement() async throws {
        let (calibration, provider, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        calibration.translationX = 0.4
        let save = Task { await calibration.saveAnchor() }
        try await waitUntil { provider.pendingAnchor != nil }
        let staleID = provider.pendingAnchor!.id
        await calibration.clearAnchor()
        calibration.translationX = -0.2
        provider.suspendRemovals = true
        provider.finishAdd()
        try await waitUntil { provider.removalIsSuspended }
        try check(calibration.isSavingAnchor, "Saving state ended before stale cleanup completed")
        provider.finishRemoval()
        await save.value
        try check(calibration.anchorID == nil && calibration.translationX == -0.2,
                  "An outdated save overwrote a newly calibrated position")
        try check(calibration.isCalibrating && provider.removedIDs.contains(staleID),
                  "An outdated accepted anchor was not removed")
    }

    @MainActor
    static func manualEditDuringAddIsPreserved() async throws {
        let (calibration, provider, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let save = Task { await calibration.saveAnchor() }
        try await waitUntil { provider.pendingAnchor != nil }
        calibration.whiteKeyWidth = 0.024
        calibration.yawDegrees = 12
        provider.finishAdd()
        await save.value
        try check(calibration.anchorID == nil && calibration.yawDegrees == 12,
                  "A manual edit did not invalidate the pending save")
        try check(calibration.whiteKeyWidth == 0.024 && calibration.isCalibrating,
                  "A pending save reset manual dimensions or hid calibration")
    }

    @MainActor
    static func stopAndNewRunDuringAddCannotCommit() async throws {
        let (calibration, provider, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let save = Task { await calibration.saveAnchor() }
        try await waitUntil { provider.pendingAnchor != nil }
        let staleID = provider.pendingAnchor!.id
        calibration.stop()
        calibration.startForRegression(using: WorldTrackingProvider())
        calibration.translationZ = -0.9
        provider.finishAdd()
        await save.value
        try check(calibration.anchorID == nil && calibration.translationZ == -0.9,
                  "An old run's save changed the new run")
        try check(provider.removedIDs.contains(staleID), "An old run leaked its accepted anchor")
        try check(!calibration.isSavingAnchor, "Old-run cleanup left saving state active")
    }

    @MainActor
    static func cancelledSaveCannotCommit() async throws {
        let (calibration, provider, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let save = Task { await calibration.saveAnchor() }
        try await waitUntil { provider.pendingAnchor != nil }
        let staleID = provider.pendingAnchor!.id
        save.cancel()
        provider.finishAdd()
        await save.value
        try check(calibration.anchorID == nil && provider.removedIDs.contains(staleID),
                  "A cancelled save committed or leaked its accepted anchor")
        try check(calibration.errorMessage == nil && !calibration.isSavingAnchor,
                  "A cancelled save left an error or active saving state")
    }

    @MainActor
    static func clearDuringAnchorReadCannotCommit() async throws {
        let (calibration, provider, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        provider.suspendReads = true
        let save = Task { await calibration.saveAnchor() }
        try await waitUntil { provider.pendingAnchor != nil }
        let staleID = provider.pendingAnchor!.id
        provider.finishAdd()
        try await waitUntil { provider.readIsSuspended }
        await calibration.clearAnchor()
        calibration.translationY = 0.8
        provider.finishRead()
        await save.value
        try check(calibration.anchorID == nil && calibration.translationY == 0.8,
                  "The anchor lookup await allowed an outdated save to commit")
        try check(provider.removedIDs.contains(staleID), "Lookup-race anchor was not removed")
    }

    @MainActor
    static func failedStaleCleanupIsPersisted() async throws {
        let (calibration, provider, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let save = Task { await calibration.saveAnchor() }
        try await waitUntil { provider.pendingAnchor != nil }
        let staleID = provider.pendingAnchor!.id
        await calibration.clearAnchor()
        provider.failRemoval = true
        provider.finishAdd()
        await save.value
        let data = defaults.data(forKey: "piano.spatial-calibration.v1")!
        let saved = try JSONDecoder().decode(SavedCalibration.self, from: data)
        try check(saved.anchorID == nil && saved.pendingRemovalIDs?.contains(staleID) == true,
                  "A failed stale-anchor cleanup was not persisted for retry")
        try check(calibration.errorMessage == nil && !calibration.isSavingAnchor,
                  "Stale cleanup changed the new placement's error or saving state")
    }

    @MainActor
    static func directDraggingIsCumulativeAndPersistsOnEnd() throws {
        let (calibration, _, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        calibration.translationX = 0.1
        try check(calibration.beginDirectPlacementDrag(), "An editable tracked template rejected dragging")
        calibration.updateDirectPlacementDrag(worldTranslation: [0.02, 0.01, -0.03])
        calibration.updateDirectPlacementDrag(worldTranslation: [0.05, 0.02, -0.04])
        try check(abs(calibration.translationX - 0.15) < 0.0001
                  && abs(calibration.translationY - 0.74) < 0.0001
                  && abs(calibration.translationZ + 0.69) < 0.0001,
                  "Cumulative gesture translation was accumulated twice")
        let during = try JSONDecoder().decode(SavedCalibration.self, from: defaults.data(forKey: "piano.spatial-calibration.v1")!)
        try check(abs(during.translationX - 0.1) < 0.0001, "Each drag frame wrote intermediate settings")
        calibration.endDirectPlacementDrag()
        let restored = SpatialCalibration(defaults: defaults)
        try check(abs(restored.translationX - 0.15) < 0.0001, "Ending a drag did not persist its final position")
        calibration.applyDragTranslation([.nan, 0, 0])
        try check(calibration.translationX.isFinite, "A malformed drag corrupted the saved placement")
        calibration.isCalibrating = false
        try check(!calibration.beginDirectPlacementDrag(), "A hidden calibration template accepted dragging")
    }

    @MainActor
    static func anchoredDragAndDirectionButtonsUseWorldCoordinates() async throws {
        let (calibration, provider, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        calibration.yawDegrees = 90
        let save = Task { await calibration.saveAnchor() }
        try await waitUntil { provider.pendingAnchor != nil }
        provider.finishAdd()
        await save.value
        let anchorID = calibration.anchorID
        let before = calibration.worldFromKeyboard.columns.3
        calibration.isCalibrating = true
        try check(calibration.beginDirectPlacementDrag(), "A saved anchor prevented further manual adjustment")
        calibration.updateDirectPlacementDrag(worldTranslation: [0.03, 0.02, -0.04])
        calibration.endDirectPlacementDrag()
        let moved = calibration.worldFromKeyboard.columns.3 - before
        try check(abs(moved.x - 0.03) < 0.0001 && abs(moved.y - 0.02) < 0.0001
                  && abs(moved.z + 0.04) < 0.0001,
                  "A rotated anchor changed the direction of a world-space drag")
        let beforeNudge = calibration.worldFromKeyboard.columns.3
        calibration.nudgePlacement(right: 0.01, up: 0.001, towardPlayer: 0.02)
        let nudged = calibration.worldFromKeyboard.columns.3 - beforeNudge
        try check(abs(nudged.x - 0.02) < 0.0001 && abs(nudged.y - 0.001) < 0.0001
                  && abs(nudged.z + 0.01) < 0.0001,
                  "Direction buttons did not follow the displayed keyboard's horizontal axes")
        try check(calibration.anchorID == anchorID, "Micro adjustment discarded the saved room anchor")
    }

    @MainActor
    static func pendingSaveRejectsDragAndFrontPlacement() async throws {
        let (calibration, provider, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let before = calibration.worldFromKeyboard.columns.3
        let save = Task { await calibration.saveAnchor() }
        try await waitUntil { provider.pendingAnchor != nil }
        try check(!calibration.beginDirectPlacementDrag(), "Dragging began during an anchor save")
        calibration.applyDragTranslation([1, 0, 0])
        calibration.nudgePlacement(right: 1)
        await calibration.placeTemplateInFront()
        let after = calibration.worldFromKeyboard.columns.3
        try check(simd_length(after - before) < 0.0001, "A placement helper altered a pending save")
        provider.finishAdd()
        await save.value
        try check(calibration.hasSavedAnchor, "Rejected concurrent placement prevented a valid save")
    }

    @MainActor
    static func frontPlacementFollowsHeadDirectionAndClearsPreviousAnchor() async throws {
        let (calibration, provider, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let save = Task { await calibration.saveAnchor() }
        try await waitUntil { provider.pendingAnchor != nil }
        let previousID = provider.pendingAnchor!.id
        provider.finishAdd()
        await save.value
        calibration.whiteKeyWidth = 0.024
        var head = simd_float4x4(simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
        head.columns.3 = [2, 1.3, 3, 1]
        provider.deviceAnchor = .init(isTracked: true, originFromAnchorTransform: head)
        await calibration.placeTemplateInFront()
        let origin = calibration.worldFromKeyboard.columns.3
        try check(abs(origin.x - 1.35) < 0.0001 && abs(origin.y - 0.72) < 0.0001
                  && abs(origin.z - 3) < 0.0001 && abs(calibration.yawDegrees - 90) < 0.0001,
                  "Front placement did not use the current head pose and heading")
        try check(!calibration.hasSavedAnchor && calibration.isCalibrating
                  && provider.removedIDs.contains(previousID), "Front placement did not retire the previous anchor")
        try check(calibration.whiteKeyWidth == 0.024, "Front placement overwrote the piano's dimensions")
        let restored = SpatialCalibration(defaults: defaults)
        try check(!restored.hasSavedAnchor && abs(restored.translationX - 1.35) < 0.0001,
                  "Front placement was not persisted")
    }

    @MainActor
    static func frontPlacementWithoutDeviceTrackingPreservesPlacement() async throws {
        let (calibration, provider, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        calibration.translationX = 0.4
        provider.deviceAnchor = nil
        await calibration.placeTemplateInFront()
        try check(calibration.translationX == 0.4 && calibration.errorMessage != nil,
                  "Missing device tracking discarded the current placement")
        var lookingDown = simd_float4x4(simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
        lookingDown.columns.3 = [0, 1.3, 0, 1]
        provider.deviceAnchor = .init(isTracked: true, originFromAnchorTransform: lookingDown)
        await calibration.placeTemplateInFront()
        try check(calibration.translationX == 0.4 && calibration.errorMessage != nil,
                  "A nearly vertical head pose generated an arbitrary piano heading")
    }

    @MainActor
    static func defaultCalibrationIsLockedUntilExplicitAction() throws {
        let suite = "piano.spatial-default-lock.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let calibration = SpatialCalibration(defaults: defaults)
        try check(!calibration.isCalibrating && !calibration.beginDirectPlacementDrag()
                  && !calibration.canStartFingerCalibration, "Fresh calibration was editable or started outside a tracked space")
        calibration.startForRegression(using: WorldTrackingProvider(), editing: false)
        try check(!calibration.isCalibrating && !calibration.beginDirectPlacementDrag()
                  && calibration.canStartFingerCalibration, "Opening a tracked space unlocked the template without an explicit action")
        calibration.translationX = 0.21
        let restored = SpatialCalibration(defaults: defaults)
        try check(!restored.isCalibrating && abs(restored.translationX - 0.21) < 0.0001,
                  "Restoring an unanchored manual pose unlocked or lost the saved placement")
    }

    @MainActor
    static func twoFingerSamplesCommitOnlyAfterBothEndpoints() async throws {
        let (calibration, provider, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = calibration.sessionForRegression
        let before = calibration.worldFromKeyboard
        let left = SIMD3<Float>(-0.4, 0.76, -0.9)
        let right = SIMD3<Float>(0.7985, 0.76, -0.9)
        let leftHand = try await captureFingerPoint(calibration, point: left)
        try check(calibration.hasFingerCalibrationFirstPoint && samePose(calibration.worldFromKeyboard, before),
                  "The first stable finger point moved the keyboard before its second endpoint existed")
        try check(simd_distance(calibration.fingerCalibrationLeftPoint!, left) < 0.0001
                  && leftHand.latestAnchorsReadCount >= 8 && leftHand.state == .stopped,
                  "Left capture did not use fresh tracked world-space samples or stop its hand provider")
        let rightHand = try await captureFingerPoint(calibration, point: right)
        try check(leftHand !== rightHand && rightHand.latestAnchorsReadCount >= 8,
                  "The next endpoint restarted a stopped provider or lost right-hand samples to a second consuming getter")
        try check(!calibration.hasFingerCalibrationFirstPoint && !calibration.isFingerCalibrationActive
                  && calibration.canStartFingerCalibration && calibration.isCalibrating,
                  "A completed two-point calibration retained its capture lock or first point")
        try check(abs(calibration.translationX - 0.19925) < 0.0001
                  && abs(calibration.translationY - 0.76) < 0.0001
                  && abs(calibration.translationZ + 0.9) < 0.0001
                  && abs(calibration.whiteKeyWidth - 0.0235) < 0.00001,
                  "The real sampling workflow failed to apply the two front-key centre solution")
        try check(session.runRequests.count == 4
                  && session.runRequests[0].count == 2 && session.runRequests[1].count == 1
                  && session.runRequests[2].count == 2 && session.runRequests[3].count == 1
                  && session.runRequests.allSatisfy { $0.first === provider }
                  && session.runningProviders.count == 1 && session.runningProviders[0] === provider
                  && provider.state == .running && rightHand.state == .stopped && calibration.isTracked,
                  "Hand capture replaced or stopped world tracking instead of changing only the hand provider")
        let restored = SpatialCalibration(defaults: defaults)
        try check(samePose(restored.worldFromKeyboard, calibration.worldFromKeyboard) && !restored.isCalibrating,
                  "Completed finger pose was not persisted or reloaded locked")
    }

    @MainActor
    static func invalidRightEndpointPreservesSavedPose() async throws {
        let (calibration, _, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        calibration.translationX = 0.31
        calibration.yawDegrees = 17
        calibration.whiteKeyWidth = 0.024
        let before = calibration.worldFromKeyboard
        try await captureFingerPoint(calibration, point: [-0.5, 0.74, -0.8])
        try await captureFingerPoint(calibration, point: [-0.3, 0.74, -0.8])
        try check(samePose(calibration.worldFromKeyboard, before) && calibration.whiteKeyWidth == 0.024
                  && calibration.hasFingerCalibrationFirstPoint && calibration.canStartFingerCalibration,
                  "An impossible endpoint span replaced the previous keyboard pose instead of allowing a right-point retry")
        let restored = SpatialCalibration(defaults: defaults)
        try check(samePose(restored.worldFromKeyboard, before), "Invalid two-point geometry overwrote the durable pose")
        calibration.cancelFingerCalibration()
        try check(!calibration.hasFingerCalibrationFirstPoint && samePose(calibration.worldFromKeyboard, before),
                  "Cancelling an invalid pair lost the previous placement")
    }

    @MainActor
    static func handPermissionDenialAndEventsLeaveWorldTrackingIntact() async throws {
        let (calibration, provider, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let before = calibration.worldFromKeyboard
        let session = calibration.sessionForRegression
        session.authorizationStatuses[.handTracking] = .denied
        await calibration.startFingerCalibration()
        try check(calibration.isTracked && provider.state == .running && !calibration.hasFingerCalibrationFirstPoint
                  && calibration.canStartFingerCalibration && session.runRequests.isEmpty
                  && samePose(calibration.worldFromKeyboard, before),
                  "Denied hand permission stopped world tracking, mutated placement, or retained the capture lock")
        let events = Task { await calibration.consumeEventsForRegression() }
        let hand = HandTrackingProvider()
        session.emit(.dataProviderStateChanged([hand], .stopped, MockFailure.operationFailed))
        session.emit(.authorizationChanged(.handTracking, .denied))
        try await Task.sleep(for: .milliseconds(5))
        try check(calibration.isTracked && calibration.errorMessage == nil,
                  "Hand-only events invalidated spatial world tracking")
        session.emit(.dataProviderStateChanged([provider], .stopped, nil))
        try await waitUntil { !calibration.isTracked }
        events.cancel()
        await events.value
    }

    @MainActor
    static func cancelDuringPermissionRetainsExclusiveCaptureUntilCleanup() async throws {
        let (calibration, _, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = calibration.sessionForRegression
        session.suspendAuthorization = true
        let before = calibration.worldFromKeyboard
        let capture = Task { await calibration.startFingerCalibration() }
        try await waitUntil { session.authorizationIsSuspended }
        let providerCount = HandTrackingProvider.instances.count
        calibration.cancelFingerCalibration()
        try check(!calibration.isFingerCalibrationActive && !calibration.canStartFingerCalibration,
                  "Cancellation released the exclusive capture lock before suspended permission returned")
        await calibration.startFingerCalibration()
        try check(HandTrackingProvider.instances.count == providerCount,
                  "A second capture began while an older permission request was still in flight")
        session.finishAuthorization()
        await capture.value
        try check(calibration.canStartFingerCalibration && session.runRequests.isEmpty
                  && !calibration.hasFingerCalibrationFirstPoint && samePose(calibration.worldFromKeyboard, before),
                  "Cancelled permission later started tracking, committed a point, or kept the capture lock")
    }

    @MainActor
    static func stopDuringPermissionCannotAffectANewRun() async throws {
        let (calibration, _, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldSession = calibration.sessionForRegression
        oldSession.suspendAuthorization = true
        let capture = Task { await calibration.startFingerCalibration() }
        try await waitUntil { oldSession.authorizationIsSuspended }
        calibration.stop()
        let newProvider = WorldTrackingProvider()
        calibration.startForRegression(using: newProvider)
        let newSession = calibration.sessionForRegression
        calibration.translationZ = -1.1
        oldSession.finishAuthorization()
        await capture.value
        try check(calibration.isTracked && calibration.translationZ == -1.1
                  && !calibration.hasFingerCalibrationFirstPoint && calibration.canStartFingerCalibration
                  && oldSession.runRequests.isEmpty && newSession.runRequests.isEmpty && newProvider.state == .running,
                  "A permission response from a stopped run modified or restarted the new spatial session")
    }

    @MainActor
    static func cancelDuringProviderRunRestoresOnlyWorldTracking() async throws {
        let (calibration, provider, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = calibration.sessionForRegression
        session.suspendRuns = true
        let before = calibration.worldFromKeyboard
        let capture = Task { await calibration.startFingerCalibration() }
        try await waitUntil { session.runIsSuspended }
        calibration.cancelFingerCalibration()
        try check(!calibration.canStartFingerCalibration, "Cancel released a still-suspended provider reconfiguration")
        session.finishRun()
        await capture.value
        try check(session.runRequests.count == 2 && session.runRequests.last?.count == 1
                  && session.runningProviders.count == 1 && session.runningProviders[0] === provider
                  && HandTrackingProvider.instances.last?.state == .stopped
                  && calibration.canStartFingerCalibration && samePose(calibration.worldFromKeyboard, before),
                  "A cancelled hand-provider start remained active or stopped the original world provider")
    }

    @MainActor
    static func pausedWorldCleansUpHandWhenTrackingResumes() async throws {
        let (calibration, provider, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = calibration.sessionForRegression
        let before = calibration.worldFromKeyboard
        let (capture, feed, hand) = try await startFingerPoint(calibration, point: [-0.5, 0.74, -0.8])
        try await Task.sleep(for: .milliseconds(60))
        provider.state = .paused
        let monitoring = Task { await calibration.monitorTrackingForRegression(using: provider) }
        try await waitUntil { !calibration.isTracked }
        await capture.value
        feed.cancel()
        await feed.value
        try check(!calibration.canStartFingerCalibration && !calibration.isFingerCalibrationActive
                  && provider.state == .paused && samePose(calibration.worldFromKeyboard, before),
                  "Pausing world tracking resumed it prematurely, retained a sample, or released a pending hand cleanup")
        provider.state = .running
        try await waitUntil { calibration.canStartFingerCalibration && hand.state == .stopped }
        try check(session.runningProviders.count == 1 && session.runningProviders[0] === provider
                  && calibration.isTracked && provider.state == .running,
                  "Resuming world tracking failed to remove its previously active hand provider")
        monitoring.cancel()
        await monitoring.value
        calibration.stop()
    }

    @MainActor
    static func cancellationAndTrackingLossDuringSamplingCannotCommit() async throws {
        for action in 0..<3 {
            let (calibration, _, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let before = calibration.worldFromKeyboard
            let (capture, feed, _) = try await startFingerPoint(calibration, point: [-0.5, 0.74, -0.8])
            try await Task.sleep(for: .milliseconds(60))
            switch action {
            case 0: calibration.cancelFingerCalibration()
            case 1: capture.cancel()
            default: calibration.setTrackingForRegression(false)
            }
            await capture.value
            feed.cancel()
            await feed.value
            try check(!calibration.isFingerCalibrationActive && !calibration.hasFingerCalibrationFirstPoint
                      && samePose(calibration.worldFromKeyboard, before),
                      "Cancellation/tracking loss accepted an incomplete fingertip window or moved placement")
        }
    }

    @MainActor
    static func untrackedHandsAndJointsNeverBecomeSamplePoints() async throws {
        for isHandTracked in [false, true] {
            let (calibration, provider, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let before = calibration.worldFromKeyboard
            let hand = try await captureFingerPoint(calibration, point: [-0.5, 0.74, -0.8],
                                                    tracked: isHandTracked, jointTracked: false)
            try check(!calibration.hasFingerCalibrationFirstPoint && !calibration.isFingerCalibrationActive
                      && calibration.canStartFingerCalibration && samePose(calibration.worldFromKeyboard, before)
                      && hand.state == .stopped && provider.state == .running,
                      "An untracked hand/joint was accepted or a timed-out sample stopped world tracking")
        }
    }

    @MainActor
    static func explicitTrackingLossRestartsTheFullStableWindow() async throws {
        let (calibration, _, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        calibration.setFingerTimeoutForRegression(1.5)
        let point = SIMD3<Float>(-0.5, 0.74, -0.8)
        let (capture, initialFeed, hand) = try await startFingerPoint(calibration, point: point)
        try await Task.sleep(for: .milliseconds(250))
        initialFeed.cancel()
        await initialFeed.value
        let lost = fingerAnchor(at: point, right: false, tracked: false)
        for _ in 0..<5 {
            hand.publish(left: lost)
            try await Task.sleep(for: .milliseconds(10))
        }
        let tracked = fingerAnchor(at: point, right: false)
        let resumedFeed = Task { @MainActor in
            while !Task.isCancelled {
                hand.publish(left: tracked)
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        try await Task.sleep(for: .milliseconds(150))
        try check(calibration.isFingerCalibrationActive && !calibration.hasFingerCalibrationFirstPoint,
                  "A brief explicit tracking loss bridged the stable window using samples from before the loss")
        await capture.value
        resumedFeed.cancel()
        await resumedFeed.value
        try check(calibration.hasFingerCalibrationFirstPoint && !calibration.isFingerCalibrationActive,
                  "Fresh samples failed to complete after a full continuous stable window following tracking recovery")
    }

    @MainActor
    static func pendingSaveAndFingerCaptureExcludeEachOther() async throws {
        let (calibration, provider, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let save = Task { await calibration.saveAnchor() }
        try await waitUntil { provider.pendingAnchor != nil }
        let handCount = HandTrackingProvider.instances.count
        try check(!calibration.canStartFingerCalibration, "A pending anchor save allowed a concurrent finger capture")
        await calibration.startFingerCalibration()
        try check(HandTrackingProvider.instances.count == handCount,
                  "Finger capture raced an in-flight anchor commit")
        provider.finishAdd()
        await save.value
        let (capture, feed, _) = try await startFingerPoint(calibration, point: [-0.5, 0.74, -0.8])
        await calibration.saveAnchor()
        try check(provider.pendingAnchor == nil, "Saving an anchor began during a finger sample")
        await capture.value
        feed.cancel()
        await feed.value
        await calibration.saveAnchor()
        try check(provider.pendingAnchor == nil && calibration.hasFingerCalibrationFirstPoint,
                  "Saving an anchor committed an unfinished one-endpoint calibration")
        calibration.cancelFingerCalibration()
    }

    @MainActor
    static func failedFingerAnchorRetirementRemainsDurable() async throws {
        let (calibration, provider, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let save = Task { await calibration.saveAnchor() }
        try await waitUntil { provider.pendingAnchor != nil }
        let previousID = provider.pendingAnchor!.id
        provider.finishAdd()
        await save.value
        try await captureFingerPoint(calibration, point: [-0.4, 0.76, -0.9])
        provider.failRemoval = true
        try await captureFingerPoint(calibration, point: [0.7985, 0.76, -0.9])
        let saved = try JSONDecoder().decode(SavedCalibration.self,
            from: defaults.data(forKey: "piano.spatial-calibration.v1")!)
        try check(calibration.anchorID == nil && saved.anchorID == nil
                  && saved.pendingRemovalIDs?.contains(previousID) == true
                  && abs(saved.translationX - 0.19925) < 0.0001 && calibration.errorMessage != nil,
                  "Finger calibration lost the new pose or forgot a failed old-anchor retirement")
        let restored = SpatialCalibration(defaults: defaults)
        try check(!restored.isCalibrating && samePose(restored.worldFromKeyboard, calibration.worldFromKeyboard),
                  "The provisional finger pose did not survive a failed old-anchor removal and reload")
    }

    @MainActor
    static func clearDuringFingerCommitCleanupDoesNotReportOldSuccess() async throws {
        let (calibration, provider, defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let save = Task { await calibration.saveAnchor() }
        try await waitUntil { provider.pendingAnchor != nil }
        provider.finishAdd()
        await save.value
        try await captureFingerPoint(calibration, point: [-0.4, 0.76, -0.9])
        provider.suspendRemovals = true
        let (capture, feed, _) = try await startFingerPoint(calibration, point: [0.7985, 0.76, -0.9])
        try await waitUntil { provider.removalIsSuspended }
        try check(!calibration.canStartFingerCalibration && calibration.anchorID == nil,
                  "Finger commit released its in-flight guard before anchor retirement finished")
        try check(!calibration.isFingerCalibrationActive && calibration.isFingerCalibrationBusy,
                  "A committed pose still offered cancellation instead of only waiting for cleanup")
        await calibration.clearAnchor()
        let cleared = calibration.worldFromKeyboard
        try check(!calibration.canStartFingerCalibration, "Explicit clear allowed a second capture before old cleanup returned")
        provider.finishRemoval()
        await capture.value
        feed.cancel()
        await feed.value
        try check(samePose(calibration.worldFromKeyboard, cleared) && !calibration.hasFingerCalibrationFirstPoint
                  && calibration.canStartFingerCalibration && !calibration.fingerCalibrationStatus.contains("两端取点完成"),
                  "An obsolete finger commit reported success or overwrote a clear performed during anchor cleanup")
    }
}

enum RegressionFailure: Error {
    case assertion(String)
    case timedOut
}
