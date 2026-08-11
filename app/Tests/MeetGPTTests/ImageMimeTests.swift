import Foundation
import Testing
@testable import MeetGPT

/// Sniffing an image's type from its first bytes.
///
/// Every attached image is sent to the model as `data:<mime>;base64,…`. The
/// mime is not cosmetic: providers decode against the declared type, so getting
/// it wrong means the image is rejected or misread, and the user sees an answer
/// that ignores the screenshot they attached — with no error anywhere.
///
/// Layered on one base fact — a PNG is recognised — with each later test adding
/// a format, then the cases where a confident answer would be wrong.
@Suite("Image MIME sniffing")
struct ImageMimeTests {

    /// A header followed by filler, so length-sensitive branches see real data.
    private func bytes(_ header: [UInt8], padTo length: Int = 32) -> Data {
        var all = header
        all.append(contentsOf: [UInt8](repeating: 0, count: max(0, length - header.count)))
        return Data(all)
    }

    // MARK: - Base

    @Test("a PNG is recognised by its signature")
    func detectsPNG() {
        // 89 50 4E 47 0D 0A 1A 0A
        #expect(ImageMime.type(bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == "image/png")
    }

    // MARK: - Layer: the other formats

    @Test("a JPEG is recognised by its SOI marker")
    func detectsJPEG() {
        #expect(ImageMime.type(bytes([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg")
        // JFIF and EXIF variants differ after the marker; both are JPEG.
        #expect(ImageMime.type(bytes([0xFF, 0xD8, 0xFF, 0xE1])) == "image/jpeg")
    }

    @Test("a GIF is recognised")
    func detectsGIF() {
        // "GIF89a"
        #expect(ImageMime.type(bytes([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])) == "image/gif")
        // "GIF87a" — same first two bytes, still a GIF.
        #expect(ImageMime.type(bytes([0x47, 0x49, 0x46, 0x38, 0x37, 0x61])) == "image/gif")
    }

    @Test("a WebP is recognised by RIFF plus the WEBP tag")
    func detectsWebP() {
        // "RIFF" ???? "WEBP" — the tag sits at bytes 8–11, after the size.
        let webp: [UInt8] = [0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
                             0x57, 0x45, 0x42, 0x50]
        #expect(ImageMime.type(bytes(webp)) == "image/webp")
    }

    // MARK: - Layer: where a confident answer would be wrong

    @Test("a RIFF container that is not WebP is not claimed as WebP")
    func riffWithoutWebPTagIsNotWebP() {
        // WAV and AVI open with "RIFF" too. Checking only those four bytes
        // would declare a dropped audio file an image — the real trap here.
        let wav: [UInt8] = [0x52, 0x49, 0x46, 0x46, 0x24, 0x08, 0x00, 0x00,
                            0x57, 0x41, 0x56, 0x45]   // "WAVE"
        #expect(ImageMime.type(bytes(wav)) != "image/webp")
        let avi: [UInt8] = [0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
                            0x41, 0x56, 0x49, 0x20]   // "AVI "
        #expect(ImageMime.type(bytes(avi)) != "image/webp")
    }

    @Test("a truncated RIFF header cannot be read as WebP")
    func truncatedRIFFIsNotWebP() {
        // The tag lives at bytes 8–11; fewer than 12 bytes means there is
        // nothing to check, and indexing them would trap.
        #expect(ImageMime.type(Data([0x52, 0x49, 0x46, 0x46])) != "image/webp")
        #expect(ImageMime.type(Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00])) != "image/webp")
    }

    @Test("data too short to identify falls back instead of trapping")
    func shortDataIsSafe() {
        // Fewer than four bytes cannot match any signature. The requirement is
        // that it returns something rather than crashing on a subscript.
        for count in 0...3 {
            let data = Data([UInt8](repeating: 0xFF, count: count))
            #expect(ImageMime.type(data) == "image/jpeg", "\(count) bytes")
        }
    }

    @Test("an unrecognised format falls back to JPEG")
    func unknownFallsBackToJPEG() {
        // JPEG is the safe default: it is what a camera or a screenshot most
        // often is, and every vision provider accepts it.
        #expect(ImageMime.type(bytes([0x00, 0x01, 0x02, 0x03])) == "image/jpeg")
        #expect(ImageMime.type(bytes([0x25, 0x50, 0x44, 0x46])) == "image/jpeg")   // "%PDF"
        #expect(ImageMime.type(bytes([0x42, 0x4D])) == "image/jpeg")               // BMP
    }

    @Test("only the header decides — trailing content never changes the answer")
    func onlyTheHeaderMatters() {
        // A large image must not be scanned end to end, and bytes later in the
        // file must not be able to flip the verdict.
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(Data([UInt8](repeating: 0xFF, count: 100_000)))   // JPEG-looking filler
        #expect(ImageMime.type(png) == "image/png")
    }

    @Test("every answer is a type a vision provider will accept")
    func alwaysReturnsAServableType() {
        // The value goes straight into a data URL; an empty or invented type
        // would be rejected by the provider rather than by us.
        let servable: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
        let samples: [[UInt8]] = [
            [], [0xFF], [0x89, 0x50, 0x4E, 0x47], [0xFF, 0xD8, 0xFF, 0xE0],
            [0x47, 0x49, 0x46, 0x38], [0x52, 0x49, 0x46, 0x46], [0xDE, 0xAD, 0xBE, 0xEF],
        ]
        for sample in samples {
            let type = ImageMime.type(Data(sample))
            #expect(servable.contains(type), "\(sample) produced \(type)")
        }
    }
}
