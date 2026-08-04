import SwiftUI
import MapKit

struct MapHistoryView: View {
    @EnvironmentObject var loc: LocationService
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var poi: PointsOfInterestService
    @ObservedObject private var appearance = OrionAppearance.shared

    @State private var recenterToken = 0
    /// Где сейчас синяя точка пользователя — в долях от размера карты.
    /// Питомец играет именно с ней, поэтому точка нужна в экранных
    /// координатах, а не в градусах.
    @State private var userDot: UnitPoint?

    // MARK: - Фильтры истории перемещений
    /// День в формате `yyyy-MM-dd`; nil — показывать все дни.
    @State private var dayFilter: String?
    @State private var fromHour = 0
    @State private var toHour   = 23
    @State private var placeQuery = ""
    @State private var showFilters = false
    @State private var showList = false

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                RouteMapView(
                    points: filtered,
                    current: loc.currentLocation?.coordinate,
                    pois: poi.points,
                    opacity: settings.routeOpacity,
                    width: settings.routeWidth,
                    colorName: settings.routeColorName,
                    gradient: settings.routeGradient,
                    recenterToken: recenterToken,
                    onUserPoint: { userDot = $0 }
                )
                .ignoresSafeArea(edges: .top)
                .overlay(petLayer)

                VStack(spacing: 0) {
                    if isFiltering { activeFilterBar }
                    bottomBar
                }
            }
            .navigationTitle("Карта")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showFilters) { filterSheet }
            .sheet(isPresented: $showList) { historySheet }
        }
    }

    // MARK: - Фильтрация истории

    /// История, суженная фильтрами «дата · время · место».
    private var filtered: [LocationPoint] {
        let needle = placeQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return loc.locationHistory.filter { p in
            if let day = dayFilter, p.dayKey != day { return false }
            let h = p.hourOfDay
            if h < fromHour || h > toHour { return false }
            if !needle.isEmpty, !(p.place?.lowercased().contains(needle) ?? false) { return false }
            return true
        }
    }

    private var isFiltering: Bool {
        dayFilter != nil || fromHour > 0 || toHour < 23 || !placeQuery.isEmpty
    }

    /// Дни, за которые есть точки — свежие сверху.
    private var days: [String] {
        Array(Set(loc.locationHistory.map(\.dayKey))).sorted(by: >)
    }

    /// Известные названия мест — фильтр не надо набирать вслепую.
    private var places: [String] {
        Array(Set(loc.locationHistory.compactMap { $0.place }.filter { !$0.isEmpty })).sorted()
    }

    private func resetFilters() {
        dayFilter = nil
        fromHour = 0
        toHour = 23
        placeQuery = ""
    }

    /// `2026-08-04` → `4 августа`; сегодня и вчера называем словами.
    private func dayLabel(_ key: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: key) else { return key }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "сегодня" }
        if cal.isDateInYesterday(date) { return "вчера" }
        let out = DateFormatter()
        out.locale = Locale(identifier: "ru_RU")
        out.dateFormat = "d MMMM"
        return out.string(from: date)
    }

    /// Питомец охотится за точкой пользователя: подкрадывается, прыгает,
    /// отбегает. Если точки на экране нет (нет фикса или её увели за край) —
    /// играет по центру карты, чтобы не пропадать совсем.
    @ViewBuilder
    private var petLayer: some View {
        if appearance.petOnMap {
            PetLayer(habitat: .mapPlay,
                     anchor: userDot ?? UnitPoint(x: 0.5, y: 0.45))
        }
    }

    // MARK: - Нижняя панель

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Label("\(filtered.count) точек", systemImage: "mappin.and.ellipse")
                .font(.caption).foregroundColor(OrionTheme.accent)
            if !poi.points.isEmpty {
                Text("· \(poi.points.count) мест")
                    .font(.caption).foregroundColor(OrionTheme.textSecondary)
            }
            if routeKm > 0 {
                Text(String(format: "· %.1f км", routeKm))
                    .font(.caption).foregroundColor(OrionTheme.textSecondary)
            }
            Spacer()
            chipButton("Фильтр", icon: "line.3.horizontal.decrease.circle",
                       active: isFiltering) { showFilters = true }
            chipButton("История", icon: "list.bullet") { showList = true }
            chipButton("Я здесь", icon: "location.fill") { recenterToken += 1 }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func chipButton(_ title: String, icon: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundColor(active ? OrionTheme.bg : OrionTheme.accent)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(active ? OrionTheme.accent : OrionTheme.surface)
                .cornerRadius(OrionTheme.Radius.chip)
        }
    }

    /// Строка над панелью: что именно сейчас показано и как это снять.
    private var activeFilterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .font(.caption).foregroundColor(OrionTheme.accent)
            Text(filterSummary)
                .font(.caption).foregroundColor(OrionTheme.textSecondary)
                .lineLimit(1)
            Spacer()
            Button("Сбросить", action: resetFilters)
                .font(.caption).foregroundColor(OrionTheme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private var filterSummary: String {
        var parts: [String] = []
        if let day = dayFilter { parts.append(dayLabel(day)) }
        if fromHour > 0 || toHour < 23 {
            parts.append(String(format: "%02d:00–%02d:59", fromHour, toHour))
        }
        let place = placeQuery.trimmingCharacters(in: .whitespaces)
        if !place.isEmpty { parts.append("«\(place)»") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Лист фильтров

    private var filterSheet: some View {
        NavigationView {
            Form {
                Section("Дата") {
                    Picker("День", selection: $dayFilter) {
                        Text("Все дни").tag(String?.none)
                        ForEach(days, id: \.self) { day in
                            Text(dayLabel(day)).tag(String?.some(day))
                        }
                    }
                }

                Section("Время суток") {
                    // Одноаргументный onChange — цель сборки iOS 16, где
                    // формы без параметра и с двумя ещё нет.
                    Stepper("С \(String(format: "%02d", fromHour)):00", value: $fromHour, in: 0...23)
                        .onChange(of: fromHour) { new in if toHour < new { toHour = new } }
                    Stepper("По \(String(format: "%02d", toHour)):59", value: $toHour, in: 0...23)
                        .onChange(of: toHour) { new in if fromHour > new { fromHour = new } }
                }

                Section("Место") {
                    TextField("Например: Мира", text: $placeQuery)
                        .autocorrectionDisabled()
                    if places.isEmpty {
                        Text("Названия появятся, когда приложение определит места точек.")
                            .font(.caption).foregroundColor(OrionTheme.textSecondary)
                    } else {
                        ForEach(places.prefix(12), id: \.self) { place in
                            Button(place) { placeQuery = place }
                                .foregroundColor(OrionTheme.accent)
                        }
                    }
                }

                Section {
                    Text("Найдено точек: \(filtered.count)")
                        .foregroundColor(OrionTheme.textSecondary)
                    Button("Сбросить фильтры", role: .destructive, action: resetFilters)
                }
            }
            .navigationTitle("Фильтр истории")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { showFilters = false }
                }
            }
        }
    }

    // MARK: - Лист истории (список точек по дням)

    private var historySheet: some View {
        NavigationView {
            Group {
                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "map").font(.largeTitle)
                            .foregroundColor(OrionTheme.textSecondary)
                        Text("За выбранный период точек нет")
                            .foregroundColor(OrionTheme.textSecondary)
                        if isFiltering {
                            Button("Сбросить фильтры", action: resetFilters)
                                .foregroundColor(OrionTheme.accent)
                        }
                    }
                } else {
                    List {
                        // Свежие дни сверху, внутри дня — тоже сверху свежее:
                        // историю смотрят «что было только что», а не с начала
                        // недели.
                        ForEach(groupedDays, id: \.self) { day in
                            Section(dayLabel(day)) {
                                ForEach(pointsOf(day)) { p in
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(p.timeString)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(OrionTheme.accent)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(p.placeOrCoords).font(.subheadline)
                                            if p.place != nil {
                                                Text(p.formattedCoords)
                                                    .font(.caption2)
                                                    .foregroundColor(OrionTheme.textSecondary)
                                            }
                                        }
                                        Spacer()
                                        Link(destination: p.mapsURL) {
                                            Image(systemName: "arrow.up.right.square")
                                                .foregroundColor(OrionTheme.accent)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("История перемещений")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Фильтр") { showList = false; showFilters = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { showList = false }
                }
            }
        }
    }

    private var groupedDays: [String] {
        Array(Set(filtered.map(\.dayKey))).sorted(by: >)
    }

    private func pointsOf(_ day: String) -> [LocationPoint] {
        filtered.filter { $0.dayKey == day }.sorted { $0.timestamp > $1.timestamp }
    }

    /// Длина маршрута (км) по показанной сейчас части истории.
    private var routeKm: Double {
        let pts = filtered
        guard pts.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<pts.count {
            total += CLLocation(latitude: pts[i-1].latitude, longitude: pts[i-1].longitude)
                .distance(from: CLLocation(latitude: pts[i].latitude, longitude: pts[i].longitude))
        }
        return total / 1000
    }
}

// MARK: - Цветная полилиния (несёт цвет/прозрачность/ширину сегмента)

final class ColoredPolyline: MKPolyline {
    var strokeUIColor: UIColor = .cyan
    var strokeAlpha: CGFloat = 1
    var strokeWidth: CGFloat = 4
}

// MARK: - Карта с маршрутом (MKMapView)

/// Аннотация точки интереса на карте.
final class POIAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let glyph: String
    let markerColor: UIColor
    init(_ p: PointOfInterest) {
        self.coordinate = p.coordinate
        self.title = p.name
        self.glyph = p.category.icon
        switch p.category {
        case .home:   self.markerColor = .systemBlue
        case .gym:    self.markerColor = .systemOrange
        case .work:   self.markerColor = .systemPurple
        case .school: self.markerColor = .systemGreen
        case .other:  self.markerColor = .systemTeal
        }
    }
}

struct RouteMapView: UIViewRepresentable {
    let points: [LocationPoint]
    let current: CLLocationCoordinate2D?
    let pois: [PointOfInterest]
    let opacity: Double
    let width: Double
    let colorName: String
    let gradient: Bool
    let recenterToken: Int
    /// Сообщает наверх, где на экране оказалась точка пользователя
    /// (в долях от размера карты). nil — точки не видно.
    var onUserPoint: ((UnitPoint?) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true            // текущее местоположение (синяя точка)
        map.pointOfInterestFilter = .excludingAll
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Перестраиваем маршрут
        map.removeOverlays(map.overlays)

        let coords = points.map { $0.coordinate }
        if coords.count > 1 {
            let base = Self.uiColor(colorName)
            let n = coords.count - 1
            for i in 0..<n {
                let seg = ColoredPolyline(coordinates: [coords[i], coords[i+1]], count: 2)
                let fraction = Double(i) / Double(max(1, n - 1))   // 0 старое → 1 свежее
                seg.strokeUIColor = base
                // Градиент: старые сегменты прозрачнее; иначе ровная прозрачность
                seg.strokeAlpha = gradient
                    ? CGFloat(opacity) * CGFloat(0.25 + 0.75 * fraction)
                    : CGFloat(opacity)
                seg.strokeWidth = CGFloat(width)
                map.addOverlay(seg)
            }
        }

        // Точки интереса — маркеры (сохраняем синюю точку пользователя)
        let oldPOI = map.annotations.filter { $0 is POIAnnotation }
        map.removeAnnotations(oldPOI)
        map.addAnnotations(pois.map { POIAnnotation($0) })

        // Первичное центрирование и реакция на кнопку «Я здесь»
        let c = context.coordinator
        c.onUserPoint = onUserPoint
        c.userCoordinate = current ?? coords.last
        // Не синхронно: updateUIView вызывается во время построения тела,
        // а замыкание меняет @State — SwiftUI за такое ругается.
        DispatchQueue.main.async { c.reportUserPoint(map) }

        let fitCoords = coords + pois.map { $0.coordinate }
        if !c.didInitialFit, !fitCoords.isEmpty {
            c.didInitialFit = true
            Self.fit(map, coords: fitCoords, current: current)
        }
        if c.lastRecenterToken != recenterToken {
            c.lastRecenterToken = recenterToken
            if let cur = current ?? coords.last {
                let region = MKCoordinateRegion(center: cur,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
                map.setRegion(region, animated: true)
            }
        }
    }

    // MARK: - Helpers

    static func uiColor(_ name: String) -> UIColor {
        switch name {
        case "green":  return UIColor.systemGreen
        case "orange": return UIColor.systemOrange
        case "purple": return UIColor.systemPurple
        case "red":    return UIColor.systemRed
        default:       return UIColor.systemTeal   // cyan
        }
    }

    static func fit(_ map: MKMapView, coords: [CLLocationCoordinate2D], current: CLLocationCoordinate2D?) {
        var all = coords
        if let cur = current { all.append(cur) }
        guard !all.isEmpty else { return }
        var rect = MKMapRect.null
        for c in all {
            let p = MKMapPoint(c)
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
        }
        let pad = UIEdgeInsets(top: 60, left: 40, bottom: 120, right: 40)
        map.setVisibleMapRect(rect, edgePadding: pad, animated: false)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        var didInitialFit = false
        var lastRecenterToken = 0

        var onUserPoint: ((UnitPoint?) -> Void)?
        var userCoordinate: CLLocationCoordinate2D?
        private var lastReported: UnitPoint?

        /// Переводит координату пользователя в долю экрана карты и отдаёт
        /// наверх. Порог в 1 % гасит поток обновлений при панорамировании:
        /// иначе SwiftUI перестраивал бы слой питомца на каждый кадр жеста.
        func reportUserPoint(_ map: MKMapView) {
            guard let report = onUserPoint else { return }
            let size = map.bounds.size
            guard size.width > 1, size.height > 1,
                  let coord = userCoordinate,
                  CLLocationCoordinate2DIsValid(coord) else {
                if lastReported != nil { lastReported = nil; report(nil) }
                return
            }
            let p = map.convert(coord, toPointTo: map)
            guard p.x.isFinite, p.y.isFinite else { return }
            let unit = UnitPoint(x: p.x / size.width, y: p.y / size.height)
            // Точку увели далеко за край — играть не с чем.
            guard unit.x > -0.2, unit.x < 1.2, unit.y > -0.2, unit.y < 1.2 else {
                if lastReported != nil { lastReported = nil; report(nil) }
                return
            }
            if let last = lastReported,
               abs(last.x - unit.x) < 0.01, abs(last.y - unit.y) < 0.01 { return }
            lastReported = unit
            report(unit)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            reportUserPoint(mapView)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? ColoredPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = line.strokeUIColor.withAlphaComponent(line.strokeAlpha)
                r.lineWidth = line.strokeWidth
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let poi = annotation as? POIAnnotation else { return nil } // user location — по умолчанию
            let id = "poi"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.markerTintColor = poi.markerColor
            view.glyphImage = UIImage(systemName: poi.glyph)
            view.canShowCallout = true
            return view
        }
    }
}
