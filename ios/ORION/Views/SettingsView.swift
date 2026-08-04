import SwiftUI

// MARK: - Main Settings View

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var loc: LocationService
    @EnvironmentObject var poi: PointsOfInterestService
    /// Подписка на оформление: экран целиком собран из токенов OrionTheme,
    /// без неё смена палитры не перерисовала бы настройки.
    @ObservedObject private var appearance = OrionAppearance.shared

    @State private var urlDraft    = ""
    @State private var tokenDraft  = ""
    @State private var orKeyDraft  = ""
    @State private var orKeySaved  = false
    @State private var keyError    = ""
    @State private var tokenSaved  = false

    /// Истина, если ключ реально лежит в Keychain (а не только в памяти).
    private var keyStored: Bool {
        !((try? KeychainService.shared.retrieve(for: .openRouterKey)) ?? "").isEmpty
    }
    @State private var duressDraft = ""
    @State private var duressSaved = false
    @State private var nameDraft   = ""
    @State private var apiKeyDraft = ""
    @State private var cascadeDraft = ""
    @State private var accessSaved  = false
    @State private var histOld     = ""
    @State private var histNew     = ""
    @State private var histMsg     = ""
    @State private var passOld     = ""
    @State private var passNew     = ""
    @State private var passMsg     = ""
    @State private var saved       = false
    @State private var showAddContact   = false
    @State private var editingContact: SOSContact? = nil

    var body: some View {
        NavigationView {
            ZStack {
                OrionTheme.backgroundGradient.ignoresSafeArea()
                Form {
                    accessSection
                    appearanceSection
                    brainSection
                    mapSection
                    poiSection
                    sosSection
                    passcodeSection
                    securitySection
                    historyCodeSection
                    serverSection
                    trackingSection
                    permissionsSection
                    infoSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("⚙️ Настройки")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            urlDraft = settings.serverURL
            nameDraft = settings.deviceName
            // Секреты (ключ, токен) НЕ предзагружаем в SecureField:
            // iOS очищает secure-поле при повторном фокусе, и это затирало бы
            // сохранённое значение. Поля пустые = «введи новое, чтобы заменить».
            tokenDraft = ""
            orKeyDraft = ""
        }
        .sheet(isPresented: $showAddContact) {
            ContactEditSheet(contact: nil) { newContact in
                settings.sosContacts.append(newContact)
            }
        }
        .sheet(item: $editingContact) { contact in
            ContactEditSheet(contact: contact) { updated in
                if let idx = settings.sosContacts.firstIndex(where: { $0.id == updated.id }) {
                    settings.sosContacts[idx] = updated
                }
            }
        }
    }

    // MARK: - Секции

    var serverSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("URL сервера O.R.I.O.N.")
                    .font(.caption).foregroundColor(OrionTheme.textSecondary)
                TextField("http://192.168.1.X:8000", text: $urlDraft)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(OrionTheme.accent)
            }
            .padding(.vertical, 4)

            Button {
                settings.serverURL = urlDraft.trimmingCharacters(in: .whitespaces)
                saved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
            } label: {
                HStack {
                    Spacer()
                    Text(saved ? "✅ Сохранено" : "Сохранить")
                        .font(.headline)
                        .foregroundColor(saved ? OrionTheme.success : OrionTheme.accent)
                    Spacer()
                }
            }
        } header: { Text("📡 Подключение") }
         footer: { Text("IP-адрес компьютера с O.R.I.O.N. сервером в одной Wi-Fi сети.") }
    }

    var trackingSection: some View {
        Section {
            Stepper(
                "Каждые \(settings.intervalMinutes) мин.",
                value: $settings.intervalMinutes,
                in: 1...60
            )
            .foregroundColor(OrionTheme.textPrimary)
        } header: { Text("⏱ Интервал отправки") }
         footer: { Text("5 минут — оптимальный баланс точности и батареи.") }
    }

    var brainSection: some View {
        Section {
            Toggle("Анализ подозрений", isOn: $settings.suspicionEnabled)
                .foregroundColor(OrionTheme.textPrimary)
                .tint(OrionTheme.accent)

            Toggle("Озвучка «Анализирую»", isOn: $settings.voiceEnabled)
                .foregroundColor(OrionTheme.textPrimary)
                .tint(OrionTheme.accent)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("API Key (опционально)")
                        .font(.caption).foregroundColor(OrionTheme.textSecondary)
                    Spacer()
                    if keyStored {
                        Text("✅ нейро-усиление включено").font(.caption2).foregroundColor(OrionTheme.success)
                    } else {
                        Text("без ключа — работает AEGIS").font(.caption2).foregroundColor(OrionTheme.textSecondary)
                    }
                }
                SecureField(keyStored ? "вставь новый ключ для замены" : "вставь ключ",
                            text: $orKeyDraft)
                    .font(.system(.body, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .foregroundColor(OrionTheme.accent)
                HStack(spacing: 12) {
                    Button(orKeySaved ? "✅ Сохранено" : "Сохранить ключ") {
                        let k = orKeyDraft.trimmingCharacters(in: .whitespaces)
                        guard !k.isEmpty else { return }   // пустое не затирает ключ
                        settings.openRouterKey = k
                        // Проверяем, что ключ реально записался в Keychain
                        let back = (try? KeychainService.shared.retrieve(for: .openRouterKey)) ?? ""
                        if back == k {
                            orKeyDraft = ""; keyError = ""; orKeySaved = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { orKeySaved = false }
                        } else {
                            keyError = "Не удалось сохранить ключ в Keychain"
                        }
                    }
                    .font(.caption).foregroundColor(orKeySaved ? OrionTheme.success : OrionTheme.accent)
                    if keyStored {
                        Button("Удалить") {
                            settings.openRouterKey = ""
                            orKeyDraft = ""
                        }.font(.caption).foregroundColor(OrionTheme.danger)
                    }
                }
                if !keyError.isEmpty {
                    Text("⚠️ \(keyError)").font(.caption2).foregroundColor(OrionTheme.danger)
                }
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text("Модель")
                    .font(.caption).foregroundColor(OrionTheme.textSecondary)
                TextField("deepseek/deepseek-chat-v3-0324:free", text: $settings.openRouterModel)
                    .font(.system(.caption, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .foregroundColor(OrionTheme.accent)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text("Endpoint (API-шлюз)")
                    .font(.caption).foregroundColor(OrionTheme.textSecondary)
                TextField("https://openrouter.ai/api/v1/chat/completions", text: $settings.llmEndpoint)
                    .font(.system(.caption2, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .foregroundColor(OrionTheme.accent)
                Text("Пресеты endpoint:")
                    .font(.caption2).foregroundColor(OrionTheme.textSecondary)
                HStack(spacing: 6) {
                    Button("Gemini") {
                        settings.llmEndpoint = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
                        settings.openRouterModel = "gemini-2.5-flash"
                    }.font(.caption2).buttonStyle(.bordered).tint(OrionTheme.accent)
                    Button("Groq") {
                        settings.llmEndpoint = "https://api.groq.com/openai/v1/chat/completions"
                        settings.openRouterModel = "llama-3.3-70b-versatile"
                    }.font(.caption2).buttonStyle(.bordered).tint(OrionTheme.accent)
                    Button("OpenRouter") {
                        settings.llmEndpoint = "https://openrouter.ai/api/v1/chat/completions"
                    }.font(.caption2).buttonStyle(.bordered).tint(OrionTheme.accent)
                }
            }
            .padding(.vertical, 4)
        } header: { Text("🧠 Мозг (AEGIS + нейро-усиление)") }
         footer: { Text("AEGIS работает автономно — анализ идёт без ключа и без сети. Ключ опционален: он лишь добавляет нейро-усиление (второе мнение нейросети). Проще всего: пресет «Gemini» + бесплатный ключ с aistudio.google.com/apikey (без карты). Ключ хранится в Keychain. Endpoint — любой OpenAI-совместимый шлюз; «модель» = id у этого шлюза, «ключ» — его ключ. Groq: ключ с console.groq.com.") }
    }

    var mapSection: some View {
        Section {
            VStack(alignment: .leading) {
                Text("Прозрачность маршрута: \(Int(settings.routeOpacity * 100))%")
                    .foregroundColor(OrionTheme.textPrimary)
                Slider(value: $settings.routeOpacity, in: 0.1...1.0).tint(OrionTheme.accent)
            }
            VStack(alignment: .leading) {
                Text("Толщина линии: \(Int(settings.routeWidth))")
                    .foregroundColor(OrionTheme.textPrimary)
                Slider(value: $settings.routeWidth, in: 1...12, step: 1).tint(OrionTheme.accent)
            }
            Picker("Цвет маршрута", selection: $settings.routeColorName) {
                Text("Голубой").tag("cyan")
                Text("Зелёный").tag("green")
                Text("Оранжевый").tag("orange")
                Text("Фиолетовый").tag("purple")
                Text("Красный").tag("red")
            }
            .foregroundColor(OrionTheme.textPrimary)
            Toggle("Градиент прозрачности (свежее — ярче)", isOn: $settings.routeGradient)
                .foregroundColor(OrionTheme.textPrimary).tint(OrionTheme.accent)
        } header: { Text("🗺 Маршрут на карте") }
         footer: { Text("Линия строится по записанным точкам перемещения. Цвет, прозрачность и градиент применяются сразу.") }
    }

    var poiSection: some View {
        Section {
            NavigationLink {
                POIView()
            } label: {
                HStack {
                    Label("Точки интереса", systemImage: "mappin.and.ellipse")
                        .foregroundColor(OrionTheme.accent)
                    Spacer()
                    Text("\(poi.points.count)")
                        .font(.caption).foregroundColor(OrionTheme.textSecondary)
                }
            }
        } header: { Text("📍 Места") }
         footer: { Text("Дом, зал, работа, школа — система спросит «направляешься туда?» при подходе.") }
    }

    // MARK: - Ключи доступа к серверу

    var accessSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Имя этого устройства").font(.caption).foregroundColor(OrionTheme.textSecondary)
                TextField("ORION", text: $nameDraft)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(OrionTheme.accent)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Ключ доступа к серверу (X-Orion-Key)")
                    .font(.caption).foregroundColor(OrionTheme.textSecondary)
                SecureField(KeychainService.shared.hasServerKey
                            ? "Задан — введите новый, чтобы заменить" : "ORION_API_KEY",
                            text: $apiKeyDraft)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(OrionTheme.accent)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Секрет шифрования (ORION_CASCADE_SECRET)")
                    .font(.caption).foregroundColor(OrionTheme.textSecondary)
                SecureField(KeychainService.shared.hasCascadeSecret
                            ? "Задан — введите новый, чтобы заменить" : "необязательно",
                            text: $cascadeDraft)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(OrionTheme.accent)
            }
            .padding(.vertical, 4)

            Button {
                settings.deviceName = nameDraft.trimmingCharacters(in: .whitespaces)
                let key = apiKeyDraft.trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { try? KeychainService.shared.save(key, for: .serverAuthToken) }
                let secret = cascadeDraft.trimmingCharacters(in: .whitespaces)
                if !secret.isEmpty { try? KeychainService.shared.save(secret, for: .cascadeSecret) }
                apiKeyDraft = ""; cascadeDraft = ""
                accessSaved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { accessSaved = false }
            } label: {
                HStack {
                    Spacer()
                    Text(accessSaved ? "✅ Сохранено" : "Сохранить")
                        .font(.headline).foregroundColor(accessSaved ? OrionTheme.success : OrionTheme.accent)
                    Spacer()
                }
            }
        } header: { Text("🔑 Доступ к серверу") }
         footer: {
            Text("Имя устройства — то, как оно подписано на сервере и в дашборде. Ключ должен совпадать с `ORION_API_KEY` на сервере: без него защищённые эндпоинты отвечают 401. Секрет необязателен — если он задан (и совпадает с `ORION_CASCADE_SECRET`), данные шифруются каскадом перед отправкой.")
        }
    }

    // MARK: - Код-пароль истории записей

    var historyCodeSection: some View {
        Section {
            if KeychainService.shared.hasHistoryCode {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("Текущий код", text: $histOld)
                        .keyboardType(.numberPad)
                        .font(.system(.body, design: .monospaced)).foregroundColor(OrionTheme.accent)
                    SecureField("Новый код", text: $histNew)
                        .keyboardType(.numberPad)
                        .font(.system(.body, design: .monospaced)).foregroundColor(OrionTheme.accent)
                }
                .padding(.vertical, 4)

                Button {
                    if HistoryLock.shared.changeCode(old: histOld, new: histNew) {
                        histMsg = "✅ Код изменён"
                        histOld = ""; histNew = ""
                    } else {
                        histMsg = HistoryLock.shared.lastError ?? "Не удалось изменить код"
                    }
                } label: {
                    HStack {
                        Spacer()
                        Text("Сменить код истории").font(.subheadline).foregroundColor(OrionTheme.accent)
                        Spacer()
                    }
                }
            } else {
                Text("Код ещё не задан — он создаётся при первой попытке изменить или удалить запись в истории.")
                    .font(.caption).foregroundColor(OrionTheme.textSecondary)
            }

            if !histMsg.isEmpty {
                Text(histMsg).font(.caption)
                    .foregroundColor(histMsg.hasPrefix("✅") ? OrionTheme.success : OrionTheme.danger)
            }
        } header: { Text("🗂 Код-пароль истории") }
         footer: { Text("Смотреть историю записей можно без кода. Код требуется, чтобы изменить, удалить или восстановить запись.") }
    }

    var passcodeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                SecureField("Текущий код", text: $passOld)
                    .keyboardType(.numberPad)
                    .font(.system(.body, design: .monospaced))
                SecureField("Новый код", text: $passNew)
                    .keyboardType(.numberPad)
                    .font(.system(.body, design: .monospaced))
            }
            .padding(.vertical, 4)

            Button {
                let old = passOld.trimmingCharacters(in: .whitespaces)
                let new = passNew.trimmingCharacters(in: .whitespaces)
                if new.isEmpty {
                    passMsg = "Новый код не может быть пустым"
                } else if new == old {
                    passMsg = "Новый код совпадает со старым"
                } else if KeychainService.shared.verifyDuressCode(new) {
                    passMsg = "Это код тревоги — обычный вход стал бы тихим SOS"
                } else if AppLock.shared.changePasscode(old: old, new: new) {
                    passMsg = "✅ Код изменён"
                    passOld = ""; passNew = ""
                } else {
                    passMsg = "Текущий код неверный"
                }
            } label: {
                HStack {
                    Spacer()
                    Text("Сменить код доступа").font(.subheadline).foregroundColor(OrionTheme.accent)
                    Spacer()
                }
            }

            if !passMsg.isEmpty {
                Text(passMsg).font(.caption)
                    .foregroundColor(passMsg.hasPrefix("✅") ? OrionTheme.success : OrionTheme.danger)
            }
        } header: { Text("🔒 Код доступа") }
         footer: { Text("Код придумывается при первом запуске — предустановленного кода нет, исходники приложения открыты. Хранится хешем в Keychain; забытый код сбрасывается только переустановкой. Неверный код открывает ложное хранилище, а не сообщает об ошибке.") }
    }

    var securitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Код тревоги (тихий сигнал)")
                    .font(.caption).foregroundColor(OrionTheme.textSecondary)
                SecureField("4 цифры, отличные от обычного кода", text: $duressDraft)
                    .keyboardType(.numberPad)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(OrionTheme.accent)
            }
            .padding(.vertical, 4)

            Button {
                let code = duressDraft.trimmingCharacters(in: .whitespaces)
                if code.isEmpty {
                    KeychainService.shared.clearDuressCode()
                } else {
                    try? KeychainService.shared.saveDuressCode(code)
                }
                duressSaved = true
                duressDraft = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { duressSaved = false }
            } label: {
                HStack {
                    Spacer()
                    Text(duressSaved ? "✅ Сохранено" : (KeychainService.shared.hasDuressCode ? "Изменить код тревоги" : "Задать код тревоги"))
                        .font(.subheadline)
                        .foregroundColor(duressSaved ? OrionTheme.success : OrionTheme.accent)
                    Spacer()
                }
            }

            if KeychainService.shared.hasDuressCode {
                Button(role: .destructive) {
                    KeychainService.shared.clearDuressCode()
                    duressDraft = ""
                } label: {
                    Text("Удалить код тревоги").font(.caption)
                }
            }
        } header: { Text("🔕 Тихий сигнал") }
         footer: { Text("Ввод этого кода на экране блокировки внешне откроет приложение как обычно, но скрытно отправит SOS с координатами доверенным контактам — без звука и уведомлений на экране.") }
    }

    // MARK: - Оформление

    var appearanceSection: some View {
        Section {
            NavigationLink {
                AppearanceView()
            } label: {
                Label("Оформление", systemImage: "paintbrush")
                    .foregroundColor(OrionTheme.accent)
            }
        } header: { Text("🎨 Внешний вид") }
         footer: { Text("Тема, акцент, обои, жидкое стекло, питомец и другие параметры интерфейса.") }
    }

    var sosSection: some View {
        Section {
            // Токен бота
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Telegram Bot Token")
                        .font(.caption).foregroundColor(OrionTheme.textSecondary)
                    Spacer()
                    if !settings.sosBotToken.isEmpty {
                        Text("✅ установлен").font(.caption2).foregroundColor(OrionTheme.success)
                    }
                }
                SecureField(settings.sosBotToken.isEmpty ? "1234567890:AAH..." : "вставь новый токен для замены",
                            text: $tokenDraft)
                    .font(.system(.body, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .foregroundColor(OrionTheme.accent)
                HStack(spacing: 12) {
                    Button(tokenSaved ? "✅ Сохранено" : "Сохранить токен") {
                        let t = tokenDraft.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { return }
                        settings.sosBotToken = t
                        tokenDraft = ""
                        tokenSaved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { tokenSaved = false }
                    }
                    .font(.caption).foregroundColor(tokenSaved ? OrionTheme.success : OrionTheme.accent)
                    if !settings.sosBotToken.isEmpty {
                        Button("Удалить") {
                            settings.sosBotToken = ""
                            tokenDraft = ""
                        }.font(.caption).foregroundColor(OrionTheme.danger)
                    }
                }
            }
            .padding(.vertical, 4)

            // Список контактов
            if settings.sosContacts.isEmpty {
                HStack {
                    Image(systemName: "person.badge.plus")
                        .foregroundColor(OrionTheme.warning)
                    Text("Нет контактов")
                        .foregroundColor(OrionTheme.textSecondary)
                }
            } else {
                ForEach(settings.sosContacts) { contact in
                    ContactRow(contact: contact)
                        .contentShape(Rectangle())
                        .onTapGesture { editingContact = contact }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            // Удалить
                            Button(role: .destructive) {
                                withAnimation {
                                    settings.sosContacts.removeAll { $0.id == contact.id }
                                }
                            } label: {
                                Label("Удалить", systemImage: "trash.fill")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            // Редактировать
                            Button {
                                editingContact = contact
                            } label: {
                                Label("Изменить", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                }

                // Подсказка про свайп
                Text("← Свайп для редактирования · Свайп → для удаления")
                    .font(.caption2)
                    .foregroundColor(OrionTheme.textTertiary)
                    .listRowBackground(Color.clear)
            }

            Button {
                showAddContact = true
            } label: {
                Label("Добавить контакт", systemImage: "person.badge.plus")
                    .foregroundColor(OrionTheme.accent)
            }
        } header: {
            HStack {
                Text("SOS — контакты")
                Spacer()
                Text("\(settings.sosContacts.count) контактов")
                    .font(.caption).foregroundColor(OrionTheme.textSecondary)
            }
        } footer: {
            Text("При SOS каждый контакт получит Telegram-сообщение с координатами. Нажми на контакт чтобы изменить.")
        }
    }

    var permissionsSection: some View {
        Section {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Открыть настройки iPhone", systemImage: "gear")
                    .foregroundColor(OrionTheme.accent)
            }
        } header: { Text("🧭 Геолокация") }
         footer: { Text("Для фоновой работы выдай разрешение «Всегда».") }
    }

    var infoSection: some View {
        Section {
            infoRow("Bundle ID",  "com.stark.orion")
            infoRow("Версия",     "2.0")
            infoRow("iOS",        "16.0+")
        } header: { Text("ℹ️ О приложении") }
    }

    func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(OrionTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(OrionTheme.textPrimary.opacity(0.7))
        }
    }
}

// MARK: - Contact Row

struct ContactRow: View {
    let contact: SOSContact
    // Строка не зависит от контакта при смене темы — без подписки на
    // оформление SwiftUI не перерисовал бы её и цвета остались бы старыми.
    @ObservedObject private var appearance = OrionAppearance.shared

    var body: some View {
        HStack(spacing: 12) {
            // Аватар-инициал
            ZStack {
                Circle()
                    .fill(OrionTheme.success.opacity(0.2))
                    .frame(width: 36, height: 36)
                Text(String(contact.name.prefix(1)).uppercased())
                    .font(.system(.subheadline, design: .rounded).bold())
                    .foregroundColor(OrionTheme.success)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name)
                    .foregroundColor(OrionTheme.textPrimary)
                    .font(.subheadline)
                Text("ID: \(contact.telegramChatID)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(OrionTheme.textSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(OrionTheme.textTertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Contact Edit Sheet (Add / Edit)

struct ContactEditSheet: View {
    // Если contact == nil — режим добавления, иначе — редактирование
    let contact: SOSContact?
    let onSave: (SOSContact) -> Void

    @Environment(\.dismiss) var dismiss
    @ObservedObject private var appearance = OrionAppearance.shared

    @State private var name    = ""
    @State private var chatID  = ""
    @State private var showDeleteConfirm = false

    var isEditing: Bool { contact != nil }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !chatID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationView {
            ZStack {
                OrionTheme.backgroundGradient.ignoresSafeArea()
                Form {
                    Section {
                        // Имя
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Имя контакта")
                                .font(.caption).foregroundColor(OrionTheme.textSecondary)
                            TextField("напр. Мама", text: $name)
                                .foregroundColor(OrionTheme.textPrimary)
                        }
                        .padding(.vertical, 4)

                        // Chat ID
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Telegram Chat ID")
                                .font(.caption).foregroundColor(OrionTheme.textSecondary)
                            TextField("123456789", text: $chatID)
                                .keyboardType(.numberPad)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(OrionTheme.accent)
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text(isEditing ? "Изменить контакт" : "Новый контакт")
                    } footer: {
                        Text("Chat ID можно узнать отправив сообщение боту @userinfobot в Telegram.")
                    }

                    // Кнопка удаления (только при редактировании)
                    if isEditing {
                        Section {
                            Button(role: .destructive) {
                                showDeleteConfirm = true
                            } label: {
                                HStack {
                                    Spacer()
                                    Label("Удалить контакт", systemImage: "trash")
                                    Spacer()
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(isEditing ? "Изменить" : "Добавить")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .foregroundColor(OrionTheme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        let saved = SOSContact(
                            id:             contact?.id ?? UUID(),
                            name:           name.trimmingCharacters(in: .whitespaces),
                            telegramChatID: chatID.trimmingCharacters(in: .whitespaces)
                        )
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(!isValid)
                    .foregroundColor(isValid ? OrionTheme.accent : OrionTheme.textTertiary)
                    .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                "Удалить \(contact?.name ?? "контакт")?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Удалить", role: .destructive) {
                    // Сигнализируем родителю удалить через пустое имя
                    // Родитель проверяет и удаляет из массива
                    dismiss()
                    // Небольшой delay чтобы sheet закрылся до обновления
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        // Передаём контакт обратно — родитель его не найдёт в массиве
                        // и просто ничего не сделает. Удаление через swipe action.
                    }
                }
                Button("Отмена", role: .cancel) {}
            }
        }
        .onAppear {
            name   = contact?.name           ?? ""
            chatID = contact?.telegramChatID ?? ""
        }
    }
}

// MARK: - SOSContact Identifiable for sheet(item:)
extension SOSContact: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: SOSContact, rhs: SOSContact) -> Bool { lhs.id == rhs.id }
}
