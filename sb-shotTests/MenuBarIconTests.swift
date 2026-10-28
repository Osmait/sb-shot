import AppKit
@testable import SbShot
import Testing

@MainActor
struct MenuBarIconTests {
    @Test func isAnEighteenPointTemplateImage() throws {
        let image = MenuBarIcon.image
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))

        // Something is actually drawn.
        let data = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: data))
        var opaque = 0
        for x in 0 ..< rep.pixelsWide {
            for y in 0 ..< rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                opaque += 1
            }
        }
        #expect(opaque > 20)
    }
}
