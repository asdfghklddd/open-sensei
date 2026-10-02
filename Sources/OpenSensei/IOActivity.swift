import Foundation
import Darwin
import IOKit

struct NetworkInterface: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let active: Bool
    var isTunnel: Bool { name.hasPrefix("utun") }
    var label: String { "\(name) · \(isTunnel ? "VPN / 隧道" : "网络接口") · \(active ? "已启用" : "未启用")" }
}

struct NetworkReading {
    var counters: [String: NetworkCounter] = [:]
    var interfaces: [NetworkInterface] = []
}

enum NetworkReader {
    static func read() -> NetworkReading? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0, length < 4 * 1024 * 1024 else { return nil }
        var data = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &data, &length, nil, 0) == 0 else { return nil }
        return decode(data, length: length) { index in
            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            guard if_indextoname(index, &name) != nil else { return nil }; return String(cString: name)
        }
    }
    static func decode(_ data: [UInt8], length: Int, nameForIndex: (UInt32) -> String?) -> NetworkReading {
        var result = NetworkReading()
        data.withUnsafeBytes { bytes in
            var offset = 0
            let length = min(length, bytes.count)
            while offset + 4 <= length {
                // Routing buffers also contain shorter address messages between interfaces.
                let size = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard size >= 4, offset + size <= length else { break }
                defer { offset += size }
                guard bytes[offset + 3] == RTM_IFINFO2, size >= MemoryLayout<if_msghdr2>.size else { continue }
                let info = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard let name = nameForIndex(UInt32(info.ifm_index)) else { continue }
                guard name.hasPrefix("en") || name.hasPrefix("utun") else { continue }
                let active = info.ifm_flags & IFF_UP != 0 && info.ifm_flags & IFF_RUNNING != 0
                result.interfaces.append(NetworkInterface(name: name, active: active))
                if active { result.counters[name] = NetworkCounter(received: info.ifm_data.ifi_ibytes, sent: info.ifm_data.ifi_obytes) }
            }
        }
        result.interfaces.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }
    static func select(_ counters: [String: NetworkCounter], interface: String) -> [String: NetworkCounter] {
        counters.filter { interface == "all" ? $0.key.hasPrefix("en") : $0.key == interface }
    }
}

struct DiskActivity {
    var read: Double?
    var write: Double?
    var devices = 0
}

final class DiskActivityReader {
    private var previous: [String: NetworkCounter] = [:]
    private var previousTime: Double?
    func reset() { previous.removeAll(); previousTime = nil }

    // Driver counters only: no file reads, volume traversal or benchmark writes.
    func sample(now: Double) -> DiskActivity {
        guard let current = Self.counters(), !current.isEmpty else { reset(); return DiskActivity() }
        defer { previous = current; previousTime = now }
        guard let time = previousTime, now > time, now - time <= 180,
              !Set(previous.keys).isDisjoint(with: Set(current.keys)) else { return DiskActivity(devices: current.count) }
        let rate = NetworkRate.between(previous, current, seconds: now - time)
        return DiskActivity(read: rate.download, write: rate.upload, devices: current.count)
    }
    static func counters() -> [String: NetworkCounter]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: [String: NetworkCounter] = [:]
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS,
               let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let read = stats["Bytes (Read)"] as? NSNumber, let write = stats["Bytes (Write)"] as? NSNumber,
               read.doubleValue >= 0, write.doubleValue >= 0 {
                result[String(id)] = NetworkCounter(received: read.uint64Value, sent: write.uint64Value)
            }
            IOObjectRelease(service); service = IOIteratorNext(iterator)
        }
        return result
    }
}
