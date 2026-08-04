import SwiftUI

struct StatusView: View {
    @EnvironmentObject var loc: LocationService
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var suspicion: SuspicionService
    @EnvironmentObject var poi: PointsOfInterestService
    @EnvironmentObject var safePath: SafePathService
    @ObservedObject private var appearance = OrionAppearance.shared

    @State private var safePathMinutes = 15
    @State private var safeCode = ""
    @State private var safeCodeWrong = false

    var body: some View {
        NavigationView {
            ZStack {
                OrionScreenBackground()

                ScrollView {
                    VStack(spacing: 16) {
                        headerSection
                        trackingButton
                        safePathCard
                        if poi.pendingApproach != nil { approachCard }
                        suspicionCard
                        serverCard
                        gpsCard
                        statsCard
                        if let err = loc.errorMessage { errorCard(err) }
                        journalSection
                        Spacer(minLength: 30)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                // Питомец гуляет по тому экрану, где сейчас пользователь.
                PetLayer(habitat: .roam)
            }
            .navigationBarHidden(true)
            .onReceive(suspicion.$assessment) { verdict in
                // Питомец реагирует на то, что и так видно на экране.
                PetCompanion.shared.react(suspicion: verdict?.suspicion ?? 0)
            }
        }
    }

    // MARK: - Header

    var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("O.R.I.O.N.")
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(OrionTheme.accent)
                Text("Adaptive Emergency Guardian")
                    .font(.caption2)
                    .foregroundColor(OrionTheme.textSecondary)
            }
            Spacer()
            // Индикатор связи с сервером
            Circle()
                .fill(loc.serverOnline ? OrionTheme.success : OrionTheme.danger)
                .frame(width: 10, height: 10)
                .shadow(color: loc.serverOnline ? OrionTheme.success : OrionTheme.danger, radius: 4)
                .animation(.easeInOut(duration: 0.5), value: loc.serverOnline)
        }
        .padding(.top, 8)
    }

    // MARK: - Кнопка старт/стоп

    var trackingButton: some View {
        Button {
            loc.isTracking ? loc.stopTracking() : loc.startTracking()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: loc.isTracking ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
                Text(loc.isTracking ? "Остановить" : "Запустить слежение")
            }
        }
        .buttonStyle(OrionActionButtonStyle(role: loc.isTracking ? .danger : .primary))
    }

    // MARK: - Карточки

    // MARK: - Безопасный путь (таймер → SOS)

    @ViewBuilder
    var safePathCard: some View {
        ORIONCard(accent: safePath.isArmed) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Безопасный путь", systemImage: "figure.walk.motion")
                    .font(.caption).foregroundColor(OrionTheme.accent)
                    .textCase(.uppercase).tracking(1)

                if safePath.isArmed {
                    HStack {
                        Image(systemName: "timer").foregroundColor(OrionTheme.warning)
                        Text(safePath.remainingString)
                            .font(.system(size: 30, weight: .bold, design: .monospaced))
                            .foregroundColor(OrionTheme.warning)
                        Spacer()
                    }
                    Text("По прибытии введи код безопасности, иначе сработает SOS.")
                        .font(.caption).foregroundColor(OrionTheme.textSecondary)

                    SecureField("Код безопасности", text: $safeCode)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)

                    if safeCodeWrong {
                        Text("Неверный код").font(.caption2).foregroundColor(OrionTheme.danger)
                    }

                    HStack(spacing: 10) {
                        Button("Я в безопасности") {
                            if safePath.confirmSafe(code: safeCode) {
                                safeCode = ""; safeCodeWrong = false
                            } else {
                                safeCodeWrong = true
                            }
                        }
                        .buttonStyle(OrionActionButtonStyle(role: .success))

                        Button("+5 мин") { safePath.extend(minutes: 5) }
                            .buttonStyle(OrionSecondaryButtonStyle())
                    }
                } else {
                    Text("Запусти таймер в опасной зоне. Не подтвердишь прибытие вовремя — уйдёт SOS.")
                        .font(.caption).foregroundColor(OrionTheme.textSecondary)

                    Stepper("Время: \(safePathMinutes) мин", value: $safePathMinutes, in: 5...120, step: 5)
                        .foregroundColor(OrionTheme.textPrimary)

                    Button("Запустить безопасный путь") {
                        safePath.arm(minutes: safePathMinutes)
                    }
                    .buttonStyle(OrionActionButtonStyle(role: .primary))
                }
            }
        }
    }

    // MARK: - Вопрос о приближении к точке интереса

    @ViewBuilder
    var approachCard: some View {
        if let p = poi.pendingApproach {
            ORIONCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Точка интереса", systemImage: p.category.icon)
                        .font(.caption).foregroundColor(OrionTheme.accent)
                        .textCase(.uppercase).tracking(1)

                    Text("Направляешься в «\(p.name)»?")
                        .font(.headline).foregroundColor(OrionTheme.textPrimary)

                    HStack(spacing: 10) {
                        Button("Да") { poi.answerApproach(true) }
                            .buttonStyle(OrionActionButtonStyle(role: .primary))
                        Button("Нет") { poi.answerApproach(false) }
                            .buttonStyle(OrionSecondaryButtonStyle())
                    }
                }
            }
        }
    }

    // MARK: - Счётчик подозрений («Мозг»)

    private var suspicionColor: Color {
        switch suspicion.assessment?.level {
        case .alarm: return OrionTheme.danger
        case .watch: return OrionTheme.warning
        default:     return OrionTheme.success
        }
    }

    @ViewBuilder
    var suspicionCard: some View {
        ORIONCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Анализ", systemImage: "brain.head.profile")
                        .font(.caption).foregroundColor(OrionTheme.accent)
                        .textCase(.uppercase).tracking(1)
                    Spacer()
                    if suspicion.isAnalyzing || suspicion.startupAnalyzing {
                        Text("Анализирую…")
                            .font(.caption2).foregroundColor(OrionTheme.accent)
                    }
                }

                if let a = suspicion.assessment {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(a.suspicion)")
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .foregroundColor(suspicionColor)
                        Text("/ 100")
                            .font(.caption).foregroundColor(OrionTheme.textSecondary)
                        Spacer()
                        if let badge = sourceBadge(a.source) {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(OrionTheme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(OrionTheme.surfaceHi.opacity(0.6)))
                                .overlay(Capsule().stroke(OrionTheme.border, lineWidth: 1))
                        }
                    }

                    // Шкала
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(OrionTheme.border)
                            Capsule().fill(suspicionColor)
                                .frame(width: geo.size.width * CGFloat(a.suspicion) / 100)
                        }
                    }
                    .frame(height: 6)

                    Text(a.reason)
                        .font(.caption).foregroundColor(OrionTheme.textPrimary.opacity(0.85))

                    // Реплика «голосом» AEGIS
                    if !a.voice.isEmpty {
                        Text(a.voice)
                            .font(.caption2)
                            .foregroundColor(OrionTheme.textSecondary)
                    }

                    if let err = suspicion.lastError {
                        Text("⚠️ Нейро-усиление недоступно: \(err)")
                            .font(.caption2).foregroundColor(OrionTheme.warning)
                    }

                    if a.shouldAsk {
                        Text(a.question.isEmpty ? "Всё ли с тобой хорошо?" : a.question)
                            .font(.subheadline).foregroundColor(OrionTheme.warning)
                        Button("Всё в порядке") { suspicion.acknowledge() }
                            .buttonStyle(OrionActionButtonStyle(role: .primary))
                    }
                } else {
                    Text(settings.suspicionEnabled
                         ? "Ожидание первой оценки маршрута…"
                         : "Анализ выключен в настройках")
                        .font(.caption).foregroundColor(OrionTheme.textSecondary)
                }
            }
        }
    }

    var serverCard: some View {
        ORIONCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Сервер", systemImage: "server.rack")
                    .font(.caption).foregroundColor(OrionTheme.accent)
                    .textCase(.uppercase).tracking(1)

                HStack {
                    Circle()
                        .fill(loc.serverOnline ? OrionTheme.success : OrionTheme.danger)
                        .frame(width: 8, height: 8)
                    Text(loc.serverOnline ? "Онлайн" : "Недоступен")
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Button("Проверить") {
                        Task {
                            let ok = await NetworkService().checkHealth(settings.serverURL)
                            loc.serverOnline = ok
                        }
                    }
                    .font(.caption).foregroundColor(OrionTheme.accent)
                }

                Text(settings.serverURL)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(OrionTheme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    var gpsCard: some View {
        ORIONCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("GPS", systemImage: "location.fill")
                    .font(.caption).foregroundColor(OrionTheme.accent)
                    .textCase(.uppercase).tracking(1)

                switch loc.authStatus {
                case .authorizedAlways:
                    row("🟢", "Разрешено: всегда")
                case .authorizedWhenInUse:
                    row("🟡", "Разрешено: при использовании")
                    Text("Лучше выдать «Всегда» для фона")
                        .font(.caption2).foregroundColor(OrionTheme.warning)
                case .denied, .restricted:
                    row("🔴", "Доступ запрещён")
                default:
                    row("⚪", "Нет разрешения")
                }

                if let coord = loc.currentLocation?.coordinate {
                    row("📍", String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                }

                if !loc.isTracking && loc.authStatus != .denied {
                    Button("Выдать разрешение") { loc.requestPermission() }
                        .font(.caption).foregroundColor(OrionTheme.accent)
                }
            }
        }
    }

    var statsCard: some View {
        ORIONCard {
            HStack(spacing: 0) {
                statItem(value: "\(settings.totalPointsSent)", label: "Отправлено")
                Divider().background(OrionTheme.border)
                statItem(value: "\(loc.locationHistory.count)", label: "В памяти")
                Divider().background(OrionTheme.border)
                statItem(
                    value: settings.lastLocationDate.map {
                        let m = Int(-$0.timeIntervalSinceNow / 60)
                        return m < 1 ? "сейчас" : "\(m)м"
                    } ?? "—",
                    label: "Обновление"
                )
            }
        }
    }

    func errorCard(_ msg: String) -> some View {
        ORIONCard {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(OrionTheme.warning)
                Text(msg).font(.caption).foregroundColor(OrionTheme.warning)
            }
        }
    }

    // MARK: - Журнал (пункт внизу «Статуса»)

    /// Раньше это была отдельная вкладка, из-за которой iOS прятала часть
    /// меню в «Ещё». Теперь — блок внизу «Статуса»: вкладки прежние,
    /// а пункт на виду.
    @ViewBuilder
    var journalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Журнал").orionSectionLabel()

            ORIONCard {
                NavigationLink {
                    RecordsHistoryView().environmentObject(HealthService.shared)
                } label: {
                    menuRow(
                        icon: "clock.arrow.circlepath",
                        title: "История записей",
                        subtitle: "Правка и удаление — по код-паролю",
                        badge: nil)
                }
            }
        }
    }

    private func menuRow(icon: String, title: String, subtitle: String, badge: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(OrionTheme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(OrionTheme.textPrimary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(OrionTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if let badge = badge {
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(OrionTheme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .glassPill(tint: OrionTheme.accent)
            }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(OrionTheme.textTertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    /// Подпись бейджа источника вердикта «мозга».
    private func sourceBadge(_ source: String) -> String? {
        switch source {
        case "aegis":     return "AEGIS"
        case "aegis+llm": return "AEGIS+нейро"
        case "llm":       return "нейро"
        default:          return nil
        }
    }

    func row(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(icon).font(.caption)
            Text(text).font(.system(.caption, design: .monospaced)).foregroundColor(OrionTheme.textPrimary.opacity(0.85))
        }
    }

    func statItem(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.title3, design: .monospaced)).foregroundColor(OrionTheme.accent)
            Text(label).font(.caption2).foregroundColor(OrionTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
