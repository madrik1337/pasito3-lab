import Foundation

func parseHex(_ string: String) -> Data? {
    let chars = Array(string.filter { !$0.isWhitespace })
    guard chars.count % 2 == 0 else { return nil }
    var bytes = [UInt8]()
    for i in stride(from: 0, to: chars.count, by: 2) {
        guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
        bytes.append(byte)
    }
    return Data(bytes)
}
func readSlice(_ data: Data, offset: Int) -> Data? {
    guard offset >= 0 && offset <= data.count else { return nil }
    return Data(data.dropFirst(offset))
}
func payload(_ data: Data) -> [String: Any] {
    ["hex": data.map { String(format: "%02x", $0) }.joined(),
     "length": data.count,
     "ascii_preview": data.map { $0 >= 32 && $0 <= 126 ? String(UnicodeScalar($0)) : "." }.joined()]
}
