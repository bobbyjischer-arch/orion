import Foundation
import AVFoundation

/// Простая озвучка системных реплик O.R.I.O.N. (например, «Анализирую»
/// при старте). Использует системный синтезатор речи.
final class SpeechService {

    static let shared = SpeechService()

    private let synthesizer = AVSpeechSynthesizer()

    private init() {}

    /// Произнести фразу (по умолчанию по-русски). Молча игнорирует сбои.
    func speak(_ text: String, language: String = "ru-RU") {
        guard AppSettings.shared.voiceEnabled else { return }

        // Не перебиваем сами себя
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        // Не глушим чужое аудио (.duckOthers временно приглушает музыку)
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
