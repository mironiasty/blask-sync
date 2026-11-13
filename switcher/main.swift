// MXSwitch: switch Logitech MX Keys + MX Master 4 (Bluetooth) to an Easy-Switch channel
// via HID++ 2.0 feature 0x1814 (CHANGE_HOST), and the external monitor's input via DDC/CI.
// Args: --host N (1-based, default 1), --input N (monitor input, default 17),
//       --no-monitor, --monitor-only, --dry-run
//
// Peripheral transport: Logitech's BLE GATT HID++ channel (needs Bluetooth permission);
// IOHID fallback (needs Input Monitoring; macOS refuses writes to keyboards).
import AppKit
import CoreBluetooth
import Foundation
import IOKit.hid

let vendorID = 0x046D
let devices: [Int: String] = [0xB35B: "MX Keys", 0xB042: "MX Master 4"]
let reportLong: UInt8 = 0x11
let devIdx: UInt8 = 0xFF
let swID: UInt8 = 0x0A
let hidppService = CBUUID(string: "00010000-0000-1000-8000-011F2000046D")
let hidppChar = CBUUID(string: "00010001-0000-1000-8000-011F2000046D")

var targetHost = 1
var dryRun = false
var monitorInput: UInt16? = 17
var monitorOnly = false
var argIt = CommandLine.arguments.dropFirst().makeIterator()
while let a = argIt.next() {
    if a == "--dry-run" { dryRun = true }
    if a == "--host", let v = argIt.next(), let n = Int(v) { targetHost = n }
    if a == "--input", let v = argIt.next(), let n = UInt16(v) { monitorInput = n }
    if a == "--no-monitor" { monitorInput = nil }
    if a == "--monitor-only" { monitorOnly = true }
}
let launchedFromFinder = isatty(STDOUT_FILENO) == 0
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MXSwitch.log")
var log: [String] = []
func say(_ s: String) {
    print(s)
    log.append(s)
}
var debugLog: [String] = []
func dbg(_ s: String) {
    print(s)
    debugLog.append(s)
}
func hex(_ r: IOReturn) -> String { "0x" + String(UInt32(bitPattern: r), radix: 16) }
func err(_ s: String) -> NSError { NSError(domain: s, code: 1) }

/// Pump the run loop until `done()` or timeout.
func spin(_ timeout: TimeInterval, until done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if done() { return true }
        CFRunLoopRunInMode(.defaultMode, 0.02, true)
    }
    return done()
}

protocol Transport: AnyObject {
    var label: String { get }
    /// Send a HID++ frame starting at the device index byte (no report ID).
    func send(_ frame: [UInt8]) throws
    /// Last received frame starting at the device index byte, or nil.
    var reply: [UInt8]? { get set }
    func close()
}

extension Transport {
    func request(_ feat: UInt8, _ fn: UInt8, _ params: [UInt8] = [], wait: Bool = true) throws -> [UInt8]? {
        var frame = [devIdx, feat, (fn << 4) | swID] + params
        frame += [UInt8](repeating: 0, count: 19 - frame.count)
        reply = nil
        try send(frame)
        guard wait else { return nil }
        var got: [UInt8]?
        _ = spin(2) {
            guard let r = reply else { return false }
            reply = nil
            if r.count > 4, r[1] == 0xFF, r[2] == feat {
                got = r
                return true
            }  // HID++ error
            if r.count > 2, r[1] == feat, r[2] == (fn << 4) | swID {
                got = r
                return true
            }
            return false
        }
        guard let r = got else { throw err("no response via \(label)") }
        if r[1] == 0xFF { throw err("HID++ error 0x\(String(r[4], radix: 16))") }
        return r
    }
}

// MARK: IOHID transport

final class HIDTransport: Transport {
    let label = "HID"
    let dev: IOHIDDevice
    var buf = [UInt8](repeating: 0, count: 64)
    var reply: [UInt8]?

    init(_ d: IOHIDDevice) throws {
        dev = d
        let r = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else { throw err("HID open \(hex(r))") }
        IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        buf.withUnsafeMutableBufferPointer { bp in
            IOHIDDeviceRegisterInputReportCallback(
                d, bp.baseAddress!, bp.count,
                { ctx, _, _, _, id, report, len in
                    let t = Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue()
                    var bytes = Array(UnsafeBufferPointer(start: report, count: len))
                    if bytes.first == UInt8(id) { bytes.removeFirst() }
                    if id == reportLong { t.reply = bytes }
                }, ctx)
        }
    }

    func send(_ frame: [UInt8]) throws {
        let msg = [reportLong] + frame
        let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(reportLong), msg, msg.count)
        guard r == kIOReturnSuccess else { throw err("HID write \(hex(r))") }
    }

    func close() { IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone)) }
}

// MARK: BLE GATT transport

final class BLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var connected = Set<UUID>()
    var chars: [UUID: CBCharacteristic] = [:]
    var transports: [UUID: BLETransport] = [:]
    var failures: [UUID: String] = [:]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {}

    func ready() -> Bool {
        _ = spin(15) { central.state != .unknown && central.state != .resetting }
        return central.state == .poweredOn
    }

    func stateDescription() -> String {
        switch central.state {
        case .unauthorized: return "Bluetooth permission not granted (System Settings > Privacy & Security > Bluetooth)"
        case .poweredOff: return "Bluetooth is off"
        default: return "Bluetooth state \(central.state.rawValue)"
        }
    }

    func open(name: String) throws -> BLETransport {
        let peers = central.retrieveConnectedPeripherals(withServices: [hidppService])
        guard let p = peers.first(where: { $0.name == name }) else {
            throw err("not found via BLE (connected: \(peers.compactMap(\.name)))")
        }
        p.delegate = self
        central.connect(p)
        guard spin(5, until: { chars[p.identifier] != nil || failures[p.identifier] != nil }),
            let ch = chars[p.identifier]
        else {
            throw err("BLE setup failed: \(failures[p.identifier] ?? "timeout")")
        }
        let t = BLETransport(p, ch)
        transports[p.identifier] = t
        return t
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([hidppService])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        failures[p.identifier] = "connect: \(error?.localizedDescription ?? "?")"
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == hidppService }) else {
            failures[p.identifier] = "service missing \(error?.localizedDescription ?? "")"
            return
        }
        p.discoverCharacteristics(nil, for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            dbg("  \(p.name ?? "?") char \(c.uuid) props=0x\(String(c.properties.rawValue, radix: 16))")
            if c.properties.contains(.notify) || c.properties.contains(.indicate) { p.setNotifyValue(true, for: c) }
        }
        guard s.characteristics?.contains(where: { $0.uuid == hidppChar }) == true else {
            failures[p.identifier] = "characteristic missing \(error?.localizedDescription ?? "")"
            return
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if let e = error { dbg("  notify \(ch.uuid) error: \(e.localizedDescription)") }
        if ch.uuid == hidppChar {
            if let e = error {
                failures[p.identifier] = "notify: \(e.localizedDescription)"
            } else {
                chars[p.identifier] = ch
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value else { return }
        var b = Array(v)
        dbg("  <- \(ch.uuid.uuidString.prefix(8)) \(b.map { String(format: "%02x", $0) }.joined(separator: " "))")
        b.insert(devIdx, at: 0)
        transports[p.identifier]?.reply = b
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error { dbg("  write error: \(e.localizedDescription)") }
        transports[p.identifier]?.writeError = error
    }
}

final class BLETransport: Transport {
    let label = "BLE"
    let p: CBPeripheral
    let ch: CBCharacteristic
    var reply: [UInt8]?
    var writeError: Error?
    init(_ p: CBPeripheral, _ ch: CBCharacteristic) {
        self.p = p
        self.ch = ch
    }

    func send(_ frame: [UInt8]) throws {
        writeError = nil
        // Logitech BLE HID++ characteristic: frame without report ID and device index, 18 bytes.
        var out = Array(frame.dropFirst())
        out += [UInt8](repeating: 0, count: max(0, 18 - out.count))
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        dbg(
            "  -> \(type == .withResponse ? "req" : "cmd") \(out.map { String(format: "%02x", $0) }.joined(separator: " "))"
        )
        p.writeValue(Data(out), for: ch, type: type)
        if let e = writeError { throw err("BLE write: \(e.localizedDescription)") }
    }

    func close() {}
}

// MARK: main

/// Query CHANGE_HOST over a transport; returns its feature index.
func probe(_ t: Transport, _ name: String) throws -> UInt8 {
    let idx = try t.request(0x00, 0, [0x18, 0x14])![3]
    if idx == 0 { throw err("CHANGE_HOST not supported") }
    let info = try t.request(idx, 0)!
    say("\(name): on channel \(Int(info[4]) + 1) of \(info[3]) [\(t.label)]")
    return idx
}

/// IOHID devices by name (lazy: only needed if BLE fails; requires Input Monitoring).
var hidByNameCache: [String: IOHIDDevice]?
func hidDevice(_ name: String) -> IOHIDDevice? {
    if hidByNameCache == nil {
        if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
            say("(Input Monitoring not granted; HID fallback unavailable)")
        }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // The HID++ collection (0xFF43/0x0202) is a secondary usage pair, not the primary usage.
        IOHIDManagerSetDeviceMatching(
            mgr,
            [
                kIOHIDVendorIDKey: vendorID,
                kIOHIDDeviceUsagePageKey: 0xFF43,
                kIOHIDDeviceUsageKey: 0x0202,
            ] as CFDictionary)
        var m: [String: IOHIDDevice] = [:]
        for d in IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> ?? [] {
            let pid = (IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int) ?? 0
            if let n = devices[pid], m[n] == nil { m[n] = d }
        }
        hidByNameCache = m
    }
    return hidByNameCache![name]
}

var ok = true
// Phase 1: query everything. Phase 2: switch only if all of it is ready.
var ready: [(Transport, UInt8, String)] = []

var displays: [CFTypeRef] = []
if let input = monitorInput {
    do {
        displays = try DDC.externalServices()
        for (i, av) in displays.enumerated() {
            let cur = (try? DDC.getVCP(av, DDC.vcpInput)).map(String.init) ?? "unknown"
            say("Monitor \(i + 1): input \(cur) (target \(input))")
        }
    } catch {
        ok = false
        say("Monitor: failed: \((error as NSError).domain)")
    }
}

let ble = monitorOnly ? nil : BLE()
let bleReady = ble?.ready() ?? false

for name in monitorOnly ? [] : Set(devices.values).sorted() {
    var attempts: [String] = []
    var done = false
    // 1) BLE GATT (needs only Bluetooth permission; works for keyboards too)
    if bleReady {
        do {
            let t = try ble!.open(name: name)
            ready.append((t, try probe(t, name), name))
            done = true
        } catch { attempts.append("BLE: " + (error as NSError).domain) }
    } else {
        attempts.append(ble!.stateDescription())
    }
    // 2) IOHID fallback (needs Input Monitoring; macOS blocks writes to keyboards)
    if !done {
        if let d = hidDevice(name) {
            do {
                let t = try HIDTransport(d)
                do {
                    ready.append((t, try probe(t, name), name))
                    done = true
                } catch {
                    t.close()
                    throw error
                }
            } catch { attempts.append("HID: " + (error as NSError).domain) }
        } else {
            attempts.append("HID: not listed")
        }
    }
    if !done {
        ok = false
        say("\(name): failed: " + attempts.joined(separator: "; "))
    }
}

if dryRun {
    say("(dry run, nothing switched)")
} else if !ok {
    say("Not switching anything because a device failed.")
} else {
    // Monitor first: if it fails we still have keyboard + mouse here to see the error.
    if let input = monitorInput {
        for (i, av) in displays.enumerated() {
            do {
                try DDC.setVCP(av, DDC.vcpInput, input)
                say("Monitor \(i + 1) -> input \(input)")
            } catch {
                ok = false
                say("Monitor \(i + 1): switch failed: \((error as NSError).domain)")
            }
        }
    }
    for (t, idx, name) in ok ? ready : [] {
        do {
            _ = try t.request(idx, 1, [UInt8(targetHost - 1)], wait: false)
            _ = spin(0.3) { false }  // let BLE writes flush before exit
            say("\(name) -> switched to \(targetHost)")
        } catch {
            ok = false
            say("\(name): switch failed: \((error as NSError).domain)")
        }
    }
}
for (t, _, _) in ready { t.close() }

let stamp = ISO8601DateFormatter().string(from: Date())
try?
    (["[\(stamp)] args=\(CommandLine.arguments.dropFirst().joined(separator: " "))"] + log + ["--- debug ---"]
    + debugLog + [""])
    .joined(separator: "\n").appending("\n")
    .write(to: logURL, atomically: true, encoding: .utf8)

// When launched from Finder/Spotlight, only show a dialog if something went wrong (or dry run).
if launchedFromFinder && (!ok || dryRun) {
    let alert = NSAlert()
    alert.messageText = "MXSwitch"
    alert.informativeText = log.joined(separator: "\n")
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
}
exit(ok ? 0 : 1)
