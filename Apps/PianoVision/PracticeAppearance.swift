import PianoCore
import SwiftUI
import UIKit

/// The same hand palette is used by the dashboard and the spatial renderer.
enum PracticeAppearance {
    static func uiColor(for hand: PianoHand, isBlack: Bool = false) -> UIColor {
        switch (hand, isBlack) {
        case (.left, false): UIColor(red: 0.12, green: 0.56, blue: 1, alpha: 1)
        case (.left, true): UIColor(red: 0.02, green: 0.25, blue: 0.65, alpha: 1)
        case (.right, false): UIColor(red: 1, green: 0.51, blue: 0.08, alpha: 1)
        case (.right, true): UIColor(red: 0.68, green: 0.24, blue: 0.01, alpha: 1)
        case (.unassigned, false): UIColor(red: 0.79, green: 0.83, blue: 0.90, alpha: 1)
        case (.unassigned, true): UIColor(red: 0.30, green: 0.36, blue: 0.46, alpha: 1)
        }
    }

    static func color(for hand: PianoHand, isBlack: Bool = false) -> Color {
        Color(uiColor: uiColor(for: hand, isBlack: isBlack))
    }

    enum InputFeedback { case pressed, correct, wrong }

    static func inputUIColor(_ feedback: InputFeedback, isBlack: Bool = false) -> UIColor {
        switch (feedback, isBlack) {
        case (.pressed, false): UIColor(red: 0, green: 0.72, blue: 0.94, alpha: 1)
        case (.pressed, true): UIColor(red: 0, green: 0.38, blue: 0.55, alpha: 1)
        case (.correct, false): UIColor(red: 0.03, green: 0.80, blue: 0.20, alpha: 1)
        case (.correct, true): UIColor(red: 0, green: 0.43, blue: 0.10, alpha: 1)
        case (.wrong, false): UIColor(red: 0.98, green: 0.05, blue: 0.10, alpha: 1)
        case (.wrong, true): UIColor(red: 0.64, green: 0.01, blue: 0.04, alpha: 1)
        }
    }

    static func noteUIColor(for feedback: PianoNoteFeedback, hand: PianoHand, isBlack: Bool = false) -> UIColor {
        // A note keeps its hand identity after a hit. Completion and physical
        // hold are communicated separately by checks and bright edges.
        let base = uiColor(for: hand, isBlack: isBlack)
        guard feedback == .pressed else { return base }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        base.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let lift: CGFloat = isBlack ? 0.16 : 0.28
        return UIColor(red: red + (1 - red) * lift, green: green + (1 - green) * lift,
                       blue: blue + (1 - blue) * lift, alpha: 1)
    }

    static func noteColor(for feedback: PianoNoteFeedback, hand: PianoHand, isBlack: Bool = false) -> Color {
        Color(uiColor: noteUIColor(for: feedback, hand: hand, isBlack: isBlack))
    }

    static func name(for hand: PianoHand) -> String {
        switch hand {
        case .left: "左手"
        case .right: "右手"
        case .unassigned: "未分配"
        }
    }
}
