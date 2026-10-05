import SwiftUI

@main struct FGOTrackApp: App {
    @StateObject private var store = HouseStore.shared
    @StateObject private var backend = SupabaseService.shared
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store).environmentObject(backend)
                .task { backend.start(); await backend.loadProviders() }
                .onOpenURL { url in if !RoomInvitationRouter.shared.open(url) && !QuickCaptureRouter.shared.open(url) { Task { await backend.handleCallback(url) } } }
                .environment(\.timeZone, TimeZone(identifier: "Asia/Kolkata")!)
        }
    }
}
