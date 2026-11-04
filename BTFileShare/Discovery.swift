import Foundation
import Darwin

/// Объявляет это устройство в локальной сети (режим «Принять»)
final class BeaconSender {
    private var flag = RunFlag()
    private let name: String

    init(name: String) {
        self.name = name
    }

    func start() {
        guard !flag.isOn else { return }
        let mine = RunFlag()
        mine.set(true)
        flag = mine
        DispatchQueue.global(qos: .utility).async { self.loop(mine) }
    }

    func stop() {
        flag.set(false)
    }

    private func loop(_ mine: RunFlag) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        var target = makeIPv4Address(ip: "255.255.255.255", port: BTNet.discoveryPort)
        let payload = Array((BTNet.beaconPrefix + name).utf8)

        while mine.isOn {
            payload.withUnsafeBytes { raw in
                _ = withUnsafePointer(to: &target) { tp in
                    tp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                        sendto(fd, raw.baseAddress, raw.count, 0, sp,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }
}

/// Слушает объявления других устройств (режим «Отправить»)
final class BeaconListener {
    var onFound: ((String, String) -> Void)?
    private var flag = RunFlag()

    func start() throws {
        guard !flag.isOn else { return }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw AppError(message: "Не удалось создать UDP-сокет") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = makeIPv4Address(ip: "0.0.0.0", port: BTNet.discoveryPort)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw AppError(message: "Не удалось открыть порт \(BTNet.discoveryPort)")
        }

        let mine = RunFlag()
        mine.set(true)
        flag = mine
        DispatchQueue.global(qos: .userInitiated).async { self.loop(fd, mine) }
    }

    func stop() {
        flag.set(false)
    }

    private func loop(_ fd: Int32, _ mine: RunFlag) {
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 512)

        while mine.isOn {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 500) > 0 else { continue }

            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                withUnsafeMutablePointer(to: &from) { fp in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                        recvfrom(fd, raw.baseAddress, raw.count, 0, sp, &fromLen)
                    }
                }
            }
            guard count > 0 else { continue }

            let text = String(decoding: buffer[0..<count], as: UTF8.self)
            guard text.hasPrefix(BTNet.beaconPrefix) else { continue }
            let name = String(text.dropFirst(BTNet.beaconPrefix.count))
            let ip = String(cString: inet_ntoa(from.sin_addr))
            onFound?(ip, name)
        }
    }
}
