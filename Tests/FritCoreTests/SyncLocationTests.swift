import Foundation
import XCTest
@testable import FritCore

final class SyncLocationTests: XCTestCase {
    private let container = URL(fileURLWithPath: "/fixture/container", isDirectory: true)
    private let drive = URL(fileURLWithPath: "/fixture/drive", isDirectory: true)

    func testOverrideWinsWithoutLookingUpAnAccountOrFolder() {
        XCTAssertEqual(SyncLocation.resolve(override: "/fixture/override", containerRoot: container,
            driveRoot: drive, driveFolder: "App"), .override(URL(fileURLWithPath: "/fixture/override", isDirectory: true)))
    }

    func testEmptyOverrideUsesContainerBeforeDriveWithConfiguredSubfolder() {
        let location = SyncLocation.resolve(override: "", containerRoot: container, driveRoot: drive,
                                            driveFolder: "App", containerSubfolder: "Documents/Settings")
        XCTAssertEqual(location, .container(container.appendingPathComponent("Documents/Settings", isDirectory: true)))
        XCTAssertEqual(location?.kind, "container")
        XCTAssertEqual(location?.fileURL(named: "config.json")?.lastPathComponent, "config.json")
    }

    func testDriveFolderIsAppSpecificAndUnavailableRootsRemainUnavailable() {
        let location = SyncLocation.resolve(override: nil, containerRoot: nil, driveRoot: drive, driveFolder: "Proxi")
        XCTAssertEqual(location, .drive(drive.appendingPathComponent("Proxi", isDirectory: true)))
        XCTAssertEqual(location?.fileURL()?.lastPathComponent, "sync.json")
        XCTAssertNil(SyncLocation.resolve(override: nil, containerRoot: nil, driveRoot: nil, driveFolder: "App"))
    }

    func testInvalidConfiguredPathsDoNotEscapeTheSelectedRootOrFallBack() {
        for path in ["", "/absolute", "../outside", "a/../b", "a//b", "./a", "nul\0x"] {
            XCTAssertNil(SyncLocation.resolve(override: nil, containerRoot: nil, driveRoot: drive, driveFolder: path))
            XCTAssertNil(SyncLocation.resolve(override: nil, containerRoot: container, driveRoot: drive,
                                              driveFolder: "App", containerSubfolder: path))
            XCTAssertNil(SyncLocation.drive(drive).fileURL(named: path))
        }
        XCTAssertNil(SyncLocation.resolve(override: nil, containerRoot: URL(string: "https://example.com")!,
                                          driveRoot: drive, driveFolder: "App"))
    }
}
