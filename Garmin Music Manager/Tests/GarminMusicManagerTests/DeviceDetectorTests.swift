import XCTest
@testable import GarminMusicManager

final class USBProfilerItemTests: XCTestCase {
    func testParsesLegacySPUSBDataTypeKeys() {
        let item = USBProfilerItem(profilerDictionary: [
            "_name": "Forerunner 955 Solar",
            "manufacturer": "Garmin",
            "vendor_id": "0x091e",
            "product_id": "0x4fb8",
            "serial_num": "0000cd9a80d8"
        ])

        XCTAssertNotNil(item)
        XCTAssertEqual(item?.name, "Forerunner 955 Solar")
        XCTAssertEqual(item?.normalizedVendorID, "091e")
        XCTAssertEqual(item?.normalizedProductID, "4fb8")
        XCTAssertEqual(item?.serialNumber, "0000cd9a80d8")
        XCTAssertTrue(item?.isGarminVendor == true)
        XCTAssertEqual(item?.displayName, "Forerunner 955 Solar")
    }

    func testParsesAppleSiliconSPUSBHostDataTypeKeys() {
        // Modern macOS reports watches under SPUSBHostDataType with USBDeviceKey* fields
        // and often "_name": "Unnamed Device" when USB string descriptors are empty.
        let item = USBProfilerItem(profilerDictionary: [
            "_name": "Unnamed Device",
            "USBDeviceKeyVendorID": "0x091e",
            "USBDeviceKeyProductID": "0x4fb8",
            "USBDeviceKeySerialNumber": "0000cd9a80d8",
            "USBKeyLocationID": "0x01100000"
        ])

        XCTAssertNotNil(item)
        XCTAssertTrue(item?.isGarminVendor == true)
        XCTAssertEqual(item?.normalizedVendorID, "091e")
        XCTAssertEqual(item?.normalizedProductID, "4fb8")
        XCTAssertEqual(item?.serialNumber, "0000cd9a80d8")
        XCTAssertEqual(item?.displayName, "Garmin watch")
    }

    func testSkipsUSBBusControllerNodes() {
        let item = USBProfilerItem(profilerDictionary: [
            "_name": "USB 3.1 Bus",
            "Driver": "AppleT6000USBXHCI",
            "USBKeyHardwareType": "Built-in",
            "USBKeyLocationID": "0x02000000"
        ])
        XCTAssertNil(item)
    }

    func testParsesIoregVendorAsGarmin() {
        let item = USBProfilerItem(ioregDictionary: [
            "idVendor": 2334, // 0x091e
            "idProduct": 20408, // 0x4fb8
            "USB Serial Number": "0000cd9a80d8",
            "locationID": 17825792
        ])

        XCTAssertNotNil(item)
        XCTAssertTrue(item?.isGarminVendor == true)
        XCTAssertEqual(item?.normalizedVendorID, "091e")
        XCTAssertEqual(item?.normalizedProductID, "4fb8")
        XCTAssertEqual(item?.serialNumber, "0000cd9a80d8")
        XCTAssertEqual(item?.displayName, "Garmin watch")
    }

    func testNormalizeHexIDAcceptsDecimalAndAnnotatedForms() {
        XCTAssertEqual(USBProfilerItem.normalizeHexID("0x091e"), "091e")
        XCTAssertEqual(USBProfilerItem.normalizeHexID("0x091e (Garmin International)"), "091e")
        XCTAssertEqual(USBProfilerItem.normalizeHexID("2334"), "091e")
        XCTAssertEqual(USBProfilerItem.normalizeHexID("4fb8"), "4fb8")
        XCTAssertNil(USBProfilerItem.normalizeHexID(nil))
        XCTAssertNil(USBProfilerItem.normalizeHexID("  "))
    }

    func testGarminUSBDeviceDisplayNameForUnnamed() {
        let device = GarminUSBDevice(
            id: "test",
            name: "Unnamed Device",
            manufacturer: nil,
            vendorID: "0x091e",
            productID: "0x4fb8",
            serialNumber: "0000cd9a80d8"
        )
        XCTAssertEqual(device.displayName, "Garmin watch")
        XCTAssertTrue(device.isLikelyGarmin)
    }

    func testLiveDetectorFindsPluggedInGarminWhenPresent() {
        // Integration-style: only asserts when a real Garmin is on USB right now.
        let devices = DeviceDetector().findConnectedGarminUSBDevices()
        let signature = DeviceDetector().connectedGarminUSBSignature()
        if devices.isEmpty {
            // No watch attached in this environment — parsing unit tests above still cover the bug.
            XCTAssertEqual(signature, "")
            return
        }
        XCTAssertFalse(signature.isEmpty, "Signature should be non-empty when USB devices are listed")
        XCTAssertTrue(devices.contains(where: \.isLikelyGarmin))
        XCTAssertFalse(devices.contains(where: { $0.displayName.lowercased() == "unnamed device" }))
    }
}
