import SwiftUI


@main
struct SingleBuildProjectApp: App {
    @StateObject private var vm = PlantsVM()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(vm)
        }
    }
}
