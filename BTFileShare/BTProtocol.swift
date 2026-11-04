import CoreBluetooth
import Foundation

enum BTConstants {
    static let serviceUUID = CBUUID(string: "E7A1C000-1F2B-4C3D-9E8F-0A1B2C3D4E5F")
    static let transferUUID = CBUUID(string: "E7A1C001-1F2B-4C3D-9E8F-0A1B2C3D4E5F")
}

enum PacketType: UInt8 {
    case header = 0x01   // JSON: { "name", "size" }
    case data   = 0x02   // сырые байты файла
    case end    = 0x03   // конец передачи
}

struct FileHeader: Codable {
    let name: String
    let size: Int
}

func makePacket(_ type: PacketType, _ payload: Data = Data()) -> Data {
    var packet = Data([type.rawValue])
    packet.append(payload)
    return packet
}
