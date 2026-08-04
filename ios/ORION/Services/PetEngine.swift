import SwiftUI
import Combine
import UIKit

// ╔══════════════════════════════════════════════════════════════╗
// ║  ДВИЖОК ПИТОМЦА — куда он идёт и что делает                   ║
// ╚══════════════════════════════════════════════════════════════╝
//
// Устройство намеренно двухслойное:
//
//  • РЕДКИЕ РЕШЕНИЯ — advance(now:bounds:anchor:). Раз в полсекунды
//    движок решает: пора выбрать новую цель, лечь, отдохнуть. Это
//    единственное место, где меняется состояние, и вызывается оно из
//    .onReceive таймера — то есть вне построения body.
//
//  • ЧАСТАЯ ОТРИСОВКА — frame(at:bounds:anchor:). Чистая функция от
//    времени: по текущему отрезку пути считает точку и позу. Ничего не
//    меняет, поэтому её можно звать хоть 60 раз в секунду прямо в body
//    из TimelineView, и SwiftUI не ругается «Modifying state during
//    view update».
//
// Координаты внутри движка нормализованы (0…1 от размера контейнера),
// поэтому поворот экрана и разные размеры ничего не ломают.

/// Где именно живёт питомец на конкретном экране.
enum PetHabitat {
    /// Свободно гуляет по экрану, на котором сейчас пользователь.
    case roam
    /// Дремлет калачиком возле точки-якоря (кнопки SOS), изредка встаёт.
    case sosGuard
    /// Играет с точкой на карте: подкрадывается, бьёт лапой, отбегает.
    case mapPlay
    /// Уголок: сидит на месте, дышит, изредка умывается.
    case nest
}

struct PetFrame {
    var position: CGPoint
    var pose: PetPose
}

final class PetMotion: ObservableObject {

    // Ничего не публикуем: перерисовку обеспечивает TimelineView, а лишние
    // инвалидации SwiftUI на 60 Гц дорого стоили бы батарее.

    let habitat: PetHabitat

    private enum Phase { case moving, resting }

    private var phase: Phase = .resting
    private var from: CGPoint
    private var to: CGPoint
    private var segmentStart: Date
    private var duration: Double = 1
    private var movingActivity: PetActivity = .walk
    private var restActivity: PetActivity = .idle
    private var restUntil: Date
    private var facingRight = true
    private var phaseOffset: Double = 0
    private var playBeat = 0

    // Скорости в долях ширины экрана в секунду — так питомец одинаково
    // резв и на маленьком, и на большом устройстве.
    private let walkSpeed = 0.16
    private let runSpeed  = 0.42

    init(habitat: PetHabitat) {
        self.habitat = habitat
        let start = PetMotion.defaultSpot(for: habitat)
        self.from = start
        self.to = start
        self.segmentStart = Date()
        self.restUntil = Date()
    }

    private static func defaultSpot(for habitat: PetHabitat) -> CGPoint {
        switch habitat {
        case .roam:     return CGPoint(x: 0.22, y: 0.82)
        case .sosGuard: return CGPoint(x: 0.68, y: 0.58)
        case .mapPlay:  return CGPoint(x: 0.30, y: 0.70)
        case .nest:     return CGPoint(x: 0.5,  y: 0.62)
        }
    }

    // MARK: - Отрисовка (чистая функция)

    func frame(at date: Date, bounds: CGSize, anchor: CGPoint?) -> PetFrame {
        let elapsed = max(0, date.timeIntervalSince(segmentStart))
        let companion = PetCompanion.shared

        var unit: CGPoint
        var activity: PetActivity

        switch phase {
        case .moving:
            let t = duration > 0 ? min(1, elapsed / duration) : 1
            let eased = t * t * (3 - 2 * t)      // плавный старт и остановка
            unit = CGPoint(x: from.x + (to.x - from.x) * eased,
                           y: from.y + (to.y - from.y) * eased)
            activity = t >= 1 ? .idle : movingActivity
        case .resting:
            unit = to
            activity = restActivity
        }

        // Тревога важнее любой запланированной позы: питомец не спит,
        // когда на экране тревога.
        if companion.mood == .alert && activity == .sleep {
            activity = .alert
        }

        let rate: Double
        switch activity {
        case .run:   rate = 11
        case .walk:  rate = 6.5
        case .play:  rate = 8
        case .sleep: rate = 1.1
        default:     rate = 1.8
        }

        let pose = PetPose(
            phase: phaseOffset + elapsed * rate,
            facingRight: facingRight,
            activity: activity,
            blink: activity == .sleep ? 1 : PetRenderer.blink(at: date.timeIntervalSinceReferenceDate),
            happiness: companion.affection
        )

        return PetFrame(
            position: CGPoint(x: unit.x * bounds.width, y: unit.y * bounds.height),
            pose: pose
        )
    }

    // MARK: - Решения (вызывать по таймеру, вне body)

    func advance(now: Date, bounds: CGSize, anchor: CGPoint?) {
        guard bounds.width > 1, bounds.height > 1 else { return }

        // Анимации выключены — питомец просто сидит там, где стоял.
        guard OrionAppearance.shared.animationsEnabled,
              !UIAccessibility.isReduceMotionEnabled else {
            phase = .resting
            restActivity = PetCompanion.shared.baseActivity
            restUntil = now.addingTimeInterval(60)
            return
        }

        switch phase {
        case .moving:
            if now.timeIntervalSince(segmentStart) >= duration {
                beginRest(now: now)
            }
        case .resting:
            if now >= restUntil {
                planNextMove(now: now, bounds: bounds, anchor: anchor)
            }
        }
    }

    /// Ткнули пальцем: питомец бежит к точке и радуется.
    func poke(at point: CGPoint, bounds: CGSize) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let target = clampUnit(CGPoint(x: point.x / bounds.width, y: point.y / bounds.height))
        start(to: target, activity: .run, bounds: bounds, now: Date())
        restActivity = .play
    }

    // MARK: - Планирование

    private func beginRest(now: Date) {
        from = to
        phase = .resting
        segmentStart = now
        phaseOffset = 0

        let companion = PetCompanion.shared
        switch habitat {
        case .sosGuard:
            // Возле кнопки SOS питомец именно дремлет калачиком —
            // ради этой картинки всё и затевалось.
            restActivity = companion.mood == .alert ? .alert : .sleep
            restUntil = now.addingTimeInterval(Double.random(in: 10...22))
        case .mapPlay:
            restActivity = playBeat % 2 == 0 ? .play : .sit
            restUntil = now.addingTimeInterval(Double.random(in: 0.6...2.0))
        case .nest:
            restActivity = companion.mood == .sleepy ? .sleep : .sit
            restUntil = now.addingTimeInterval(Double.random(in: 6...14))
        case .roam:
            if companion.mood == .sleepy {
                restActivity = .sleep
                restUntil = now.addingTimeInterval(Double.random(in: 10...25))
            } else if companion.mood == .alert || companion.mood == .worried {
                restActivity = companion.mood == .alert ? .alert : .sit
                restUntil = now.addingTimeInterval(Double.random(in: 3...7))
            } else {
                restActivity = Bool.random() ? .idle : .sit
                restUntil = now.addingTimeInterval(Double.random(in: 2...6))
            }
        }
    }

    private func planNextMove(now: Date, bounds: CGSize, anchor: CGPoint?) {
        let companion = PetCompanion.shared

        switch habitat {
        case .roam:
            // Держимся нижней трети и краёв: середина экрана занята текстом.
            let target = CGPoint(x: Double.random(in: 0.10...0.90),
                                 y: Double.random(in: 0.62...0.90))
            let running = companion.mood == .playful || Double.random(in: 0...1) < 0.2
            start(to: target, activity: running ? .run : .walk, bounds: bounds, now: now)

        case .sosGuard:
            guard let anchor = anchor else {
                restUntil = now.addingTimeInterval(3)
                return
            }
            // Устраивается сбоку от кнопки, чуть ниже — не перекрывая её.
            let side: Double = Bool.random() ? 1 : -1
            let target = CGPoint(x: anchor.x + side * Double.random(in: 0.14...0.22),
                                 y: anchor.y + Double.random(in: 0.06...0.13))
            start(to: target, activity: .walk, bounds: bounds, now: now)

        case .mapPlay:
            guard let anchor = anchor else {
                restUntil = now.addingTimeInterval(2)
                return
            }
            playBeat += 1
            // Цикл: подкрался — прыгнул на точку — отбежал.
            switch playBeat % 3 {
            case 0:
                let angle = Double.random(in: 0..<(2 * .pi))
                let target = CGPoint(x: anchor.x + cos(angle) * 0.16,
                                     y: anchor.y + sin(angle) * 0.12)
                start(to: target, activity: .walk, bounds: bounds, now: now)
            case 1:
                let target = CGPoint(x: anchor.x + Double.random(in: -0.05...0.05),
                                     y: anchor.y + Double.random(in: 0.02...0.07))
                start(to: target, activity: .run, bounds: bounds, now: now)
                companion.play()
            default:
                let angle = Double.random(in: 0..<(2 * .pi))
                let target = CGPoint(x: anchor.x + cos(angle) * 0.24,
                                     y: anchor.y + sin(angle) * 0.18)
                start(to: target, activity: .run, bounds: bounds, now: now)
            }

        case .nest:
            // В уголке питомец только переминается — уходить некуда.
            let target = CGPoint(x: 0.5 + Double.random(in: -0.06...0.06),
                                 y: 0.62 + Double.random(in: -0.03...0.03))
            start(to: target, activity: .walk, bounds: bounds, now: now)
        }
    }

    private func start(to target: CGPoint, activity: PetActivity, bounds: CGSize, now: Date) {
        let clamped = clampUnit(target)
        from = currentUnit(now: now)
        to = clamped
        facingRight = clamped.x >= from.x
        movingActivity = activity
        phase = .moving
        segmentStart = now
        phaseOffset = Double.random(in: 0...(2 * .pi))

        let dx = (clamped.x - from.x) * Double(bounds.width)
        let dy = (clamped.y - from.y) * Double(bounds.height)
        let distance = sqrt(dx * dx + dy * dy) / Double(max(bounds.width, 1))
        let speed = activity == .run ? runSpeed : walkSpeed
        duration = max(0.35, distance / speed)
    }

    /// Где питомец находится прямо сейчас (нужно, чтобы новый отрезок
    /// начинался из текущей точки, а не из старой цели).
    private func currentUnit(now: Date) -> CGPoint {
        guard phase == .moving, duration > 0 else { return to }
        let t = min(1, max(0, now.timeIntervalSince(segmentStart) / duration))
        let eased = t * t * (3 - 2 * t)
        return CGPoint(x: from.x + (to.x - from.x) * eased,
                       y: from.y + (to.y - from.y) * eased)
    }

    private func clampUnit(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(0.94, max(0.06, p.x)),
                y: min(0.94, max(0.10, p.y)))
    }
}
