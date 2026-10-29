import Darwin
import Foundation

/// A web link the default browser may open, the one rule for every way out of the page (`fs_exec`, a click, a
/// navigation): `http` or `https` in any letter case, no userinfo, and a host that is not this Mac, since the page's
/// own URLs carry the token. Roland's links name public sites without userinfo, which could make the browser read
/// another host than Foundation does.
public func isWebLinkOffThisMac(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
        url.user == nil, url.password == nil
    else { return false }
    return !isThisMac(host: url.host(percentEncoded: false) ?? "")
}

/// An empty host, a `localhost` name, or any spelling a browser reads as a loopback or unspecified address:
/// `inet_aton` takes `127.1` and `0x7f000001` as browsers do, and `::1`, `::` and `::ffff:127.0.0.1` end in one.
public func isThisMac(host: String) -> Bool {
    var name = host.lowercased()
    if name.hasSuffix(".") { name.removeLast() }
    if name.isEmpty || name == "localhost" || name.hasSuffix(".localhost") { return true }
    let localFirstOctets: Set<UInt32> = [0, 127]
    var ipv4 = in_addr()
    if inet_aton(name, &ipv4) == 1 { return localFirstOctets.contains(UInt32(bigEndian: ipv4.s_addr) >> 24) }
    var ipv6 = in6_addr()
    guard inet_pton(AF_INET6, name, &ipv6) == 1 else { return false }
    let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
    let mapped: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]
    let embedsIPv4 = bytes[..<12].allSatisfy { $0 == 0 } || bytes[..<12].elementsEqual(mapped)
    return embedsIPv4 && localFirstOctets.contains(UInt32(bytes[12]))
}
