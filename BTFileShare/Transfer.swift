import Foundation
import Darwin

// MARK: - Низкоуровневые функции сокетов

private func recvExact(_ fd: Int32, _ count: Int) -> Data? {
    guard count > 0 else { return Data() }
    var out = Data(count: count)
    var got = 0
    let ok: Bool = out.withUnsafeMutableBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return false }
        while got < count {
            let n = recv(fd, base + got, count - got, 0)
            if n <= 0 { return false }
            got += n
        }
        return true
    }
    return ok ? out : nil
}

private func recvUInt(_ fd: Int32, bytes: Int) -> UInt64? {
    guard let data = recvExact(fd, bytes) else { return nil }
    return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
}

private func sendAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        var sent = 0
        while sent < raw.count {
            let n = send(fd, base + sent, raw.count - sent, 0)
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}

/// Читает тело файла прямо на диск, чтобы большой файл не лежал в памяти целиком
private func receiveFile(_ fd: Int32, to url: URL, size: UInt64, progress: (Double) -> Void) throws {
    _ = FileManager.default.createFile(atPath: url.path, contents: nil)
    let out = try FileHandle(forWritingTo: url)
    defer { try? out.close() }

    let buffer = UnsafeMutableRawPointer.allocate(byteCount: BTNet.chunkSize, alignment: 16)
    defer { buffer.deallocate() }

    var remaining = size
    while remaining > 0 {
        let want = Int(min(remaining, UInt64(BTNet.chunkSize)))
        let n = recv(fd, buffer, want, 0)
        if n <= 0 { throw AppError(message: "Соединение прервано") }
        try out.write(contentsOf: Data(bytesNoCopy: buffer, count: n, deallocator: .none))
        remaining -= UInt64(n)
        progress(1 - Double(remaining) / Double(size))
    }
}

private func uniqueURL(in dir: URL, name: String) -> URL {
    let ext = (name as NSString).pathExtension
    let stem = (name as NSString).deletingPathExtension
    var url = dir.appendingPathComponent(name)
    var index = 1
    while FileManager.default.fileExists(atPath: url.path) {
        let candidate = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
        url = dir.appendingPathComponent(candidate)
        index += 1
    }
    return url
}

// MARK: - Приём

final class TransferServer {
    var onStatus: ((String) -> Void)?
    var onProgress: ((Double) -> Void)?
    var onSaved: ((URL) -> Void)?

    private var flag = RunFlag()

    func start() throws {
        guard !flag.isOn else { return }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppError(message: "Не удалось создать сокет") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = makeIPv4Address(ip: "0.0.0.0", port: BTNet.transferPort)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw AppError(message: "Порт \(BTNet.transferPort) занят")
        }

        let mine = RunFlag()
        mine.set(true)
        flag = mine
        DispatchQueue.global(qos: .userInitiated).async { self.acceptLoop(fd, mine) }
    }

    func stop() {
        flag.set(false)
    }

    private func acceptLoop(_ listenFD: Int32, _ mine: RunFlag) {
        defer { close(listenFD) }
        while mine.isOn {
            var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 500) > 0 else { continue }
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { continue }
            DispatchQueue.global(qos: .userInitiated).async { self.handle(client) }
        }
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        setNoSigPipe(fd)
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var unfinished: URL?
        do {
            guard recvExact(fd, 4) == Data(BTNet.magic) else {
                throw AppError(message: "Неизвестный отправитель")
            }
            guard let countValue = recvUInt(fd, bytes: 4) else {
                throw AppError(message: "Соединение прервано")
            }

            let dir = try Self.receiveDirectory()
            var savedCount = 0

            for _ in 0..<Int(countValue) {
                guard let nameLength = recvUInt(fd, bytes: 2),
                      let nameData = recvExact(fd, Int(nameLength)),
                      let size = recvUInt(fd, bytes: 8) else {
                    throw AppError(message: "Соединение прервано")
                }

                let name = safeFileName(String(decoding: nameData, as: UTF8.self))
                let url = uniqueURL(in: dir, name: name)
                unfinished = url

                try receiveFile(fd, to: url, size: size) { value in
                    self.post { self.onProgress?(value) }
                }

                unfinished = nil
                savedCount += 1
                let saved = url
                post { self.onSaved?(saved) }
            }

            _ = sendAll(fd, Data([BTNet.ack]))
            post { self.onStatus?("Получено файлов: \(savedCount)") }
        } catch {
            if let unfinished {
                try? FileManager.default.removeItem(at: unfinished)
            }
            let text = error.localizedDescription
            post { self.onStatus?("Ошибка приёма: \(text)") }
        }
    }

    private static func receiveDirectory() throws -> URL {
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = docs.appendingPathComponent("Received", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func post(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}

// MARK: - Отправка

enum TransferClient {
    /// Блокирующая отправка. Вызывать из фонового потока.
    static func send(files: [URL], toIP ip: String,
                     progress: (_ fraction: Double, _ mbps: Double) -> Void) throws {
        var sizes: [UInt64] = []
        for url in files {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            sizes.append(UInt64((attrs[.size] as? NSNumber)?.int64Value ?? 0))
        }
        let total = max(1, sizes.reduce(0, +))

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppError(message: "Не удалось создать сокет") }
        defer { close(fd) }
        setNoSigPipe(fd)

        var sendBuffer: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = makeIPv4Address(ip: ip, port: BTNet.transferPort)
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            throw AppError(message: "Нет соединения с \(ip). Проверьте, что там открыт режим «Принять»")
        }

        var header = Data(BTNet.magic)
        header.append(bigEndianData(UInt32(files.count)))
        guard sendAll(fd, header) else { throw AppError(message: "Соединение прервано") }

        let started = Date()
        var sent: UInt64 = 0

        for (index, url) in files.enumerated() {
            let nameData = Data(url.lastPathComponent.utf8)
            var meta = bigEndianData(UInt16(nameData.count))
            meta.append(nameData)
            meta.append(bigEndianData(sizes[index]))
            guard sendAll(fd, meta) else { throw AppError(message: "Соединение прервано") }

            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }

            while let chunk = try input.read(upToCount: BTNet.chunkSize), !chunk.isEmpty {
                guard sendAll(fd, chunk) else { throw AppError(message: "Соединение прервано") }
                sent += UInt64(chunk.count)
                let elapsed = max(Date().timeIntervalSince(started), 0.001)
                let mbps = Double(sent) / elapsed / 1_048_576
                progress(Double(sent) / Double(total), mbps)
            }
        }

        var ack = [UInt8](repeating: 0, count: 1)
        guard recv(fd, &ack, 1, 0) == 1, ack[0] == BTNet.ack else {
            throw AppError(message: "Получатель не подтвердил приём")
        }
    }
}
