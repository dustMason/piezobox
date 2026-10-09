import Foundation
import IOKit
import IOKit.serial
import Darwin
import PiezoCore

struct SerialDevice: Identifiable, Equatable {
    let path: String
    let serial: String
    var id: String { path }
    var title: String { serial.isEmpty ? "Teensy" : "Teensy · \(serial)" }
}

enum DeviceDiscovery {
    static func teensys() -> [SerialDevice] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [SerialDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { continue }
            func parentProperty(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString,
                                                kCFAllocatorDefault,
                                                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            guard (parentProperty("idVendor") as? NSNumber)?.intValue == 0x16c0 else { continue }
            let serial = parentProperty("USB Serial Number") as? String ?? ""
            result.append(SerialDevice(path: path, serial: serial))
        }
        return result.sorted { $0.path < $1.path }
    }
}

struct CaptureConfiguration {
    let port: String
    let pin: Int
    let rate: Int
}

enum SerialEvent {
    case message(String)
    case capture(CaptureEvent)
    case finished(String?)
}

private final class Cancellation {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private enum SerialFailure: Error, LocalizedError {
    case message(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .cancelled: return "Stopped"
        }
    }
}

/// Serial I/O lives on a dedicated queue. No Python or microphone access is used.
final class SerialTransport {
    private let queue = DispatchQueue(label: "com.dustmason.piezo.serial", qos: .userInitiated)
    private var cancellation: Cancellation?

    func start(_ config: CaptureConfiguration, handler: @escaping (SerialEvent) -> Void) {
        stop()
        let token = Cancellation()
        cancellation = token
        queue.async { Self.run(config, token: token, handler: handler) }
    }

    func stop() { cancellation?.cancel() }

    func shutdown() {
        stop()
        queue.sync {} // bounded by the poll/STOP timeout; no descriptor-close race
    }

    private static func run(_ config: CaptureConfiguration, token: Cancellation,
                            handler: @escaping (SerialEvent) -> Void) {
        var fd: Int32 = -1
        var failure: String?
        defer {
            if fd >= 0 {
                _ = writeCommand("STOP\n", fd: fd)
                _ = ioctl(fd, TIOCNXCL)
                _ = flock(fd, LOCK_UN)
                Darwin.close(fd)
            }
            handler(.finished(failure))
        }
        do {
            handler(.message("Opening Teensy…"))
            fd = Darwin.open(config.port, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard fd >= 0 else {
                throw SerialFailure.message("Cannot open the Teensy: \(String(cString: strerror(errno))). Close Serial Monitor or another capture app, then try again.")
            }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0, ioctl(fd, TIOCEXCL) == 0 else {
                throw SerialFailure.message("The Teensy is in use. Close Serial Monitor or the Python recorder, then try again.")
            }
            var options = termios()
            guard tcgetattr(fd, &options) == 0 else { throw SerialFailure.message("Cannot read serial settings.") }
            cfmakeraw(&options)
            options.c_cflag |= tcflag_t(CLOCAL | CREAD)
            _ = cfsetispeed(&options, speed_t(B115200))
            _ = cfsetospeed(&options, speed_t(B115200))
            withUnsafeMutableBytes(of: &options.c_cc) { bytes in
                bytes[Int(VMIN)] = 0
                bytes[Int(VTIME)] = 0
            }
            guard tcsetattr(fd, TCSANOW, &options) == 0 else { throw SerialFailure.message("Cannot configure the serial port.") }
            guard writeCommand("\nSTOP\n", fd: fd) else { throw SerialFailure.message("Cannot write to the Teensy.") }
            let drainUntil = ProcessInfo.processInfo.systemUptime + 0.25
            while ProcessInfo.processInfo.systemUptime < drainUntil {
                if token.cancelled { throw SerialFailure.cancelled }
                _ = try readAvailable(fd: fd, timeoutMS: 20)
            }
            tcflush(fd, TCIFLUSH)
            guard writeCommand("INFO\n", fd: fd) else { throw SerialFailure.message("The Teensy disconnected.") }
            handler(.message("Checking capture firmware…"))
            let info = try readLine(fd: fd, token: token)
            guard info.hasPrefix("PZLC1 Teensy-LC USB-serial ADC12") else {
                throw SerialFailure.message("This device is not running the piezo capture firmware. Response: \(info)")
            }

            var decoder = CaptureDecoder()
            func beginCapture() throws {
                guard writeCommand("CAP \(config.rate) \(config.rate * 600) \(config.pin)\n", fd: fd) else {
                    throw SerialFailure.message("Cannot start capture. Reconnect the Teensy and try again.")
                }
                decoder = CaptureDecoder()
            }
            try beginCapture()
            var lastData = ProcessInfo.processInfo.systemUptime
            var stoppingAt: TimeInterval?
            while true {
                let now = ProcessInfo.processInfo.systemUptime
                if token.cancelled && stoppingAt == nil {
                    _ = writeCommand("STOP\n", fd: fd)
                    stoppingAt = now
                }
                if let stoppingAt, now - stoppingAt > 0.6 { return }
                let data = try readAvailable(fd: fd, timeoutMS: 20)
                if data.isEmpty {
                    if now - lastData > 2.5 && stoppingAt == nil {
                        throw SerialFailure.message("The Teensy stopped sending samples. Check its USB connection and try again.")
                    }
                    continue
                }
                lastData = now
                let events = try decoder.append(data)
                var restart = false
                for event in events {
                    if case .header(let header) = event {
                        guard header.rate == config.rate && header.pins == [config.pin] else {
                            throw SerialFailure.message("The Teensy acknowledged a different input or sample rate.")
                        }
                    }
                    handler(.capture(event))
                    if case .end(let stats) = event {
                        if token.cancelled || stats.reason == 1 { return }
                        if stats.reason == 3 { throw SerialFailure.message("Sampling overloaded the Teensy. Select a lower sample rate and restart.") }
                        if stats.reason == 2 { throw SerialFailure.message("The Teensy could not start its sample timer. Reconnect it and try again.") }
                        restart = true
                    }
                }
                if restart { try beginCapture() }
            }
        } catch SerialFailure.cancelled {
            failure = nil
        } catch {
            failure = token.cancelled ? nil : error.localizedDescription
        }
    }

    private static func writeCommand(_ command: String, fd: Int32) -> Bool {
        let bytes = Array(command.utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), bytes.count - sent) }
            if count > 0 { sent += count }
            else if count < 0 && errno == EINTR { continue }
            else { return false }
        }
        return true
    }

    private static func readAvailable(fd: Int32, timeoutMS: Int32) throws -> Data {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, timeoutMS)
        if ready < 0 && errno == EINTR { return Data() }
        guard ready >= 0 else { throw SerialFailure.message("The USB connection could not be read.") }
        if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
            throw SerialFailure.message("Teensy disconnected. Reconnect it, then press Start.")
        }
        guard ready > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return Data() }
        guard count >= 0 else { throw SerialFailure.message("The USB sample stream could not be read.") }
        return Data(bytes.prefix(count))
    }

    private static func readLine(fd: Int32, token: Cancellation) throws -> String {
        var data = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if token.cancelled { throw SerialFailure.cancelled }
            data.append(try readAvailable(fd: fd, timeoutMS: 20))
            if let newline = data.firstIndex(of: 10) {
                return String(data: data[..<newline], encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Invalid response"
            }
            if data.count > 512 { throw SerialFailure.message("Unexpected firmware response. Install the PZLC1 capture sketch.") }
        }
        throw SerialFailure.message("No response from the capture firmware. Check that the LC is running the new sketch.")
    }
}
