import SwiftUI

struct SOSView: View {
    @EnvironmentObject var loc: LocationService
    @EnvironmentObject var sos: SOSService
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var appearance = OrionAppearance.shared

    @State private var showConfirm = false
    @State private var showResult  = false
    @State private var countdown   = 5
    @State private var countTimer: Timer?

    var body: some View {
        NavigationView {
            ZStack {
                OrionScreenBackground()

                VStack(spacing: 24) {
                    Spacer()

                    // Большая кнопка SOS
                    SOSButton(isSending: sos.isSending) {
                        startCountdown()
                    }

                    Text("Нажми и удерживай для подтверждения")
                        .font(.caption)
                        .foregroundColor(OrionTheme.textSecondary)

                    // Статус
                    if let result = sos.lastResult {
                        Text(sos.resultMessage)
                            .font(.subheadline)
                            .foregroundColor(resultColor(result))
                            .padding(.horizontal, 20)
                            .multilineTextAlignment(.center)
                            .transition(.opacity)
                    }

                    Spacer()

                    // Контакты
                    contactsPreview

                    // Местоположение
                    if let coord = loc.currentLocation?.coordinate {
                        Text(String(format: "📍 %.5f, %.5f", coord.latitude, coord.longitude))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(OrionTheme.textSecondary)
                    }

                    Spacer()
                }
                .padding()

                // Питомец дремлет калачиком рядом с кнопкой SOS.
                // Якорь — примерное место кнопки в этой раскладке: точнее
                // не нужно, движок сам отходит в сторону, чтобы её не закрыть.
                if appearance.petGuardsSOS {
                    PetLayer(habitat: .sosGuard, anchor: UnitPoint(x: 0.5, y: 0.30))
                }
            }
            .navigationTitle("🆘 SOS")
            .navigationBarTitleDisplayMode(.inline)
            // Диалог подтверждения с обратным отсчётом
            .alert("Отправить SOS?", isPresented: $showConfirm) {
                Button("Отмена", role: .cancel) { cancelCountdown() }
                Button("Отправить (\(countdown))", role: .destructive) { sendSOS() }
            } message: {
                Text("Будут уведомлены \(settings.sosContacts.count) контакт(ов).\nОтправка через \(countdown) сек.")
            }
            .onChange(of: countdown) { val in
                if val == 0 { sendSOS() }
            }
            .onChange(of: sos.isSending) { sending in
                // Когда тревога уходит, питомец не спит — встаёт и смотрит.
                PetCompanion.shared.react(sosActive: sending)
            }
        }
    }

    // MARK: - Контакты

    var contactsPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            if settings.sosContacts.isEmpty {
                Label("Нет контактов. Добавь в Настройках.", systemImage: "person.badge.plus")
                    .font(.caption).foregroundColor(OrionTheme.warning)
            } else {
                Label("Контакты для SOS:", systemImage: "person.2.fill")
                    .font(.caption).foregroundColor(OrionTheme.textSecondary)
                ForEach(settings.sosContacts) { c in
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(OrionTheme.success)
                        Text(c.name).font(.caption).foregroundColor(OrionTheme.textPrimary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OrionTheme.surface)
        .cornerRadius(OrionTheme.Radius.button)
    }

    // MARK: - Logic

    func startCountdown() {
        guard !sos.isSending else { return }
        countdown = 5
        showConfirm = true
        countTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if countdown > 0 { countdown -= 1 }
        }
    }

    func cancelCountdown() {
        countTimer?.invalidate()
        countTimer = nil
    }

    func sendSOS() {
        cancelCountdown()
        showConfirm = false
        Task {
            await sos.trigger(location: loc.currentLocation)
            withAnimation { showResult = true }
        }
    }

    func resultColor(_ result: SOSService.SOSResult) -> Color {
        switch result {
        case .success:         return OrionTheme.success
        case .partialSuccess:  return OrionTheme.warning
        case .serverOnly:      return OrionTheme.accent
        case .failed:          return OrionTheme.danger
        }
    }
}

// MARK: - Кнопка SOS

/// Единственный элемент, намеренно не подчинённый оформлению: паническая
/// кнопка обязана выглядеть одинаково при любой теме и акценте.
struct SOSButton: View {
    let isSending: Bool
    let action: () -> Void

    @State private var pressing = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Внешнее пульсирующее кольцо
                Circle()
                    .stroke(Color.red.opacity(0.2), lineWidth: 20)
                    .frame(width: 180, height: 180)
                    .scaleEffect(pressing ? 1.1 : 1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pressing)

                // Основная кнопка
                Circle()
                    .fill(isSending ? Color.orange : Color.red)
                    .frame(width: 140, height: 140)
                    .shadow(color: .red.opacity(0.6), radius: isSending ? 20 : 10)

                if isSending {
                    ProgressView().tint(.white).scaleEffect(1.5)
                } else {
                    Text("SOS")
                        .font(.system(size: 42, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                }
            }
        }
        .disabled(isSending)
        .onAppear { pressing = true }
        .scaleEffect(isSending ? 0.95 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isSending)
    }
}
