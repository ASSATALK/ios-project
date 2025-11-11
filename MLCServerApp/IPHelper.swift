import Foundation
import Network

enum IPHelper {
    static func localIPv4() -> String? {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        let queue = DispatchQueue(label: "ip.monitor")
        var address: String?
        let sema = DispatchSemaphore(value: 0)

        monitor.pathUpdateHandler = { _ in
            monitor.cancel()
            address = fetchIPv4()
            sema.signal()
        }
        monitor.start(queue: queue)
        _ = sema.wait(timeout: .now() + 0.5)
        return address ?? fetchIPv4()
    }

    private static func fetchIPv4() -> String? {
        var addr: String?
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>? = nil
        if getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr {
            var ptr = first
            while true {
                let ifa = ptr.pointee
                if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                    let name = String(cString: ifa.ifa_name)
                    if name != "lo0" {
                        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                                    &hostBuffer, socklen_t(hostBuffer.count),
                                    nil, 0, NI_NUMERICHOST)
                        addr = String(cString: hostBuffer)
                        break
                    }
                }
                if let next = ifa.ifa_next {
                    ptr = next
                } else {
                    break
                }
            }
            freeifaddrs(ifaddrPtr)
        }
        return addr
    }
}
