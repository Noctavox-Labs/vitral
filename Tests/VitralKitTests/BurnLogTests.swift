import Testing
@testable import VitralKit

@Test func noticesABurnBundleThatRepeatsAPrerequisite() {
    let once = """
    [00D8:00DC][2026-11-05T12:26:16]i052: Condition 'NETFRAMEWORK45 >= 394802' evaluates to false.
    [00D8:00DC][2026-11-05T12:26:28]i319: Applied execute package: NetFx462Web, result: 0x0, restart: None
    [00D8:00DC][2026-11-05T12:26:28]i319: Applied execute package: ProductMSI, result: 0x0, restart: None
    """
    #expect(BurnLog.repeatedPackage(in: once) == nil)
    let twice = once + "\r\n[00D8:00DC][2026-11-05T12:26:47]i319: Applied execute package: NetFx462Web, result: 0x0, restart: None\r\n"
    #expect(BurnLog.repeatedPackage(in: twice) == "NetFx462Web")
    // A failed attempt followed by a retry is not a loop.
    let failed = "i319: Applied execute package: VCRedist, result: 0x80070643, restart: None\ni319: Applied execute package: VCRedist, result: 0x0, restart: None\n"
    #expect(BurnLog.repeatedPackage(in: failed) == nil)

    #expect(BurnLog.friendlyName("NetFx462Web") == ".NET Framework 4.6.2")
    #expect(BurnLog.friendlyName("NetFx48") == ".NET Framework 4.8")
    #expect(BurnLog.friendlyName("ProductMSI") == "ProductMSI")
}
