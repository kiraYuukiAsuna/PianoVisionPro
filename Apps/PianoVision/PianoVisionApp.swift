import SwiftUI

@main
struct PianoVisionApp: App {
    @State private var session = PianoSession()

    var body: some Scene {
        WindowGroup {
            DashboardView(session: session)
        }
        .defaultSize(width: 1040, height: 760)

        ImmersiveSpace(id: "PianoSpace") {
            PianoImmersiveView(session: session)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
