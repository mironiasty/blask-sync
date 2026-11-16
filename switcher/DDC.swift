// DDC/CI for external displays on Apple Silicon, same approach as m1ddc:
// talk to the DCPAVServiceProxy via the private IOAVService I2C functions.
import Foundation
import IOKit

enum DDC {
    typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias WriteFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias ReadFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    static let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    static func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let p = dlsym(lib, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    static let create = sym("IOAVServiceCreateWithService", CreateFn.self)
    static let write = sym("IOAVServiceWriteI2C", WriteFn.self)
    static let read = sym("IOAVServiceReadI2C", ReadFn.self)

    static let chipAddress: UInt32 = 0x37
    static let dataAddress: UInt32 = 0x51
    static let vcpInput: UInt8 = 0x60

    /// AV services of external displays (built-in panel excluded).
    static func externalServices() throws -> [CFTypeRef] {
        guard let create else { throw err("IOAVService API unavailable") }
        var iter: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("DCPAVServiceProxy"), &iter)
                == KERN_SUCCESS
        else {
            throw err("cannot enumerate displays")
        }
        defer { IOObjectRelease(iter) }
        var out: [CFTypeRef] = []
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            let loc =
                IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard loc == "External", let av = create(kCFAllocatorDefault, s) else { continue }
            out.append(av.takeRetainedValue())
        }
        if out.isEmpty { throw err("no external display found") }
        return out
    }

    static func setVCP(_ av: CFTypeRef, _ code: UInt8, _ value: UInt16) throws {
        guard let write else { throw err("IOAVServiceWriteI2C unavailable") }
        var d: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        d[5] = d[0..<5].reduce(UInt8(0x6E ^ dataAddress)) { $0 ^ $1 }
        var last: IOReturn = kIOReturnSuccess
        for _ in 0..<2 {  // m1ddc also sends twice; some displays drop the first one
            usleep(10_000)
            last = d.withUnsafeMutableBytes { write(av, chipAddress, dataAddress, $0.baseAddress!, UInt32($0.count)) }
        }
        guard last == kIOReturnSuccess else { throw err("DDC write \(hex(last))") }
    }

    static func getVCP(_ av: CFTypeRef, _ code: UInt8) throws -> UInt16 {
        guard let write, let read else { throw err("IOAVService I2C unavailable") }
        var q: [UInt8] = [0x82, 0x01, code, 0]
        q[3] = q[0..<3].reduce(UInt8(0x6E ^ dataAddress)) { $0 ^ $1 }
        var buf = [UInt8](repeating: 0, count: 12)
        for _ in 0..<3 {
            usleep(10_000)
            let w = q.withUnsafeMutableBytes { write(av, chipAddress, dataAddress, $0.baseAddress!, UInt32($0.count)) }
            usleep(50_000)
            let r = buf.withUnsafeMutableBytes { read(av, chipAddress, dataAddress, $0.baseAddress!, UInt32($0.count)) }
            if w == kIOReturnSuccess, r == kIOReturnSuccess, buf[2] == 0x02, buf[4] == code {
                return UInt16(buf[8]) << 8 | UInt16(buf[9])
            }
        }
        throw err("DDC read failed")
    }
}
