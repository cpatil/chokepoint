import Cocoa
import IOKit

// Checks what Chokepoint asserts about each attached storage device against sources
// that owe it nothing: system_profiler for the USB link and identity, diskutil for
// the medium, the SD specification for the capacity bands, and a second, independent
// walk of the I/O registry for the byte counters.
//
// The last one is the double-counting proof. The sampler attributes each
// IOBlockStorageDriver to exactly one device by stopping its walk at nested USB
// devices, so that a hub is not credited with its children's traffic. If that holds,
// the sum over devices equals the sum over every driver in the registry. Larger means
// something was counted twice; smaller means a driver belongs to nothing the app
// shows, which is reported but is not an error - disk images, for one.
//
// Prints one line per check and exits non-zero if any check fails. Run it through
// tools/verify.sh, which compiles it against Sources/ as a universal binary.

_ = NSApplication.shared
Catalogue.seedIfMissing()

var failures = 0
func report(_ status: String, _ what: String, _ detail: String = "") {
    if status == "DIFF" { failures += 1 }
    print("  \(status.padding(toLength: 5, withPad: " ", startingAt: 0)) \(what)" + (detail.isEmpty ? "" : "   \(detail)"))
}

// ---- independent sources --------------------------------------------------------

func run(_ path: String, _ args: [String]) -> Data {
    let p = Process(); p.launchPath = path; p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    try? p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return data
}

struct USBFacts { var speedBits: UInt64?; var sizeBytes: UInt64?; var removable: Bool? }

/// system_profiler's USB tree, indexed by vendor:product. Its speed is a word
/// ("super_speed"); the mapping to bits is the USB specification's, not the app's.
func profilerUSB() -> [String: USBFacts] {
    let data = run("/usr/sbin/system_profiler", ["SPUSBDataType", "-json"])
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tops = root["SPUSBDataType"] as? [[String: Any]] else { return [:] }
    let speeds: [String: UInt64] = ["low_speed": 1_500_000, "full_speed": 12_000_000,
                                    "high_speed": 480_000_000, "super_speed": 5_000_000_000,
                                    "super_speed_plus": 10_000_000_000]
    var out: [String: USBFacts] = [:]
    func hex(_ s: String) -> String {
        // "0x1058  (Western Digital Technologies, Inc.)" -> "1058"
        let token = s.split(separator: " ").first.map(String.init) ?? s
        return token.lowercased().replacingOccurrences(of: "0x", with: "")
    }
    func walk(_ node: [String: Any]) {
        if let v = node["vendor_id"] as? String, let p = node["product_id"] as? String {
            var facts = USBFacts()
            facts.speedBits = (node["device_speed"] as? String).flatMap { speeds[$0] }
            if let media = (node["Media"] as? [[String: Any]])?.first {
                facts.sizeBytes = (media["size_in_bytes"] as? NSNumber)?.uint64Value
                if let r = media["removable_media"] as? String { facts.removable = (r == "yes") }
            }
            out[hex(v) + ":" + hex(p)] = facts
        }
        for child in node["_items"] as? [[String: Any]] ?? [] { walk(child) }
    }
    tops.forEach(walk)
    return out
}

struct DiskFacts { var removable: Bool?; var size: UInt64?; var solidState: Bool?; var protocolName: String? }

func diskutil(_ bsd: String) -> DiskFacts? {
    let data = run("/usr/sbin/diskutil", ["info", "-plist", bsd])
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    return DiskFacts(removable: plist["RemovableMedia"] as? Bool,
                     size: (plist["TotalSize"] as? NSNumber)?.uint64Value,
                     solidState: plist["SolidState"] as? Bool,
                     protocolName: plist["BusProtocol"] as? String)
}

/// Every IOBlockStorageDriver in the registry, summed - with no notion of devices,
/// so it cannot share the sampler's attribution mistakes.
struct Driver { var bsd: String; var read: UInt64; var write: UInt64 }

/// The BSD name of the medium a driver publishes, so an unclaimed driver can be named.
func mediumName(under driver: io_registry_entry_t) -> String {
    var iter: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &iter) == KERN_SUCCESS else { return "?" }
    defer { IOObjectRelease(iter) }
    while true {
        let child = IOIteratorNext(iter); if child == 0 { break }
        defer { IOObjectRelease(child) }
        if let bsd = IORegistryEntryCreateCFProperty(child, "BSD Name" as CFString,
                                                     kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String { return bsd }
    }
    return "?"
}

func allDrivers() -> [Driver] {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMasterPortDefault,
                                       IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iter) }
    var out: [Driver] = []
    while true {
        let entry = IOIteratorNext(iter); if entry == 0 { break }
        defer { IOObjectRelease(entry) }
        guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString,
                                                          kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] else { continue }
        out.append(Driver(bsd: mediumName(under: entry),
                          read: (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0,
                          write: (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0))
    }
    return out
}

func allDriverBytes() -> (read: UInt64, write: UInt64, drivers: Int) {
    let d = allDrivers()
    return (d.reduce(0) { $0 + $1.read }, d.reduce(0) { $0 + $1.write }, d.count)
}

// ---- the app's claims ---------------------------------------------------------------

let usb = profilerUSB()
// Bracketed: counters move between any two reads, so the sampler's sum is taken
// between two registry walks and judged against the pair. Inside the bracket is
// what "no double counting" looks like; outside it is a real discrepancy.
let before = allDriverBytes()
let devices = (USBSampler.sample() + InternalStorage.sample()).filter { $0.hasStorageCounters }
let after = allDriverBytes()
print("\(devices.count) storage device(s) with counters\n")

var sumRead: UInt64 = 0, sumWrite: UInt64 = 0
for d in devices {
    sumRead += d.diskRead; sumWrite += d.diskWritten
    let vidpid = String(format: "%04x:%04x", d.vendorID, d.productID)
    let std = Reference.standard(forLinkBits: d.linkSpeedBits)?.name ?? "(none)"
    let medium = Reference.mediumClass(bytes: d.mediumBytes, deviceName: d.name, removable: d.removableMedia)
    print("\(d.name)  [\(vidpid)]  link \(d.linkSpeedBits) bit/s \"\(std)\"  removable=\(d.removableMedia)  medium=\"\(medium)\"  \(d.disks.joined(separator: ","))")

    // USB identity and link, against system_profiler.
    if d.vendorID != 0, let facts = usb[vidpid] {
        report("PASS", "USB vendor:product present in system_profiler", vidpid)
        if let bits = facts.speedBits {
            report(bits == d.linkSpeedBits ? "PASS" : "DIFF",
                   "link speed", "app \(d.linkSpeedBits)  profiler \(bits)")
        } else { report("SKIP", "link speed", "profiler reports no device_speed") }
        if let size = facts.sizeBytes, d.mediumBytes > 0 {
            report(size == d.mediumBytes ? "PASS" : "DIFF",
                   "medium size vs profiler", "app \(d.mediumBytes)  profiler \(size)")
        }
    } else if d.vendorID != 0 {
        report("DIFF", "USB vendor:product in system_profiler", "\(vidpid) not found")
    }

    // The medium, against diskutil.
    if let bsd = d.disks.first, let disk = diskutil(bsd) {
        if let r = disk.removable {
            report(r == d.removableMedia ? "PASS" : "DIFF",
                   "removable medium", "app \(d.removableMedia)  diskutil \(r)  (\(bsd))")
        }
        if let s = disk.size, d.mediumBytes > 0 {
            report(s == d.mediumBytes ? "PASS" : "DIFF",
                   "medium size vs diskutil", "app \(d.mediumBytes)  diskutil \(s)")
        }
        if let proto = disk.protocolName { report("INFO", "diskutil protocol", proto) }
    } else if let bsd = d.disks.first {
        report("SKIP", "diskutil info", "\(bsd) unreadable")
    }

    // The SD family, against the specification's decimal capacity bands.
    if medium.hasPrefix("SD") {
        let gb = Double(d.mediumBytes) / 1e9
        let expected = gb <= 2 ? "SD" : gb <= 32 ? "SDHC" : gb <= 2000 ? "SDXC" : "SDUC"
        let claimed = medium.split(separator: " ").first.map(String.init) ?? ""
        report(claimed == expected ? "PASS" : "DIFF",
               "SD family from capacity", "app \(claimed)  spec \(expected) for \(String(format: "%.1f", gb)) GB")
    }
    print()
}

// ---- double counting ----------------------------------------------------------------

print("byte counters: \(devices.count) devices vs \(after.drivers) drivers in the registry")
report("INFO", "read  drivers before / devices / drivers after",
       "\(before.read) / \(sumRead) / \(after.read)")
report("INFO", "write drivers before / devices / drivers after",
       "\(before.write) / \(sumWrite) / \(after.write)")
// Above the bracket is the failure: bytes attributed to more than one device. Below
// it is legitimate - a driver the app shows no device for, such as a disk image or a
// snapshot mount - and is named rather than failed, so it can be judged.
let doubled = sumRead > after.read || sumWrite > after.write
report(doubled ? "DIFF" : "PASS",
       "no byte attributed to more than one device",
       doubled ? "devices exceed the registry by read \(sumRead > after.read ? sumRead - after.read : 0) write \(sumWrite > after.write ? sumWrite - after.write : 0)" : "")
let claimed = Set(devices.flatMap { $0.disks })
let orphans = allDrivers().filter { !claimed.contains($0.bsd) }
if orphans.isEmpty {
    report("PASS", "every driver in the registry belongs to a device the app shows")
} else {
    for o in orphans {
        report("INFO", "driver the app shows no device for",
               "\(o.bsd)  read \(o.read)  write \(o.write)")
    }
}

print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) differ")
exit(failures == 0 ? 0 : 1)
