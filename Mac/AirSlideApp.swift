import SwiftUI

@main
struct AirSlideApp: App {
    @StateObject private var rx = ReceiverService()

    var body: some Scene {
        Window("AirSlide", id: "main") {
            MainView().environmentObject(rx)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("AirSlide", systemImage: "antenna.radiowaves.left.and.right") {
            MenuBarContent().environmentObject(rx)
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject var rx: ReceiverService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusText)
        Divider()
        Button("Open AirSlide") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Show Desktop Folder") { rx.openDesktop() }
        Button("Forget all paired iPhones") { rx.forgetAll() }
        Divider()
        Button("Quit AirSlide") { NSApp.terminate(nil) }
    }

    private var statusText: String {
        switch rx.status {
        case .connected(let n): "Connected to \(n)"
        case .failed(let m): m
        default: "Waiting for iPhone"
        }
    }
}
