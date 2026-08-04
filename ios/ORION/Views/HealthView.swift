import SwiftUI

struct HealthView: View {
    @EnvironmentObject var health: HealthService
    @EnvironmentObject var settings: AppSettings
    /// Экран собран из токенов OrionTheme — без подписки смена палитры
    /// не перерисовала бы карточки.
    @ObservedObject private var appearance = OrionAppearance.shared

    @State private var weightDraft = ""
    @State private var mood = 3
    @State private var stress = 3
    @State private var sleep = 7.0
    @State private var moodNote = ""

    // Скринеры заполняют не каждый день — по умолчанию выключены, чтобы
    // не превращать ежедневную отметку настроения в анкету из четырёх вопросов.
    @State private var screenerOn = false
    @State private var phqInterest = 0
    @State private var phqMood = 0
    @State private var gadNervous = 0
    @State private var gadWorry = 0

    @State private var suppName = ""
    @State private var suppDose = ""

    @State private var noteTitle = ""
    @State private var noteText = ""

    @State private var assessment: HealthAssessment?
    @State private var analyzing = false

    private let llm = LLMService()

    var body: some View {
        NavigationView {
            ZStack {
                OrionTheme.backgroundGradient.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        activityCard
                        weightCard
                        moodCard
                        noteCard
                        supplementsCard
                        historyCard
                        analysisCard
                        Spacer(minLength: 30)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("❤️ Состояние")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { health.startPedometer() }
    }

    // MARK: - История записей

    var historyCard: some View {
        ORIONCard {
            NavigationLink {
                RecordsHistoryView().environmentObject(health)
            } label: {
                HStack {
                    Label("История записей", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline).foregroundColor(OrionTheme.textPrimary)
                    Spacer()
                    Text("\(health.history().count)")
                        .font(.caption.monospaced()).foregroundColor(OrionTheme.accent)
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(OrionTheme.textTertiary)
                }
            }
        }
    }

    // MARK: - Активность (шагомер)

    var activityCard: some View {
        ORIONCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Активность", systemImage: "figure.walk")
                    .font(.caption).foregroundColor(OrionTheme.accent)
                    .textCase(.uppercase).tracking(1)
                if health.pedometerAvailable {
                    HStack {
                        statItem("\(health.todaySteps)", "шагов")
                        Divider().background(OrionTheme.border)
                        statItem(String(format: "%.1f", health.todayDistance / 1000), "км")
                    }
                } else {
                    Text("Шагомер недоступен на устройстве")
                        .font(.caption).foregroundColor(OrionTheme.textSecondary)
                }
            }
        }
    }

    // MARK: - Вес

    var weightCard: some View {
        ORIONCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Вес", systemImage: "scalemass")
                    .font(.caption).foregroundColor(OrionTheme.accent)
                    .textCase(.uppercase).tracking(1)

                if let w = health.latestWeight {
                    HStack {
                        Text(String(format: "%.1f кг", w.kg))
                            .font(.system(.title3, design: .monospaced))
                            .foregroundColor(OrionTheme.textPrimary)
                        if let t = health.weightTrend {
                            Text(String(format: "%+.1f", t))
                                .font(.caption)
                                .foregroundColor(t > 0 ? OrionTheme.warning : OrionTheme.success)
                        }
                        Spacer()
                    }
                }

                HStack {
                    TextField("кг", text: $weightDraft)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                    Button("Записать") {
                        if let kg = Double(weightDraft.replacingOccurrences(of: ",", with: ".")) {
                            health.addWeight(kg)
                            weightDraft = ""
                        }
                    }
                    .foregroundColor(OrionTheme.accent)
                }
            }
        }
    }

    // MARK: - Настроение / тест

    var moodCard: some View {
        ORIONCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Самочувствие", systemImage: "brain")
                    .font(.caption).foregroundColor(OrionTheme.accent)
                    .textCase(.uppercase).tracking(1)

                Stepper("Настроение: \(mood)/5", value: $mood, in: 1...5).foregroundColor(OrionTheme.textPrimary)
                Stepper("Стресс: \(stress)/5", value: $stress, in: 1...5).foregroundColor(OrionTheme.textPrimary)
                VStack(alignment: .leading) {
                    Text(String(format: "Сон: %.1f ч", sleep)).foregroundColor(OrionTheme.textPrimary)
                    Slider(value: $sleep, in: 0...12, step: 0.5).tint(OrionTheme.accent)
                }
                TextField("Заметка (необязательно)", text: $moodNote)
                    .textFieldStyle(.roundedBorder)

                Toggle(isOn: $screenerOn) {
                    Text("Скрининг PHQ-2 / GAD-2")
                        .font(.subheadline).foregroundColor(OrionTheme.textPrimary)
                }
                .tint(OrionTheme.accent)

                if screenerOn { screenerQuestions }

                Button {
                    health.addMood(MoodEntry(date: Date(), mood: mood, stress: stress,
                                             sleepHours: sleep, note: moodNote,
                                             phq2: screenerOn ? [phqInterest, phqMood] : nil,
                                             gad2: screenerOn ? [gadNervous, gadWorry] : nil))
                    moodNote = ""
                    screenerOn = false
                } label: {
                    Text("Сохранить запись")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(OrionTheme.accent.orionContrastingText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(OrionTheme.accent)
                        .cornerRadius(OrionTheme.Radius.button)
                }
            }
        }
    }

    /// Четыре пункта PHQ-2 / GAD-2. Показываются только по тумблеру:
    /// скринер спрашивает про две недели, каждый день его заполнять незачем.
    var screenerQuestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Как часто за последние две недели тебя это беспокоило?")
                .font(.caption2).foregroundColor(OrionTheme.textSecondary)
            screenerRow(MentalScreen.phq2Questions[0], value: $phqInterest)
            screenerRow(MentalScreen.phq2Questions[1], value: $phqMood)
            screenerRow(MentalScreen.gad2Questions[0], value: $gadNervous)
            screenerRow(MentalScreen.gad2Questions[1], value: $gadWorry)
            Text("Это скрининг, а не диагноз: он лишь показывает, есть ли повод "
                 + "пройти полную шкалу со специалистом.")
                .font(.caption2).foregroundColor(OrionTheme.textTertiary)
        }
    }

    func screenerRow(_ question: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question)
                .font(.caption).foregroundColor(OrionTheme.textPrimary.opacity(0.85))
            Picker(question, selection: value) {
                ForEach(0..<MentalScreen.answerLabels.count, id: \.self) { i in
                    Text("\(i)").tag(i)
                }
            }
            .pickerStyle(.segmented)
            Text(MentalScreen.answerLabels[value.wrappedValue])
                .font(.caption2).foregroundColor(OrionTheme.textSecondary)
        }
    }

    // MARK: - Свободная заметка

    var noteCard: some View {
        ORIONCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Заметка", systemImage: "text.alignleft")
                    .font(.caption).foregroundColor(OrionTheme.accent)
                    .textCase(.uppercase).tracking(1)

                TextField("Заголовок (необязательно)", text: $noteTitle)
                    .textFieldStyle(.roundedBorder)
                TextField("Что записать", text: $noteText, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.roundedBorder)

                Button {
                    let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    health.addNote(title: noteTitle.trimmingCharacters(in: .whitespaces),
                                   text: text)
                    noteTitle = ""; noteText = ""
                } label: {
                    Text("Сохранить заметку")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(OrionTheme.accent.orionContrastingText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(OrionTheme.accent)
                        .cornerRadius(OrionTheme.Radius.button)
                }

                if let last = health.activeNotes.last {
                    Text("Последняя: \(last.text)")
                        .font(.caption2).foregroundColor(OrionTheme.textSecondary).lineLimit(2)
                }
            }
        }
    }

    // MARK: - БАДы

    var supplementsCard: some View {
        ORIONCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("БАДы и приём", systemImage: "pills")
                    .font(.caption).foregroundColor(OrionTheme.accent)
                    .textCase(.uppercase).tracking(1)

                ForEach(health.activeSupplements) { s in
                    HStack {
                        Image(systemName: "pill.fill").foregroundColor(OrionTheme.accent).font(.caption)
                        Text([s.name, s.dose, s.schedule].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundColor(OrionTheme.textPrimary.opacity(0.85))
                        Spacer()
                        Button {
                            health.deleteSupplement(s)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(OrionTheme.textSecondary)
                        }
                    }
                }

                HStack {
                    TextField("Название", text: $suppName).textFieldStyle(.roundedBorder)
                    TextField("Доза", text: $suppDose).textFieldStyle(.roundedBorder).frame(width: 90)
                    Button {
                        guard !suppName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        health.addSupplement(Supplement(name: suppName, dose: suppDose))
                        suppName = ""; suppDose = ""
                    } label: {
                        Image(systemName: "plus.circle.fill").foregroundColor(OrionTheme.accent)
                    }
                }
            }
        }
    }

    // MARK: - Мед-анализ ИИ

    var analysisCard: some View {
        ORIONCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Анализ ИИ", systemImage: "waveform.path.ecg")
                        .font(.caption).foregroundColor(OrionTheme.accent)
                        .textCase(.uppercase).tracking(1)
                    Spacer()
                    if analyzing {
                        Text("Анализирую…").font(.caption2).foregroundColor(OrionTheme.accent)
                    }
                }

                if let a = assessment {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(a.score)")
                            .font(.system(size: 30, weight: .bold, design: .monospaced))
                            .foregroundColor(scoreColor(a.score))
                        Text("/ 100").font(.caption).foregroundColor(OrionTheme.textSecondary)
                        Spacer()
                        Text(a.source == "aegis" ? "AEGIS" : "нейро")
                            .font(.caption2).foregroundColor(OrionTheme.textSecondary)
                    }
                    Text(a.summary).font(.caption).foregroundColor(OrionTheme.textPrimary.opacity(0.85))
                    ForEach(a.recommendations, id: \.self) { r in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundColor(OrionTheme.accent)
                            Text(r).font(.caption).foregroundColor(OrionTheme.textPrimary.opacity(0.8))
                        }
                    }

                    // Скринеры и тренды считает AEGIS, а не нейросеть — это
                    // арифметика по журналу, и показывать её нужно отдельно
                    // от текста модели.
                    if !a.screens.isEmpty || !a.trends.isEmpty {
                        Divider().background(OrionTheme.border)
                    }
                    ForEach(a.screens.keys.sorted(), id: \.self) { key in
                        if let s = a.screens[key] {
                            HStack {
                                Text(key.uppercased())
                                    .font(.caption2.monospaced()).foregroundColor(OrionTheme.textSecondary)
                                Text("\(s.score)/\(s.maxScore)")
                                    .font(.caption).foregroundColor(OrionTheme.textPrimary)
                                Spacer()
                                Text(s.positive ? "положительный" : "отрицательный")
                                    .font(.caption2)
                                    .foregroundColor(s.positive ? OrionTheme.warning : OrionTheme.success)
                            }
                        }
                    }
                    ForEach(a.trends.keys.sorted(), id: \.self) { key in
                        if let t = a.trends[key] {
                            HStack {
                                Text(t.label)
                                    .font(.caption).foregroundColor(OrionTheme.textPrimary.opacity(0.85))
                                Spacer()
                                Text(t.direction).font(.caption2)
                                    .foregroundColor(t.worsening ? OrionTheme.warning : OrionTheme.textSecondary)
                            }
                        }
                    }
                }

                Button {
                    runAnalysis()
                } label: {
                    Text("Проанализировать состояние")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(OrionTheme.accent.orionContrastingText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(OrionTheme.accent)
                        .cornerRadius(OrionTheme.Radius.button)
                }
                .disabled(analyzing)

                Text("Не является медицинской консультацией.")
                    .font(.caption2).foregroundColor(OrionTheme.textSecondary)
            }
        }
    }

    // MARK: - Logic / helpers

    func runAnalysis() {
        analyzing = true
        let ctx = health.makeHealthContext()
        Task {
            let result = await llm.analyzeHealth(ctx, model: settings.openRouterModel)
            await MainActor.run {
                assessment = result
                analyzing = false
            }
        }
    }

    func scoreColor(_ s: Int) -> Color {
        switch s {
        case ..<40: return OrionTheme.danger
        case 40..<70: return OrionTheme.warning
        default: return OrionTheme.success
        }
    }

    func statItem(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.title3, design: .monospaced)).foregroundColor(OrionTheme.accent)
            Text(label).font(.caption2).foregroundColor(OrionTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}
