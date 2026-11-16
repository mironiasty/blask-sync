import Testing

@testable import HueKit

struct LocalNetworkAccessTests {
    private func address(_ text: String) -> UInt32 {
        text.split(separator: ".").reduce(0) { $0 << 8 | UInt32($1)! }
    }

    @Test func probesANeighborOnTheSubnet() {
        #expect(
            LocalNetworkAccess.neighbor(of: address("192.168.9.235"), netmask: address("255.255.255.0"))
                == "192.168.9.234")
    }

    @Test func avoidsTheRouterNetworkAndBroadcastAddresses() {
        // .0 ^ 1 would be the router (.1): take .2 instead.
        #expect(LocalNetworkAccess.neighbor(of: address("10.0.0.0"), netmask: address("255.255.255.0")) == "10.0.0.2")
        // .1 ^ 1 is the network address: take .3.
        #expect(LocalNetworkAccess.neighbor(of: address("10.0.0.1"), netmask: address("255.255.255.0")) == "10.0.0.3")
        // .254 ^ 1 is the broadcast address: take .252.
        #expect(
            LocalNetworkAccess.neighbor(of: address("10.0.0.254"), netmask: address("255.255.255.0")) == "10.0.0.252")
    }

    @Test func skipsLinkLocalAndTinySubnets() {
        #expect(LocalNetworkAccess.neighbor(of: address("169.254.3.4"), netmask: address("255.255.0.0")) == nil)
        #expect(LocalNetworkAccess.neighbor(of: address("10.0.0.5"), netmask: address("255.255.255.252")) == nil)
    }
}
