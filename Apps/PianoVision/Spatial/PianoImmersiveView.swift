import PianoCore
import RealityKit
import SwiftUI
import UIKit
import simd

struct PianoImmersiveView: View {
    let session: PianoSession
    @State private var renderer = PianoSceneRenderer()

    var body: some View {
        RealityView { content in
            PianoSceneComponent.registerComponent()
            PianoAnimationSystem.registerSystem()
            renderer.synchronize(session: session)
            content.add(renderer.root)
        } update: { _ in
            renderer.synchronize(session: session)
        }
        .task { [session] in
            session.calibration.onTrackingChanged = { [weak session] tracked in
                session?.spatialTrackingDidChange(tracked)
            }
            await session.calibration.run()
        }
        .onDisappear {
            session.calibration.stop()
            session.calibration.onTrackingChanged = nil
            session.isImmersiveActive = false
        }
    }

}

/// RealityKit owns the frame loop; SwiftUI updates only configuration and imported-song caches.
@MainActor
private final class PianoSceneRenderer {
    let root = Entity()
    private let keyboard = Entity()
    private let keysRoot = Entity()
    private let templatesRoot = Entity()
    private let highlightsRoot = Entity()
    private let feedbackRoot = Entity()
    private let notesRoot = Entity()
    private let calibrationGuidesRoot = Entity()
    private let capturedLeftPoint = ModelEntity()
    private let landmarksRoot = Entity()
    private let beatRoot = Entity()
    private let hitLine = ModelEntity()
    private weak var session: PianoSession?
    private var layout = KeyboardLayout()
    private var configuredWidth: Float = -1
    private var configuredDepth: Float = -1
    private var configuredMinimum = -1
    private var configuredCount = -1
    private var configuredRevision = -1
    private var configuredAnnotationRevision = -1
    private var configuredTracks: Set<Int> = []
    private var configuredDisplaySettings: PianoDisplaySettings?
    private var configuredCalibrationVisible = false
    private var cachedNotes: [PianoNote] = []
    private var nextOnsets: [Int: Double] = [:]
    private var prefixMaximumEnd: [Double] = []
    private var keys: [Int: KeyVisual] = [:]
    private var visibleNotes: [Int: NoteVisual] = [:]
    private var spareNotes: [NoteVisual] = []
    private var fingerMeshes: [Int: MeshResource] = [:]
    private var laneLines: [(entity: ModelEntity, x: Float, isOctave: Bool)] = []
    private var octaveLabels: [ModelEntity] = []
    private var beatLines: [ModelEntity] = []

    private let box = MeshResource.generateBox(size: 1)
    private let templateWhite = makeMaterial(.white, opacity: 1, writesDepth: true)
    private let templateBlack = makeMaterial(UIColor(white: 0.018, alpha: 1), opacity: 1, writesDepth: true)
    private let playedMaterial = makeMaterial(PracticeAppearance.inputUIColor(.pressed), opacity: 1, writesDepth: true)
    private let playedBlackMaterial = makeMaterial(PracticeAppearance.inputUIColor(.pressed, isBlack: true), opacity: 1, writesDepth: true)
    private let correctMaterial = makeMaterial(PracticeAppearance.inputUIColor(.correct), opacity: 1, writesDepth: true)
    private let correctBlackMaterial = makeMaterial(PracticeAppearance.inputUIColor(.correct, isBlack: true), opacity: 1, writesDepth: true)
    private let wrongMaterial = makeMaterial(PracticeAppearance.inputUIColor(.wrong), opacity: 1, writesDepth: true)
    private let wrongBlackMaterial = makeMaterial(PracticeAppearance.inputUIColor(.wrong, isBlack: true), opacity: 1, writesDepth: true)
    private let whiteKeyBoundary = makeMaterial(UIColor(white: 0.035, alpha: 1), opacity: 1, writesDepth: true)
    private let blackKeyBoundary = makeMaterial(UIColor(white: 0.96, alpha: 1), opacity: 1, writesDepth: true)
    private let fingerMaterial = makeMaterial(.black, opacity: 1)
    private let blackFingerMaterial = makeMaterial(.white, opacity: 1)
    private let onsetMaterial = makeMaterial(.white, opacity: 1)
    private let whiteOnsetMaterial = makeMaterial(UIColor(white: 0.05, alpha: 1), opacity: 1)
    private let blackNoteEdgeMaterial = makeMaterial(UIColor(red: 0.85, green: 0.93, blue: 1, alpha: 1), opacity: 1)
    private let completionMaterial = makeMaterial(UIColor(red: 0.3, green: 1, blue: 0.45, alpha: 1), opacity: 1)
    private let landmarkMaterial = makeMaterial(UIColor(white: 0.75, alpha: 1), opacity: 0.16)
    private let laneMaterial = makeMaterial(UIColor(red: 0.33, green: 0.45, blue: 0.61, alpha: 1), opacity: 0.10)
    private let beatMaterial = makeMaterial(.white, opacity: 0.13)
    private let measureMaterial = makeMaterial(.white, opacity: 0.28)
    private let heldNoteMaterials = Dictionary(uniqueKeysWithValues: [PianoHand.left, .right, .unassigned].map {
        ($0, makeMaterial(PracticeAppearance.noteUIColor(for: .pressed, hand: $0), opacity: 1))
    })
    private let heldBlackNoteMaterials = Dictionary(uniqueKeysWithValues: [PianoHand.left, .right, .unassigned].map {
        ($0, makeMaterial(PracticeAppearance.noteUIColor(for: .pressed, hand: $0, isBlack: true), opacity: 1))
    })
    private let noteMaterials = Dictionary(uniqueKeysWithValues: [PianoHand.left, .right, .unassigned].map {
        ($0, makeMaterial(PracticeAppearance.uiColor(for: $0), opacity: 1))
    })
    private let targetMaterials = Dictionary(uniqueKeysWithValues: [PianoHand.left, .right, .unassigned].map {
        ($0, makeMaterial(PracticeAppearance.uiColor(for: $0), opacity: 1, writesDepth: true))
    })
    private let blackNoteMaterials = Dictionary(uniqueKeysWithValues: [PianoHand.left, .right, .unassigned].map {
        ($0, makeMaterial(PracticeAppearance.uiColor(for: $0, isBlack: true), opacity: 1))
    })
    private let blackTargetMaterials = Dictionary(uniqueKeysWithValues: [PianoHand.left, .right, .unassigned].map {
        ($0, makeMaterial(PracticeAppearance.uiColor(for: $0, isBlack: true), opacity: 1, writesDepth: true))
    })

    init() {
        root.name = "PianoWorldRoot"
        keyboard.name = "KeyboardRoot"
        root.addChild(keyboard)
        keyboard.addChild(keysRoot)
        keysRoot.addChild(templatesRoot)
        keysRoot.addChild(highlightsRoot)
        keysRoot.addChild(feedbackRoot)
        keyboard.addChild(notesRoot)
        keyboard.addChild(calibrationGuidesRoot)
        capturedLeftPoint.model = ModelComponent(mesh: .generateSphere(radius: 0.004),
            materials: [makeMaterial(PracticeAppearance.uiColor(for: .left), opacity: 0.95)])
        capturedLeftPoint.isEnabled = false
        root.addChild(capturedLeftPoint)
        keyboard.addChild(landmarksRoot)
        keyboard.addChild(beatRoot)
        keyboard.addChild(hitLine)
        root.components.set(PianoSceneComponent(renderer: self))
        // Generate five meshes once. Note entities and their labels are pooled as they scroll.
        for finger in 1...5 {
            fingerMeshes[finger] = MeshResource.generateText("\(finger)", extrusionDepth: 0.005,
                font: .systemFont(ofSize: 1, weight: .bold), containerFrame: .zero,
                alignment: .center, lineBreakMode: .byClipping)
        }
    }

    func synchronize(session: PianoSession) {
        self.session = session
        let calibration = session.calibration
        if configuredWidth != calibration.whiteKeyWidth || configuredDepth != calibration.whiteKeyDepth
            || configuredMinimum != session.minMIDINote || configuredCount != session.keyCount {
            configuredWidth = calibration.whiteKeyWidth
            configuredDepth = calibration.whiteKeyDepth
            configuredMinimum = session.minMIDINote
            configuredCount = session.keyCount
            layout = KeyboardLayout(minMIDINote: session.minMIDINote, keyCount: session.keyCount,
                                    whiteKeyWidth: calibration.whiteKeyWidth,
                                    whiteKeyDepth: calibration.whiteKeyDepth)
            rebuildKeyboard()
        }
        let songChanged = configuredRevision != session.songRevision
        if songChanged {
            configuredRevision = session.songRevision
            cachedNotes = session.song?.notes ?? []
            var maximumEnd = 0.0
            prefixMaximumEnd = cachedNotes.map { note in
                maximumEnd = max(maximumEnd, note.end)
                return maximumEnd
            }
            recycleAllNotes()
        }
        if songChanged || configuredTracks != session.enabledTrackIDs {
            configuredTracks = session.enabledTrackIDs
            nextOnsets = PianoRollGeometry.nextOnsets(for: cachedNotes.filter { configuredTracks.contains($0.track) })
        }
        if configuredAnnotationRevision != session.annotationRevision {
            configuredAnnotationRevision = session.annotationRevision
            recycleAllNotes()
        }
        // Read observable tracking here as well as in the frame loop. This restarts rendering
        // after ARKit recovers even if RealityKit stopped drawing all hidden descendants.
        keyboard.isEnabled = calibration.isTracked && !calibration.isFingerCalibrationActive
            && !calibration.hasFingerCalibrationFirstPoint
        updateFrame()
    }

    func updateFrame() {
        guard let session else { return }
        let calibration = session.calibration
        keyboard.isEnabled = calibration.isTracked && !calibration.isFingerCalibrationActive
            && !calibration.hasFingerCalibrationFirstPoint
        capturedLeftPoint.isEnabled = calibration.isTracked && calibration.hasFingerCalibrationFirstPoint
        guard calibration.isTracked else { return }
        keyboard.transform = Transform(matrix: calibration.worldFromKeyboard)

        let now = session.songTime
        let display = session.displaySettings.validated()
        let showsCalibration = calibration.isCalibrating && !session.isPlaying && !calibration.isFingerCalibrationActive
            && !calibration.hasFingerCalibrationFirstPoint
        calibrationGuidesRoot.isEnabled = showsCalibration
        if let point = calibration.fingerCalibrationLeftPoint { capturedLeftPoint.position = point }
        if configuredDisplaySettings != display || configuredCalibrationVisible != showsCalibration {
            configuredDisplaySettings = display
            configuredCalibrationVisible = showsCalibration
            // Practice guides can be invisible without hiding explicit calibration.
            templatesRoot.components.set(OpacityComponent(opacity: showsCalibration ? 0.55 : Float(display.templateOpacity)))
            highlightsRoot.components.set(OpacityComponent(opacity: Float(display.highlightOpacity)))
            feedbackRoot.components.set(OpacityComponent(opacity: Float(display.feedbackOpacity)))
            notesRoot.components.set(OpacityComponent(opacity: Float(display.noteOpacity)))
        }
        let roll = PianoRollGeometry(layout: layout, rearOffsetMeters: display.rearOffsetMeters,
                                     surfaceHeightMeters: display.surfaceHeightMeters)
        let timing = PianoRollTiming(settings: display, playbackRate: session.playbackRate)
        let horizon = timing.horizonSeconds
        let speed = timing.speedMetersPerScoreSecond
        let noteThickness = Float(display.noteThicknessMillimeters / 1000)
        let windowEnd = now + horizon
        let previewIDs = session.targetPreviewNoteIDs
        let keyboardCueIDs = session.keyboardTargetNoteIDs
        var targetHands: [Int: PianoHand] = [:]
        var targetStrength: [Int: Float] = [:]
        var heldHands: [Int: PianoHand] = [:]
        var collectedPitches = Set<Int>()
        var displayedIDs = Set<Int>()
        let first = firstIndex(withEndAfter: now)
        var index = first
        while index < cachedNotes.count {
            let note = cachedNotes[index]
            if note.start > windowEnd { break }
            index += 1
            let isWaitingTarget = session.isWaiting && session.waitingNoteIDs.contains(note.id)
            guard (note.end > now || isWaitingTarget), session.enabledTrackIDs.contains(note.track),
                  let key = layout.key(for: note.pitch) else { continue }
            let hand = session.hand(for: note)
            let presentation = session.notePresentation(for: note)
            if presentation.isHeld { merge(hand, for: note.pitch, into: &heldHands) }
            if presentation.role == .current && presentation.progress == .accepted && !presentation.isPendingEarly {
                collectedPitches.insert(note.pitch)
            }
            if keyboardCueIDs.contains(note.id), presentation.role != .upcoming {
                let strength: Float = presentation.role == .current
                    ? (presentation.progress == .unplayed ? 1 : 0.30) : 0.25
                // Wait mode supplies only the unfinished current group. In
                // automatic playback, a current cue owns a shared-pitch key.
                if strength >= (targetStrength[note.pitch] ?? 0) {
                    if strength > (targetStrength[note.pitch] ?? 0) { targetHands[note.pitch] = hand }
                    else { merge(hand, for: note.pitch, into: &targetHands) }
                    targetStrength[note.pitch] = strength
                }
            }
            guard let segment = roll.note(note, at: now, speed: speed, horizon: horizon,
                gapMillimeters: display.noteGapMillimeters, nextSamePitchStart: nextOnsets[note.id],
                isWaitingTarget: isWaitingTarget) else { continue }
            let visual: NoteVisual
            if let existing = visibleNotes[note.id] { visual = existing }
            else {
                visual = spareNotes.popLast() ?? NoteVisual(box: box)
                if visual.root.parent == nil { notesRoot.addChild(visual.root) }
                visual.appearance = nil
                visual.fingerValue = nil
                visibleNotes[note.id] = visual
            }
            // A later strike of the same pitch can completely trim an older
            // overlapping tail. Its old check/meter must not sit on the new head.
            visual.root.isEnabled = segment.hasVisibleContent
            displayedIDs.insert(note.id)
            let current = presentation.role == .current && presentation.progress == .unplayed
                && previewIDs.contains(note.id)
            configureNoteAppearance(visual, hand: hand, isBlack: key.isBlack,
                                    isHeld: presentation.isHeld, isCurrent: current)
            let fade = timing.distanceOpacity(forScoreOffset: max(0, note.start - now), settings: display)
            let collected = presentation.progress != .unplayed && !presentation.isHeld
            visual.root.components.set(OpacityComponent(opacity: Float(fade) * (collected ? 0.80 : 1)))
            let topY = segment.surfaceY + noteThickness
            let x = key.centerX - layout.width / 2
            visual.bar.isEnabled = segment.length > 0.00001
            visual.bar.scale = [key.width * 0.76, noteThickness, max(0.00001, segment.length)]
            visual.bar.position = [x, segment.surfaceY + noteThickness / 2, segment.centerZ]
            for (edge, side) in [(visual.leftEdge, Float(-1)), (visual.rightEdge, Float(1))] {
                edge.isEnabled = (key.isBlack || current || presentation.isHeld) && visual.bar.isEnabled
                let edgeWidth: Float = presentation.isHeld ? 0.0015 : current ? 0.0011 : 0.00065
                edge.scale = [edgeWidth, 0.0009, max(0.00001, segment.length)]
                edge.position = [x + side * key.width * 0.38, topY + 0.0005, segment.centerZ]
            }
            visual.onset.isEnabled = (display.showsOnsetMarkers && segment.showsOnset) || presentation.needsRestrike
            // A wider head identifies a fresh attack even when a repeated note
            // is so short that gap trimming has removed its body.
            visual.onset.scale = [key.width * 0.94, current ? 0.002 : 0.0014, current ? 0.003 : 0.002]
            visual.onset.position = [x, topY + 0.001, segment.frontZ]
            visual.restrike.isEnabled = presentation.needsRestrike
            visual.restrike.scale = [key.width * 0.72, 0.001, 0.0012]
            visual.restrike.position = [x, topY + 0.001, segment.frontZ - 0.0045]
            visual.completion.isEnabled = presentation.progress != .unplayed
            visual.completion.position = [x, topY + 0.002, segment.frontZ - 0.006]
            // A short cyan cap means an early candidate is still conditional;
            // a green check means the onset has been accumulated/completed.
            visual.completionCheck.isEnabled = !presentation.isPendingEarly
            visual.pendingCap.isEnabled = !visual.completionCheck.isEnabled
            let finger = session.showFingering ? session.finger(for: note) : nil
            visual.finger.isEnabled = finger != nil && note.start >= now - 0.05
                && note.start <= now + min(horizon, 3.5 * session.playbackRate)
            if visual.finger.isEnabled, let finger, let mesh = fingerMeshes[finger] {
                if visual.fingerValue != finger {
                    visual.fingerValue = finger
                    visual.finger.model = ModelComponent(mesh: mesh, materials: [key.isBlack ? blackFingerMaterial : fingerMaterial])
                    let bounds = mesh.bounds
                    visual.fingerScale = min(0.014 / max(bounds.extents.y, 0.001),
                                             key.width * 0.64 / max(bounds.extents.x, 0.001))
                    visual.fingerCenter = bounds.center
                }
                let scale = visual.fingerScale
                visual.finger.scale = SIMD3(repeating: scale)
                let rotation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
                visual.finger.orientation = rotation
                let center = SIMD3<Float>(x, topY + 0.002, segment.frontZ - 0.016)
                visual.finger.position = center - rotation.act(visual.fingerCenter * scale)
            }
        }
        for id in visibleNotes.keys.filter({ !displayedIDs.contains($0) }) {
            if let visual = visibleNotes.removeValue(forKey: id) {
                visual.root.isEnabled = false
                spareNotes.append(visual)
            }
        }
        updateKeys(session: session, display: display, roll: roll, noteThickness: noteThickness,
                   targetHands: targetHands, targetStrength: targetStrength,
                   heldHands: heldHands, collectedPitches: collectedPitches)
        updateLandmarks(display: display, roll: roll, timing: timing)
        updateBeats(session: session, display: display, roll: roll, timing: timing, now: now)
        hitLine.isEnabled = calibration.isCalibrating || !cachedNotes.isEmpty
        hitLine.position = [0, roll.surfaceY + 0.0002, roll.hitLineZ]
        hitLine.components.set(OpacityComponent(opacity: Float(display.noteOpacity) * (session.isWaiting ? 1 : 0.60)))
    }

    private func merge(_ hand: PianoHand, for pitch: Int, into hands: inout [Int: PianoHand]) {
        hands[pitch] = hands[pitch].map { $0 == hand ? hand : .unassigned } ?? hand
    }

    private func updateKeys(session: PianoSession, display: PianoDisplaySettings, roll: PianoRollGeometry,
                            noteThickness: Float, targetHands: [Int: PianoHand], targetStrength: [Int: Float],
                            heldHands: [Int: PianoHand], collectedPitches: Set<Int>) {
        let activeNotes = session.activeNotes
        let correct = session.heldCorrectNotes
        let wrong = session.heldWrongNotes
        let recentCorrect = session.correctNotes
        let recentWrong = session.wrongNotes
        let showsCalibration = session.calibration.isCalibrating && !session.isPlaying && !session.calibration.isFingerCalibrationActive
            && !session.calibration.hasFingerCalibrationFirstPoint
        for (pitch, visual) in keys {
            visual.template.isEnabled = showsCalibration || (display.showsKeyboardGuides && display.templateOpacity > 0)
            visual.templateBoundary.isEnabled = visual.template.isEnabled
            let isPlayed = activeNotes.contains(pitch)
            let target = targetHands[pitch]
            let hand = heldHands[pitch] ?? target
            let state: KeyState = isPlayed ? (wrong.contains(pitch) ? .wrong : correct.contains(pitch) ? .correct : .played)
                : target != nil ? .target : .off
            visual.highlight.isEnabled = !isPlayed && target != nil && display.highlightOpacity > 0
            visual.highlight.components.set(OpacityComponent(opacity: targetStrength[pitch] ?? 0))
            visual.feedback.isEnabled = isPlayed && display.feedbackOpacity > 0
            let intensity = session.inputPulseIntensity(for: pitch)
            let pulseState: KeyState = recentWrong.contains(pitch) ? .wrong
                : recentCorrect.contains(pitch) || collectedPitches.contains(pitch) ? .correct : .played
            visual.pulse.isEnabled = intensity > 0 && display.feedbackOpacity > 0
            visual.pulse.components.set(OpacityComponent(opacity: Float(intensity)))
            if visual.pulseState != pulseState {
                visual.pulseState = pulseState
                visual.pulse.model?.materials = [pulseState == .wrong ? wrongMaterial
                    : pulseState == .correct ? correctMaterial : playedMaterial]
            }
            visual.completion.isEnabled = collectedPitches.contains(pitch) && !isPlayed && display.highlightOpacity > 0
            visual.handStrip.isEnabled = hand != nil && (isPlayed || target != nil) && display.highlightOpacity > 0
            if visual.state != state || visual.targetHand != hand {
                visual.state = state
                visual.targetHand = hand
                let materials = visual.isBlack ? blackTargetMaterials : targetMaterials
                if let material = hand.flatMap({ materials[$0] }) {
                    for surface in visual.targetSurfaces { surface.model?.materials = [material] }
                    visual.handStrip.model?.materials = [material]
                    visual.connector.model?.materials = [material]
                }
                let material: UnlitMaterial
                switch state {
                case .correct: material = visual.isBlack ? correctBlackMaterial : correctMaterial
                case .wrong: material = visual.isBlack ? wrongBlackMaterial : wrongMaterial
                default: material = visual.isBlack ? playedBlackMaterial : playedMaterial
                }
                for surface in visual.pressedSurfaces { surface.model?.materials = [material] }
            }
            visual.connector.isEnabled = display.showsKeyConnectors && hand != nil && display.highlightOpacity > 0
            if let key = layout.key(for: pitch), visual.connector.isEnabled {
                let start = SIMD3<Float>(key.centerX - layout.width / 2, roll.surfaceY + noteThickness / 2, roll.hitLineZ)
                let end = SIMD3<Float>(start.x, key.topY + (key.isBlack ? 0.005 : 0.0035),
                                       key.centerZ - key.depth / 2 + 0.012)
                let vector = end - start
                visual.connector.position = (start + end) / 2
                visual.connector.scale = [key.width * 0.40, 0.0008, max(0.0001, simd_length(vector))]
                visual.connector.orientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: simd_normalize(vector))
                visual.connector.components.set(OpacityComponent(opacity: isPlayed ? 0.72 : (targetStrength[pitch] ?? 0) * 0.40))
            }
        }
    }

    private func configureNoteAppearance(_ visual: NoteVisual, hand: PianoHand, isBlack: Bool,
                                         isHeld: Bool, isCurrent: Bool) {
        let appearance = NoteAppearance(hand: hand, isBlack: isBlack, isHeld: isHeld,
                                        isCurrent: isCurrent)
        guard visual.appearance != appearance else { return }
        visual.appearance = appearance
        let materials = isHeld ? (isBlack ? heldBlackNoteMaterials : heldNoteMaterials)
            : (isBlack ? blackNoteMaterials : noteMaterials)
        if let fill = materials[hand] { visual.bar.model?.materials = [fill] }
        visual.onset.model?.materials = [isBlack || isCurrent || isHeld ? onsetMaterial : whiteOnsetMaterial]
        let edge = isHeld ? completionMaterial : isCurrent ? onsetMaterial : blackNoteEdgeMaterial
        visual.leftEdge.model?.materials = [edge]
        visual.rightEdge.model?.materials = [edge]
    }

    private func updateLandmarks(display: PianoDisplaySettings, roll: PianoRollGeometry, timing: PianoRollTiming) {
        landmarksRoot.isEnabled = display.showsLaneLandmarks && !cachedNotes.isEmpty
        guard landmarksRoot.isEnabled else { return }
        for lane in laneLines {
            lane.entity.scale = [lane.isOctave ? 0.00075 : 0.003, 0.0004, timing.lengthMeters]
            lane.entity.position = [lane.x, roll.surfaceY - 0.0008, roll.hitLineZ - timing.lengthMeters / 2]
        }
        for label in octaveLabels { label.position.z = roll.hitLineZ - 0.045; label.position.y = roll.surfaceY + 0.0004 }
    }

    private func updateBeats(session: PianoSession, display: PianoDisplaySettings, roll: PianoRollGeometry,
                              timing: PianoRollTiming, now: Double) {
        beatRoot.isEnabled = display.showsBeatGrid && session.song != nil
        guard beatRoot.isEnabled, let song = session.song else { return }
        let beats = song.beats(in: max(0, now)...max(0, now + timing.horizonSeconds), limit: 96)
        while beatLines.count < beats.count {
            let line = ModelEntity(mesh: box, materials: [beatMaterial])
            beatRoot.addChild(line)
            beatLines.append(line)
        }
        for index in beatLines.indices {
            let line = beatLines[index]
            line.isEnabled = index < beats.count
            guard index < beats.count else { continue }
            let beat = beats[index]
            line.model?.materials = [beat.isMeasure ? measureMaterial : beatMaterial]
            line.scale = [layout.width, 0.0004, beat.isMeasure ? 0.0015 : 0.0007]
            line.position = [0, roll.surfaceY - 0.0002,
                             roll.hitLineZ - Float(beat.time - now) * timing.speedMetersPerScoreSecond]
            line.components.set(OpacityComponent(opacity: Float(timing.distanceOpacity(forScoreOffset: beat.time - now, settings: display))))
        }
    }

    private func rebuildKeyboard() {
        templatesRoot.children.removeAll()
        highlightsRoot.children.removeAll()
        feedbackRoot.children.removeAll()
        landmarksRoot.children.removeAll()
        calibrationGuidesRoot.children.removeAll()
        laneLines.removeAll(keepingCapacity: true)
        octaveLabels.removeAll(keepingCapacity: true)
        keys.removeAll(keepingCapacity: true)
        for key in layout.keys {
            let template = ModelEntity(mesh: box, materials: [key.isBlack ? templateBlack : templateWhite])
            template.name = "CalibrationKey-\(key.note)"
            template.scale = [max(0.001, key.width - 0.001), 0.0012, key.depth]
            template.position = [key.centerX - layout.width / 2, key.topY + 0.0008, key.centerZ]
            templatesRoot.addChild(template)

            let displayY = key.topY + (key.isBlack ? 0.004 : 0.0025)
            let boundaryMaterial = key.isBlack ? blackKeyBoundary : whiteKeyBoundary
            let shape = keySurfaceShape(for: key)
            let templateBoundary = makeKeyBoundary(shape, y: key.topY + 0.0017, material: boundaryMaterial)
            templatesRoot.addChild(templateBoundary)
            let highlight = Entity()
            highlight.name = "HighlightKey-\(key.note)"
            let targetSurfaces = makeKeySurfaces(shape, y: displayY, material: playedMaterial, parent: highlight)
            highlight.addChild(makeKeyBoundary(shape, y: displayY + 0.0008, material: boundaryMaterial))
            highlight.isEnabled = false
            highlightsRoot.addChild(highlight)
            let feedback = Entity()
            feedback.name = "PressedKey-\(key.note)"
            let pressedSurfaces = makeKeySurfaces(shape, y: displayY, material: playedMaterial, parent: feedback)
            feedback.addChild(makeKeyBoundary(shape, y: displayY + 0.0008, material: boundaryMaterial))
            feedback.isEnabled = false
            feedbackRoot.addChild(feedback)
            let pulse = ModelEntity(mesh: box, materials: [correctMaterial])
            pulse.name = "ReleasedKeyPulse-\(key.note)"
            pulse.scale = [key.width * 0.80, 0.0012, 0.006]
            pulse.position = [key.centerX - layout.width / 2, displayY + 0.0015,
                              key.centerZ + key.depth / 2 - 0.004]
            pulse.isEnabled = false
            feedbackRoot.addChild(pulse)
            let handStrip = ModelEntity(mesh: box, materials: [playedMaterial])
            handStrip.scale = [key.width * 0.80, 0.001, 0.004]
            handStrip.position = [key.centerX - layout.width / 2, displayY + 0.002,
                                   key.centerZ - key.depth / 2 + 0.005]
            highlightsRoot.addChild(handStrip)
            let completion = makeCompletionCheck(box: box, material: completionMaterial)
            completion.position = [key.centerX - layout.width / 2, displayY + 0.002,
                                   key.centerZ + key.depth / 2 - 0.010]
            highlightsRoot.addChild(completion)
            let connector = ModelEntity(mesh: box, materials: [playedMaterial])
            highlightsRoot.addChild(connector)
            keys[key.note] = KeyVisual(template: template, templateBoundary: templateBoundary,
                highlight: highlight, feedback: feedback, pulse: pulse, targetSurfaces: targetSurfaces,
                pressedSurfaces: pressedSurfaces, isBlack: key.isBlack, handStrip: handStrip,
                completion: completion, connector: connector)

            if key.isBlack || key.note % 12 == 0 {
                let octave = key.note % 12 == 0
                let lane = ModelEntity(mesh: box, materials: [octave ? landmarkMaterial : laneMaterial])
                landmarksRoot.addChild(lane)
                let x = key.centerX - layout.width / 2 - (octave ? key.width / 2 : 0)
                laneLines.append((lane, x, octave))
                if octave {
                    let mesh = MeshResource.generateText("C\(key.note / 12 - 1)", extrusionDepth: 0.001,
                        font: .systemFont(ofSize: 1, weight: .medium), containerFrame: .zero,
                        alignment: .center, lineBreakMode: .byClipping)
                    let label = ModelEntity(mesh: mesh, materials: [makeMaterial(.white, opacity: 0.48)])
                    let scale = min(0.007 / max(mesh.bounds.extents.y, 0.001),
                                    key.width * 0.75 / max(mesh.bounds.extents.x, 0.001))
                    label.scale = SIMD3(repeating: scale)
                    label.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
                    label.position.x = key.centerX - layout.width / 2 - mesh.bounds.center.x * scale
                    landmarksRoot.addChild(label)
                    octaveLabels.append(label)
                }
            }
        }
        for (pitch, title, hand) in [(21, "A0 · 左端", PianoHand.left), (60, "C4 · 检查", .unassigned), (108, "C8 · 右端", .right)] {
            guard let key = layout.key(for: pitch) else { continue }
            let material = makeMaterial(PracticeAppearance.uiColor(for: hand), opacity: 1)
            let marker = ModelEntity(mesh: box, materials: [material])
            marker.scale = [key.width * 0.75, 0.001, 0.003]
            marker.position = [key.centerX - layout.width / 2, key.topY + 0.003, 0]
            calibrationGuidesRoot.addChild(marker)
            let mesh = MeshResource.generateText(title, extrusionDepth: 0.001,
                font: .systemFont(ofSize: 1, weight: .bold), containerFrame: .zero,
                alignment: .center, lineBreakMode: .byClipping)
            let label = ModelEntity(mesh: mesh, materials: [material])
            let scale = min(0.009 / max(mesh.bounds.extents.y, 0.001),
                            0.065 / max(mesh.bounds.extents.x, 0.001))
            label.scale = SIMD3(repeating: scale)
            let rotation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            label.orientation = rotation
            label.position = SIMD3(key.centerX - layout.width / 2, key.topY + 0.004, 0.020)
                - rotation.act(mesh.bounds.center * scale)
            calibrationGuidesRoot.addChild(label)
        }
        // The single onset line is behind the entire keyboard, including black
        // keys. Bars share a horizontal plane rather than crossing the key tops.
        hitLine.model = ModelComponent(mesh: box, materials: [makeMaterial(.white, opacity: 1)])
        hitLine.scale = [layout.width, 0.0015, 0.0025]
    }

    /// The visible white-key surface narrows behind adjacent black keys. Its
    /// depth and placement still come from the calibrated physical geometry.
    private func keySurfaceShape(for key: KeyGeometry) -> KeySurfaceShape {
        let gap: Float = key.isBlack ? 0.0004 : 0.0008
        let left = key.centerX - layout.width / 2 - key.width / 2 + gap / 2
        let right = key.centerX - layout.width / 2 + key.width / 2 - gap / 2
        let front = key.centerZ + key.depth / 2
        let rear = key.centerZ - key.depth / 2
        let leftBlack = layout.key(for: key.note - 1).flatMap { $0.isBlack ? $0 : nil }
        let rightBlack = layout.key(for: key.note + 1).flatMap { $0.isBlack ? $0 : nil }
        guard !key.isBlack, leftBlack != nil || rightBlack != nil else {
            return KeySurfaceShape(rectangles: [SIMD4(left, right, rear, front)],
                outline: [SIMD2(left, front), SIMD2(right, front), SIMD2(right, rear), SIMD2(left, rear)])
        }
        let neckFront = max(leftBlack.map { $0.centerZ + $0.depth / 2 } ?? rear,
                            rightBlack.map { $0.centerZ + $0.depth / 2 } ?? rear)
        let neckLeft = leftBlack.map { $0.centerX - layout.width / 2 + $0.width / 2 + gap / 2 } ?? left
        let neckRight = rightBlack.map { $0.centerX - layout.width / 2 - $0.width / 2 - gap / 2 } ?? right
        return KeySurfaceShape(rectangles: [SIMD4(left, right, neckFront, front),
                                           SIMD4(neckLeft, neckRight, rear, neckFront)],
            outline: [SIMD2(left, front), SIMD2(right, front), SIMD2(right, neckFront),
                      SIMD2(neckRight, neckFront), SIMD2(neckRight, rear), SIMD2(neckLeft, rear),
                      SIMD2(neckLeft, neckFront), SIMD2(left, neckFront)])
    }

    private func makeKeySurfaces(_ shape: KeySurfaceShape, y: Float, material: UnlitMaterial,
                                 parent: Entity) -> [ModelEntity] {
        shape.rectangles.map { rect in
            let surface = ModelEntity(mesh: box, materials: [material])
            surface.scale = [max(0.0001, rect.y - rect.x), 0.0012, max(0.0001, rect.w - rect.z)]
            surface.position = [(rect.x + rect.y) / 2, y, (rect.z + rect.w) / 2]
            parent.addChild(surface)
            return surface
        }
    }

    private func makeKeyBoundary(_ shape: KeySurfaceShape, y: Float, material: UnlitMaterial) -> Entity {
        let boundary = Entity()
        for index in shape.outline.indices {
            let first = shape.outline[index]
            let second = shape.outline[(index + 1) % shape.outline.count]
            guard simd_length_squared(second - first) > 0.00000001 else { continue }
            let edge = ModelEntity(mesh: box, materials: [material])
            edge.scale = [max(0.00065, abs(second.x - first.x)), 0.0005,
                          max(0.00065, abs(second.y - first.y))]
            edge.position = [(first.x + second.x) / 2, y, (first.y + second.y) / 2]
            boundary.addChild(edge)
        }
        return boundary
    }

    private func firstIndex(withEndAfter time: Double) -> Int {
        // Prefix maxima retain sustained notes that began before the visible time window.
        var low = 0
        var high = prefixMaximumEnd.count
        while low < high {
            let middle = (low + high) / 2
            if prefixMaximumEnd[middle] < time { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func recycleAllNotes() {
        for visual in visibleNotes.values {
            visual.root.isEnabled = false
            spareNotes.append(visual)
        }
        visibleNotes.removeAll(keepingCapacity: true)
    }
}

@MainActor
private final class KeyVisual {
    let template: ModelEntity
    let templateBoundary: Entity
    let highlight: Entity
    let feedback: Entity
    let pulse: ModelEntity
    let targetSurfaces: [ModelEntity]
    let pressedSurfaces: [ModelEntity]
    let isBlack: Bool
    let handStrip: ModelEntity
    let completion: Entity
    let connector: ModelEntity
    var state = KeyState.off
    var pulseState = KeyState.off
    var targetHand: PianoHand?

    init(template: ModelEntity, templateBoundary: Entity, highlight: Entity, feedback: Entity, pulse: ModelEntity,
         targetSurfaces: [ModelEntity], pressedSurfaces: [ModelEntity], isBlack: Bool,
         handStrip: ModelEntity, completion: Entity, connector: ModelEntity) {
        self.template = template
        self.templateBoundary = templateBoundary
        self.highlight = highlight
        self.feedback = feedback
        self.pulse = pulse
        self.targetSurfaces = targetSurfaces
        self.pressedSurfaces = pressedSurfaces
        self.isBlack = isBlack
        self.handStrip = handStrip
        self.completion = completion
        self.connector = connector
    }
}

@MainActor
private final class NoteVisual {
    let root = Entity()
    let bar: ModelEntity
    let onset: ModelEntity
    let restrike: ModelEntity
    let finger = ModelEntity()
    let leftEdge = ModelEntity()
    let rightEdge = ModelEntity()
    let completion = Entity()
    let completionCheck: Entity
    let pendingCap: ModelEntity
    var fingerValue: Int?
    var appearance: NoteAppearance?
    var fingerScale: Float = 1
    var fingerCenter = SIMD3<Float>.zero

    init(box: MeshResource) {
        let white = makeMaterial(.white, opacity: 1)
        let green = makeMaterial(UIColor(red: 0.3, green: 1, blue: 0.45, alpha: 1), opacity: 1)
        bar = ModelEntity(mesh: box, materials: [white])
        onset = ModelEntity(mesh: box, materials: [white])
        restrike = ModelEntity(mesh: box, materials: [white])
        leftEdge.model = ModelComponent(mesh: box, materials: [white])
        rightEdge.model = ModelComponent(mesh: box, materials: [white])
        completionCheck = makeCompletionCheck(box: box, material: green)
        pendingCap = ModelEntity(mesh: box, materials: [makeMaterial(.cyan, opacity: 1)])
        pendingCap.scale = [0.007, 0.001, 0.0015]
        completion.addChild(completionCheck)
        completion.addChild(pendingCap)
        for entity in [bar, onset, restrike, finger, leftEdge, rightEdge, completion] {
            root.addChild(entity)
        }
    }
}

private enum KeyState { case off, target, played, correct, wrong }

private struct NoteAppearance: Equatable {
    let hand: PianoHand
    let isBlack: Bool
    let isHeld: Bool
    let isCurrent: Bool
}

private struct KeySurfaceShape {
    /// Left, right, rear, front in keyboard-local metres.
    let rectangles: [SIMD4<Float>]
    let outline: [SIMD2<Float>]
}

private struct PianoSceneComponent: Component {
    weak var renderer: PianoSceneRenderer?
}

private struct PianoAnimationSystem: System {
    static let query = EntityQuery(where: .has(PianoSceneComponent.self))
    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            entity.components[PianoSceneComponent.self]?.renderer?.updateFrame()
        }
    }
}

@MainActor
private func makeMaterial(_ color: UIColor, opacity: Float, writesDepth: Bool = false) -> UnlitMaterial {
    var material = UnlitMaterial(color: color)
    material.blending = .transparent(opacity: .init(floatLiteral: opacity))
    material.writesDepth = writesDepth
    return material
}

@MainActor
private func makeCompletionCheck(box: MeshResource, material: UnlitMaterial) -> Entity {
    let result = Entity()
    let strokes: [(Float, Float, Float, Float)] =
        [(-0.002, 0.001, 0.004, -.pi / 4), (0.001, 0, 0.007, .pi / 4)]
    for (x, z, length, angle) in strokes {
        let stroke = ModelEntity(mesh: box, materials: [material])
        stroke.scale = [length, 0.001, 0.0012]
        stroke.position = [x, 0, z]
        stroke.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
        result.addChild(stroke)
    }
    return result
}
