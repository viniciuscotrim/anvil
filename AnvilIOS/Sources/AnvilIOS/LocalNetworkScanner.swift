import AnvilCore
import Foundation

/// Finds the phone's own IPv4 address on its Wi-Fi interface (`en0`) —
/// the basis for guessing which `/24` subnet a Mac on the same network
/// is probably on (the overwhelming majority of home/office Wi-Fi
/// networks route this way). Reading the phone's own interface needs no
/// permission; it's the actual outbound probes in `LocalNetworkScanner`
/// that need Local Network access (`NSLocalNetworkUsageDescription`).
enum LocalNetworkAddress {
    static func currentIPv4() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let interface = current.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard String(cString: interface.ifa_name) == "en0" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            return String(cString: hostname)
        }
        return nil
    }
}

/// One live Anvil-shaped server found on the network — a real, running
/// model, not just an open port. `kind` is only ever `.image` when the
/// second probe (`/v1/images/progress`, a route only `ImageServerScript`
/// implements) actually answers; everything else that responds on
/// `/v1/models` is treated as a text model, matching what `LLMServer`'s
/// `mlx_lm.server` actually serves.
struct DiscoveredMacModel: Identifiable {
    let host: String
    let port: Int
    let kind: ModelKind
    let displayName: String
    var id: String { "\(host):\(port)" }
}

/// Scans the local `/24` for Anvil model servers instead of asking the
/// user to type an IP and port — the whole point being that "Local
/// only" is still the default for every load on the Mac, so this only
/// ever finds something the user *already* explicitly switched to
/// "Network" access. No Bonjour/mDNS (that would need the Mac itself to
/// advertise a service, a change this deliberately never makes) — just
/// direct HTTP probes across the subnet's 254 possible hosts, on the
/// same small set of ports `ModelSessionManager`/`ImageSessionManager`
/// actually hand out (text from 8100, image from 8200).
enum LocalNetworkScanner {
    private static let textPorts = Array(8100...8109)
    private static let imagePorts = Array(8200...8209)
    private static let probeTimeout: TimeInterval = 0.4

    /// `onProgress` is called occasionally (not once per probe — with
    /// thousands of them, that would be its own performance problem)
    /// with a 0...1 fraction.
    static func scan(onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async -> [DiscoveredMacModel] {
        guard let myIP = LocalNetworkAddress.currentIPv4() else { return [] }
        let octets = myIP.split(separator: ".")
        guard octets.count == 4, let myLastOctet = Int(octets[3]) else { return [] }
        let prefix = octets.prefix(3).joined(separator: ".")

        let hosts = (1...254).compactMap { octet -> String? in
            octet == myLastOctet ? nil : "\(prefix).\(octet)"
        }
        let allPorts = textPorts + imagePorts
        let totalProbes = hosts.count * allPorts.count
        let progress = ProgressCounter(total: totalProbes, onUpdate: onProgress)

        var discovered: [DiscoveredMacModel] = []
        await withTaskGroup(of: DiscoveredMacModel?.self) { group in
            for host in hosts {
                for port in allPorts {
                    group.addTask {
                        defer { Task { await progress.increment() } }
                        return await probe(host: host, port: port)
                    }
                }
            }
            for await result in group {
                if let result { discovered.append(result) }
            }
        }
        return discovered
    }

    private static func probe(host: String, port: Int) async -> DiscoveredMacModel? {
        guard let displayName = await probeModels(host: host, port: port) else { return nil }
        let isImage = await probeIsImageServer(host: host, port: port)
        return DiscoveredMacModel(
            host: host, port: port, kind: isImage ? .image : .text,
            displayName: isImage ? "Image model on \(host)" : displayName
        )
    }

    /// `/v1/models` — both `LLMServer` (via `mlx_lm.server`) and
    /// `ImageServerScript` answer this, so it only confirms "something
    /// Anvil-shaped is alive here", not which kind.
    private static func probeModels(host: String, port: Int) async -> String? {
        guard let url = URL(string: "http://\(host):\(port)/v1/models") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = probeTimeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        struct ModelsResponse: Decodable {
            struct Item: Decodable { let id: String }
            let data: [Item]
        }
        let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded?.data.first?.id ?? "Model on \(host)"
    }

    /// `/v1/images/progress` — a route only `ImageServerScript` (Anvil's
    /// own image server) implements; `mlx_lm.server` (text) has no such
    /// route and 404s.
    private static func probeIsImageServer(host: String, port: Int) async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/v1/images/progress") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = probeTimeout
        guard let (_, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return false }
        return true
    }
}

/// Coalesces thousands of individual probe completions into occasional
/// progress callbacks instead of one per probe.
private actor ProgressCounter {
    private let total: Int
    private let onUpdate: @Sendable (Double) -> Void
    private var completed = 0

    init(total: Int, onUpdate: @escaping @Sendable (Double) -> Void) {
        self.total = max(total, 1)
        self.onUpdate = onUpdate
    }

    func increment() {
        completed += 1
        if completed % 25 == 0 || completed == total {
            onUpdate(Double(completed) / Double(total))
        }
    }
}
