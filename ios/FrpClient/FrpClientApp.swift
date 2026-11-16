import SwiftUI

@main
struct FrpClientApp: App {
    @StateObject private var controller = FrpcController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
                .environmentObject(controller.keepAlive)
        }
    }
}
