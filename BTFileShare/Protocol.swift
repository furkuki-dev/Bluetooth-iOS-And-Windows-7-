import Foundation
import Darwin

/// Константы протокола. Такие же значения в windows/btcore.py.
///
/// Объявление: UDP broadcast на discoveryPort раз в секунду, текст "BTSHARE1:<имя>".
/// Передача: TCP на transferPort:
///   "BTS1" | u32 число файлов (big-endian)
///   для каждого файла: u16 длина имени | имя UTF-8 | u64 размер | данные
///   получатель отвечает байтом 0x06 после приёма всех файлов
enum BTNet {
    static let discoveryPort: UInt16 = 45678
    static let transferPort: UInt16 = 45679
    static let beaconPrefix = "BTSHARE1:"
    static let magic: [UInt8] = Array("BTS1".utf8)
    static let ack: UInt8 = 0x06
    static let chunkSize = 1 << 20
}

struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Флаг работы, безопасный для чтения из фонового потока
final class RunFlag {
    private let lock = NSLock()
    private var value = false

    var isOn: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

func makeIPv4Address(ip: String, port: UInt16) -> sockaddr_in {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr(ip)
    return addr
}

func bigEndianData<T: FixedWidthInteger>(_ value: T) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
}

/// Запрещает SIGPIPE при обрыве соединения, иначе приложение упадёт
func setNoSigPipe(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
}

func safeFileName(_ raw: String) -> String {
    let base = (raw as NSString).lastPathComponent
    let cleaned = base
        .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
        .joined(separator: "_")
    let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    return trimmed.isEmpty ? "file.bin" : trimmed
}
