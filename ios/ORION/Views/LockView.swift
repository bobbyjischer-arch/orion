import SwiftUI

/// Экран блокировки.
/// Выглядит как вход в защищённое хранилище файлов.
/// Правильный код → O.R.I.O.N.
/// Неверный код → DecoyVaultView (фальшивые файлы).
///
/// На первом запуске кода ещё нет (`AppLock.needsSetup`) — тот же экран
/// просит придумать его и повторить. Предустановленного кода нет намеренно:
/// исходники открыты, см. `AppLock.init`.
///
/// Цвета здесь намеренно жёстко заданы и не берутся из OrionTheme: маскировка
/// работает только пока «Secure Vault» не похож на ORION. Общая палитра
/// связала бы два экрана — по чужой теме сразу видно, что это одно приложение.
struct LockView: View {

    @ObservedObject var lock = AppLock.shared
    @State private var code       = ""
    @State private var showDecoy  = false
    @State private var showBiometricPrompt = false
    /// Первый ввод при создании кода — ждём повтора, чтобы владелец не
    /// заперся опечаткой: сбросить код без переустановки нельзя.
    @State private var setupFirst = ""
    @State private var setupHint  = ""

    // Максимум 4 цифры
    private let codeLength = 4
    private let biometric = BiometricService.shared

    var body: some View {
        ZStack {
            // Фон — нейтральный серый, совсем не похожий на ORION
            LinearGradient(
                colors: [Color(hex: "1C1C1E"), Color(hex: "2C2C2E")],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Иконка и заголовок
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: "4FC3F7"), Color(hex: "0288D1")],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .shadow(color: Color(hex: "4FC3F7").opacity(0.3), radius: 12)

                    Text("Secure Vault")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)

                    Text(prompt)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                }

                Spacer().frame(height: 48)

                // Точки кода
                HStack(spacing: 18) {
                    ForEach(0..<codeLength, id: \.self) { i in
                        Circle()
                            .fill(i < code.count
                                  ? Color(hex: "4FC3F7")
                                  : Color.white.opacity(0.15))
                            .frame(width: 16, height: 16)
                            .scaleEffect(i < code.count ? 1.1 : 1.0)
                            .animation(.spring(response: 0.2), value: code.count)
                    }
                }

                Spacer().frame(height: 48)

                // Цифровая клавиатура
                numpad

                Spacer().frame(height: 32)

                // Биометрия кнопка
                if !lock.needsSetup, biometric.isBiometricAvailable && lock.biometricEnabled {
                    Button(action: {
                        Task {
                            await lock.authenticateWithBiometric()
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: biometric.biometricType == .faceID ? "faceid" : "touchid")
                                .font(.title3)
                            Text(biometric.biometricType == .faceID ? "Face ID" : "Touch ID")
                                .font(.subheadline)
                        }
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.vertical, 12)
                        .padding(.horizontal, 24)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(12)
                    }
                    .padding(.bottom, 16)
                }

                // Подпись
                Text("Secure Vault Pro · v3.1")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.2))

                Spacer()
            }
            .padding(.horizontal, 40)
        }
        .fullScreenCover(isPresented: $showDecoy) {
            DecoyVaultView(onCorrectCode: {
                showDecoy = false
                lock.isUnlocked = true
            })
        }
        .onAppear {
            // Auto-trigger biometric on appear if enabled
            if biometric.isBiometricAvailable && lock.biometricEnabled {
                Task {
                    await lock.authenticateWithBiometric()
                }
            }
        }
        // Правильный код — переход к ORION происходит в ORIONApp через lock.isUnlocked
    }

    // MARK: - Numpad

    /// Подпись под заголовком: на первом запуске ведёт через создание кода,
    /// дальше — обычное «введите код».
    var prompt: String {
        if !setupHint.isEmpty { return setupHint }
        guard lock.needsSetup else { return "Введите код доступа" }
        return setupFirst.isEmpty ? "Придумайте код доступа" : "Повторите код"
    }

    var numpad: some View {
        let rows: [[String]] = [
            ["1","2","3"],
            ["4","5","6"],
            ["7","8","9"],
            ["","0","⌫"],
        ]
        return VStack(spacing: 14) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(row, id: \.self) { key in
                        NumpadKey(label: key) {
                            handleKey(key)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Logic

    func handleKey(_ key: String) {
        switch key {
        case "⌫":
            if !code.isEmpty { code.removeLast() }
        case "":
            break
        default:
            guard code.count < codeLength else { return }
            code.append(key)

            if code.count == codeLength {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    submit()
                }
            }
        }
    }

    func submit() {
        // Первый запуск: создаём код. Ложное хранилище здесь не при чём —
        // проверять ещё нечего, а несовпадение повтора нужно показать прямо.
        if lock.needsSetup {
            let entered = code
            code = ""
            if setupFirst.isEmpty {
                setupFirst = entered
                setupHint = ""
            } else if setupFirst == entered {
                setupFirst = ""
                setupHint = ""
                lock.setupPasscode(entered)
            } else {
                setupFirst = ""
                setupHint = "Коды не совпали — придумайте заново"
            }
            return
        }

        if lock.attempt(code) {
            // Correct passcode - isUnlocked = true → ORIONApp покажет ContentView
            code = ""
        } else {
            // Неверный код: НЕ трясём точки (это выдало бы наличие "другого" входа).
            // Просто плавно открываем ложное хранилище — выглядит как обычная разблокировка.
            code = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                showDecoy = true
            }
        }
    }
}

// MARK: - Numpad Key

struct NumpadKey: View {
    let label: String
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        Button(action: {
            guard !label.isEmpty else { return }
            action()
        }) {
            ZStack {
                Circle()
                    .fill(label.isEmpty
                          ? Color.clear
                          : Color.white.opacity(pressed ? 0.25 : 0.1))
                    .frame(width: 72, height: 72)

                if label == "⌫" {
                    Image(systemName: "delete.left")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.8))
                } else {
                    Text(label)
                        .font(.system(size: 26, weight: .regular, design: .rounded))
                        .foregroundColor(label.isEmpty ? .clear : .white)
                }
            }
        }
        .buttonStyle(PressedButtonStyle())
        .disabled(label.isEmpty)
    }
}

struct PressedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Hex Color Extension

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >>  8) & 0xFF) / 255
        let b = Double( rgb        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
