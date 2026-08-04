import SwiftUI

@main
struct ORIONApp: App {
    @StateObject private var location = LocationService()
    @StateObject private var sos      = SOSService()
    @StateObject private var settings = AppSettings.shared
    @ObservedObject  private var suspicion = SuspicionService.shared
    @ObservedObject  private var poi       = PointsOfInterestService.shared
    @ObservedObject  private var safePath  = SafePathService.shared
    @ObservedObject  private var health    = HealthService.shared
    @ObservedObject  private var lock  = AppLock.shared
    /// Оформление живёт на корне: от него зависят системный вид контролов
    /// (тумблеры, слайдеры, клавиатура — на светлых палитрах они должны быть
    /// светлыми) и размер текста во всём приложении.
    @ObservedObject  private var appearance = OrionAppearance.shared
    @State private var showJailbreakWarning = false
    @State private var jailbreakMessage = ""

    init() {
        // Единый тёмный вид навигации/таб-бара (дизайн-система).
        OrionTheme.configureAppearance()

        Task { await NotificationService.shared.requestPermission() }

        // Check for jailbreak
        if let warning = JailbreakDetector.shared.warnIfJailbroken() {
            jailbreakMessage = warning
            showJailbreakWarning = true
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if lock.isUnlocked {
                    // Правильный пароль — показываем настоящий O.R.I.O.N.
                    ContentView()
                        .environmentObject(location)
                        .environmentObject(sos)
                        .environmentObject(settings)
                        .environmentObject(suspicion)
                        .environmentObject(poi)
                        .environmentObject(safePath)
                        .environmentObject(health)
                        .transition(.opacity)
                } else {
                    // Экран блокировки — выглядит как Secure Vault
                    LockView()
                        .transition(.opacity)
                }
            }
            // Оформление применяется к обоим состояниям — и к экрану
            // блокировки тоже, иначе «Secure Vault» жил бы в своей теме.
            .preferredColorScheme(appearance.colorScheme)
            .dynamicTypeSize(appearance.dynamicTypeSize)
            .animation(appearance.animation(.easeInOut(duration: 0.25)), value: lock.isUnlocked)
            .alert("Предупреждение безопасности", isPresented: $showJailbreakWarning) {
                Button("Понятно", role: .cancel) { }
            } message: {
                Text(jailbreakMessage)
            }
        }
    }
}
