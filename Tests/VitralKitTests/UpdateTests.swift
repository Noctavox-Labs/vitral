import Foundation
import Testing
@testable import VitralKit

@Test func comparesVersionsAsNumbers() {
    #expect(VitralUpdate.isNewer("0.1.10", than: "0.1.9"))
    #expect(VitralUpdate.isNewer("0.2", than: "0.1.9"))
    #expect(!VitralUpdate.isNewer("0.1.6", than: "0.1.6"))
    #expect(!VitralUpdate.isNewer("0.1.5", than: "0.1.6"))
}

@Test func readsTheNewestVersionOfSparklesFeed() {
    // As scripts/release.sh publishes it (Sparkle's generate_appcast), with an older item too.
    let feed = """
    <?xml version="1.0" standalone="yes"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
        <channel>
            <title>Vitral</title>
            <item>
                <title>0.1.10</title>
                <sparkle:version>11</sparkle:version>
                <sparkle:shortVersionString>0.1.10</sparkle:shortVersionString>
                <description><![CDATA[<li>Version 9.9.9 of something else</li>]]></description>
            </item>
            <item>
                <title>0.1.9</title>
                <enclosure url="https://example.com/Vitral-0.1.9.dmg" sparkle:shortVersionString="0.1.9" sparkle:version="10"/>
            </item>
        </channel>
    </rss>
    """
    #expect(VitralUpdate.latestVersion(inAppcast: Data(feed.utf8)) == "0.1.10")
    #expect(VitralUpdate.latestVersion(inAppcast: Data("<rss></rss>".utf8)) == nil)
}

@Test func readsTheFeedOncePerDay() throws {
    let folder = try TemporaryFolder()
    let home = VitralHome(url: folder.url)
    let now = Date()
    #expect(VitralUpdate.isDue(home: home, now: now))
    VitralUpdate.markChecked(home: home, now: now)
    #expect(!VitralUpdate.isDue(home: home, now: now.addingTimeInterval(3_600)))
    #expect(VitralUpdate.isDue(home: home, now: now.addingTimeInterval(90_000)))
    // A clock set back does not stop it for good.
    #expect(VitralUpdate.isDue(home: home, now: now.addingTimeInterval(-90_000)))
}

@Test func findsTheLauncherAVitralCarries() throws {
    let folder = try TemporaryFolder()
    let vitral = folder.url.appendingPathComponent("Vitral.app")
    #expect(VitralUpdate.launcher(in: vitral) == nil)
    try folder.write("Vitral.app/Contents/MacOS/vitral-launcher", Data("#!/bin/sh\n".utf8))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vitral.appendingPathComponent("Contents/MacOS/vitral-launcher").path)
    #expect(VitralUpdate.launcher(in: vitral)?.lastPathComponent == "vitral-launcher")
    let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.1.7"], format: .xml, options: 0)
    try folder.write("Vitral.app/Contents/Info.plist", info)
    #expect(VitralUpdate.version(of: vitral) == "0.1.7")
}

@Test func theInstalledVitralIsTheNewestCopy() throws {
    let folder = try TemporaryFolder()
    func copy(_ path: String, _ version: String) throws -> URL {
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
        try folder.write("\(path)/Contents/Info.plist", info)
        return folder.url.appendingPathComponent(path)
    }
    let applications = try copy("Applications/Vitral.app", "0.1.7")
    let downloads = try copy("Downloads/Vitral.app", "0.1.5")
    let trash = try copy(".Trash/Vitral.app", "0.2.0")
    let gone = folder.url.appendingPathComponent("Gone/Vitral.app")
    #expect(VitralUpdate.installed(among: [downloads, applications, trash, gone]) == applications.standardizedFileURL)
    // The same version elsewhere: the one in Applications.
    let other = try copy("Other/Vitral.app", "0.1.7")
    #expect(VitralUpdate.installed(among: [other, applications]) == applications.standardizedFileURL)
    // A newer copy wins wherever it is.
    let newer = try copy("Desktop/Vitral.app", "0.1.10")
    #expect(VitralUpdate.installed(among: [applications, newer]) == newer.standardizedFileURL)
    #expect(VitralUpdate.installed(among: []) == nil)
}
