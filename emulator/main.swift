import Foundation
import CoreBluetooth
import Darwin

let base = "-B5A3-F393-E0A9-E50E24DCCA9D"
let serviceID = CBUUID(string: "6E400001" + base)
let receiveID = CBUUID(string: "6E400002" + base)
let notifyID = CBUUID(string: "6E400003" + base)
let controlID = CBUUID(string: "6E400004" + base)

struct Options {
    var name = "LE-S052"
    var logPath = "pasito-events.jsonl"
    var duration: Double = 1200
    var advertisement = "both"
    var control: Data?
    init() {
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let flag = args.removeFirst()
            if flag == "--help" {
                print("PasitoEmulator [--name LE-S052] [--log FILE] [--duration SECONDS] [--advertise both|name|service] [--control-hex HEX]\nNo application-level replies or notifications are invented. Unknown 0004 reads return Request Not Supported until configured or written.")
                exit(0)
            }
            guard !args.isEmpty else { fputs("Missing value for \(flag)\n", stderr); exit(2) }
            let value = args.removeFirst()
            switch flag {
            case "--name": name = value
            case "--log": logPath = value
            case "--duration":
                guard let n = Double(value), n.isFinite, n > 0 else { exit(2) }; duration = n
            case "--advertise":
                guard ["both","name","service"].contains(value) else { exit(2) }; advertisement = value
            case "--control-hex":
                guard let data = parseHex(value), data.count <= 512 else { fputs("Invalid control hex (maximum 512 bytes)\n", stderr); exit(2) }; control = data
            default: fputs("Unknown argument \(flag)\n", stderr); exit(2)
            }
        }
    }
}

final class EventLog {
    let file: FileHandle
    let start = ProcessInfo.processInfo.systemUptime
    let session = UUID().uuidString
    var sequence = 0
    init(path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw NSError(domain: "Logger", code: 1, userInfo: [NSLocalizedDescriptionKey:"Cannot create log \(path)"])
            }
        }
        file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try file.seekToEnd()
    }
    func event(_ type: String, _ values: [String: Any] = [:]) {
        sequence += 1
        var object = values
        object["event"] = type
        object["session"] = session
        object["sequence"] = sequence
        object["timestamp"] = ISO8601DateFormatter().string(from: Date())
        object["elapsed_ms"] = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
        do {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(10)
            try file.write(contentsOf: data)
            try file.synchronize()
            FileHandle.standardOutput.write(data)
        } catch {
            fputs("Logger failed: \(error)\n", stderr)
            exit(1)
        }
    }
}

final class Emulator: NSObject, CBPeripheralManagerDelegate {
    let options: Options
    let log: EventLog
    var manager: CBPeripheralManager!
    var control: Data?
    var registered = false
    var failure = false
    var peers = Set<UUID>()
    var stopRequested = false
    init(_ options: Options, _ log: EventLog) {
        self.options = options; self.log = log; self.control = options.control
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }
    func peer(_ central: CBCentral) {
        if peers.insert(central.identifier).inserted {
            log.event("peer_seen", ["peer":central.identifier.uuidString,"maximum_update_length":central.maximumUpdateValueLength,
                "note":"First GATT callback, not a raw connection event; identity is unverified"])
        }
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        log.event("bluetooth_state", ["state":peripheral.state.rawValue])
        guard peripheral.state == .poweredOn else {
            registered = false
            if peripheral.state == .unauthorized || peripheral.state == .unsupported { failure = true; stopRequested = true }
            return
        }
        guard !registered else { return }
        registered = true
        let service = CBMutableService(type: serviceID, primary: true)
        service.characteristics = [
            CBMutableCharacteristic(type: notifyID, properties: [.notify], value: nil, permissions: []),
            CBMutableCharacteristic(type: receiveID, properties: [.writeWithoutResponse], value: nil, permissions: [.writeable]),
            CBMutableCharacteristic(type: controlID, properties: [.read,.write], value: nil, permissions: [.readable,.writeable])
        ]
        peripheral.add(service)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error { log.event("service_error", ["error":error.localizedDescription]); failure = true; stopRequested = true; return }
        log.event("service_added", ["uuid":service.uuid.uuidString,"characteristics":["0003":"notify","0002":"writeWithoutResponse","0004":"read,write"]])
        var advertisement: [String: Any] = [:]
        if options.advertisement != "service" { advertisement[CBAdvertisementDataLocalNameKey] = options.name }
        if options.advertisement != "name" { advertisement[CBAdvertisementDataServiceUUIDsKey] = [serviceID] }
        log.event("advertising_requested", ["mode":options.advertisement,"name":options.name,"manufacturer_data_reproduced":false])
        peripheral.startAdvertising(advertisement)
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error { log.event("advertising_error", ["error":error.localizedDescription]); failure = true; stopRequested = true }
        else { log.event("advertising_started", ["is_advertising":peripheral.isAdvertising,"note":"Local API success; discovery by real Pasito not yet verified"]) }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        peer(central)
        log.event("subscribe", ["peer":central.identifier.uuidString,"characteristic":characteristic.uuid.uuidString])
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        log.event("unsubscribe", ["peer":central.identifier.uuidString,"characteristic":characteristic.uuid.uuidString,
            "note":"Not proof of disconnection"])
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        peer(request.central)
        var fields: [String:Any] = ["peer":request.central.identifier.uuidString,"characteristic":request.characteristic.uuid.uuidString,"offset":request.offset]
        var status: CBATTError.Code = .readNotPermitted
        if request.characteristic.uuid == controlID {
            if let control = control {
                if let value = readSlice(control, offset: request.offset) {
                    request.value = value; fields["response"] = payload(value); status = .success
                } else { status = .invalidOffset }
            } else { status = .requestNotSupported; fields["note"] = "Unknown original 0004 value; supply --control-hex or record a write" }
        }
        fields["att_status"] = status.rawValue
        log.event("read", fields)
        peripheral.respond(to: request, withResult: status)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        var status: CBATTError.Code = .success
        // Validate the entire callback batch before applying any writes.
        for request in requests {
            peer(request.central)
            var fields: [String:Any] = ["peer":request.central.identifier.uuidString,"characteristic":request.characteristic.uuid.uuidString,"offset":request.offset,"value_present":request.value != nil]
            fields["data"] = payload(request.value ?? Data())
            log.event("write_received", fields)
            if request.characteristic.uuid != receiveID && request.characteristic.uuid != controlID { status = .writeNotPermitted }
            else if request.offset != 0 { status = .invalidOffset }
            else if request.value == nil || (request.value?.count ?? 0) > 512 { status = .invalidAttributeValueLength }
        }
        if status == .success {
            for request in requests where request.characteristic.uuid == controlID {
                control = request.value
                log.event("control_stored", ["data":payload(control!),"note":"Local memory only; original semantics unknown"])
            }
        }
        log.event("write_batch_result", ["count":requests.count,"att_status":status.rawValue,"application_reply_sent":false])
        peripheral.respond(to: first, withResult: status)
    }
    func stop() {
        manager.stopAdvertising(); manager.removeAllServices()
        log.event("stopped", ["unique_peers_seen":peers.count])
    }
}

let options = Options()
let log: EventLog
do { log = try EventLog(path: options.logPath) }
catch { fputs("Cannot open log: \(error)\n", stderr); exit(1) }
log.event("startup", ["name":options.name,"service":serviceID.uuidString,"duration_seconds":options.duration,"control_value_configured":options.control != nil])
let emulator = Emulator(options, log)
signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
interrupt.setEventHandler { emulator.stopRequested = true }; interrupt.resume()
terminate.setEventHandler { emulator.stopRequested = true }; terminate.resume()
let deadline = ProcessInfo.processInfo.systemUptime + options.duration
while !emulator.stopRequested && ProcessInfo.processInfo.systemUptime < deadline {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
}
emulator.stop()
exit(emulator.failure ? 1 : 0)
