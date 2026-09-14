import Foundation

let pasitoSuffix = "-B5A3-F393-E0A9-E50E24DCCA9D"
let pasitoService = "6E400001" + pasitoSuffix
let pasitoNotify = "6E400003" + pasitoSuffix
let pasitoControl = "6E400004" + pasitoSuffix
let pasitoRX = "6E400002" + pasitoSuffix

func candidateReason(name: String, manufacturer: Data?, services: [String]) -> String? {
    if services.contains(where: { $0.uppercased() == pasitoService }) { return "Совпадает UUID сервиса" }
    if name.uppercased() == "LE-S052" { return "Имя LE-S052" }
    if let manufacturer, manufacturer.count == 15, manufacturer.prefix(5) == Data([0x42, 0x06, 0x02, 0x02, 0x00]) {
        return "Похожее manufacturer data — кандидат"
    }
    return nil
}

enum AcceptanceStep: Equatable { case idle, notification, acknowledgement, value }
enum AcceptanceAction: Equatable { case none, subscribe, write0100, read }
struct AcceptanceFlow {
    private(set) var step = AcceptanceStep.idle
    mutating func begin() -> AcceptanceAction {
        guard step == .idle else { return .none }
        step = .notification; return .subscribe
    }
    mutating func notified(success: Bool) -> AcceptanceAction {
        guard step == .notification else { return .none }
        guard success else { reset(); return .none }
        step = .acknowledgement; return .write0100
    }
    mutating func acknowledged(success: Bool) -> AcceptanceAction {
        guard step == .acknowledgement else { return .none }
        guard success else { reset(); return .none }
        step = .value; return .read
    }
    mutating func reset() { step = .idle }
}

// Observed 11-byte write to 0004: 02 followed by ten powers matching the user's curve.
// Length/header recognition only; duration and general protocol semantics remain unknown.
func observedPowers(_ data: Data) -> [Int]? {
    guard data.count == 11, data.first == 2 else { return nil }
    return data.dropFirst().map(Int.init)
}

func configFrame(_ powers: [Int]) -> Data? {
    guard powers.count == 10, powers.allSatisfy({ (0...255).contains($0) }) else { return nil }
    return Data([2] + powers.map(UInt8.init))
}

func nextRepeatTarget(_ ids: [UUID], after previous: UUID?) -> UUID? {
    let sorted = Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
    guard let previous else { return sorted.first }
    return sorted.first { $0.uuidString > previous.uuidString } ?? sorted.first
}
