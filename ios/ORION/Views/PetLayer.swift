import SwiftUI

// ╔══════════════════════════════════════════════════════════════╗
// ║  СЛОЙ ПИТОМЦА — то, что кладут поверх экрана                  ║
// ╚══════════════════════════════════════════════════════════════╝
//
// Использование:
//   .overlay(PetLayer(habitat: .roam))                       // гуляет по экрану
//   .overlay(PetLayer(habitat: .sosGuard, anchor: .center))  // дремлет у кнопки
//   .overlay(PetLayer(habitat: .mapPlay, anchor: .center))   // играет с точкой
//
// Слой прозрачен для жестей: ловит касания только сам питомец, поэтому
// карта под ним продолжает тянуться, а кнопка SOS — нажиматься.

struct PetLayer: View {

    let habitat: PetHabitat
    /// К чему привязан питомец: кнопка SOS, точка на карте и т.п.
    var anchor: UnitPoint?
    var size: CGFloat = 58

    @StateObject private var motion: PetMotion
    @ObservedObject private var appearance = OrionAppearance.shared
    @ObservedObject private var companion = PetCompanion.shared

    /// Медленный таймер решений: 2 раза в секунду достаточно, чтобы
    /// поведение выглядело живым, и в 30 раз дешевле частоты кадров.
    private let beat = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(habitat: PetHabitat, anchor: UnitPoint? = nil, size: CGFloat = 58) {
        self.habitat = habitat
        self.anchor = anchor
        self.size = size
        _motion = StateObject(wrappedValue: PetMotion(habitat: habitat))
    }

    var body: some View {
        if appearance.petsEnabled {
            GeometryReader { geo in
                content(bounds: geo.size)
                    .onReceive(beat) { now in
                        motion.advance(now: now, bounds: geo.size, anchor: anchorPoint)
                        companion.nightCheck(now: now)
                    }
            }
        }
    }

    private var anchorPoint: CGPoint? {
        guard let a = anchor else { return nil }
        return CGPoint(x: a.x, y: a.y)
    }

    @ViewBuilder
    private func content(bounds: CGSize) -> some View {
        if appearance.animationsEnabled {
            // Кадры считает TimelineView: позиция — чистая функция от даты,
            // состояние движка при этом не меняется.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                sprite(frame: motion.frame(at: timeline.date, bounds: bounds, anchor: anchorPoint),
                       bounds: bounds)
            }
        } else {
            // Анимации выключены — рисуем один статичный кадр.
            sprite(frame: motion.frame(at: Date(), bounds: bounds, anchor: anchorPoint),
                   bounds: bounds)
        }
    }

    private func sprite(frame: PetFrame, bounds: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // Подложка нужна, чтобы слой занял весь экран, но она не
            // должна перехватывать касания — иначе под ней «умрут»
            // карта и кнопки.
            Color.clear.allowsHitTesting(false)

            PetSprite(species: companion.species, pose: frame.pose, tint: companion.furColor)
                .frame(width: size, height: size)
                .overlay(alignment: .top) { bubble }
                .contentShape(Circle())
                .onTapGesture {
                    companion.pet()
                    motion.poke(at: frame.position, bounds: bounds)
                }
                .position(x: frame.position.x, y: frame.position.y)
        }
    }

    /// Облачко с короткой репликой. Появляется редко и само гаснет.
    @ViewBuilder
    private var bubble: some View {
        if let phrase = companion.phrase {
            Text(phrase)
                .font(.caption2.weight(.medium))
                .foregroundColor(OrionTheme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassPill(tint: OrionTheme.accent)
                .fixedSize()
                .offset(y: -size * 0.55)
                .transition(.opacity)
        }
    }
}
