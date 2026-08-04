import SwiftUI

// ╔══════════════════════════════════════════════════════════════╗
// ║  ОТРИСОВКА ПИТОМЦА — чистая векторная графика                 ║
// ╚══════════════════════════════════════════════════════════════╝
//
// Почему не SF Symbols: cat.fill / dog.fill появились только в iOS 18,
// а приложение собирается под iOS 16. Плюс готовая иконка не умеет
// шагать, вилять хвостом и сворачиваться калачиком — а именно это здесь
// и нужно. Поэтому питомец рисуется путями в Canvas: поза целиком
// задаётся параметрами PetPose, и любую фазу движения можно посчитать.
//
// Система координат внутри рисовалки — единичный квадрат (0…1), который
// масштабируется под размер, заданный родителем через .frame.

// MARK: - Поза

struct PetPose {
    /// Фаза шага/дыхания в радианах — от неё зависят лапы, хвост, корпус.
    var phase: Double = 0
    var facingRight: Bool = true
    var activity: PetActivity = .idle
    /// 0 — глаза открыты, 1 — закрыты (моргание).
    var blink: Double = 0
    /// 0…1: чем выше, тем бодрее хвост и уши.
    var happiness: Double = 0.5
}

// MARK: - Вид

/// Параметры силуэта: именно они делают кота котом, а пингвина пингвином.
struct PetLook {
    enum Stance { case quadruped, upright, owl }
    enum Ears { case pointed, floppy, long, round, tufts, none }
    enum Tail { case long, bushy, stubby, puff, tiny, none }

    var stance: Stance = .quadruped
    var ears: Ears = .pointed
    var tail: Tail = .long
    var bodyRX: Double = 0.28
    var bodyRY: Double = 0.17
    var headR: Double = 0.155
    /// Сколько лапы торчит из-под корпуса. Именно этим коротколапые
    /// (хомяк, пухлая кошечка) отличаются от кота: земля у всех одна,
    /// разная — высота посадки.
    var legLength: Double = 0.155
    var legWidth: Double = 0.055
    var snout: Bool = false
    /// Светлое брюшко идёт от шерсти. У пингвина — нет: белый перёд это и
    /// есть пингвин, а не оттенок его спины.
    var tintsBelly: Bool = true

    var fur: Color
    var belly: Color
    var inner: Color
    var outline: Color

    static func of(_ species: PetSpecies, tint: Color? = nil) -> PetLook {
        var look: PetLook
        switch species {
        case .cat:
            look = PetLook(stance: .quadruped, ears: .pointed, tail: .long,
                           bodyRX: 0.27, bodyRY: 0.165, headR: 0.155,
                           legLength: 0.155, legWidth: 0.052, snout: false,
                           fur: Color(hex: "9AA5B1"), belly: Color(hex: "E3E8EF"),
                           inner: Color(hex: "F0A9B8"), outline: Color(hex: "1B2230"))
        case .chonky:
            // Та же кошка, но круглее корпус, короче лапы и ниже посадка —
            // «пухлость» читается именно пропорциями, а не отдельным силуэтом.
            look = PetLook(stance: .quadruped, ears: .pointed, tail: .long,
                           bodyRX: 0.325, bodyRY: 0.235, headR: 0.160,
                           legLength: 0.060, legWidth: 0.070, snout: false,
                           fur: Color(hex: "9AA5B1"), belly: Color(hex: "E3E8EF"),
                           inner: Color(hex: "F0A9B8"), outline: Color(hex: "1B2230"))
        case .dog:
            look = PetLook(stance: .quadruped, ears: .floppy, tail: .stubby,
                           bodyRX: 0.29, bodyRY: 0.175, headR: 0.165,
                           legLength: 0.145, legWidth: 0.060, snout: true,
                           fur: Color(hex: "C99A63"), belly: Color(hex: "F0DFC6"),
                           inner: Color(hex: "E7A08E"), outline: Color(hex: "241A12"))
        case .fox:
            look = PetLook(stance: .quadruped, ears: .pointed, tail: .bushy,
                           bodyRX: 0.27, bodyRY: 0.155, headR: 0.150,
                           legLength: 0.165, legWidth: 0.050, snout: true,
                           fur: Color(hex: "E8834A"), belly: Color(hex: "F7EAD9"),
                           inner: Color(hex: "F2A98C"), outline: Color(hex: "2A1608"))
        case .bunny:
            look = PetLook(stance: .quadruped, ears: .long, tail: .puff,
                           bodyRX: 0.25, bodyRY: 0.175, headR: 0.150,
                           legLength: 0.145, legWidth: 0.055, snout: false,
                           fur: Color(hex: "E8E4E1"), belly: Color(hex: "FFFFFF"),
                           inner: Color(hex: "F3B0BE"), outline: Color(hex: "2B2622"))
        case .hamster:
            look = PetLook(stance: .quadruped, ears: .round, tail: .tiny,
                           bodyRX: 0.26, bodyRY: 0.195, headR: 0.150,
                           legLength: 0.125, legWidth: 0.050, snout: false,
                           fur: Color(hex: "E3B87C"), belly: Color(hex: "F8ECD9"),
                           inner: Color(hex: "E8A08E"), outline: Color(hex: "3A2A16"))
        case .penguin:
            look = PetLook(stance: .upright, ears: .none, tail: .none,
                           bodyRX: 0.22, bodyRY: 0.30, headR: 0.17,
                           legLength: 0.08, legWidth: 0.060, snout: false,
                           tintsBelly: false,
                           fur: Color(hex: "27303F"), belly: Color(hex: "F5F7FA"),
                           inner: Color(hex: "F5A524"), outline: Color(hex: "121821"))
        case .owl:
            look = PetLook(stance: .owl, ears: .tufts, tail: .none,
                           bodyRX: 0.235, bodyRY: 0.245, headR: 0.195,
                           legLength: 0.06, legWidth: 0.045, snout: false,
                           fur: Color(hex: "C79A6B"), belly: Color(hex: "F4E7D6"),
                           inner: Color(hex: "F0A93C"), outline: Color(hex: "2A2018"))
        }
        if let tint = tint {
            // Перекрашиваем не только шерсть: чёрный кот с молочным животом
            // и светлым контуром выглядит как чужая заготовка, а не как кот.
            // Клюв/нос/внутренность уха (`inner`) остаются — они от окраса
            // шерсти не зависят.
            if look.tintsBelly { look.belly = tint.orionDarkened(-0.42) }
            look.outline = tint.orionDarkened(0.70)
            look.fur = tint
        }
        return look
    }
}

// MARK: - Вьюха

struct PetSprite: View {
    let species: PetSpecies
    var pose: PetPose = PetPose()
    var tint: Color? = nil

    var body: some View {
        Canvas { ctx, size in
            PetRenderer.draw(&ctx, size: size, look: PetLook.of(species, tint: tint), pose: pose)
        }
    }
}

/// Анимированная витрина для выбора вида в «Оформлении».
struct PetPreview: View {
    let species: PetSpecies
    var size: CGFloat = 64
    var tint: Color? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            PetSprite(
                species: species,
                pose: PetPose(phase: t * 3.2,
                              facingRight: true,
                              activity: .walk,
                              blink: PetRenderer.blink(at: t),
                              happiness: 0.8),
                tint: tint
            )
            .frame(width: size, height: size)
        }
    }
}

// MARK: - Рисовалка

enum PetRenderer {

    /// Моргание: редкое и короткое, считается прямо из времени.
    static func blink(at t: TimeInterval) -> Double {
        let cycle = t.truncatingRemainder(dividingBy: 4.2)
        return cycle > 4.0 ? 1 : 0
    }

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, look: PetLook, pose: PetPose) {
        let side = min(size.width, size.height)
        guard side > 1 else { return }

        var g = ctx
        g.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
        if !pose.facingRight {
            g.translateBy(x: side, y: 0)
            g.scaleBy(x: -1, y: 1)
        }

        // Мягкая тень под питомцем — он «стоит», а не висит в воздухе.
        let shadowSquash = pose.activity == .sleep ? 1.15 : 1.0
        g.fill(ellipse(0.5, 0.925, (0.16 + look.bodyRX * 0.30) * shadowSquash, 0.035, side),
               with: .color(look.outline.opacity(0.22)))

        switch look.stance {
        case .quadruped: drawQuadruped(&g, side: side, look: look, pose: pose)
        case .upright:   drawUpright(&g, side: side, look: look, pose: pose)
        case .owl:       drawOwl(&g, side: side, look: look, pose: pose)
        }
    }

    // MARK: Четвероногие

    private static func drawQuadruped(_ g: inout GraphicsContext, side: CGFloat,
                                      look: PetLook, pose: PetPose) {
        if pose.activity == .sleep {
            drawCurled(&g, side: side, look: look, pose: pose)
            return
        }

        let sitting = pose.activity == .sit
        let playing = pose.activity == .play
        let alerted = pose.activity == .alert

        // Амплитуда шага и «дыхание» корпуса.
        let swing: Double
        switch pose.activity {
        case .walk: swing = 0.055
        case .run:  swing = 0.095
        default:    swing = 0
        }
        let bob = swing > 0 ? 0.012 * sin(pose.phase * 2) : 0.006 * sin(pose.phase * 0.8)

        // Передняя часть корпуса при игре («поклон») опускается.
        let frontDrop = playing ? 0.06 : 0
        // Корпус садится так, чтобы из-под него торчало ровно `legLength`
        // лапы. У кота, пса, лисы, кролика и хомяка выходит те же 0.58,
        // что были вписаны раньше; пухлая кошечка садится заметно ниже.
        let ground = 0.90
        let bodyY = ground - look.legLength - look.bodyRY + bob + (sitting ? 0.02 : 0)

        // ── Лапы (задние рисуем до корпуса, передние — после)
        let legTop = bodyY + look.bodyRY * 0.5
        let stroke = StrokeStyle(lineWidth: look.legWidth * side, lineCap: .round)

        if sitting {
            // Сидит: задние лапы сложены в бедро, передние прямые. Бедро
            // привязано к земле, а не к корпусу: у пухлой кошечки корпус
            // ниже, и «поехавшее» вместе с ним бедро ушло бы под пол.
            g.fill(ellipse(0.34, ground - 0.16, 0.15 + (look.bodyRX - 0.27) * 0.5, 0.16, side),
                   with: .color(look.fur))
        } else {
            g.stroke(leg(0.34, legTop, ground, swing * sin(pose.phase + .pi), side),
                     with: .color(look.fur.orionDarkened(0.18)), style: stroke)
            g.stroke(leg(0.42, legTop, ground, swing * sin(pose.phase + .pi / 2), side),
                     with: .color(look.fur.orionDarkened(0.18)), style: stroke)
        }

        // ── Корпус
        g.fill(ellipse(0.48, bodyY + frontDrop * 0.4, look.bodyRX, look.bodyRY, side),
               with: .color(look.fur))
        // Брюшко — светлее, даёт объём.
        g.fill(ellipse(0.50, bodyY + look.bodyRY * 0.45 + frontDrop * 0.4,
                       look.bodyRX * 0.72, look.bodyRY * 0.45, side),
               with: .color(look.belly.opacity(0.9)))

        // ── Хвост
        drawTail(&g, side: side, look: look, pose: pose, bodyY: bodyY, alerted: alerted)

        // ── Передние лапы
        if !sitting {
            g.stroke(leg(0.62, legTop + frontDrop, ground, swing * sin(pose.phase), side),
                     with: .color(look.fur), style: stroke)
            g.stroke(leg(0.70, legTop + frontDrop, ground, swing * sin(pose.phase + 3 * .pi / 2), side),
                     with: .color(look.fur), style: stroke)
        } else {
            // Передние лапы начинаются не выше низа корпуса — иначе у
            // низкосидящих видов линия лапы прочерчивала бы брюхо.
            let sitTop = max(ground - 0.20, bodyY + look.bodyRY * 0.72)
            g.stroke(leg(0.64, sitTop, ground, 0, side), with: .color(look.fur), style: stroke)
            g.stroke(leg(0.72, sitTop, ground, 0, side), with: .color(look.fur), style: stroke)
        }

        // ── Голова
        let headY = 0.42 + bob * 0.6 + frontDrop * 0.9 + (sitting ? -0.02 : 0)
        let headX = 0.745
        g.fill(circle(headX, headY, look.headR, side), with: .color(look.fur))

        drawEars(&g, side: side, look: look, pose: pose, headX: headX, headY: headY, alerted: alerted)

        // Морда (у пса и лисы — вытянутая)
        if look.snout {
            g.fill(ellipse(headX + look.headR * 0.72, headY + look.headR * 0.30,
                           look.headR * 0.52, look.headR * 0.34, side),
                   with: .color(look.belly))
        }

        // Глаз
        let eyeX = headX + look.headR * 0.35
        let eyeY = headY - look.headR * 0.10
        if pose.blink > 0.5 {
            var line = Path()
            line.move(to: pt(eyeX - 0.022, eyeY, side))
            line.addLine(to: pt(eyeX + 0.022, eyeY, side))
            g.stroke(line, with: .color(look.outline),
                     style: StrokeStyle(lineWidth: 0.012 * side, lineCap: .round))
        } else {
            let r = alerted ? 0.030 : 0.024
            g.fill(circle(eyeX, eyeY, r, side), with: .color(look.outline))
            g.fill(circle(eyeX + 0.008, eyeY - 0.008, r * 0.35, side), with: .color(.white.opacity(0.9)))
        }

        // Нос
        let noseX = headX + look.headR * (look.snout ? 1.15 : 0.86)
        let noseY = headY + look.headR * (look.snout ? 0.26 : 0.34)
        g.fill(ellipse(noseX, noseY, 0.020, 0.016, side), with: .color(look.inner))

        // Усы — только коту, они делают силуэт узнаваемым.
        if look.ears == .pointed && !look.snout {
            for k in -1...1 {
                var w = Path()
                w.move(to: pt(noseX - 0.01, noseY + Double(k) * 0.012, side))
                w.addLine(to: pt(noseX + 0.12, noseY + Double(k) * 0.035, side))
                g.stroke(w, with: .color(look.outline.opacity(0.45)),
                         style: StrokeStyle(lineWidth: 0.007 * side, lineCap: .round))
            }
        }
    }

    // MARK: Свернулся калачиком

    private static func drawCurled(_ g: inout GraphicsContext, side: CGFloat,
                                   look: PetLook, pose: PetPose) {
        // Дыхание: тело чуть заметно раздувается.
        let breath = 1 + 0.022 * sin(pose.phase * 0.9)
        let r = (0.22 + look.bodyRX * 0.30) * breath

        g.fill(circle(0.48, 0.64, r, side), with: .color(look.fur))
        g.fill(ellipse(0.52, 0.74, r * 0.62, r * 0.38, side), with: .color(look.belly.opacity(0.85)))

        // Хвост обнимает тело — та самая деталь, ради которой «калачик».
        var tail = Path()
        tail.move(to: pt(0.22, 0.60, side))
        tail.addQuadCurve(to: pt(0.74, 0.84, side), control: pt(0.36, 0.98, side))
        let tailWidth: Double
        switch look.tail {
        case .bushy: tailWidth = 0.11
        case .long:  tailWidth = 0.070
        case .stubby, .tiny, .puff, .none: tailWidth = 0.060
        }
        g.stroke(tail, with: .color(look.fur.orionDarkened(0.12)),
                 style: StrokeStyle(lineWidth: tailWidth * side, lineCap: .round))

        // Голова, уткнувшаяся в бок.
        let headY = 0.70 + 0.006 * sin(pose.phase * 0.9)
        g.fill(circle(0.66, headY, look.headR * 1.02, side), with: .color(look.fur))

        // Ушки видно даже во сне.
        if look.ears == .pointed {
            g.fill(triangle(pt(0.58, headY - 0.10, side), pt(0.62, headY - 0.20, side),
                            pt(0.67, headY - 0.09, side)), with: .color(look.fur))
            g.fill(triangle(pt(0.70, headY - 0.11, side), pt(0.75, headY - 0.20, side),
                            pt(0.78, headY - 0.08, side)), with: .color(look.fur))
        } else if look.ears == .long {
            g.fill(ellipse(0.63, headY - 0.17, 0.035, 0.10, side), with: .color(look.fur))
            g.fill(ellipse(0.72, headY - 0.16, 0.035, 0.10, side), with: .color(look.fur))
        } else if look.ears == .round || look.ears == .floppy {
            g.fill(circle(0.60, headY - 0.11, 0.045, side), with: .color(look.fur.orionDarkened(0.1)))
            g.fill(circle(0.74, headY - 0.11, 0.045, side), with: .color(look.fur.orionDarkened(0.1)))
        }

        // Закрытый глаз.
        var eye = Path()
        eye.move(to: pt(0.70, headY, side))
        eye.addQuadCurve(to: pt(0.76, headY, side), control: pt(0.73, headY + 0.022, side))
        g.stroke(eye, with: .color(look.outline),
                 style: StrokeStyle(lineWidth: 0.013 * side, lineCap: .round))

        // Сонные «z» — маленькая, но очень читаемая деталь.
        let zPhase = pose.phase.truncatingRemainder(dividingBy: .pi * 2) / (.pi * 2)
        for i in 0..<2 {
            let p = (zPhase + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
            var text = g.resolve(Text("z").font(.system(size: side * (0.10 + 0.05 * p), weight: .heavy)))
            text.shading = .color(look.outline.opacity(0.55 * (1 - p)))
            g.draw(text, at: pt(0.80 + 0.10 * p, 0.52 - 0.28 * p, side))
        }
    }

    // MARK: Пингвин (стоит столбиком)

    private static func drawUpright(_ g: inout GraphicsContext, side: CGFloat,
                                    look: PetLook, pose: PetPose) {
        let sleeping = pose.activity == .sleep
        let moving = pose.activity == .walk || pose.activity == .run
        // Переваливается: качается вокруг лап, а не шагает.
        let waddle = moving ? 0.10 * sin(pose.phase) : 0.02 * sin(pose.phase * 0.7)

        var g2 = g
        let pivot = pt(0.5, 0.90, side)
        g2.translateBy(x: pivot.x, y: pivot.y)
        g2.rotate(by: .radians(waddle))
        g2.translateBy(x: -pivot.x, y: -pivot.y)

        let squat = sleeping ? 0.06 : 0.0

        // Лапы
        g2.fill(ellipse(0.40, 0.905, 0.075, 0.030, side), with: .color(look.inner))
        g2.fill(ellipse(0.61, 0.905, 0.075, 0.030, side), with: .color(look.inner))

        // Корпус
        g2.fill(ellipse(0.5, 0.60 + squat, look.bodyRX + squat * 0.6, look.bodyRY - squat, side),
                with: .color(look.fur))
        g2.fill(ellipse(0.5, 0.63 + squat, look.bodyRX * 0.66, (look.bodyRY - squat) * 0.78, side),
                with: .color(look.belly))

        // Ласты
        let flap = moving ? 0.045 * sin(pose.phase + .pi / 2) : 0.012 * sin(pose.phase * 0.6)
        g2.fill(ellipse(0.255, 0.62 + flap + squat, 0.055, 0.16, side), with: .color(look.fur))
        g2.fill(ellipse(0.745, 0.62 - flap + squat, 0.055, 0.16, side), with: .color(look.fur))

        // Голова
        let headY = 0.26 + squat * 1.6
        g2.fill(circle(0.5, headY, look.headR, side), with: .color(look.fur))
        g2.fill(ellipse(0.53, headY + 0.03, look.headR * 0.66, look.headR * 0.60, side),
                with: .color(look.belly))

        // Клюв
        g2.fill(triangle(pt(0.62, headY + 0.005, side),
                         pt(0.75, headY + 0.035, side),
                         pt(0.62, headY + 0.065, side)),
                with: .color(look.inner))

        // Глаз
        if sleeping || pose.blink > 0.5 {
            var line = Path()
            line.move(to: pt(0.545, headY - 0.005, side))
            line.addLine(to: pt(0.585, headY - 0.005, side))
            g2.stroke(line, with: .color(look.outline),
                      style: StrokeStyle(lineWidth: 0.012 * side, lineCap: .round))
        } else {
            g2.fill(circle(0.565, headY - 0.01, 0.026, side), with: .color(look.outline))
            g2.fill(circle(0.573, headY - 0.018, 0.009, side), with: .color(.white.opacity(0.9)))
        }

        if sleeping {
            let zPhase = pose.phase.truncatingRemainder(dividingBy: .pi * 2) / (.pi * 2)
            var text = g2.resolve(Text("z").font(.system(size: side * 0.12, weight: .heavy)))
            text.shading = .color(look.outline.opacity(0.5 * (1 - zPhase)))
            g2.draw(text, at: pt(0.72 + 0.08 * zPhase, 0.22 - 0.16 * zPhase, side))
        }
    }

    // MARK: Совёнок (сидит столбиком, голова больше туловища)

    /// Сова не шагает — она сидит и вертит головой. Поэтому у неё свой
    /// рисовальщик: ни четвероногая механика лап, ни переваливание пингвина
    /// ей не подходят. Смотрит она всегда на зрителя (оба глаза видно) —
    /// в этом вся узнаваемость совы, поэтому поворот силуэта её не касается.
    private static func drawOwl(_ g: inout GraphicsContext, side: CGFloat,
                                look: PetLook, pose: PetPose) {
        let sleeping = pose.activity == .sleep
        let alerted  = pose.activity == .alert
        let moving   = pose.activity == .walk || pose.activity == .run
        let playing  = pose.activity == .play

        // Дыхание/подпрыгивание корпуса и отдельное покачивание головы —
        // та самая «совиная» повадка.
        let bob  = moving ? 0.018 * sin(pose.phase * 2) : 0.007 * sin(pose.phase * 0.8)
        let sway = sleeping ? 0 : (playing ? 0.05 : 0.022) * sin(pose.phase * (moving ? 1.6 : 0.7))
        let squat = sleeping ? 0.035 : 0

        let bodyY = 0.66 + bob + squat
        let headY = 0.34 + bob * 1.4 + squat * 1.6 - (alerted ? 0.012 : 0)
        let headX = 0.5 + sway * 0.5

        // ── Лапы: три коротких когтя, торчащих из-под перьев.
        for foot in [0.42, 0.58] {
            for k in -1...1 {
                var claw = Path()
                claw.move(to: pt(foot, 0.875, side))
                claw.addLine(to: pt(foot + Double(k) * 0.030, 0.915, side))
                g.stroke(claw, with: .color(look.inner),
                         style: StrokeStyle(lineWidth: 0.016 * side, lineCap: .round))
            }
        }

        // ── Корпус каплей: снизу шире, сверху уходит в голову.
        g.fill(ellipse(0.5, bodyY, look.bodyRX + squat, look.bodyRY - squat * 0.5, side),
               with: .color(look.fur))
        // Пёстрая грудка — светлое пятно с рябью из коротких штрихов.
        g.fill(ellipse(0.5, bodyY + 0.03, look.bodyRX * 0.62, (look.bodyRY - squat) * 0.66, side),
               with: .color(look.belly))
        for i in 0..<5 {
            let row = Double(i)
            var speck = Path()
            let y = bodyY - 0.05 + row * 0.045
            speck.move(to: pt(0.5 - 0.055 + (row.truncatingRemainder(dividingBy: 2)) * 0.045, y, side))
            speck.addLine(to: pt(0.5 - 0.015 + (row.truncatingRemainder(dividingBy: 2)) * 0.045, y, side))
            g.stroke(speck, with: .color(look.fur.opacity(0.45)),
                     style: StrokeStyle(lineWidth: 0.010 * side, lineCap: .round))
        }

        // ── Крылья: при игре приподняты, во сне плотно сложены.
        let flap = playing ? 0.055 * sin(pose.phase * 2.4) : (moving ? 0.02 * sin(pose.phase) : 0)
        g.fill(ellipse(0.5 - look.bodyRX * 0.86, bodyY + 0.01 - flap, 0.062, look.bodyRY * 0.78, side),
               with: .color(look.fur.orionDarkened(0.12)))
        g.fill(ellipse(0.5 + look.bodyRX * 0.86, bodyY + 0.01 + flap, 0.062, look.bodyRY * 0.78, side),
               with: .color(look.fur.orionDarkened(0.12)))

        // ── Голова и кисточки на ушах.
        g.fill(circle(headX, headY, look.headR, side), with: .color(look.fur))
        let lift = alerted ? 0.035 : 0
        g.fill(triangle(pt(headX - 0.155, headY - 0.075, side),
                        pt(headX - 0.150, headY - 0.235 - lift, side),
                        pt(headX - 0.055, headY - 0.145, side)),
               with: .color(look.fur))
        g.fill(triangle(pt(headX + 0.155, headY - 0.075, side),
                        pt(headX + 0.150, headY - 0.235 - lift, side),
                        pt(headX + 0.055, headY - 0.145, side)),
               with: .color(look.fur))

        // Лицевой диск — то, из-за чего сова читается совой с первого взгляда.
        g.fill(ellipse(headX, headY + 0.012, look.headR * 0.84, look.headR * 0.78, side),
               with: .color(look.belly))

        // ── Глаза: круглые, большие, близко посаженные.
        let eyeDX = look.headR * 0.44
        let eyeY  = headY - 0.005
        let eyeR  = alerted ? 0.062 : 0.055
        for dx in [-eyeDX, eyeDX] {
            if sleeping || pose.blink > 0.5 {
                var lid = Path()
                lid.move(to: pt(headX + dx - eyeR * 0.8, eyeY, side))
                lid.addQuadCurve(to: pt(headX + dx + eyeR * 0.8, eyeY, side),
                                 control: pt(headX + dx, eyeY + eyeR * 0.7, side))
                g.stroke(lid, with: .color(look.outline),
                         style: StrokeStyle(lineWidth: 0.013 * side, lineCap: .round))
            } else {
                g.fill(circle(headX + dx, eyeY, eyeR, side), with: .color(.white.opacity(0.95)))
                g.fill(circle(headX + dx, eyeY, eyeR * 0.62, side), with: .color(look.inner))
                g.fill(circle(headX + dx, eyeY, eyeR * 0.40, side), with: .color(look.outline))
                g.fill(circle(headX + dx + 0.012, eyeY - 0.014, eyeR * 0.20, side),
                       with: .color(.white.opacity(0.9)))
            }
        }

        // ── Клюв: маленький крючок между глазами.
        g.fill(triangle(pt(headX - 0.020, eyeY + eyeR * 0.75, side),
                        pt(headX + 0.020, eyeY + eyeR * 0.75, side),
                        pt(headX, eyeY + eyeR * 1.55, side)),
               with: .color(look.inner))

        if sleeping {
            let zPhase = pose.phase.truncatingRemainder(dividingBy: .pi * 2) / (.pi * 2)
            var text = g.resolve(Text("z").font(.system(size: side * 0.12, weight: .heavy)))
            text.shading = .color(look.outline.opacity(0.5 * (1 - zPhase)))
            g.draw(text, at: pt(0.74 + 0.08 * zPhase, 0.24 - 0.16 * zPhase, side))
        }
    }

    // MARK: Уши и хвост

    private static func drawEars(_ g: inout GraphicsContext, side: CGFloat, look: PetLook,
                                 pose: PetPose, headX: Double, headY: Double, alerted: Bool) {
        // Настороженный питомец поднимает уши, довольный — чуть подёргивает.
        let twitch = alerted ? 0 : 0.012 * sin(pose.phase * 1.7)
        let lift = alerted ? 0.03 : 0

        switch look.ears {
        case .pointed:
            g.fill(triangle(pt(headX - 0.10, headY - 0.08, side),
                            pt(headX - 0.07, headY - 0.23 - lift + twitch, side),
                            pt(headX - 0.005, headY - 0.10, side)),
                   with: .color(look.fur))
            g.fill(triangle(pt(headX + 0.04, headY - 0.10, side),
                            pt(headX + 0.085, headY - 0.24 - lift - twitch, side),
                            pt(headX + 0.125, headY - 0.06, side)),
                   with: .color(look.fur))
            // Внутренняя часть уха — иначе силуэт читается плоско.
            g.fill(triangle(pt(headX + 0.052, headY - 0.10, side),
                            pt(headX + 0.083, headY - 0.20 - lift - twitch, side),
                            pt(headX + 0.108, headY - 0.075, side)),
                   with: .color(look.inner.opacity(0.85)))
        case .floppy:
            g.fill(ellipse(headX - 0.085, headY + 0.02 + twitch, 0.048, 0.105, side),
                   with: .color(look.fur.orionDarkened(0.12)))
            g.fill(ellipse(headX + 0.095, headY + 0.01 - twitch, 0.048, 0.105, side),
                   with: .color(look.fur.orionDarkened(0.12)))
        case .long:
            g.fill(ellipse(headX - 0.045, headY - 0.21 - lift + twitch, 0.040, 0.135, side),
                   with: .color(look.fur))
            g.fill(ellipse(headX + 0.055, headY - 0.20 - lift - twitch, 0.040, 0.135, side),
                   with: .color(look.fur))
            g.fill(ellipse(headX + 0.055, headY - 0.20 - lift - twitch, 0.020, 0.095, side),
                   with: .color(look.inner.opacity(0.8)))
        case .round:
            g.fill(circle(headX - 0.085, headY - 0.10 + twitch, 0.050, side),
                   with: .color(look.fur.orionDarkened(0.12)))
            g.fill(circle(headX + 0.085, headY - 0.11 - twitch, 0.050, side),
                   with: .color(look.fur.orionDarkened(0.12)))
        case .tufts, .none:
            // Кисточки рисует сама сова (`drawOwl`) — вместе с головой.
            break
        }
    }

    private static func drawTail(_ g: inout GraphicsContext, side: CGFloat, look: PetLook,
                                 pose: PetPose, bodyY: Double, alerted: Bool) {
        let wag = 0.055 * sin(pose.phase * 1.4)
        let root = pt(0.24, bodyY - 0.02, side)

        switch look.tail {
        case .long:
            var path = Path()
            path.move(to: root)
            // Настороженный кот держит хвост трубой, спокойный — дугой.
            let tipY = alerted ? 0.16 : 0.30 - 0.08 * pose.happiness
            path.addQuadCurve(to: pt(0.13 + wag, tipY, side),
                              control: pt(0.05, bodyY - 0.02 + wag, side))
            g.stroke(path, with: .color(look.fur),
                     style: StrokeStyle(lineWidth: 0.055 * side, lineCap: .round))
        case .bushy:
            var path = Path()
            path.move(to: root)
            path.addQuadCurve(to: pt(0.11 + wag, 0.30, side),
                              control: pt(0.03, bodyY + 0.10, side))
            g.stroke(path, with: .color(look.fur),
                     style: StrokeStyle(lineWidth: 0.115 * side, lineCap: .round))
            g.fill(circle(0.11 + wag, 0.30, 0.062, side), with: .color(look.belly))
        case .stubby:
            var path = Path()
            path.move(to: root)
            path.addQuadCurve(to: pt(0.15 + wag * 1.6, bodyY - 0.16, side),
                              control: pt(0.16, bodyY - 0.06, side))
            g.stroke(path, with: .color(look.fur),
                     style: StrokeStyle(lineWidth: 0.062 * side, lineCap: .round))
        case .puff:
            g.fill(circle(0.20 + wag * 0.3, bodyY + 0.02, 0.065, side), with: .color(look.belly))
        case .tiny:
            g.fill(circle(0.22, bodyY + 0.03, 0.030, side), with: .color(look.fur.orionDarkened(0.15)))
        case .none:
            break
        }
    }

    // MARK: Примитивы (единичные координаты → точки)

    private static func pt(_ x: Double, _ y: Double, _ s: CGFloat) -> CGPoint {
        CGPoint(x: CGFloat(x) * s, y: CGFloat(y) * s)
    }

    private static func ellipse(_ cx: Double, _ cy: Double,
                                _ rx: Double, _ ry: Double, _ s: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: CGFloat(cx - rx) * s, y: CGFloat(cy - ry) * s,
                               width: CGFloat(rx * 2) * s, height: CGFloat(ry * 2) * s))
    }

    private static func circle(_ cx: Double, _ cy: Double, _ r: Double, _ s: CGFloat) -> Path {
        ellipse(cx, cy, r, r, s)
    }

    private static func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Path {
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        p.addLine(to: c)
        p.closeSubpath()
        return p
    }

    private static func leg(_ x: Double, _ top: Double, _ ground: Double,
                            _ swing: Double, _ s: CGFloat) -> Path {
        var p = Path()
        p.move(to: pt(x, top, s))
        p.addLine(to: pt(x + swing, ground, s))
        return p
    }
}
