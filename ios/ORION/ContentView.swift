import SwiftUI

struct ContentView: View {
    @EnvironmentObject var location: LocationService
    @ObservedObject private var appearance = OrionAppearance.shared
    @State private var tab = 0

    var body: some View {
        // Меню — ровно пять вкладок: больше пяти iOS всё равно прячет в
        // «Ещё», а SOS обязан оставаться на виду. Поэтому всё, что не
        // попало во вкладки, живёт блоками внизу «Статуса» — журнал там,
        // а история записей — экран внутри «Состояния», там же, где записи
        // и создаются.
        TabView(selection: $tab) {
            StatusView()
                .tabItem { Label("Статус", systemImage: "shield.fill") }
                .tag(0)

            MapHistoryView()
                .tabItem { Label("Карта", systemImage: "map.fill") }
                .tag(1)

            HealthView()
                .tabItem { Label("Состояние", systemImage: "heart.fill") }
                .tag(2)

            SOSView()
                .tabItem { Label("SOS", systemImage: "sos.circle.fill") }
                .tag(3)

            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
                .tag(4)
        }
        .tint(OrionTheme.accent)
        .onAppear {
            // «Безопасный путь» берёт текущую локацию из LocationService
            SafePathService.shared.locationProvider = { location.currentLocation }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSOSTab)) { _ in
            tab = 3
        }
    }
}

extension Notification.Name {
    static let openSOSTab = Notification.Name("openSOSTab")
}
