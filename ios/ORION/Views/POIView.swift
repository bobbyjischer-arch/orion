import SwiftUI
import MapKit

// MARK: - Список точек интереса

struct POIView: View {
    @EnvironmentObject var poi: PointsOfInterestService
    @EnvironmentObject var loc: LocationService
    @ObservedObject private var appearance = OrionAppearance.shared

    @State private var showEditor = false
    @State private var editing: PointOfInterest?

    var body: some View {
        ZStack {
            OrionTheme.backgroundGradient.ignoresSafeArea()
            Form {
                Section {
                    if poi.points.isEmpty {
                        HStack {
                            Image(systemName: "mappin.slash")
                                .foregroundColor(OrionTheme.warning)
                            Text("Точек пока нет")
                                .foregroundColor(OrionTheme.textSecondary)
                        }
                    } else {
                        ForEach(poi.points) { p in
                            POIRow(poi: p)
                                .contentShape(Rectangle())
                                .onTapGesture { editing = p; showEditor = true }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation { poi.delete(p) }
                                    } label: {
                                        Label("Удалить", systemImage: "trash.fill")
                                    }
                                }
                        }
                    }

                    Button {
                        editing = nil; showEditor = true
                    } label: {
                        Label("Добавить точку", systemImage: "plus.circle.fill")
                            .foregroundColor(OrionTheme.accent)
                    }
                } header: {
                    Text("Привычные места")
                } footer: {
                    Text("O.R.I.O.N. спросит «направляешься туда?» при приближении и учитывает эти точки в анализе.")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("📍 Точки интереса")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEditor) {
            POIEditSheet(
                poi: editing,
                currentLat: loc.currentLocation?.coordinate.latitude,
                currentLon: loc.currentLocation?.coordinate.longitude
            ) { result in
                if poi.points.contains(where: { $0.id == result.id }) {
                    poi.update(result)
                } else {
                    poi.add(result)
                }
            }
        }
    }
}

// MARK: - Строка точки

struct POIRow: View {
    let poi: PointOfInterest
    // Точка сама по себе не меняется при смене темы — без подписки на
    // оформление строка осталась бы в старых цветах.
    @ObservedObject private var appearance = OrionAppearance.shared

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(OrionTheme.accent.opacity(0.18)).frame(width: 36, height: 36)
                Image(systemName: poi.category.icon)
                    .foregroundColor(OrionTheme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(poi.name).foregroundColor(OrionTheme.textPrimary).font(.subheadline)
                Text("\(poi.category.rawValue) · r\(Int(poi.radius)) м")
                    .font(.caption2).foregroundColor(OrionTheme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundColor(OrionTheme.textTertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Редактор точки

struct POIEditSheet: View {
    let poi: PointOfInterest?
    let currentLat: Double?
    let currentLon: Double?
    let onSave: (PointOfInterest) -> Void

    @ObservedObject private var appearance = OrionAppearance.shared
    @Environment(\.dismiss) var dismiss

    @State private var name = ""
    @State private var category: PointOfInterest.Category = .home
    @State private var latText = ""
    @State private var lonText = ""
    @State private var radius: Double = 150

    var isEditing: Bool { poi != nil }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        Double(latText) != nil && Double(lonText) != nil
    }

    /// Текущая выбранная координата (из полей), если валидна.
    var pinCoord: CLLocationCoordinate2D? {
        guard let la = Double(latText), let lo = Double(lonText) else { return nil }
        return CLLocationCoordinate2D(latitude: la, longitude: lo)
    }

    /// Центр карты при открытии: выбранная точка → текущая → Москва.
    var initialCenter: CLLocationCoordinate2D {
        if let p = pinCoord { return p }
        if let la = currentLat, let lo = currentLon {
            return CLLocationCoordinate2D(latitude: la, longitude: lo)
        }
        return CLLocationCoordinate2D(latitude: 55.7558, longitude: 37.6173)
    }

    var body: some View {
        NavigationView {
            ZStack {
                OrionTheme.backgroundGradient.ignoresSafeArea()
                Form {
                    Section {
                        Picker("Категория", selection: $category) {
                            ForEach(PointOfInterest.Category.allCases) { c in
                                Label(c.rawValue, systemImage: c.icon).tag(c)
                            }
                        }
                        .foregroundColor(OrionTheme.textPrimary)
                        .onChange(of: category) { newValue in
                            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                                name = newValue.defaultName
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Название").font(.caption).foregroundColor(OrionTheme.textSecondary)
                            TextField("напр. Дом", text: $name).foregroundColor(OrionTheme.textPrimary)
                        }
                        .padding(.vertical, 4)
                    } header: { Text(isEditing ? "Изменить точку" : "Новая точка") }

                    Section {
                        PickerMapView(coordinate: pinCoord, initialCenter: initialCenter) { picked in
                            latText = String(format: "%.5f", picked.latitude)
                            lonText = String(format: "%.5f", picked.longitude)
                        }
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                    } header: { Text("На карте") }
                     footer: { Text("Нажми на карту, чтобы поставить точку.") }

                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Широта").font(.caption).foregroundColor(OrionTheme.textSecondary)
                                TextField("55.7558", text: $latText)
                                    .keyboardType(.numbersAndPunctuation)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(OrionTheme.accent)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Долгота").font(.caption).foregroundColor(OrionTheme.textSecondary)
                                TextField("37.6173", text: $lonText)
                                    .keyboardType(.numbersAndPunctuation)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(OrionTheme.accent)
                            }
                        }

                        Button {
                            if let lat = currentLat, let lon = currentLon {
                                latText = String(format: "%.5f", lat)
                                lonText = String(format: "%.5f", lon)
                            }
                        } label: {
                            Label("Текущее местоположение", systemImage: "location.fill")
                                .foregroundColor(currentLat == nil ? OrionTheme.textSecondary : OrionTheme.accent)
                        }
                        .disabled(currentLat == nil)
                    } header: { Text("Координаты") }
                     footer: { Text(currentLat == nil ? "Координаты появятся после старта слежения." : "") }

                    Section {
                        VStack(alignment: .leading) {
                            Text("Радиус прибытия: \(Int(radius)) м")
                                .foregroundColor(OrionTheme.textPrimary)
                            Slider(value: $radius, in: 50...500, step: 10).tint(OrionTheme.accent)
                        }
                    } footer: { Text("Внутри радиуса — «на месте». Вопрос задаётся при подходе к внешнему кольцу (+400 м).") }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(isEditing ? "Изменить" : "Добавить")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.foregroundColor(OrionTheme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        let result = PointOfInterest(
                            id: poi?.id ?? UUID(),
                            name: name.trimmingCharacters(in: .whitespaces),
                            category: category,
                            latitude: Double(latText) ?? 0,
                            longitude: Double(lonText) ?? 0,
                            radius: radius
                        )
                        onSave(result)
                        dismiss()
                    }
                    .disabled(!isValid)
                    .foregroundColor(isValid ? OrionTheme.accent : OrionTheme.textSecondary)
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            if let p = poi {
                name = p.name
                category = p.category
                latText = String(format: "%.5f", p.latitude)
                lonText = String(format: "%.5f", p.longitude)
                radius = p.radius
            } else {
                category = .home
                name = ""
                if let lat = currentLat, let lon = currentLon {
                    latText = String(format: "%.5f", lat)
                    lonText = String(format: "%.5f", lon)
                }
            }
        }
    }
}

// MARK: - Карта-выбор координаты (тап ставит точку)

struct PickerMapView: UIViewRepresentable {
    var coordinate: CLLocationCoordinate2D?
    let initialCenter: CLLocationCoordinate2D
    let onPick: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        let region = MKCoordinateRegion(center: initialCenter,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
        map.setRegion(region, animated: false)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        map.addGestureRecognizer(tap)
        context.coordinator.map = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Маркер выбранной точки
        map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
        if let c = coordinate {
            let a = MKPointAnnotation()
            a.coordinate = c
            map.addAnnotation(a)
        }
    }

    final class Coordinator: NSObject {
        let onPick: (CLLocationCoordinate2D) -> Void
        weak var map: MKMapView?
        init(onPick: @escaping (CLLocationCoordinate2D) -> Void) { self.onPick = onPick }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let map = map else { return }
            let point = g.location(in: map)
            let coord = map.convert(point, toCoordinateFrom: map)
            onPick(coord)
        }
    }
}
