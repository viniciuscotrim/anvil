import AnvilCore
import Foundation

/// Finds the phone's own IPv4 address on its Wi-Fi interface (`en0`) —
/// used only as a last-resort fallback to guess a `/24` subnet when
/// Bonjour discovery (see `BonjourMacDiscovery` below) finds nothing.
/// Reading the phone's own interface needs no permission; it's the
/// actual outbound probes in `LocalNetworkScanner` that need Local
/// Network access (`NSLocalNetworkUsageDescription`).
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

/// A real Mac found on the network via Bonjour, before any Anvil-specific
/// port is ever probed — "find the Mac first, then scan its ports",
/// exactly as requested. `name` is whatever the Mac calls itself
/// (System Settings ▸ General ▸ Sharing ▸ "Computer Name"), which is the
/// closest thing to a MAC address iOS apps can actually get: Apple gives
/// third-party apps no API to read another host's hardware/MAC address
/// (no ARP table access, no raw sockets) — this is the identifier that's
/// actually usable here, and arguably more useful for display anyway.
struct DiscoveredHost: Hashable {
    let ipv4: String
    let name: String
}

/// Finds Macs on the local network via Bonjour instead of guessing a
/// subnet and sweeping all 254 possible hosts. `_device-info._tcp` is a
/// standard macOS system service tied to `mDNSResponder` itself — every
/// Mac advertises it by default (it's how AirDrop/Handoff/"Find My"-style
/// UIs elsewhere show a device's name and icon), so this needs zero
/// changes on the Mac. `_companion-link._tcp`/`_airplay._tcp` are
/// browsed too as a backstop in case a particular Mac's `device-info`
/// advertisement is somehow suppressed (e.g. certain MDM/firewall
/// configurations).
final class BonjourMacDiscovery: NSObject {
    private static let serviceTypes = ["_device-info._tcp.", "_companion-link._tcp.", "_airplay._tcp."]

    private var browsers: [NetServiceBrowser] = []
    private var resolvingServices: Set<NetService> = []
    private var continuation: CheckedContinuation<[DiscoveredHost], Never>?
    private var results: [DiscoveredHost] = []

    /// Browses for up to `timeout` seconds total, resolving every result
    /// found to a real IPv4 address, then returns whatever it collected.
    static func discoverHosts(timeout: TimeInterval = 3.5) async -> [DiscoveredHost] {
        let discovery = BonjourMacDiscovery()
        return await discovery.run(timeout: timeout)
    }

    private func run(timeout: TimeInterval) async -> [DiscoveredHost] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for type in Self.serviceTypes {
                let browser = NetServiceBrowser()
                browser.delegate = self
                // The actual bug that made this find nothing, ever,
                // confirmed for real (not guessed): `NetServiceBrowser`/
                // `NetService` are old, RunLoop-based APIs — their
                // delegate callbacks only fire while *something* is
                // pumping the RunLoop they're scheduled on. Called from
                // an `async` context like this one, the calling thread
                // is one of Swift concurrency's cooperative pool
                // threads, which never runs a RunLoop at all — so
                // without this explicit `schedule(in:forMode:)`, every
                // callback (`didFind`, `didResolveAddress`, …) silently
                // never happens, no matter what the Mac actually
                // advertises. Scheduling explicitly on the main
                // RunLoop (always pumped, by SwiftUI itself) fixes that
                // regardless of which thread started the scan.
                browser.schedule(in: .main, forMode: .common)
                browsers.append(browser)
                browser.searchForServices(ofType: type, inDomain: "local.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish()
            }
        }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        for browser in browsers { browser.stop() }
        browsers.removeAll()
        for service in resolvingServices { service.stop() }
        resolvingServices.removeAll()
        // Dedupe: the same Mac often answers on more than one of the
        // service types above.
        var seen = Set<DiscoveredHost>()
        continuation.resume(returning: results.filter { seen.insert($0).inserted })
    }
}

extension BonjourMacDiscovery: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        // Same fix as the browser above — resolution is its own
        // RunLoop-driven operation and needs the same explicit
        // scheduling to ever actually call back.
        service.schedule(in: .main, forMode: .common)
        resolvingServices.insert(service)
        service.resolve(withTimeout: 3.0)
    }
}

extension BonjourMacDiscovery: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        defer { resolvingServices.remove(sender) }
        for addressData in (sender.addresses ?? []) {
            guard let ipv4 = Self.ipv4String(from: addressData) else { continue }
            results.append(DiscoveredHost(ipv4: ipv4, name: sender.name))
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolvingServices.remove(sender)
    }

    private static func ipv4String(from data: Data) -> String? {
        data.withUnsafeBytes { rawBuffer -> String? in
            guard let base = rawBuffer.baseAddress else { return nil }
            let genericAddr = base.assumingMemoryBound(to: sockaddr.self)
            guard genericAddr.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                genericAddr, socklen_t(genericAddr.pointee.sa_len),
                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            guard result == 0 else { return nil }
            return String(cString: hostname)
        }
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

/// Finds Mac model servers the way the user actually asked for: find the
/// Mac itself first (Bonjour, see `BonjourMacDiscovery` above), *then*
/// probe only that host's small set of known ports — instead of blindly
/// sweeping every one of 254 possible IPs. That original blind sweep
/// (254 hosts × 20 ports, all launched into one `withTaskGroup` at once)
/// is almost certainly why nothing was ever found: firing ~5,000
/// simultaneous `URLSession` requests floods its internal connection
/// queue, and by the time many of them actually run, their own
/// `timeoutInterval` has already elapsed before a byte goes out — not a
/// permissions problem, a self-inflicted-flood problem. The guessed-
/// subnet sweep is kept only as a fallback, and now runs with bounded
/// concurrency so it can't do that to itself again.
///
/// No changes on the Mac needed either way: "Local only" stays the
/// default for every load, so this only ever finds something the user
/// already explicitly switched to "Network" access.
enum LocalNetworkScanner {
    private static let textPorts = Array(8100...8109)
    private static let imagePorts = Array(8200...8209)
    private static let probeTimeout: TimeInterval = 0.6
    private static let maxConcurrentProbes = 48

    /// `onProgress` is called occasionally (not once per probe — with
    /// hundreds/thousands of them, that would be its own performance
    /// problem) with a 0...1 fraction.
    static func scan(onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async -> [DiscoveredMacModel] {
        let allPorts = textPorts + imagePorts

        // Phase 1: find the Mac as a host first.
        let bonjourHosts = await BonjourMacDiscovery.discoverHosts()
        var nameByHost: [String: String] = [:]
        for found in bonjourHosts { nameByHost[found.ipv4] = found.name }
        var candidateHosts = Set(bonjourHosts.map(\.ipv4))

        // Phase 2 (fallback only): Bonjour found nothing — mDNS can be
        // blocked by some router/VLAN setups — so fall back to guessing
        // the subnet from the phone's own IP and sweeping it, bounded
        // this time so the sweep itself can't be the reason nothing is
        // found.
        if candidateHosts.isEmpty, let myIP = LocalNetworkAddress.currentIPv4() {
            let octets = myIP.split(separator: ".")
            if octets.count == 4, let myLastOctet = Int(octets[3]) {
                let prefix = octets.prefix(3).joined(separator: ".")
                for octet in 1...254 where octet != myLastOctet {
                    candidateHosts.insert("\(prefix).\(octet)")
                }
            }
        }

        var hostPortPairs: [(host: String, port: Int)] = []
        for host in candidateHosts {
            for port in allPorts { hostPortPairs.append((host, port)) }
        }
        let progress = ProgressCounter(total: hostPortPairs.count, onUpdate: onProgress)

        var discovered: [DiscoveredMacModel] = []
        await withTaskGroup(of: DiscoveredMacModel?.self) { group in
            var nextIndex = 0
            func scheduleNext() {
                guard nextIndex < hostPortPairs.count else { return }
                let pair = hostPortPairs[nextIndex]
                nextIndex += 1
                group.addTask {
                    defer { Task { await progress.increment() } }
                    return await probe(host: pair.host, port: pair.port, knownName: nameByHost[pair.host])
                }
            }
            // Keep only `maxConcurrentProbes` requests in flight at
            // once — start that many, then replace each as it finishes,
            // instead of launching everything at once.
            for _ in 0..<min(maxConcurrentProbes, hostPortPairs.count) { scheduleNext() }
            for await result in group {
                if let result { discovered.append(result) }
                scheduleNext()
            }
        }
        return discovered
    }

    private static func probe(host: String, port: Int, knownName: String?) async -> DiscoveredMacModel? {
        guard let displayName = await probeModels(host: host, port: port) else { return nil }
        let isImage = await probeIsImageServer(host: host, port: port)
        let label = knownName ?? host
        return DiscoveredMacModel(
            host: host, port: port, kind: isImage ? .image : .text,
            displayName: isImage ? "Image model on \(label)" : (knownName != nil ? "\(displayName) on \(label)" : displayName)
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

/// Coalesces many individual probe completions into occasional progress
/// callbacks instead of one per probe.
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
        if completed % 10 == 0 || completed == total {
            onUpdate(Double(completed) / Double(total))
        }
    }
}
