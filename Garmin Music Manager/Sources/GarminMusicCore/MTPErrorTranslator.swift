import Foundation

/// Maps raw libmtp/libusb error text to user-facing wording. The raw text stays
/// available in `MTPHelperError.diagnosticDetail` for debugging.
public enum MTPErrorTranslator {
    public static func friendlyMessage(for rawMessages: [String]) -> String? {
        let combined = rawMessages.joined(separator: " ").lowercased()
        guard !combined.isEmpty else { return nil }

        if combined.contains("claim_interface")
            || combined.contains("libusb_error_access")
            || combined.contains("device is busy")
            || combined.contains("resource busy") {
            return "Another app is using the Garmin. Close Garmin Express, OpenMTP, or Android File Transfer and try again."
        }

        if combined.contains("object too large")
            || combined.contains("store full")
            || combined.contains("storage full")
            || combined.contains("not enough space")
            || combined.contains("store_full") {
            return "There is not enough free space on the Garmin for this file."
        }

        if combined.contains("pipe error")
            || combined.contains("stall")
            || combined.contains("connection reset")
            || combined.contains("lost contact")
            || combined.contains("device disconnected")
            || combined.contains("i/o error")
            || combined.contains("usb transfer") {
            return "The USB connection to the Garmin was interrupted. Check the cable, reconnect the watch, and try again."
        }

        if combined.contains("unable to open raw device")
            || combined.contains("failed to open session")
            || combined.contains("could not open the usb connection")
            || combined.contains("libmtp error connecting") {
            return "The Garmin's MTP connection could not be opened. Reconnect the watch and try again."
        }

        return nil
    }
}
