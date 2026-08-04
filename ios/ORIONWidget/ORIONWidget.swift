import WidgetKit
import SwiftUI

// MARK: - Timeline Provider

struct ORIONEntry: TimelineEntry {
    let date:          Date
    let latitude:      Double
    let longitude:     Double
    let locationDate:  Date?
    let systemStatus:  String
    let serverOnline:  Bool
    let totalPoints:   Int
}

struct ORIONProvider: TimelineProvider {

    func placeholder(in context: Context) -> ORIONEntry {
        ORIONEntry(date: Date(), latitude: 55.75, longitude: 37.62,
                   locationDate: Date(), systemStatus: "tracking",
                   serverOnline: true, totalPoints: 42)
    }

    func getSnapshot(in context: Context, completion: @escaping (ORIONEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ORIONEntry>) -> Void) {
        // Обновляем каждые 5 минут
        let next = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
        completion(Timeline(entries: [entry()], policy: .after(next)))
    }

    private func entry() -> ORIONEntry {
        let d = UserDefaults(suiteName: "group.com.stark.orion") ?? .standard
        return ORIONEntry(
            date:         Date(),
            latitude:     d.double(forKey: "lastLatitude"),
            longitude:    d.double(forKey: "lastLongitude"),
            locationDate: d.object(forKey: "lastLocationDate") as? Date,
            systemStatus: d.string(forKey: "systemStatus") ?? "offline",
            serverOnline: d.bool(forKey: "serverReachable"),
            totalPoints:  d.integer(forKey: "totalPointsSent")
        )
    }
}

// MARK: - Widget Views

struct ORIONWidgetEntryView: View {
    var entry: ORIONEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:  circularView
        case .accessoryRectangular: rectangularView
        case .accessoryInline:    inlineView
        default:                  systemSmallView
        }
    }

    // Круглый виджет (экран блокировки)
    var circularView: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.6))
            VStack(spacing: 1) {
                Image(systemName: statusIcon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(statusColor)
                Text("⚡")
                    .font(.system(size: 10))
                Text(timeAgo)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }

    // Прямоугольный виджет (экран блокировки)
    var rectangularView: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text("O.R.I.O.N.")
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundColor(.white)
                Text(coordString)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                Text(timeAgo)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 4)
    }

    // Строчный виджет
    var inlineView: some View {
        Label("\(statusEmoji) \(coordString)", systemImage: "shield.fill")
    }

    // Маленький виджет (главный экран)
    var systemSmallView: some View {
        ZStack {
            Color.black
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("⚡ O.R.I.O.N.")
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundColor(.cyan)
                    Spacer()
                    Circle()
                        .fill(entry.serverOnline ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                }

                Spacer()

                Image(systemName: statusIcon)
                    .font(.title)
                    .foregroundColor(statusColor)

                Text(coordString)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))

                Text(timeAgo)
                    .font(.caption2)
                    .foregroundColor(.gray)

                Text("\(entry.totalPoints) точек")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            .padding(12)
        }
    }

    // MARK: - Helpers

    var statusIcon: String {
        switch entry.systemStatus {
        case "tracking":    return "location.fill"
        case "online":      return "shield.fill"
        case "maintenance": return "wrench.fill"
        default:            return "shield.slash.fill"
        }
    }

    var statusColor: Color {
        switch entry.systemStatus {
        case "tracking": return .cyan
        case "online":   return .green
        default:         return .orange
        }
    }

    var statusEmoji: String {
        entry.serverOnline ? "🟢" : "🔴"
    }

    var coordString: String {
        entry.latitude == 0 && entry.longitude == 0
            ? "нет данных"
            : String(format: "%.4f, %.4f", entry.latitude, entry.longitude)
    }

    var timeAgo: String {
        guard let d = entry.locationDate else { return "—" }
        let secs = Int(-d.timeIntervalSinceNow)
        if secs < 60  { return "только что" }
        if secs < 3600 { return "\(secs/60) мин назад" }
        return "\(secs/3600) ч назад"
    }
}

// MARK: - Widget Declaration

@main
struct ORIONWidgetBundle: WidgetBundle {
    var body: some Widget {
        ORIONWidget()
    }
}

struct ORIONWidget: Widget {
    let kind = "ORIONWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ORIONProvider()) { entry in
            ORIONWidgetEntryView(entry: entry)
                .modifier(WidgetBackgroundModifier())
        }
        .configurationDisplayName("O.R.I.O.N.")
        .description("Статус слежения и последнее местоположение")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .systemSmall
        ])
    }
}

// MARK: - iOS 16/17 compatibility shim
// containerBackground(_:for:) требует iOS 17+.
// На iOS 16 просто оставляем фон без модификатора.

struct WidgetBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.containerBackground(Color.black, for: .widget)
        } else {
            content.background(Color.black)
        }
    }
}
