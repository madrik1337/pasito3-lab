import Foundation
import CoreBluetooth
import Observation
import AppKit

struct EmulatorPreset: Identifiable, Hashable {
    let id: String
    let title: String
    let name: String
    let controlHex: String?
    let detail: String
    static let all: [Self] = [
        .init(id: "observed76", title: "LE-S052 · ответ 024C", name: "LE-S052", controlHex: "024c", detail: "Рабочее имя. Ответ 0004 из наблюдения при первой ступени 76 Вт. Это образец двух байтов, не полная DVW-кривая."),
        .init(id: "observed75", title: "LE-S052 · ответ 024B", name: "LE-S052", controlHex: "024b", detail: "Тот же GATT, ответ 0004 из наблюдения при первой ступени 75 Вт. При записи значение заменяется полученными байтами."),
        .init(id: "baseline", title: "LE-S052 · чистый логгер", name: "LE-S052", controlHex: nil, detail: "Чтение 0004 вернёт Request Not Supported до первой записи. Все входящие записи сохраняются в журнале."),
        .init(id: "nameTest", title: "TEST-76 · тест имени", name: "TEST-76", controlHex: "024c", detail: "Исследовательский пресет: видимость на Pasito не подтверждена. Для обычного приёма выберите LE-S052.")
    ]
}
struct SeenDevice: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int?
    var lastSeen: Date?
    var manufacturer: String
    var services: [String]
    var reason: String?
    var connectable: Bool
}
struct GATTItem: Identifiable {
    var id: String { service + uuid }
    let service: String
    let uuid: String
    let properties: String
}
struct DebugEvent: Identifiable {
    let id: Int
    let time: Date
    let source: String
    let event: String
    let peer: String
    let hex: String
    let json: String
}

// Both Core Bluetooth managers deliver delegates on the main queue.
// All observable state and file writes are confined to that same queue.
@Observable final class BluetoothLab: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, CBPeripheralManagerDelegate {
    var bluetooth = "Инициализация…"
    var radioReady = false
    var scanning = false
    var advertising = false
    var emulatorStarting = false
    var emulatorStatus = "Остановлен"
    var activePreset: EmulatorPreset?
    var devices: [SeenDevice] = []
    var gatt: [GATTItem] = []
    var events: [DebugEvent] = []
    var connectedID: UUID?
    var connectingID: UUID?
    var connectionStatus = "Нет подключения"
    var operation = ""
    var notifying = false
    var canRead = false
    var canNotify = false
    var canAccept = false
    var lastValue = "—"
    var lastError = ""
    var logURL: URL?
    var logFailure = ""
    var controlPreview = "Не задано"
    var draftPowers: [Int] = Array(repeating: 20, count: 10) {
        didSet { if configFrame(draftPowers) != nil { UserDefaults.standard.set(draftPowers, forKey: "draftPowers") } }
    }
    var repeating = false
    var repeatStatus = "Повтор выключен"
    private(set) var repeatAllCandidates = false
    @ObservationIgnored private var repeatLastTarget: UUID?
    @ObservationIgnored private var repeatRejected = Set<UUID>()
    @ObservationIgnored private var repeatOwnsScan = false
    var transmittedConfigs = 0
    @ObservationIgnored private var repeatTimer: Timer?
    @ObservationIgnored private var repeatPeer: UUID?
    @ObservationIgnored private var repeatFrame: Data?
    @ObservationIgnored private var pendingConfig: Data?
    var receivedPowers: [Int] = []
    var receivedPowerPeer = ""
    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var server: CBPeripheralManager!
    @ObservationIgnored private var peers: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var target: CBPeripheral?
    @ObservationIgnored private var control: CBCharacteristic?
    @ObservationIgnored private var notify: CBCharacteristic?
    @ObservationIgnored private var controlValue: Data?
    @ObservationIgnored private var wantedEmulator = false
    @ObservationIgnored private var registered = false
    @ObservationIgnored private var currentService: CBMutableService?
    @ObservationIgnored private var flow = AcceptanceFlow()
    @ObservationIgnored private var timeout: DispatchWorkItem?
    @ObservationIgnored private var lastAdvertisementLog: [UUID: Date] = [:]
    @ObservationIgnored private var file: FileHandle?
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private let session = UUID().uuidString
    @ObservationIgnored private var discoveryRemaining = 0
    @ObservationIgnored private var acceptOnConnect = false

    override init() {
        super.init()
        if let saved = UserDefaults.standard.array(forKey: "draftPowers") as? [Int], configFrame(saved) != nil { draftPowers = saved }
        do {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Pasito Lab/Logs", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("session-\(session).jsonl")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            file = try FileHandle(forWritingTo: url); logURL = url
        } catch { logFailure = error.localizedDescription }
        log("app", "session_started", ["note": "Core Bluetooth callbacks, not raw radio packets"])
        central = CBCentralManager(delegate: self, queue: .main)
        server = CBPeripheralManager(delegate: self, queue: .main)
    }
    func log(_ source: String, _ event: String, _ fields: [String: Any] = [:]) {
        sequence += 1
        let now = Date()
        var row = fields
        row["source"] = source; row["event"] = event; row["sequence"] = sequence
        row["session"] = session; row["timestamp"] = ISO8601DateFormatter().string(from: now)
        do {
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            let string = String(decoding: data, as: UTF8.self)
            let nested = fields["data"] as? [String: Any] ?? fields["response"] as? [String: Any]
            events.append(DebugEvent(id: sequence, time: now, source: source, event: event,
                                     peer: fields["peer"] as? String ?? "", hex: fields["hex"] as? String ?? nested?["hex"] as? String ?? "", json: string))
            if events.count > 2000 { events.removeFirst(events.count - 2000) }
            if let file { try file.write(contentsOf: data + Data([10])) }
        } catch { logFailure = error.localizedDescription }
    }
    func fail(_ text: String) { stopRepeating(); lastError = text; log("app", "error", ["message": text]) }
    func exportLog() {
        guard let url = logURL else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = url.lastPathComponent
        if panel.runModal() == .OK, let destination = panel.url {
            do { try file?.synchronize(); try Data(contentsOf: url).write(to: destination, options: .atomic) }
            catch { fail("Экспорт: \(error.localizedDescription)") }
        }
    }
    func showLogs() { if let logURL { NSWorkspace.shared.activateFileViewerSelecting([logURL]) } }
    func clearVisibleLog() { events.removeAll(); log("app", "view_cleared", ["file_preserved": true]) }
    func shutdown() {
        stopScan(); disconnect(); stopEmulator()
        log("app", "session_stopped"); try? file?.synchronize(); try? file?.close(); file = nil
    }
    private func stateName(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "Bluetooth включён"
        case .poweredOff: return "Bluetooth выключен"
        case .unauthorized: return "Нет разрешения Bluetooth — откройте настройки конфиденциальности macOS"
        case .unsupported: return "Bluetooth LE не поддерживается"
        case .resetting: return "Bluetooth перезапускается"
        default: return "Инициализация Bluetooth…"
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetooth = stateName(central.state); radioReady = central.state == .poweredOn && server?.state == .poweredOn; log("scanner", "bluetooth_state", ["state": central.state.rawValue])
        if central.state != .poweredOn { stopRepeating(); scanning = false; resetConnection() }
    }
    func startScan() {
        guard central.state == .poweredOn else { fail(bluetooth); return }
        scanning = true
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        log("scanner", "scan_started", ["filter": "all BLE; candidate filtering only in UI"])
    }
    func stopScan() { if repeating && repeatAllCandidates { stopRepeating() }; central?.stopScan(); if scanning { log("scanner", "scan_stopped") }; scanning = false }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let name = ad[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Без имени"
        let data = ad[CBAdvertisementDataManufacturerDataKey] as? Data
        let uuids = ((ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []) + (ad[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])).map(\.uuidString)
        let reason = candidateReason(name: name, manufacturer: data, services: uuids)
        let now = Date()
        let device = SeenDevice(id: id, name: name, rssi: RSSI.intValue == 127 ? nil : RSSI.intValue, lastSeen: now,
                                manufacturer: (data.map { payload($0)["hex"] as! String }) ?? "", services: uuids,
                                reason: reason, connectable: (ad[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true)
        peers[id] = peripheral
        if let i = devices.firstIndex(where: { $0.id == id }) {
            // Keep UI updates bounded while retaining the newest observation at most once a second.
            if now.timeIntervalSince(devices[i].lastSeen ?? .distantPast) >= 1 { devices[i] = device }
        } else {
            if devices.count >= 500, let oldest = devices.filter({ $0.id != connectedID && $0.id != connectingID }).min(by: { ($0.lastSeen ?? .distantPast) < ($1.lastSeen ?? .distantPast) }) {
                devices.removeAll { $0.id == oldest.id }; peers.removeValue(forKey: oldest.id); lastAdvertisementLog.removeValue(forKey: oldest.id)
            }
            devices.append(device)
        }
        if now.timeIntervalSince(lastAdvertisementLog[id] ?? .distantPast) >= 5 {
            lastAdvertisementLog[id] = now
            var fields: [String: Any] = ["peer": id.uuidString, "name": name, "rssi": RSSI, "services": uuids, "candidate": reason ?? "", "connectable": device.connectable]
            if let data { fields["manufacturer"] = payload(data) }
            if let serviceData = ad[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
                fields["service_data"] = Dictionary(uniqueKeysWithValues: serviceData.map { ($0.key.uuidString, payload($0.value)) })
            }
            log("scanner", "advertisement", fields)
        }
    }
    func attachCached(_ text: String, acceptAfterDiscovery: Bool = false) {
        guard central.state == .poweredOn else { fail(bluetooth); return }
        guard let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("Некорректный UUID устройства"); return }
        guard let peer = central.retrievePeripherals(withIdentifiers: [id]).first else { fail("UUID не найден в кэше этого Mac. Сначала найдите устройство сканером."); return }
        peers[id] = peer
        if !devices.contains(where: { $0.id == id }) {
            devices.append(SeenDevice(id: id, name: peer.name ?? "Устройство из кэша", rssi: nil, lastSeen: nil, manufacturer: "", services: [], reason: "Из кэша Mac — присутствие не проверено", connectable: true))
        }
        connect(id, acceptAfterDiscovery: acceptAfterDiscovery)
    }
    func connect(_ id: UUID, acceptAfterDiscovery: Bool = false) {
        guard connectedID == nil, connectingID == nil, central.state == .poweredOn, let peer = peers[id] else { return }
        acceptOnConnect = acceptAfterDiscovery; lastValue = "—"; target = peer; peer.delegate = self; connectingID = id; connectionStatus = "Подключение…"
        log("client", "connect_requested", ["peer": id.uuidString])
        central.connect(peer)
        armTimeout(seconds: 30, label: "Подключение")
    }
    func disconnect() {
        stopRepeating(); pendingConfig = nil
        timeout?.cancel()
        if let target {
            log("client", "disconnect_requested", ["peer": target.identifier.uuidString]); central.cancelPeripheralConnection(target)
            connectionStatus = "Отключение…"
            operation = "Отключение…"
        } else { resetConnection() }
    }
    private func resetConnection() {
        timeout?.cancel(); timeout = nil; flow.reset(); pendingConfig = nil; target = nil; control = nil; notify = nil
        connectedID = nil; connectingID = nil; notifying = false; canRead = false; canNotify = false; canAccept = false
        operation = ""; connectionStatus = "Нет подключения"; gatt = []; discoveryRemaining = 0; acceptOnConnect = false
    }
    private func armTimeout(seconds: Double = 12, label: String) {
        timeout?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fail("\(label): тайм-аут. Соединение отменено."); self.disconnect()
        }
        timeout = task; DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }
    private func finishOperation() { timeout?.cancel(); operation = ""; flow.reset() }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == target?.identifier else { return }
        connectedID = peripheral.identifier; connectingID = nil; connectionStatus = "Обнаружение GATT…"
        operation = "Обнаружение GATT"; log("client", "connected", ["peer": peripheral.identifier.uuidString])
        armTimeout(label: "Обнаружение GATT"); peripheral.discoverServices(nil)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("client", "connect_failed", ["peer": peripheral.identifier.uuidString, "error": error?.localizedDescription ?? "Неизвестная ошибка"])
        if peripheral.identifier == target?.identifier { fail(error?.localizedDescription ?? "Подключение не удалось"); resetConnection() }
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("client", "disconnected", ["peer": peripheral.identifier.uuidString, "error": error?.localizedDescription ?? ""])
        if peripheral.identifier == target?.identifier { resetConnection() }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == target?.identifier else { return }
        if let error { fail(error.localizedDescription); disconnect(); return }
        let services = peripheral.services ?? []
        log("client", "services", ["peer": peripheral.identifier.uuidString, "uuids": services.map { $0.uuid.uuidString }])
        discoveryRemaining = services.count
        if services.isEmpty {
            connectionStatus = "Сервисы не найдены"; finishOperation()
            if repeating && repeatAllCandidates {
                repeatRejected.insert(peripheral.identifier); pendingConfig = nil; acceptOnConnect = false
                log("client", "repeat_candidate_rejected", ["peer": peripheral.identifier.uuidString, "reason": "No services"])
                operation = "Пропуск кандидата…"; central.cancelPeripheralConnection(peripheral)
            }
        }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral.identifier == target?.identifier else { return }
        if let error { fail(error.localizedDescription) }
        for c in service.characteristics ?? [] {
            let p = c.properties
            let names: [String] = [(p.contains(.read) ? "Read" : ""), (p.contains(.write) ? "Write" : ""), (p.contains(.writeWithoutResponse) ? "Write without response" : ""), (p.contains(.notify) ? "Notify" : ""), (p.contains(.indicate) ? "Indicate" : "")].filter { !$0.isEmpty }
            gatt.append(GATTItem(service: service.uuid.uuidString, uuid: c.uuid.uuidString, properties: names.joined(separator: " · ")))
            log("client", "characteristic", ["peer": peripheral.identifier.uuidString, "service": service.uuid.uuidString, "uuid": c.uuid.uuidString, "properties": names])
            if service.uuid.uuidString == pasitoService {
                if c.uuid.uuidString == pasitoControl { control = c; canRead = p.contains(.read) }
                if c.uuid.uuidString == pasitoNotify { notify = c; canNotify = p.contains(.notify); notifying = c.isNotifying }
            }
        }
        discoveryRemaining -= 1
        if discoveryRemaining <= 0 {
            canAccept = canRead && canNotify && (control?.properties.contains(.write) == true)
            connectionStatus = control != nil ? "Подключён · сервис Pasito найден" : "Подключён · сервис Pasito не найден"
            finishOperation()
            if repeating && repeatAllCandidates && !(repeatFrame == nil ? canAccept : control?.properties.contains(.write) == true) {
                repeatRejected.insert(peripheral.identifier)
                log("client", "repeat_candidate_rejected", ["peer": peripheral.identifier.uuidString, "reason": "Required Pasito GATT characteristics missing; no command sent"])
                pendingConfig = nil; acceptOnConnect = false; operation = "Пропуск кандидата…"
                central.cancelPeripheralConnection(peripheral)
                return
            }
            if let frame = pendingConfig {
                pendingConfig = nil
                sendConfigFrame(frame)
            } else if acceptOnConnect {
                acceptOnConnect = false
                if canAccept { acceptTransfer() } else { fail("Нужные характеристики для приёма не найдены") }
            }
        }
    }
    func readControl() {
        guard operation.isEmpty, let target, let control, canRead else { return }
        operation = "Чтение 0004"; armTimeout(label: operation)
        log("client", "read_requested", ["peer": target.identifier.uuidString, "uuid": pasitoControl]); target.readValue(for: control)
    }
    func toggleNotify() {
        guard operation.isEmpty, let target, let notify, canNotify else { return }
        operation = "Изменение подписки"; armTimeout(label: operation)
        log("client", "subscribe_requested", ["peer": target.identifier.uuidString, "enabled": !notify.isNotifying, "uuid": pasitoNotify])
        target.setNotifyValue(!notify.isNotifying, for: notify)
    }
    func acceptTransfer() {
        guard operation.isEmpty, canAccept, let target, let notify else { return }
        operation = "Приём: подписка → 0100 → чтение"; armTimeout(label: operation)
        log("client", "accept_sequence_started", ["peer": target.identifier.uuidString, "note": "Observed sequence; full DVW decoding not available"])
        _ = flow.begin()
        if notify.isNotifying { perform(flow.notified(success: true)) }
        else { target.setNotifyValue(true, for: notify) }
    }
    private func perform(_ action: AcceptanceAction) {
        guard let target, let control else { return }
        if action == .write0100 {
            log("client", "write_requested", ["peer": target.identifier.uuidString, "uuid": pasitoControl, "hex": "0100", "write_type": "withResponse"])
            target.writeValue(Data([1, 0]), for: control, type: .withResponse)
        } else if action == .read {
            log("client", "read_after_accept_requested", ["peer": target.identifier.uuidString, "uuid": pasitoControl]); target.readValue(for: control)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == target?.identifier else { return }
        notifying = characteristic.isNotifying
        log("client", "subscription", ["peer": peripheral.identifier.uuidString, "uuid": characteristic.uuid.uuidString, "enabled": characteristic.isNotifying, "error": error?.localizedDescription ?? ""])
        if let error { fail(error.localizedDescription); finishOperation(); return }
        if flow.step == .notification {
            let action = flow.notified(success: characteristic.isNotifying)
            if action == .none { finishOperation() } else { perform(action) }
        } else if operation == "Изменение подписки" { finishOperation() }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == target?.identifier else { return }
        log("client", "write_ack", ["peer": peripheral.identifier.uuidString, "uuid": characteristic.uuid.uuidString, "att_success": error == nil, "error": error?.localizedDescription ?? "", "application_success_verified": false])
        if let error { fail(error.localizedDescription); finishOperation(); return }
        if operation == "Отправка конфига" {
            transmittedConfigs += 1
            log("client", "config_att_accepted", ["peer": peripheral.identifier.uuidString, "application_success_verified": false])
            finishOperation()
        } else { perform(flow.acknowledged(success: true)) }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == target?.identifier else { return }
        var fields: [String: Any] = ["peer": peripheral.identifier.uuidString, "uuid": characteristic.uuid.uuidString, "error": error?.localizedDescription ?? "", "value_present": error == nil && characteristic.value != nil]
        if error == nil, let value = characteristic.value {
            fields["data"] = payload(value)
            if characteristic.uuid.uuidString == pasitoControl { lastValue = payload(value)["hex"] as! String }
        }
        log("client", "value", fields)
        if let error { fail(error.localizedDescription) }
        if characteristic.uuid.uuidString == pasitoControl && (flow.step == .value || operation == "Чтение 0004") { finishOperation() }
    }
    func requestRSSI() {
        guard operation.isEmpty, let target, connectedID != nil else { return }
        operation = "Чтение RSSI"; armTimeout(label: operation); target.readRSSI()
        log("client", "rssi_requested", ["peer": target.identifier.uuidString])
    }
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard peripheral.identifier == target?.identifier else { return }
        log("client", "rssi", ["peer": peripheral.identifier.uuidString, "rssi": RSSI, "error": error?.localizedDescription ?? ""])
        if error == nil, let i = devices.firstIndex(where: { $0.id == peripheral.identifier }) { devices[i].rssi = RSSI.intValue == 127 ? nil : RSSI.intValue }
        if let error { fail(error.localizedDescription) }
        if operation == "Чтение RSSI" { finishOperation() }
    }

    // Timer captures one peer and one immutable config. Busy ticks are skipped, never queued.
    func sendCustom(to id: UUID) {
        guard !repeating, let frame = configFrame(draftPowers) else { return }
        sendOrConnect(id, frame: frame)
    }
    private func sendOrConnect(_ id: UUID, frame: Data?) {
        guard radioReady, operation.isEmpty, connectingID == nil else { return }
        if let connectedID {
            guard connectedID == id else { fail("Сначала отключите другое устройство"); return }
            if let frame { sendConfigFrame(frame) } else { acceptTransfer() }
        } else {
            if peers[id] == nil, let peer = central.retrievePeripherals(withIdentifiers: [id]).first { peers[id] = peer }
            guard peers[id] != nil else { fail("Устройство не найдено в кэше Mac"); return }
            connect(id, acceptAfterDiscovery: frame == nil)
            pendingConfig = frame
        }
    }
    private func sendConfigFrame(_ frame: Data) {
        guard operation.isEmpty, let target, target.state == .connected,
              let control, control.properties.contains(.write) else {
            fail("Характеристика 0004 с Write недоступна"); return
        }
        operation = "Отправка конфига"; armTimeout(label: operation)
        log("client", "custom_config_write", ["peer": target.identifier.uuidString, "uuid": pasitoControl,
            "data": payload(frame), "direction": "Mac → Pasito", "application_semantics": "experimental"])
        target.writeValue(frame, for: control, type: .withResponse)
    }
    var repeatCandidates: [SeenDevice] {
        let now = Date()
        return devices.filter {
            $0.reason != nil && $0.connectable && !repeatRejected.contains($0.id) &&
            ($0.id == connectedID || ($0.lastSeen.map { now.timeIntervalSince($0) <= 30 } ?? false))
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    func startRepeating(to id: UUID?, config: Bool, interval: Double, allCandidates: Bool = false) {
        guard !repeating, radioReady, interval.isFinite, (1...60).contains(interval),
              (allCandidates || id != nil), connectingID == nil, operation.isEmpty,
              (allCandidates || connectedID == nil || connectedID == id) else { return }
        guard !config || configFrame(draftPowers) != nil else { return }
        repeatPeer = id; repeatFrame = config ? configFrame(draftPowers) : nil
        repeatAllCandidates = allCandidates; repeatLastTarget = nil; repeatRejected.removeAll()
        repeatOwnsScan = allCandidates && !scanning
        if repeatOwnsScan { startScan() }
        repeating = true
        repeatStatus = "\(config ? "Конфиг" : "Запрос 0100") · каждые \(Int(interval)) с · \(allCandidates ? "все кандидаты" : String(id!.uuidString.prefix(8)))"
        log("client", "repeat_started", ["peer": id?.uuidString ?? "", "scope": allCandidates ? "all_candidates" : "selected", "mode": config ? "custom_config" : "request_0100", "interval_seconds": interval])
        repeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.repeatTick() }
        repeatTick()
    }
    private func repeatTick() {
        guard repeating, radioReady, operation.isEmpty, connectingID == nil else { return }
        let id = repeatAllCandidates ? nextRepeatTarget(repeatCandidates.map(\.id), after: repeatLastTarget) : repeatPeer
        guard let id else { repeatStatus = "Ожидание кандидатов Pasito · поиск включён"; return }
        if let target, target.identifier != id {
            operation = "Смена устройства…"
            central.cancelPeripheralConnection(target)
            return
        }
        repeatLastTarget = id
        repeatStatus = "\(repeatAllCandidates ? "Все кандидаты" : "Выбранное устройство") · \(id.uuidString.prefix(8))"
        log("client", "repeat_target", ["peer": id.uuidString, "scope": repeatAllCandidates ? "all_candidates" : "selected"])
        sendOrConnect(id, frame: repeatFrame)
    }
    func stopRepeating() {
        let wasRepeating = repeating
        repeatTimer?.invalidate(); repeatTimer = nil
        if repeating { log("client", "repeat_stopped", ["note": "An already submitted ATT write cannot be recalled"]) }
        repeating = false; repeatPeer = nil; repeatFrame = nil; repeatStatus = "Повтор выключен"
        repeatAllCandidates = false; repeatLastTarget = nil
        if repeatOwnsScan { stopScan() }; repeatOwnsScan = false
        // Cancel a pending connect so stopping cannot send a config later.
        pendingConfig = nil; acceptOnConnect = false
        if let target, connectingID != nil || (wasRepeating && !operation.isEmpty) {
            flow.reset(); operation = "Отключение…"
            central.cancelPeripheralConnection(target)
        }
    }

    // MARK: Peripheral emulator
    func startEmulator(_ preset: EmulatorPreset) {
        guard server.state == .poweredOn, !wantedEmulator else { return }
        wantedEmulator = true; emulatorStarting = true; activePreset = preset
        controlValue = preset.controlHex.flatMap(parseHex); controlPreview = preset.controlHex ?? "Не задано"
        emulatorStatus = "Регистрация GATT…"
        let service = CBMutableService(type: CBUUID(string: pasitoService), primary: true)
        service.characteristics = [
            CBMutableCharacteristic(type: CBUUID(string: pasitoNotify), properties: [.notify], value: nil, permissions: []),
            CBMutableCharacteristic(type: CBUUID(string: pasitoRX), properties: [.writeWithoutResponse], value: nil, permissions: [.writeable]),
            CBMutableCharacteristic(type: CBUUID(string: pasitoControl), properties: [.read, .write], value: nil, permissions: [.readable, .writeable])
        ]
        registered = true; currentService = service
        log("emulator", "start_requested", ["preset": preset.id, "name": preset.name, "control_hex": preset.controlHex ?? "unset"])
        server.add(service)
    }
    func stopEmulator() {
        stopRepeating()
        wantedEmulator = false; server?.stopAdvertising(); server?.removeAllServices(); registered = false; currentService = nil
        if advertising || emulatorStarting { log("emulator", "stopped") }
        advertising = false; emulatorStarting = false; emulatorStatus = "Остановлен"; activePreset = nil
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        radioReady = peripheral.state == .poweredOn && central?.state == .poweredOn
        log("emulator", "bluetooth_state", ["state": peripheral.state.rawValue])
        if peripheral.state != .poweredOn { stopEmulator() }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard wantedEmulator, registered, service === currentService, let preset = activePreset else { return }
        if let error { fail(error.localizedDescription); stopEmulator(); return }
        log("emulator", "service_added", ["uuid": service.uuid.uuidString])
        peripheral.startAdvertising([CBAdvertisementDataLocalNameKey: preset.name, CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: pasitoService)]])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard wantedEmulator else { peripheral.stopAdvertising(); return }
        emulatorStarting = false
        if let error { fail(error.localizedDescription); stopEmulator(); return }
        advertising = peripheral.isAdvertising; emulatorStatus = "Объявляется · \(activePreset?.name ?? "")"
        log("emulator", "advertising_started", ["name": activePreset?.name ?? "", "is_advertising": advertising, "visibility_on_pasito_verified": false])
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        log("emulator", "subscribe", ["peer": central.identifier.uuidString, "uuid": characteristic.uuid.uuidString])
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        log("emulator", "unsubscribe", ["peer": central.identifier.uuidString, "uuid": characteristic.uuid.uuidString])
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        var fields: [String: Any] = ["peer": request.central.identifier.uuidString, "uuid": request.characteristic.uuid.uuidString, "offset": request.offset]
        var status = CBATTError.Code.readNotPermitted
        if request.characteristic.uuid.uuidString == pasitoControl {
            if let controlValue {
                if let bytes = readSlice(controlValue, offset: request.offset) { request.value = bytes; fields["response"] = payload(bytes); status = .success }
                else { status = .invalidOffset }
            } else { status = .requestNotSupported }
        }
        fields["att_status"] = status.rawValue; log("emulator", "read_received", fields)
        peripheral.respond(to: request, withResult: status)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        var status = CBATTError.Code.success
        for r in requests {
            log("emulator", "write_received", ["peer": r.central.identifier.uuidString, "uuid": r.characteristic.uuid.uuidString, "offset": r.offset, "data": payload(r.value ?? Data()), "value_present": r.value != nil])
            if ![pasitoRX, pasitoControl].contains(r.characteristic.uuid.uuidString) { status = .writeNotPermitted }
            else if r.offset != 0 { status = .invalidOffset }
            else if r.value == nil || (r.value?.count ?? 0) > 512 { status = .invalidAttributeValueLength }
        }
        if status == .success {
            for r in requests where r.characteristic.uuid.uuidString == pasitoControl {
                controlValue = r.value; controlPreview = payload(r.value ?? Data())["hex"] as! String
                log("emulator", "control_stored", ["peer": r.central.identifier.uuidString, "data": payload(r.value ?? Data())])
                if let powers = observedPowers(r.value ?? Data()) {
                    receivedPowers = powers; receivedPowerPeer = r.central.identifier.uuidString
                    log("emulator", "observed_power_frame", ["peer": receivedPowerPeer, "powers_w": powers, "hex": controlPreview, "interpretation": "Matches observed 02 + ten powers; durations unknown"])
                }
            }
        }
        log("emulator", "write_batch_result", ["count": requests.count, "att_status": status.rawValue])
        peripheral.respond(to: first, withResult: status)
    }
}
