import SwiftUI
import UIKit

// MARK: - Model

enum PlantStatus: String, Codable, CaseIterable {
    case perfectlyFine
    case needsWatering
    case withering
}

struct PlantMetrics: Codable, Equatable {
    var humidity: Int            // %
    var temperature: Double      // °C  (ТЕПЕРЬ Double)
    var light: Int               // lm
    var reservoir: Int           // % (стабильно)
    var bioelectricity_mV: Double // mV

    private enum CodingKeys: String, CodingKey {
        case humidity, temperature, light, reservoir, bioelectricity_mV
    }

    init(humidity: Int, temperature: Double, light: Int, reservoir: Int, bioelectricity_mV: Double = 3.43) {
        self.humidity = humidity
        self.temperature = temperature
        self.light = light
        self.reservoir = reservoir
        self.bioelectricity_mV = bioelectricity_mV
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        humidity = try c.decode(Int.self, forKey: .humidity)
        // если в старом сохранении температура была Int — прочтем как Int и конвертируем
        if let t = try? c.decode(Double.self, forKey: .temperature) {
            temperature = t
        } else if let tInt = try? c.decode(Int.self, forKey: .temperature) {
            temperature = Double(tInt)
        } else {
            temperature = 24.5
        }
        light = try c.decode(Int.self, forKey: .light)
        reservoir = try c.decode(Int.self, forKey: .reservoir)
        bioelectricity_mV = try c.decodeIfPresent(Double.self, forKey: .bioelectricity_mV) ?? 3.43
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(humidity, forKey: .humidity)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(light, forKey: .light)
        try c.encode(reservoir, forKey: .reservoir)
        try c.encode(bioelectricity_mV, forKey: .bioelectricity_mV)
    }
}

struct Plant: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var status: PlantStatus
    var comment: String
    var imageData: Data?
    var metrics: PlantMetrics?

    init(id: UUID = UUID(),
         name: String,
         status: PlantStatus = .perfectlyFine,
         comment: String = "",
         imageData: Data? = nil,
         metrics: PlantMetrics? = nil)
    {
        self.id = id
        self.name = name
        self.status = status
        self.comment = comment
        self.imageData = imageData
        self.metrics = metrics
    }

    func matches(_ q: String) -> Bool {
        guard !q.isEmpty else { return true }
        return name.lowercased().contains(q.lowercased())
    }
}

// MARK: - Persistence

private enum PlantsPersistence {
    private static let key = "plants_store_v3"

    static func load() -> [Plant] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Plant].self, from: data)) ?? []
    }

    static func save(_ plants: [Plant]) {
        if let data = try? JSONEncoder().encode(plants) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - ViewModel
import Combine
/// Хранилище/логика растений + «дышащие» сенсоры
final class PlantsVM: ObservableObject {

    // Публичное состояние
    @Published var plants: [Plant] = []

    // Автосейв
    private var autosave: AnyCancellable?

    // Таймер «живых» сенсоров
    private var ticker: AnyCancellable?

    // MARK: - Init
    init() {
        // загрузка из диска (или примеры)
        let loaded = PlantsPersistence.load()
        self.plants = loaded.isEmpty ? Plant.samples : loaded

        // автосейв c дебаунсом
        autosave = $plants
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { PlantsPersistence.save($0) }

        // можно запускать лайв-сенсоры сразу
        startLiveSensors()
    }

    deinit {
        ticker?.cancel()
        autosave?.cancel()
    }

    // MARK: - CRUD
    func add(name: String,
             status: PlantStatus = .perfectlyFine,
             comment: String = "",
             imageData: Data?) {
        let new = Plant(name: name,
                        status: status,
                        comment: comment,
                        imageData: imageData)
        plants.append(new)
    }

    func updateImage(for id: UUID, data: Data) {
        if let idx = plants.firstIndex(where: { $0.id == id }) {
            plants[idx].imageData = data
        }
    }

    func update(_ plant: Plant) {
        if let idx = plants.firstIndex(where: { $0.id == plant.id }) {
            plants[idx] = plant
        }
    }

    func delete(_ id: UUID) {
        plants.removeAll { $0.id == id }
    }

    // MARK: - Живые сенсоры (каждые ~3 сек)
    func startLiveSensors() {
        ticker?.cancel()
        ticker = Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tickSensors()
            }
    }
    // MARK: - Search filtering
    func filteredIndices(for query: String) -> [Int] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return Array(plants.indices) }
        return plants.indices.filter { idx in
            plants[idx].name.lowercased().contains(q)
            // при желании: || plants[idx].comment.lowercased().contains(q)
        }
    }


    func stopLiveSensors() {
        ticker?.cancel()
        ticker = nil
    }

    private func tickSensors() {
        // Узкие коридоры
        let hMin = 74.0,  hMax = 76.0,  hStep = 0.15       // %
        let tMin = 24.2,  tMax = 24.8,  tStep = 0.05      // °C
        let lMin = 8300.0, lMax = 8600.0, lStep = 40.0     // lm
        let rStable = 70                                    // %
        let beMin = 3.410, beMax = 3.522, beStep = 0.010   // mV

        for i in plants.indices {
            guard var m = plants[i].metrics else { continue }

            let nextH  = clamp(moving: Double(m.humidity),      min: hMin, max: hMax, maxStep: hStep)
            let nextT  = clamp(moving: m.temperature,            min: tMin, max: tMax, maxStep: tStep)
            let nextL  = clamp(moving: Double(m.light),          min: lMin, max: lMax, maxStep: lStep)
            let nextBE = clamp(moving: m.bioelectricity_mV,      min: beMin, max: beMax, maxStep: beStep)

            m.humidity = Int(round(nextH))
            m.temperature = (nextT * 10).rounded() / 10               // 1 знак
            m.light = Int(round(nextL))
            m.reservoir = rStable
            m.bioelectricity_mV = (nextBE * 1000).rounded() / 1000    // 3 знака

            withAnimation(.easeInOut(duration: 0.9)) {
                plants[i].metrics = m
            }
        }
    }

    // маленький «рандом-вок» с зажимом в коридор
    private func clamp(moving current: Double, min: Double, max: Double, maxStep: Double) -> Double {
        var delta = Double.random(in: -maxStep...maxStep)
        let next = current + delta
        if next < min { return min + abs(delta)*0.3 }
        if next > max { return max - abs(delta)*0.3 }
        return next
    }
}

// MARK: - Tokens & small UI bits

private struct StatusToken: Identifiable {
    let id = UUID()
    let text: String
    let tint: Color
}

private func tokens(for m: PlantMetrics) -> [StatusToken] {
    var out: [StatusToken] = []
    if m.reservoir   < 20 { out.append(.init(text: "reservoir low",       tint: .orange)) }
    if m.humidity    < 35 { out.append(.init(text: "low humidity",         tint: .orange)) }
    if m.light       < 200 { out.append(.init(text: "insufficient light",  tint: .orange)) }
    if m.temperature > 35 { out.append(.init(text: "too hot",              tint: .red)) }
    if m.temperature < 10 { out.append(.init(text: "too cold",             tint: .red)) }
    if out.isEmpty { out.append(.init(text: "perfectly fine", tint: .green)) }
    return out
}

private func primaryToken(for m: PlantMetrics) -> StatusToken { tokens(for: m).first! }

private struct StatusChip: View {
    let token: StatusToken
    var body: some View {
        Text(token.text)
            .font(.subheadline)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(token.tint.opacity(0.18), in: Capsule())
            .foregroundStyle(token.tint)
            .allowsHitTesting(false)
    }
}

private struct MetricPill: View {
    let title: String
    let value: String
    var body: some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.14), in: Capsule())
        .fixedSize()             // важное: не расширять по горизонтали
        .contentShape(Capsule())
        .allowsHitTesting(false)
    }
}

// === MARK: Blooming helpers (FILE-SCOPE, not inside any struct) ===

import SwiftUI

/// clamp в 0...1
private func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

/// Реалистичная оценка расцвета по сенсорам (0...1)
private func bloomingScore(for m: PlantMetrics) -> Double {
    let h = Double(m.humidity)
    let humidity = clamp01(1 - abs(h - 55) / 25)

    let t = Double(m.temperature)
    let temp = clamp01(1 - abs(t - 24) / 7)

    let l = max(1.0, Double(m.light))
    let logL = log10(l)
    let light = clamp01((logL - log10(300)) / (log10(10000) - log10(300)))

    let r = Double(m.reservoir)
    let reservoir = clamp01((r - 20) / 60)

    // NEW: целевой «хороший» диапазон 3.0…4.0 mV (пик около 3.5)
    let be = m.bioelectricity_mV
    let bio = clamp01(1 - abs(be - 3.5) / 0.8)   // мягкий колокол

    // маленький вес для биоэлектричества
    return clamp01(0.28*humidity + 0.28*temp + 0.28*light + 0.10*reservoir + 0.06*bio)
}


/// Широкая полоса Blooming под “пилюлями”
private struct BloomBar: View {
    let score: Double   // 0...1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.green.opacity(0.12))

                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [.red, .yellow, .green],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(14, score * geo.size.width))

                HStack {
                    Text("Blooming")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(Int(score * 100))%")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(height: 44)
        .accessibilityLabel("Blooming \(Int(score*100)) percent")
    }
}


// 2) Простой flow-layout для переноса по строкам
private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    let runSpacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 8, runSpacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.runSpacing = runSpacing
        self.content = content
    }

    var body: some View {
        GeometryReader { geo in
            self.generateContent(in: geo.size.width)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func generateContent(in totalWidth: CGFloat) -> some View {
        var width: CGFloat = 0
        var rows: [[AnyView]] = [[]]

        let views = content().asArray()
        for v in views {
            let size = v.intrinsicSize()
            if width + size.width + spacing > totalWidth, !rows.last!.isEmpty {
                rows.append([])
                width = 0
            }
            rows[rows.count-1].append(v)
            width += size.width + spacing
        }

        return VStack(alignment: .leading, spacing: runSpacing) {
            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: spacing) { ForEach(0..<rows[r].count, id: \.self) { rows[r][$0] } }
            }
        }
    }
}
private extension View {
    func asAnyView() -> AnyView { AnyView(self) }
    func intrinsicSize() -> CGSize {
        let controller = UIHostingController(rootView: self)
        return controller.sizeThatFits(in: UIView.layoutFittingCompressedSize)
    }
    func asArray() -> [AnyView] { [self.asAnyView()] }
}
private extension TupleView {
    func asArray() -> [AnyView] {
        Mirror(reflecting: value).children.compactMap {
            ($0.value as? View)?.asAnyView() ?? (AnyView(_fromValue: $0.value) )
        }
    }
}
// MARK: - ImagePicker bridge

struct ImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    @Binding var image: UIImage?

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.delegate = context.coordinator
        vc.sourceType = sourceType
        vc.allowsEditing = true
        return vc
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let key: UIImagePickerController.InfoKey = .editedImage
            if let img = info[key] as? UIImage ?? info[.originalImage] as? UIImage {
                parent.image = img
            }
            picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - Add Plant

struct AddPlantView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var comment = ""
    @State private var tempImage: UIImage?
    @State private var showPicker = false
    @State private var source: UIImagePickerController.SourceType = .photoLibrary

    var onCreate: (String, String, UIImage?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Plant name", text: $name)
                }
                Section("Photo") {
                    HStack {
                        Button("Choose from library") { source = .photoLibrary; showPicker = true }
                        Spacer()
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button("Take photo") { source = .camera; showPicker = true }
                        }
                    }
                    if let img = tempImage {
                        Image(uiImage: img)
                            .resizable().scaledToFit()
                            .frame(maxHeight: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                Section("Comments") {
                    TextField("Optional note", text: $comment, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("New plant")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onCreate(name, comment, tempImage)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .bold()
                }
            }
            .sheet(isPresented: $showPicker) {
                ImagePicker(sourceType: source, image: $tempImage)
            }
        }
    }
}

// MARK: - Plant details (read-only sensors)

// ЗАМЕНИ свою PlantDetailsView на эту (если уже такая – оставь, тут гарантированно без Stepper)

struct PlantDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Plant

    let onSave: (Plant) -> Void
    let onChangePhoto: (UIImage) -> Void
    let onDelete: (Plant) -> Void          // ← добавили

    @State private var showPicker = false
    @State private var source: UIImagePickerController.SourceType = .photoLibrary
    @State private var tempImage: UIImage?
    @State private var showDeleteConfirm = false

    init(
        plant: Plant,
        onSave: @escaping (Plant) -> Void,
        onChangePhoto: @escaping (UIImage) -> Void,
        onDelete: @escaping (Plant) -> Void      // ← добавили
    ) {
        _draft = State(initialValue: plant)
        self.onSave = onSave
        self.onChangePhoto = onChangePhoto
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                // PHOTO
                Section("Photo") {
                    HStack {
                        Button("Choose from library") {
                            source = .photoLibrary
                            showPicker = true
                        }
                        Spacer()
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button("Take photo") {
                                source = .camera
                                showPicker = true
                            }
                        }
                    }
                    if let data = draft.imageData, let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable().scaledToFit()
                            .frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }

                // NAME
                Section("Name") {
                    TextField("Plant name", text: $draft.name)
                }

                // COMMENTS
                Section("Comments") {
                    TextField("Optional note", text: $draft.comment, axis: .vertical)
                        .lineLimit(3...6)
                }

                // SENSORS (READ-ONLY)
                Section("Sensors (read-only)") {
                    if let m = draft.metrics {
                        FlowLayout(spacing: 8, runSpacing: 8) {
                            MetricPill(title: "Humidity",  value: "\(m.humidity)%")
                            MetricPill(title: "Temp",      value: String(format: "%.1f°C", m.temperature))
                            MetricPill(title: "Light",     value: "\(m.light) lm")
                            MetricPill(title: "Reservoir", value: "\(m.reservoir)%")
                            MetricPill(title: "Bioelectricity",
                                       value: String(format: "%.3f mV", m.bioelectricity_mV))


                        }
                        BloomBar(score: bloomingScore(for: m))
                    } else {
                        Text("No sensors connected").foregroundStyle(.secondary)
                    }
                }
                //delete
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete plant", systemImage: "trash")
                            .fontWeight(.semibold)
                    }
                }
            }
            .navigationTitle("Plant details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                    .bold()
                }
            }
            .sheet(isPresented: $showPicker) {
                ImagePicker(sourceType: source, image: $tempImage)
                    .onDisappear {
                        if let img = tempImage {
                            onChangePhoto(img)
                            draft.imageData = img.jpegData(compressionQuality: 0.9)
                            tempImage = nil
                        }
                    }
            }
            .confirmationDialog(
                "Delete this plant?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    onDelete(draft)
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            }
        }
    }
}



// MARK: - Card

// ЗАМЕНИ свою текущую PlantCardView на эту

struct PlantCardView: View {
    @EnvironmentObject private var vm: PlantsVM

    let plant: Plant
    var onPickImage: (UIImage) -> Void

    @State private var showPicker = false
    @State private var showSourceMenu = false
    @State private var source: UIImagePickerController.SourceType = .photoLibrary
    @State private var tempImage: UIImage?

    @State private var showDetails = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // сама карточка
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {

                    // Фото (тап по пустому — выбрать фото)
                    avatar

                    VStack(alignment: .leading, spacing: 10) {
                        // Название
                        Text(plant.name)
                            .font(.system(size: 28, weight: .bold, design: .default))

                        // Заголовок для сенсоров
                        Text("Sensors:")
                            .font(.headline)

                        // Сенсоры — на карточке, только показ
                        if let m = plant.metrics {
                            VStack(alignment: .leading, spacing: 10) {
                                // маленькие пилюли
                                FlowLayout(spacing: 8, runSpacing: 8) {
                                    MetricPill(title: "Humidity",  value: "\(m.humidity)%")
                                    MetricPill(title: "Temp",      value: "\(m.temperature)°C")
                                    MetricPill(title: "Light",     value: "\(m.light) lm")
                                    MetricPill(title: "Reservoir", value: "\(m.reservoir)%")
                                    MetricPill(title: "Bioelectricity", value: String(format: "%.2f mV", m.bioelectricity_mV))

                                }

                                // большая широкая полоса "Blooming"
                                BloomBar(score: bloomingScore(for: m))
                            }
                        } else {
                            Text("No sensors connected")
                                .foregroundStyle(.secondary)
                        }

                    }

                    Spacer()

                    // Карандаш — открывает меню (детали)
                    Button { showDetails = true } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(Color.blue)
                            .imageScale(.medium)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit")
                }

                // Комментарий
                Text(plant.comment.isEmpty ? "No comment added" : plant.comment)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))

            // GPS бейдж слева сверху — как раньше
            GPSBadge()
                .padding(.leading, 16)
                .padding(.top, 16)
        }
        // Детальный экран (read-only сенсоры, без плюс/минус)
        .sheet(isPresented: $showDetails) {
            PlantDetailsView(
                plant: plant,
                onSave: { updated in
                    vm.update(updated)
                },
                onChangePhoto: { img in
                    if let data = img.jpegData(compressionQuality: 0.9) {
                        vm.updateImage(for: plant.id, data: data)
                    }
                },
                onDelete: { doomed in
                    vm.delete(doomed.id)               // ← удаляем в VM
                }
            )
        }
        // Пикер для аватарки (тап по фото/пустому фото)
        .sheet(isPresented: $showPicker) {
            ImagePicker(sourceType: source, image: $tempImage)
                .onDisappear {
                    if let img = tempImage {
                        onPickImage(img)
                        tempImage = nil
                    }
                }
        }
        .confirmationDialog("Add photo", isPresented: $showSourceMenu) {
            Button("Choose from library") { source = .photoLibrary; showPicker = true }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take photo") { source = .camera; showPicker = true }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // Фото с обработкой тапа
    private var avatar: some View {
        Group {
            if let data = plant.imageData, let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color.secondary.opacity(0.12))
                    Image(systemName: "camera")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 120, height: 120)
        .clipShape(Circle())
        .contentShape(Circle())
        .onTapGesture { showSourceMenu = true }
        .padding(.top, 40)              // ← вот это добавь: фото станет чуть ниже, GPS больше не перекрывается
    }
}

private struct GPSBadge: View {
    @State private var isAlert = false  // false = yellow, true = red

    var body: some View {
        Text("GPS")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                (isAlert ? Color.red.opacity(0.26) : Color.yellow.opacity(0.26)),
                in: Capsule()
            )
            .foregroundStyle(isAlert ? Color.red : Color.orange)
            .onAppear {
                // бесконечное мигание
                Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
                    withAnimation(.easeInOut(duration: 0.8)) {
                        isAlert.toggle()
                    }
                }
            }
            .accessibilityLabel("GPS searching")
    }
}



// MARK: - List

struct PlantsListView: View {
    @EnvironmentObject var vm: PlantsVM
    @State private var searchText = ""
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(vm.filteredIndices(for: searchText), id: \.self) { idx in
                        PlantCardView(plant: vm.plants[idx]) { image in
                            if let data = image.jpegData(compressionQuality: 0.9) {
                                vm.updateImage(for: vm.plants[idx].id, data: data)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .navigationTitle("Your Plants")
            .titleDisplayModeLargeCompat()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus.circle.fill").imageScale(.large)
                    }
                    .accessibilityLabel("Add plant")
                }
            }
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search by name")
            .sheet(isPresented: $showAdd) {
                AddPlantView { name, comment, image in
                    var data: Data? = nil
                    if let img = image { data = img.jpegData(compressionQuality: 0.9) }
                    vm.add(name: name, comment: comment, imageData: data)
                }
            }
        }
    }
}

// MARK: - Account (как был)

struct AccountViewV2: View {
    @State private var isPrimary = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "person.crop.circle")
                            .resizable().frame(width: 64, height: 64)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(isPrimary ? "Egor" : "Guest").font(.headline)
                            Text(isPrimary ? "Email: c…@gmail.com" : "Email: guest@example.com")
                                .foregroundStyle(.secondary)
                            Text("Phone: +39 … 0829").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { } label: { Image(systemName: "pencil") }
                    }

                    Button("Change account") { isPrimary.toggle() }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)

                HStack(spacing: 12) {
                    statCard(title: "You've made",
                             value: "\(monthlyTotal)",
                             subtitle: "of our cryptocurrency last month")

                    statCard(title: "Overall",
                             value: "2,405",
                             subtitle: "+20% compared to last month")
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Earning history").font(.headline)
                    ForEach(historyItems()) { item in
                        HStack(spacing: 12) {
                            Image(systemName: "bitcoinsign.circle.fill").imageScale(.large)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("+\(item.amount) \(item.reason)").font(.subheadline)
                                Text(item.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .navigationTitle("Account")
            .titleDisplayModeLargeCompat()
        }
    }

    private func statCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(size: 34, weight: .bold, design: .rounded))
            Text(subtitle).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var monthlyTotal: Int {
        historyItems().reduce(0) { $0 + $1.amount }
    }
}

private struct EarningItem: Identifiable {
    let id = UUID()
    let amount: Int
    let reason: String
    let date: Date
}

private func historyItems() -> [EarningItem] {
    let patterns: [(Int, String)] = [
        (1, "For watering plants"),
        (20, "Your plant has bloomed!"),
        (3, "Plant covered from sunlight")
    ]
    func pick() -> (Int, String) { patterns.randomElement()! }

    return (0..<12).map { _ in
        let p = pick()
        let daysAgo = Int.random(in: 0...30)
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!
        return EarningItem(amount: p.0, reason: p.1, date: date)
    }
    .sorted { $0.date > $1.date }
}

// MARK: - Root tabs

struct RootView: View {
    @EnvironmentObject var vm: PlantsVM
    var body: some View {
        TabView {
            PlantsListView()
                .tabItem { Label("Home", systemImage: "house") }

            AccountViewV2()
                .tabItem { Label("Account", systemImage: "person") }

            // Заглушка под Crypto (оставь свою, если есть)
            
            CryptoDashboardView()
                .tabItem { Label("Crypto", systemImage: "bitcoinsign.circle") }
        }
    }
}

// MARK: - Helpers

extension View {
    @ViewBuilder
    func titleDisplayModeLargeCompat() -> some View {
        if #available(iOS 17.0, *) {
            self.toolbarTitleDisplayMode(.large)
        } else {
            self.navigationBarTitleDisplayMode(.large)
        }
    }
}

// MARK: - Sample

extension Plant {
    static let samples: [Plant] = [
        .init(
            name: "Plant1",
            status: .perfectlyFine,
            comment: "No comment added",
            imageData: nil,
            metrics: .init(humidity: 75, temperature: 25, light: 8500, reservoir: 70, bioelectricity_mV: 3.43)
        )
    ]
}
