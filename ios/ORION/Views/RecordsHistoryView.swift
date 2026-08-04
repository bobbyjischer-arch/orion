import SwiftUI

/// История записей журнала.
///
/// Смотреть можно свободно. Править и удалять — только после ввода
/// код-пароля (`HistoryLock`): один ввод открывает окно на 2 минуты.
/// Удалённые записи не исчезают, а помечаются — их видно переключателем
/// «показать удалённые» и можно восстановить.
struct RecordsHistoryView: View {
    @EnvironmentObject var health: HealthService
    @ObservedObject private var lock = HistoryLock.shared
    @ObservedObject private var appearance = OrionAppearance.shared

    @State private var kindFilter: RecordKind?
    @State private var showDeleted = false
    @State private var showCodeSheet = false
    @State private var editing: SyncRecord?
    @State private var pendingDelete: SyncRecord?
    /// Что сделать сразу после успешного ввода кода.
    @State private var afterUnlock: (() -> Void)?

    // Своего NavigationView здесь нет: экран открывается из «Состояния»,
    // вложенная навигация ломала бы заголовок и жест «назад».
    var body: some View {
        ZStack {
            OrionTheme.backgroundGradient.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    lockCard
                    filterCard
                    if records.isEmpty {
                        emptyCard
                    } else {
                        ForEach(records) { rec in
                            recordRow(rec)
                        }
                    }
                    Spacer(minLength: 30)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .navigationTitle("История записей")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCodeSheet) {
            HistoryCodeSheet {
                let action = afterUnlock
                afterUnlock = nil
                showCodeSheet = false
                action?()
            }
        }
        .sheet(item: $editing) { rec in
            RecordEditSheet(record: rec).environmentObject(health)
        }
        .alert("Удалить запись?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { rec in
            Button("Удалить", role: .destructive) {
                health.deleteRecord(rec)
                pendingDelete = nil
            }
            Button("Отмена", role: .cancel) { pendingDelete = nil }
        } message: { rec in
            Text("\(rec.kind.title): \(rec.summary)\n\nЗапись помечается удалённой — её можно восстановить.")
        }
    }

    // MARK: - Данные

    private var records: [SyncRecord] {
        health.history(includeDeleted: showDeleted)
            .filter { kindFilter == nil || $0.kind == kindFilter }
    }

    // MARK: - Карточки

    private var lockCard: some View {
        ORIONCard(accent: lock.isUnlocked) {
            HStack(spacing: 10) {
                Image(systemName: lock.isUnlocked ? "lock.open.fill" : "lock.fill")
                    .foregroundColor(lock.isUnlocked ? OrionTheme.accent : OrionTheme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lock.isUnlocked ? "Правка разрешена" : "Правка защищена кодом")
                        .font(.caption.weight(.semibold)).foregroundColor(OrionTheme.textPrimary)
                    Text(lock.isConfigured
                         ? (lock.isUnlocked
                            ? "Доступ откроется на \(Int(HistoryLock.unlockWindow / 60)) мин"
                            : "Введите код-пароль, чтобы менять или удалять записи")
                         : "Код-пароль ещё не создан")
                        .font(.caption2).foregroundColor(OrionTheme.textSecondary)
                }
                Spacer()
                if lock.isUnlocked {
                    Button("Закрыть") { lock.lock() }
                        .font(.caption).foregroundColor(OrionTheme.warning)
                } else {
                    Button(lock.isConfigured ? "Ввести" : "Создать") {
                        afterUnlock = nil
                        showCodeSheet = true
                    }
                    .font(.caption.weight(.semibold)).foregroundColor(OrionTheme.accent)
                }
            }
        }
    }

    private var filterCard: some View {
        ORIONCard {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("Все", active: kindFilter == nil) { kindFilter = nil }
                        ForEach(RecordKind.allCases, id: \.self) { k in
                            chip(k.title, active: kindFilter == k) { kindFilter = k }
                        }
                    }
                }
                Toggle(isOn: $showDeleted) {
                    Text("Показывать удалённые").font(.caption).foregroundColor(OrionTheme.textPrimary.opacity(0.85))
                }
                .tint(OrionTheme.accent)
                Text("Записей: \(records.count)")
                    .font(.caption2).foregroundColor(OrionTheme.textSecondary)
            }
        }
    }

    private var emptyCard: some View {
        ORIONCard {
            VStack(spacing: 6) {
                Image(systemName: "tray").foregroundColor(OrionTheme.textSecondary)
                Text(kindFilter == nil ? "Записей пока нет" : "Нет записей этого типа")
                    .font(.caption).foregroundColor(OrionTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    private func recordRow(_ rec: SyncRecord) -> some View {
        ORIONCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: rec.kind.icon)
                        .font(.caption).foregroundColor(OrionTheme.accent)
                    Text(rec.kind.title)
                        .font(.caption).foregroundColor(OrionTheme.accent)
                        .textCase(.uppercase).tracking(1)
                    if rec.deleted {
                        Text("УДАЛЕНА")
                            .font(.caption2.weight(.bold)).foregroundColor(OrionTheme.warning)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(OrionTheme.warning.opacity(0.15)).cornerRadius(4)
                    }
                    Spacer()
                    Text(Self.dateFormatter.string(from: rec.createdAt))
                        .font(.caption2).foregroundColor(OrionTheme.textSecondary)
                }

                Text(rec.summary.isEmpty ? "—" : rec.summary)
                    .font(.subheadline).foregroundColor(OrionTheme.textPrimary.opacity(0.9))
                    .strikethrough(rec.deleted, color: OrionTheme.textSecondary)

                if rec.updatedAt.timeIntervalSince(rec.createdAt) > 60 {
                    Text("изменена \(Self.dateFormatter.string(from: rec.updatedAt))")
                        .font(.caption2).foregroundColor(OrionTheme.textSecondary)
                }

                HStack(spacing: 14) {
                    Spacer()
                    if rec.deleted {
                        Button {
                            gated { health.restoreRecord(rec) }
                        } label: {
                            Label("Восстановить", systemImage: "arrow.uturn.backward")
                                .font(.caption)
                        }
                        .foregroundColor(OrionTheme.success)
                    } else {
                        Button {
                            gated { editing = rec }
                        } label: {
                            Label("Изменить", systemImage: "pencil").font(.caption)
                        }
                        .foregroundColor(OrionTheme.accent)

                        Button {
                            gated { pendingDelete = rec }
                        } label: {
                            Label("Удалить", systemImage: "trash").font(.caption)
                        }
                        .foregroundColor(OrionTheme.danger)
                    }
                }
            }
        }
    }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(active ? OrionTheme.accent.opacity(0.25) : OrionTheme.surface)
                .foregroundColor(active ? OrionTheme.accent : OrionTheme.textSecondary)
                .cornerRadius(OrionTheme.Radius.chip)
        }
    }

    /// Выполнить действие, если код уже введён; иначе — спросить код и
    /// выполнить его сразу после успешного ввода.
    private func gated(_ action: @escaping () -> Void) {
        if lock.isUnlocked {
            action()
        } else {
            afterUnlock = action
            showCodeSheet = true
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()
}

// MARK: - Ввод / создание код-пароля

struct HistoryCodeSheet: View {
    @ObservedObject private var lock = HistoryLock.shared
    @ObservedObject private var appearance = OrionAppearance.shared
    @Environment(\.dismiss) private var dismiss

    /// Вызывается при успешной разблокировке.
    var onUnlocked: () -> Void

    @State private var code = ""
    @State private var confirm = ""

    private var isSetup: Bool { !lock.isConfigured }

    var body: some View {
        NavigationView {
            ZStack {
                OrionTheme.backgroundGradient.ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: isSetup ? "lock.badge.plus" : "lock.fill")
                        .font(.system(size: 40)).foregroundColor(OrionTheme.accent)
                        .padding(.top, 20)

                    Text(isSetup ? "Создайте код-пароль" : "Введите код-пароль")
                        .font(.headline).foregroundColor(OrionTheme.textPrimary)

                    Text(isSetup
                         ? "Без него нельзя будет менять и удалять записи истории. Смотреть историю код не требует."
                         : "Код нужен, чтобы изменить или удалить запись.")
                        .font(.caption).foregroundColor(OrionTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    SecureField("Код", text: $code)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 24)

                    if isSetup {
                        SecureField("Повторите код", text: $confirm)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .padding(.horizontal, 24)
                    }

                    if let err = lock.lastError {
                        Text(err).font(.caption).foregroundColor(OrionTheme.danger)
                    }

                    Button {
                        submit()
                    } label: {
                        Text(isSetup ? "Сохранить код" : "Открыть доступ")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(OrionTheme.accent.orionContrastingText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(OrionTheme.accent)
                            .cornerRadius(OrionTheme.Radius.button)
                    }
                    .padding(.horizontal, 24)

                    Spacer()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { lock.lastError = nil; dismiss() }
                        .foregroundColor(OrionTheme.textSecondary)
                }
            }
        }
    }

    private func submit() {
        if isSetup {
            guard code == confirm else {
                lock.lastError = "Коды не совпадают"
                return
            }
            guard lock.setInitialCode(code) else { return }
        } else {
            guard lock.attempt(code) else { return }
        }
        code = ""; confirm = ""
        onUnlocked()
        dismiss()
    }
}

// MARK: - Правка записи

struct RecordEditSheet: View {
    @EnvironmentObject var health: HealthService
    @ObservedObject private var appearance = OrionAppearance.shared
    @Environment(\.dismiss) private var dismiss

    let record: SyncRecord

    @State private var weightText = ""
    @State private var mood = 3
    @State private var stress = 3
    @State private var sleep = 7.0
    @State private var text = ""
    @State private var title = ""
    @State private var error: String?

    var body: some View {
        NavigationView {
            ZStack {
                OrionTheme.backgroundGradient.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        ORIONCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(record.kind.title, systemImage: record.kind.icon)
                                    .font(.caption).foregroundColor(OrionTheme.accent)
                                    .textCase(.uppercase).tracking(1)

                                switch record.kind {
                                case .weight:
                                    TextField("кг", text: $weightText)
                                        .keyboardType(.decimalPad)
                                        .textFieldStyle(.roundedBorder)
                                case .mood:
                                    Stepper("Настроение: \(mood)/5", value: $mood, in: 1...5)
                                        .foregroundColor(OrionTheme.textPrimary)
                                    Stepper("Стресс: \(stress)/5", value: $stress, in: 1...5)
                                        .foregroundColor(OrionTheme.textPrimary)
                                    VStack(alignment: .leading) {
                                        Text(String(format: "Сон: %.1f ч", sleep))
                                            .foregroundColor(OrionTheme.textPrimary)
                                        Slider(value: $sleep, in: 0...12, step: 0.5).tint(OrionTheme.accent)
                                    }
                                    TextField("Заметка", text: $text)
                                        .textFieldStyle(.roundedBorder)
                                case .supplement:
                                    TextField("Название", text: $title)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("Доза и режим", text: $text)
                                        .textFieldStyle(.roundedBorder)
                                case .note:
                                    TextField("Заголовок", text: $title)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("Текст", text: $text, axis: .vertical)
                                        .lineLimit(3...8)
                                        .textFieldStyle(.roundedBorder)
                                }

                                if let error {
                                    Text(error).font(.caption).foregroundColor(OrionTheme.danger)
                                }
                            }
                        }
                        Spacer(minLength: 20)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Изменить запись")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.foregroundColor(OrionTheme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }.foregroundColor(OrionTheme.accent)
                }
            }
            .onAppear(perform: fill)
        }
    }

    private func fill() {
        weightText = record.value.map { String(format: "%.1f", $0) } ?? ""
        mood = record.mood ?? 3
        stress = record.stress ?? 3
        sleep = record.sleepHours ?? 7
        title = record.title
        text = record.text
    }

    private func save() {
        switch record.kind {
        case .weight:
            guard let e = health.weights.first(where: { $0.id.uuidString == record.id }) else {
                error = "Запись не найдена"; return
            }
            guard let kg = Double(weightText.replacingOccurrences(of: ",", with: ".")) else {
                error = "Введите вес числом"; return
            }
            health.updateWeight(e, kg: kg)
        case .mood:
            guard let e = health.moods.first(where: { $0.id.uuidString == record.id }) else {
                error = "Запись не найдена"; return
            }
            health.updateMood(e, mood: mood, stress: stress, sleepHours: sleep, note: text)
        case .supplement:
            guard let e = health.supplements.first(where: { $0.id.uuidString == record.id }) else {
                error = "Запись не найдена"; return
            }
            let parts = text.split(separator: "·").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            health.updateSupplement(e, name: title,
                                    dose: parts.first ?? "",
                                    schedule: parts.count > 1 ? parts[1] : "")
        case .note:
            guard let e = health.notes.first(where: { $0.id.uuidString == record.id }) else {
                error = "Запись не найдена"; return
            }
            health.updateNote(e, title: title, text: text)
        }
        dismiss()
    }
}
