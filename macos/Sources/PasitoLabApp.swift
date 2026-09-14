import SwiftUI
import AppKit

final class LabAppDelegate: NSObject, NSApplicationDelegate {
    var lab: BluetoothLab?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        lab?.shutdown(); return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main struct PasitoLabApp: App {
    @NSApplicationDelegateAdaptor(LabAppDelegate.self) private var delegate
    @State private var lab = BluetoothLab()
    var body: some Scene {
        Window("Pasito Lab", id: "main") {
            MainView(lab: lab)
                .onAppear { delegate.lab = lab }
                .frame(minWidth: 1020, minHeight: 700)
        }
        .defaultSize(width: 1220, height: 820)
        Window("Pasito Lab — Debug", id: "debug") {
            LogView(lab: lab).padding(20).frame(minWidth: 820, minHeight: 500)
        }.defaultSize(width: 1100, height: 650)
    }
}

enum LabPage: String, CaseIterable, Identifiable {
    case emulator = "Эмулятор", scanner = "Сканер", repetition = "Постоянный повтор", log = "Журнал"
    var id: String { rawValue }
    var icon: String {
        switch self { case .emulator: return "antenna.radiowaves.left.and.right"; case .scanner: return "dot.radiowaves.left.and.right"; case .repetition: return "repeat"; case .log: return "terminal" }
    }
}
struct MainView: View {
    @Bindable var lab: BluetoothLab
    @State private var page: LabPage = .emulator
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PASITO LAB").font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("BLUETOOTH WORKBENCH").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.8).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).padding(.top, 24)
                List(LabPage.allCases, selection: $page) { p in
                    Label(p.rawValue, systemImage: p.icon).padding(.vertical, 5).tag(p)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 10) {
                    Label(lab.bluetooth, systemImage: lab.radioReady ? "circle.fill" : "exclamationmark.circle")
                        .font(.caption).foregroundStyle(lab.radioReady ? Color.green : .orange)
                    Text("Один BLE-эмулятор на адаптере").font(.caption2).foregroundStyle(.secondary)
                    if lab.repeating {
                        Button("Остановить повтор", systemImage: "stop.fill") { lab.stopRepeating() }
                    }
                    Button("Окно дебага", systemImage: "macwindow.on.rectangle") { openWindow(id: "debug") }
                }.padding(16)
            }
            .navigationSplitViewColumnWidth(min: 205, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if !lab.lastError.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(lab.lastError).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button("Скрыть") { lab.lastError = "" }
                    }.padding(12).background(.orange.opacity(0.10))
                }
                if !lab.logFailure.isEmpty {
                    Text("Ошибка сохранения журнала: \(lab.logFailure)").font(.callout).foregroundStyle(.red).padding(8)
                }
                switch page {
                case .emulator: EmulatorView(lab: lab, page: $page)
                case .scanner: ScannerView(lab: lab)
                case .repetition: RepeatView(lab: lab)
                case .log: LogView(lab: lab).padding(24)
                }
            }
            .toolbar {
                ToolbarItem { Button("Экспорт журнала", systemImage: "square.and.arrow.up") { lab.exportLog() } }
                ToolbarItem { Button("Debug", systemImage: "terminal") { openWindow(id: "debug") }.keyboardShortcut("d", modifiers: [.command, .shift]) }
            }
        }
        .tint(.teal)
    }
}
struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.08)))
    }
}
struct EmulatorView: View {
    @Bindable var lab: BluetoothLab
    @Binding var page: LabPage
    @AppStorage("preset") private var presetID = "observed76"
    var preset: EmulatorPreset { EmulatorPreset.all.first { $0.id == presetID } ?? EmulatorPreset.all[0] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Эмулятор Pasito 3").font(.largeTitle.bold())
                    Text("Выберите пресет, запустите объявление и откройте Share на устройстве.").foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    statusTile("ЭМУЛЯТОР", lab.emulatorStatus, lab.advertising ? .green : .secondary)
                    statusTile("КЛИЕНТ", lab.connectionStatus, lab.connectedID != nil ? .teal : .secondary)
                }
                Panel(title: "Пресет получателя") {
                    Picker("Профиль", selection: $presetID) {
                        ForEach(EmulatorPreset.all) { p in Text(p.title).tag(p.id) }
                    }.disabled(lab.advertising || lab.emulatorStarting)
                    Text(preset.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button {
                            if lab.advertising || lab.emulatorStarting { lab.stopEmulator() } else { lab.startEmulator(preset) }
                        } label: {
                            Label(lab.advertising || lab.emulatorStarting ? "Остановить эмулятор" : "Запустить эмулятор", systemImage: lab.advertising || lab.emulatorStarting ? "stop.fill" : "play.fill")
                        }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!lab.radioReady)
                        if lab.emulatorStarting { ProgressView().controlSize(.small) }
                        Text("Имя в эфире: \(lab.activePreset?.name ?? preset.name)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Panel(title: "Приём с настоящего Pasito") {
                    Text("Запустите эмулятор, нажмите «Подключить и принять», затем отправьте профиль через Share на Pasito. Приём начнётся сразу после подключения.").font(.callout)
                    HStack {
                        Button("Открыть сканер", systemImage: "arrow.right") { page = .scanner }
                    }
                    Text("Выберите своё устройство в сканере и нажмите «Подключить и принять».").font(.caption).foregroundStyle(.secondary)
                }
                CustomConfigView(lab: lab)
                if !lab.receivedPowers.isEmpty {
                    Panel(title: "Последние полученные мощности · Вт") {
                        Text(lab.receivedPowers.map(String.init).joined(separator: " → "))
                            .font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                        Text("Из входящей записи 02 + 10 байт. Длительности неизвестны. Peer: \(lab.receivedPowerPeer)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    Panel(title: "GATT эмулятора") {
                        Text("0002  Write without response\n0003  Notify\n0004  Read · Write").font(.system(.callout, design: .monospaced)).lineSpacing(7)
                        Text("Текущее 0004: \(lab.controlPreview)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    Panel(title: "Что видит журнал") {
                        Text("Входящие записи, чтения и подписки; ответы и уведомления настоящего устройства. HEX сохраняется без преобразования.").font(.callout).foregroundStyle(.secondary)
                        Text("Один лишь входящий BLE-линк может не вызвать GATT-событий сервера. Для этого Pasito нужен и клиент.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Пресеты работают по одному. Имя LE-S052 вернуло видимость в Share; отдельные процессы на этом Mac объединяли объявления. RSSI и manufacturer data здесь не подменяются.").font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }.background(Color.primary.opacity(0.025))
    }
    private func statusTile(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.2).foregroundStyle(.secondary)
            Label(value, systemImage: "circle.fill").font(.callout.weight(.medium)).foregroundStyle(color)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}
struct ScannerView: View {
    @Bindable var lab: BluetoothLab
    @State private var selectedID: UUID?
    @State private var onlyCandidates = true
    @State private var query = ""
    @State private var cachedUUID = ""
    var visible: [SeenDevice] {
        lab.devices.filter { (!onlyCandidates || $0.reason != nil) && (query.isEmpty || ($0.name + $0.id.uuidString).localizedCaseInsensitiveContains(query)) }
            .sorted { ($0.rssi ?? -999) > ($1.rssi ?? -999) }
    }
    var selected: SeenDevice? { lab.devices.first { $0.id == (selectedID ?? lab.connectedID ?? lab.connectingID) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BLE-сканер").font(.largeTitle.bold())
                    Text("\(visible.count) в списке · \(lab.devices.count) обнаружено за сеанс").foregroundStyle(.secondary)
                }
                Spacer()
                if lab.scanning { ProgressView().controlSize(.small) }
                Button(lab.scanning ? "Остановить поиск" : "Начать поиск", systemImage: lab.scanning ? "stop.fill" : "magnifyingglass") {
                    if lab.scanning { lab.stopScan() } else { lab.startScan() }
                }.buttonStyle(.borderedProminent).disabled(!lab.radioReady)
            }
            HStack {
                TextField("Имя или UUID", text: $query).textFieldStyle(.roundedBorder)
                Toggle("Только кандидаты Pasito", isOn: $onlyCandidates).toggleStyle(.checkbox)
            }
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    if visible.isEmpty {
                        ContentUnavailableView("Устройств пока нет", systemImage: "dot.radiowaves.left.and.right", description: Text("Включите поиск. Чтобы видеть остальные BLE-устройства, снимите фильтр кандидатов."))
                    } else {
                        List(visible, selection: $selectedID) { device in
                            DeviceRow(device: device, connected: lab.connectedID == device.id).tag(device.id)
                        }.listStyle(.inset)
                    }
                }.frame(minWidth: 270, idealWidth: 320)
                ScrollView {
                    if let selected {
                        deviceDetail(selected)
                    } else {
                        ContentUnavailableView("Выберите устройство", systemImage: "cursorarrow.click", description: Text("Здесь появятся рекламные данные, GATT и доступные запросы."))
                    }
                }.frame(minWidth: 360)
            }
            Divider()
            DisclosureGroup("Подключение по UUID из кэша этого Mac") {
                HStack {
                    TextField("UUID", text: $cachedUUID).font(.system(.callout, design: .monospaced)).textFieldStyle(.roundedBorder)
                    Button("Подключить") { selectedID = UUID(uuidString: cachedUUID); lab.attachCached(cachedUUID) }
                        .disabled(!lab.radioReady || lab.connectedID != nil || lab.connectingID != nil)
                }.padding(.top, 8)
            }
        }.padding(24)
    }
    @ViewBuilder private func deviceDetail(_ device: SeenDevice) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(device.name).font(.title2.bold())
            Text(device.id.uuidString).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text(device.reason ?? "Не классифицирован как Pasito").font(.callout).foregroundStyle(.secondary)
            if device.id == lab.connectedID || device.id == lab.connectingID {
                Label(lab.connectionStatus, systemImage: "link").foregroundStyle(.teal)
                Button("Отключить") { lab.disconnect() }.disabled(lab.operation == "Отключение…")
                if lab.connectedID != nil {
                    Divider()
                    Text("Проверенные операции").font(.headline)
                    HStack {
                        Button("Читать 0004") { lab.readControl() }.disabled(!lab.canRead || !lab.operation.isEmpty)
                        Button(lab.notifying ? "Выключить Notify" : "Подписка 0003") { lab.toggleNotify() }.disabled(!lab.canNotify || !lab.operation.isEmpty)
                    }
                    HStack {
                        Button("Принять передачу · 0100") { lab.acceptTransfer() }.buttonStyle(.borderedProminent).disabled(!lab.canAccept || !lab.operation.isEmpty)
                        Button("RSSI") { lab.requestRSSI() }.disabled(!lab.operation.isEmpty)
                    }
                    Text("Подписка → запись 01 00 → чтение 0004. В нашем тесте Pasito показал успех; полный профиль ещё не расшифрован.").font(.caption).foregroundStyle(.secondary)
                    if !lab.operation.isEmpty { HStack { ProgressView().controlSize(.small); Text(lab.operation).font(.caption) } }
                    Text("Последний ответ 0004: \(lab.lastValue)").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    ForEach(lab.gatt) { c in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.uuid).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text(c.properties).font(.caption).foregroundStyle(.secondary)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            } else {
                Button("Подключить и принять", systemImage: "arrow.down.circle") { lab.connect(device.id, acceptAfterDiscovery: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!lab.radioReady || !device.connectable || lab.connectedID != nil || lab.connectingID != nil)
                Button("Подключить и прочитать GATT", systemImage: "link") { lab.connect(device.id) }
                    .disabled(!lab.radioReady || !device.connectable || lab.connectedID != nil || lab.connectingID != nil)
            }
            Divider()
            Text("Рекламные данные").font(.headline)
            Text("Manufacturer HEX").font(.caption).foregroundStyle(.secondary)
            Text(device.manufacturer.isEmpty ? "Не получены" : device.manufacturer).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Text("UUID сервисов: \(device.services.isEmpty ? "не объявлены" : device.services.joined(separator: ", "))").font(.caption).textSelection(.enabled)
            Text("RSSI — измеренный уровень сигнала, не расстояние. macOS показывает локальный UUID вместо MAC.").font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct DeviceRow: View {
    let device: SeenDevice
    let connected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(device.name).font(.headline).lineLimit(1)
                Spacer()
                Text(device.rssi.map { "\($0) dBm" } ?? "—").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text(connected ? "Подключён" : device.reason ?? "Другое BLE-устройство").font(.caption).foregroundStyle(connected ? .teal : .secondary).lineLimit(2)
            HStack {
                Text(String(device.id.uuidString.prefix(8))).font(.system(.caption2, design: .monospaced))
                Spacer()
                if let date = device.lastSeen { Text(date, style: .time).font(.caption2) } else { Text("Кэш").font(.caption2) }
            }.foregroundStyle(.tertiary)
        }.padding(.vertical, 7)
    }
}
struct LogView: View {
    @Bindable var lab: BluetoothLab
    @State private var source = "Все"
    @State private var search = ""
    @State private var selected: Int?
    @State private var paused = false
    @State private var frozen: [DebugEvent] = []
    var visible: [DebugEvent] {
        (paused ? frozen : lab.events).filter { (source == "Все" || $0.source == source) && (search.isEmpty || $0.json.localizedCaseInsensitiveContains(search)) }.reversed()
    }
    var detail: DebugEvent? { visible.first { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Журнал обмена").font(.title.bold())
                Spacer()
                Button(paused ? "Продолжить" : "Пауза экрана", systemImage: paused ? "play.fill" : "pause.fill") {
                    if !paused { frozen = lab.events }; paused.toggle()
                }
                Button("Экспорт") { lab.exportLog() }
                Button("Файл", systemImage: "folder") { lab.showLogs() }
            }
            HStack {
                Picker("Источник", selection: $source) {
                    ForEach(["Все", "emulator", "client", "scanner", "app"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 210)
                TextField("Поиск HEX, UUID или события", text: $search).textFieldStyle(.roundedBorder)
                Button("Очистить экран") { lab.clearVisibleLog(); frozen = []; selected = nil }
            }
            Text("Новые события сверху · на экране последние 2000 · JSONL хранит весь сеанс. Пауза останавливает только обновление окна.").font(.caption).foregroundStyle(.secondary)
            VSplitView {
                Table(visible, selection: $selected) {
                    TableColumn("Время") { e in Text(e.time, style: .time).font(.system(.caption, design: .monospaced)) }.width(70)
                    TableColumn("Источник", value: \.source).width(75)
                    TableColumn("Событие", value: \.event).width(min: 140, ideal: 200)
                    TableColumn("HEX", value: \.hex).width(min: 100, ideal: 260)
                    TableColumn("Peer", value: \.peer).width(min: 80, ideal: 120)
                }.frame(minHeight: 180)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Исходное событие · JSON").font(.headline)
                        Spacer()
                        Button("Копировать") {
                            guard let detail else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(detail.json, forType: .string)
                        }.disabled(detail == nil)
                    }
                    ScrollView([.vertical, .horizontal]) {
                        Text(prettyJSON(detail?.json) ?? "Выберите событие в таблице.")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(12).frame(minHeight: 140, idealHeight: 220)
            }
            Text("Значения из callback Core Bluetooth; это не перехват пакетов по радио. Advertising логируется не чаще раза в 5 секунд на устройство.").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func prettyJSON(_ text: String?) -> String? {
        guard let text, let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)), let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

struct CustomConfigView: View {
    @Bindable var lab: BluetoothLab
    @AppStorage("customDestination") private var destination = ""
    private var destinationID: UUID? { UUID(uuidString: destination.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var hex: String { configFrame(lab.draftPowers).map { payload($0)["hex"] as! String } ?? "Введите 10 целых чисел от 0 до 255 — по одному байту на ступень" }
    var body: some View {
        Panel(title: "Свой конфиг · Mac → Pasito") {
            Text("Десять значений с вводом числа. Лимит мощности снят; формат допускает целые 0–255 (один байт на ступень). Формат 02 + 10 байт наблюдался при получении; применение обратной записи устройством пока экспериментальное.")
                .font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                ForEach(0..<10) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Ступень \(index + 1)").font(.caption).foregroundStyle(.secondary)
                        PowerNumberField(value: $lab.draftPowers[index], stage: index + 1)
                    }.padding(10).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }.disabled(lab.repeating)
            HStack {
                Button("Из полученного") { if lab.receivedPowers.count == 10 { lab.draftPowers = lab.receivedPowers } }
                    .disabled(lab.receivedPowers.count != 10 || lab.repeating)
                Button("Все по 20 Вт") { lab.draftPowers = Array(repeating: 20, count: 10) }.disabled(lab.repeating)
                Spacer()
                Text(hex).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            HStack {
                TextField("UUID получателя на этом Mac", text: $destination).textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced)).disabled(lab.repeating)
                Menu("Из сканера") {
                    ForEach(lab.devices.filter { $0.connectable }) { device in
                        Button("\(device.name) · \(device.id.uuidString.prefix(8))") { destination = device.id.uuidString }
                    }
                }.disabled(lab.repeating)
            }
            HStack {
                Button("Отправить конфиг один раз", systemImage: "paperplane") {
                    if let id = destinationID { lab.sendCustom(to: id) }
                }.buttonStyle(.borderedProminent)
                    .disabled(destinationID == nil || configFrame(lab.draftPowers) == nil || !lab.radioReady || lab.repeating || !lab.operation.isEmpty || lab.connectingID != nil)
                Text("Подтверждений ATT: \(lab.transmittedConfigs)").font(.caption).foregroundStyle(.secondary)
            }
            Text("Настройки повторной отправки — в разделе «Постоянный повтор».")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PowerNumberField: View {
    @Binding var value: Int
    let stage: Int
    @State private var text = ""
    var body: some View {
        TextField("Число", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(.callout, design: .monospaced))
            .accessibilityLabel("Значение ступени \(stage)")
            .foregroundStyle((0...255).contains(value) ? Color.primary : Color.red)
            .onAppear { text = String(value) }
            .onChange(of: text) { _, newValue in
                value = Int(newValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Int.min
            }
            .onChange(of: value) { _, newValue in
                if newValue != Int.min && Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) != newValue { text = String(newValue) }
            }
    }
}

struct RepeatView: View {
    @Bindable var lab: BluetoothLab
    @AppStorage("customDestination") private var destination = ""
    @AppStorage("repeatInterval") private var interval = 5.0
    @AppStorage("repeatMode") private var mode = 0
    @AppStorage("repeatAllCandidates") private var allCandidates = false
    private var destinationID: UUID? { UUID(uuidString: destination.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Постоянный повтор").font(.largeTitle.bold())
                Text("Запросы и отправка конфигурации по расписанию внутри приложения.").foregroundStyle(.secondary)
                Panel(title: "Устройства") {
                    Picker("Охват", selection: $allCandidates) {
                        Text("Выбранное устройство").tag(false)
                        Text("Все кандидаты Pasito").tag(true)
                    }.pickerStyle(.segmented).disabled(lab.repeating)
                    if !allCandidates {
                        HStack {
                            TextField("UUID устройства", text: $destination).textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))
                            Menu("Из сканера") {
                                ForEach(lab.devices.filter { $0.reason != nil && $0.connectable }) { device in
                                    Button("\(device.name) · \(device.id.uuidString.prefix(8))") { destination = device.id.uuidString }
                                }
                            }
                        }.disabled(lab.repeating)
                    } else {
                        Text("Сканирование включается автоматически. Обход по очереди, одно подключение за раз. Новые кандидаты добавляются автоматически; перед отправкой проверяется точный сервис Pasito.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("Сейчас кандидатов: \(lab.repeatCandidates.count)").font(.headline)
                        ForEach(lab.repeatCandidates) { device in
                            HStack {
                                Text(device.name)
                                Spacer()
                                Text(device.id.uuidString).font(.system(.caption, design: .monospaced))
                            }.textSelection(.enabled)
                        }
                        Text("Учитываются объявления за последние 30 секунд и текущее подключённое устройство. Отсутствие кандидатов оставляет цикл в ожидании.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Panel(title: "Действие и интервал") {
                    Picker("Повторять", selection: $mode) {
                        Text("Запрашивать конфиг · 0100").tag(0)
                        Text("Отправлять свой конфиг · 02…").tag(1)
                    }.disabled(lab.repeating)
                    if mode == 1 {
                        Text(configFrame(lab.draftPowers).map { payload($0)["hex"] as! String } ?? "Ошибка: значения должны помещаться в один байт")
                            .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Text("Используется черновик из раздела «Эмулятор». При старте фиксируются данные. Применение обратной записи конфигурации на Pasito экспериментальное.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Stepper("Интервал: \(Int(interval)) с", value: $interval, in: 1...60, step: 1).disabled(lab.repeating)
                    Text("Если операция ещё выполняется, такт пропускается. Интервал общий для обхода, а не отдельный таймер на каждый девайс.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(lab.repeating ? "Остановить повтор" : "Запустить повтор", systemImage: lab.repeating ? "stop.fill" : "repeat") {
                            if lab.repeating { lab.stopRepeating() }
                            else { lab.startRepeating(to: destinationID, config: mode == 1, interval: interval, allCandidates: allCandidates) }
                        }.buttonStyle(.borderedProminent)
                            .disabled(!lab.repeating && (!lab.radioReady || (!allCandidates && destinationID == nil) || !lab.operation.isEmpty || lab.connectingID != nil || (mode == 1 && configFrame(lab.draftPowers) == nil)))
                        Text(lab.repeatStatus).font(.callout).foregroundStyle(lab.repeating ? .teal : .secondary)
                    }
                    Text("Ошибка или тайм-аут останавливают весь цикл. Ручное отключение, остановка эмулятора и выход также выключают повтор. Все действия и пропуски записываются в журнал.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28)
        }
    }
}
