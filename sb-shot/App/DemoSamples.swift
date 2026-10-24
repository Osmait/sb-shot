#if DEBUG
import AppKit
import AVFoundation
import SwiftUI

/// Synthetic content for demo mode: mock app screenshots, a wallpaper and a short video.
/// Nothing here comes from the user's machine.
@MainActor
enum DemoSamples {
    static let dashboardSize = CGSize(width: 1200, height: 750)

    static func dashboard() -> NSImage {
        image(of: DashboardMock(), size: dashboardSize)
    }

    static func tasks() -> NSImage {
        image(of: TasksMock(), size: CGSize(width: 1100, height: 700))
    }

    static func code() -> NSImage {
        image(of: CodeMock(), size: CGSize(width: 960, height: 600))
    }

    /// Renders a SwiftUI view at 2x, like a screenshot taken on a Retina display.
    static func image(of view: some View, size: CGSize, scale: CGFloat = 2) -> NSImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return NSImage(size: size) }
        return NSImage(cgImage: cgImage, size: size)
    }

    /// Crop in points of a 2x image.
    static func crop(_ image: NSImage, to rect: CGRect) -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let scale = CGFloat(cgImage.width) / image.size.width
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        guard let cropped = cgImage.cropping(to: pixels.integral) else { return image }
        return NSImage(cgImage: cropped, size: rect.size)
    }

    // MARK: - Annotations

    /// Annotations placed over the dashboard mock. Returns the document and the annotation to select.
    static func annotatedDocument() -> (document: EditorDocument, selectedID: UUID) {
        let red = CaptureEditorViewModel.palette[0]
        let blue = CaptureEditorViewModel.palette[4]
        let arrowStyle = AnnotationStyle(color: red, lineWidth: 6, fill: false)
        let arrow = EditorAnnotation(kind: .arrow(start: CGPoint(x: 560, y: 352), end: CGPoint(x: 778, y: 404)), style: arrowStyle)

        var textStyle = AnnotationStyle(color: red, lineWidth: 4, fill: false, fontSize: 24)
        textStyle.textBackground = true

        var blurStyle = AnnotationStyle(color: red, lineWidth: 4, fill: false)
        blurStyle.obfuscation = .blur

        let counterStyle = AnnotationStyle(color: blue, lineWidth: 5, fill: false)
        let annotations = [
            EditorAnnotation(kind: .obfuscate(CGRect(x: 266, y: 634, width: 528, height: 52)), style: blurStyle),
            EditorAnnotation(kind: .rectangle(CGRect(x: 838, y: 262, width: 340, height: 282)), style: AnnotationStyle(color: CaptureEditorViewModel.palette[1], lineWidth: 5, fill: false)),
            EditorAnnotation(kind: .text(content: "Best month so far", origin: CGPoint(x: 312, y: 330)), style: textStyle),
            arrow,
            EditorAnnotation(kind: .counter(center: CGPoint(x: 452, y: 168)), style: counterStyle),
            EditorAnnotation(kind: .counter(center: CGPoint(x: 1144, y: 300)), style: counterStyle),
            EditorAnnotation(kind: .counter(center: CGPoint(x: 1144, y: 598)), style: counterStyle),
        ]
        return (EditorDocument(annotations: annotations), arrow.id)
    }

    // MARK: - Wallpaper

    /// Abstract gradient used as the desktop and the "Wallpaper" background, so the real one is never shown.
    static func wallpaper(size: CGSize = CGSize(width: 2880, height: 1800)) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let base = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.10, green: 0.12, blue: 0.35, alpha: 1),
            CGColor(srgbRed: 0.33, green: 0.20, blue: 0.62, alpha: 1),
            CGColor(srgbRed: 0.86, green: 0.38, blue: 0.62, alpha: 1),
        ] as CFArray, locations: [0, 0.55, 1])!
        context.drawLinearGradient(base, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])

        // Soft glows for depth.
        let glows: [(CGPoint, CGFloat, CGColor)] = [
            (CGPoint(x: size.width * 0.2, y: size.height * 0.8), size.width * 0.45, CGColor(srgbRed: 0.25, green: 0.65, blue: 1, alpha: 0.55)),
            (CGPoint(x: size.width * 0.85, y: size.height * 0.25), size.width * 0.4, CGColor(srgbRed: 1, green: 0.55, blue: 0.45, alpha: 0.5)),
            (CGPoint(x: size.width * 0.55, y: size.height * 0.5), size.width * 0.3, CGColor(srgbRed: 0.6, green: 0.4, blue: 1, alpha: 0.35)),
        ]
        for (center, radius, color) in glows {
            let glow = CGGradient(colorsSpace: space, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
            context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
        return context.makeImage()
    }

    // MARK: - Video

    /// Writes a ~5 s MP4 of the dashboard: the chart grows and a cursor clicks Export.
    static func writeVideo(to url: URL) async throws {
        let scale: CGFloat = 1.2
        let size = CGSize(width: dashboardSize.width * scale, height: dashboardSize.height * scale)
        let fps: Int32 = 30
        let frameCount = 5 * Int(fps)

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        for frame in 0 ..< frameCount {
            let time = Double(frame) / Double(fps)
            let view = DashboardMock(progress: min(0.35 + time / 1.4, 1), cursor: cursorState(at: time))
            let renderer = ImageRenderer(content: view.frame(width: dashboardSize.width, height: dashboardSize.height))
            renderer.scale = scale
            guard let image = renderer.cgImage, let pool = adaptor.pixelBufferPool else { continue }

            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                context.draw(image, in: CGRect(origin: .zero, size: size))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    /// Cursor path: from the chart to the Export button (click at 3 s), then to the channels card.
    private static func cursorState(at time: Double) -> DashboardMock.Cursor {
        let points: [(time: Double, point: CGPoint)] = [
            (0, CGPoint(x: 560, y: 600)),
            (1.2, CGPoint(x: 700, y: 430)),
            (2.8, CGPoint(x: 1128, y: 98)),
            (3.4, CGPoint(x: 1128, y: 98)),
            (5, CGPoint(x: 980, y: 380)),
        ]
        var position = points.last!.point
        for (from, to) in zip(points, points.dropFirst()) where time >= from.time && time <= to.time {
            let raw = (time - from.time) / max(to.time - from.time, 0.001)
            let eased = raw * raw * (3 - 2 * raw)
            position = CGPoint(x: from.point.x + (to.point.x - from.point.x) * eased, y: from.point.y + (to.point.y - from.point.y) * eased)
            break
        }
        let click = time >= 2.9 && time <= 3.5 ? (time - 2.9) / 0.6 : nil
        return DashboardMock.Cursor(position: position, click: click)
    }
}

// MARK: - Dashboard mock

/// Light "analytics" app, 1200 × 750 pt. Layout uses fixed sizes so annotations can target known positions.
private struct DashboardMock: View {
    struct Cursor {
        var position: CGPoint
        /// Click ripple progress (0...1), if a click is being shown.
        var click: Double?
    }

    var progress: Double = 1
    var cursor: Cursor?

    private let accent = Color(red: 0.36, green: 0.36, blue: 0.95)
    private let ink = Color(red: 0.11, green: 0.12, blue: 0.16)
    private let muted = Color(red: 0.45, green: 0.47, blue: 0.53)
    private let line = Color(red: 0.9, green: 0.91, blue: 0.93)

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                titleBar
                HStack(spacing: 0) {
                    sidebar.frame(width: 220)
                    Rectangle().fill(line).frame(width: 1)
                    content.frame(width: 979)
                }
                .frame(height: 706)
            }

            if let cursor {
                cursorView(cursor)
            }
        }
        .frame(width: 1200, height: 750)
        .background(Color(red: 0.965, green: 0.969, blue: 0.976))
        .environment(\.colorScheme, .light)
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { color in
                Circle().fill(color).frame(width: 12, height: 12)
            }
            Spacer()
            Text(verbatim: "Orbit — Overview")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(muted)
            Spacer()
            Color.clear.frame(width: 52)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.white)
        .overlay(alignment: .bottom) { Rectangle().fill(line).frame(height: 1) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [accent, Color(red: 0.62, green: 0.4, blue: 0.98)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "circle.hexagongrid.fill").font(.system(size: 15)).foregroundStyle(.white))
                Text(verbatim: "Orbit").font(.system(size: 17, weight: .bold)).foregroundStyle(ink)
            }
            .padding(.bottom, 18)

            sidebarItem("square.grid.2x2.fill", "Overview", selected: true)
            sidebarItem("person.2.fill", "Customers")
            sidebarItem("shippingbox.fill", "Orders")
            sidebarItem("chart.line.uptrend.xyaxis", "Reports")
            sidebarItem("puzzlepiece.extension.fill", "Integrations")
            Spacer()
            sidebarItem("gearshape.fill", "Settings")
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.98, green: 0.98, blue: 0.99))
    }

    private func sidebarItem(_ icon: String, _ title: String, selected: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).frame(width: 18)
            Text(verbatim: title).font(.system(size: 13, weight: selected ? .semibold : .regular))
            Spacer()
        }
        .foregroundStyle(selected ? accent : muted)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(selected ? accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            header.frame(height: 46)
            HStack(spacing: 16) {
                stat("Revenue", "$48,290", "+24.1%", up: true, icon: "dollarsign.circle.fill")
                stat("Active users", "12,480", "+8.3%", up: true, icon: "person.fill")
                stat("Conversion", "3.8%", "-0.4%", up: false, icon: "arrow.triangle.2.circlepath")
                stat("Avg. order", "$62.40", "+2.1%", up: true, icon: "cart.fill")
            }
            .frame(height: 110)
            HStack(spacing: 16) {
                chartCard.frame(width: 580)
                channelsCard.frame(width: 328)
            }
            .frame(height: 270)
            apiCard.frame(height: 164)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Overview").font(.system(size: 24, weight: .bold)).foregroundStyle(ink)
                Text(verbatim: "Welcome back! Here’s how your store is doing.").font(.system(size: 13)).foregroundStyle(muted)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                Text(verbatim: "Last 30 days")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(ink)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(line))
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                Text(verbatim: "Export")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(accent, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func stat(_ title: String, _ value: String, _ delta: String, up: Bool, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: title).font(.system(size: 12, weight: .medium)).foregroundStyle(muted)
                Spacer()
                Image(systemName: icon).foregroundStyle(accent.opacity(0.8))
            }
            Text(verbatim: value).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(ink)
            HStack(spacing: 4) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right").font(.system(size: 10, weight: .bold))
                Text(verbatim: delta).font(.system(size: 12, weight: .semibold))
                Text(verbatim: "vs last month").font(.system(size: 12)).foregroundStyle(muted)
            }
            .foregroundStyle(up ? Color(red: 0.13, green: 0.6, blue: 0.35) : Color(red: 0.85, green: 0.25, blue: 0.25))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(card)
    }

    private var chartCard: some View {
        let values: [Double] = [32, 41, 38, 46, 52, 49, 58, 61, 57, 66, 72, 88]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(verbatim: "Monthly revenue").font(.system(size: 15, weight: .semibold)).foregroundStyle(ink)
                Spacer()
                Text(verbatim: "2026").font(.system(size: 12, weight: .medium)).foregroundStyle(muted)
            }
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(values.indices, id: \.self) { index in
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(index == values.count - 1
                                ? AnyShapeStyle(LinearGradient(colors: [accent, Color(red: 0.62, green: 0.4, blue: 0.98)], startPoint: .bottom, endPoint: .top))
                                : AnyShapeStyle(accent.opacity(0.22)))
                            .frame(height: values[index] * 2 * eased(progress))
                        Text(verbatim: months[index]).font(.system(size: 10)).foregroundStyle(muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(card)
    }

    private var channelsCard: some View {
        let channels: [(String, Double, Color)] = [
            ("Organic search", 0.38, accent),
            ("Direct", 0.24, Color(red: 0.2, green: 0.7, blue: 0.9)),
            ("Social", 0.17, Color(red: 0.95, green: 0.55, blue: 0.3)),
            ("Referral", 0.12, Color(red: 0.3, green: 0.75, blue: 0.5)),
            ("Email", 0.09, Color(red: 0.85, green: 0.4, blue: 0.75)),
        ]
        return VStack(alignment: .leading, spacing: 13) {
            Text(verbatim: "Top channels").font(.system(size: 15, weight: .semibold)).foregroundStyle(ink)
            ForEach(channels, id: \.0) { name, share, color in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(verbatim: name).font(.system(size: 12)).foregroundStyle(ink)
                        Spacer()
                        Text(verbatim: "\(Int(share * 100))%").font(.system(size: 12, weight: .semibold)).foregroundStyle(muted)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(line)
                            Capsule().fill(color).frame(width: proxy.size.width * share * 2 * eased(progress))
                        }
                    }
                    .frame(height: 6)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(card)
    }

    private var apiCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "API access").font(.system(size: 15, weight: .semibold)).foregroundStyle(ink)
            Text(verbatim: "Use this secret key to connect your storefront. Keep it private.")
                .font(.system(size: 12)).foregroundStyle(muted)
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "key.fill").foregroundStyle(muted)
                    Text(verbatim: "orb_demo_7Hq2xLm9Vb4T0kPaZcR8wYdE3")
                        .font(.system(size: 14, design: .monospaced)).foregroundStyle(ink)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(width: 520, height: 40)
                .background(Color(red: 0.97, green: 0.97, blue: 0.98), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(line))
                pill("Copy", icon: "doc.on.doc")
                pill("Regenerate", icon: "arrow.clockwise")
            }
            .padding(.top, 14)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(card)
    }

    private func pill(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(verbatim: title)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ink)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(line))
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color.white)
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(line))
    }

    private func cursorView(_ cursor: Cursor) -> some View {
        ZStack(alignment: .topLeading) {
            if let click = cursor.click {
                Circle()
                    .stroke(accent.opacity(1 - click), lineWidth: 3)
                    .frame(width: 20 + 50 * click, height: 20 + 50 * click)
                    .position(cursor.position)
            }
            CursorShape()
                .fill(Color.black)
                .overlay(CursorShape().stroke(Color.white, lineWidth: 1.5))
                .frame(width: 18, height: 26)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .offset(x: cursor.position.x, y: cursor.position.y)
        }
        .frame(width: 1200, height: 750, alignment: .topLeading)
    }

    private func eased(_ value: Double) -> Double {
        1 - pow(1 - value, 3)
    }
}

/// Classic arrow pointer, drawn in an 18 × 26 box with the tip at the top-left corner.
private struct CursorShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 13
        let sy = rect.height / 20
        let points: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 17), CGPoint(x: 4.2, y: 13.2), CGPoint(x: 7, y: 19.5),
            CGPoint(x: 9.6, y: 18.4), CGPoint(x: 6.9, y: 12.2), CGPoint(x: 12.5, y: 12.2),
        ]
        var path = Path()
        path.addLines(points.map { CGPoint(x: rect.minX + $0.x * sx, y: rect.minY + $0.y * sy) })
        path.closeSubpath()
        return path
    }
}

// MARK: - Tasks mock

/// Dark kanban board, 1100 × 700 pt.
private struct TasksMock: View {
    private let columns: [(String, Color, [(String, String, Color)])] = [
        ("To Do", Color(red: 0.55, green: 0.58, blue: 0.66), [
            ("Design onboarding flow", "Design", Color(red: 0.75, green: 0.45, blue: 0.98)),
            ("Write release notes", "Docs", Color(red: 0.35, green: 0.7, blue: 0.95)),
            ("Audit color contrast", "Design", Color(red: 0.75, green: 0.45, blue: 0.98)),
        ]),
        ("In Progress", Color(red: 1, green: 0.7, blue: 0.25), [
            ("Export to GIF", "Feature", Color(red: 0.3, green: 0.8, blue: 0.55)),
            ("Scrolling capture", "Feature", Color(red: 0.3, green: 0.8, blue: 0.55)),
        ]),
        ("Review", Color(red: 0.4, green: 0.6, blue: 1), [
            ("Pin window zoom", "Feature", Color(red: 0.3, green: 0.8, blue: 0.55)),
            ("Fix retina blur radius", "Bug", Color(red: 1, green: 0.42, blue: 0.4)),
        ]),
        ("Done", Color(red: 0.3, green: 0.8, blue: 0.55), [
            ("Quick Access overlay", "Feature", Color(red: 0.3, green: 0.8, blue: 0.55)),
            ("Wallpaper backgrounds", "Feature", Color(red: 0.3, green: 0.8, blue: 0.55)),
            ("Spanish localization", "i18n", Color(red: 1, green: 0.7, blue: 0.25)),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Sprint 14").font(.system(size: 26, weight: .bold))
                    Text(verbatim: "Oct 13 – Oct 27 · 10 tasks").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                HStack(spacing: -8) {
                    ForEach([Color.pink, .orange, .teal, .indigo], id: \.self) { color in
                        Circle().fill(color.gradient).frame(width: 30, height: 30).overlay(Circle().stroke(Color(white: 0.1), lineWidth: 2))
                    }
                }
                Text(verbatim: "+ New Task")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(Color(red: 0.4, green: 0.45, blue: 1), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 16)
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(columns, id: \.0) { title, color, cards in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Circle().fill(color).frame(width: 8, height: 8)
                            Text(verbatim: title).font(.system(size: 13, weight: .semibold))
                            Text(verbatim: "\(cards.count)").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                        }
                        ForEach(cards, id: \.0) { name, tag, tagColor in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(verbatim: tag)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(tagColor)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(tagColor.opacity(0.15), in: Capsule())
                                Text(verbatim: name).font(.system(size: 14, weight: .medium))
                                HStack {
                                    Image(systemName: "checklist").font(.system(size: 11))
                                    Text(verbatim: "2/4").font(.system(size: 11))
                                    Spacer()
                                    Circle().fill(Color.teal.gradient).frame(width: 20, height: 20)
                                }
                                .foregroundStyle(.white.opacity(0.45))
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.06)))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(32)
        .foregroundStyle(.white)
        .background(Color(white: 0.09))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Code mock

/// Dark code editor with a Swift snippet, 960 × 600 pt.
private struct CodeMock: View {
    private static let keyword = Color(red: 0.99, green: 0.37, blue: 0.64)
    private static let type = Color(red: 0.36, green: 0.85, blue: 0.95)
    private static let string = Color(red: 0.99, green: 0.55, blue: 0.4)
    private static let comment = Color(red: 0.47, green: 0.53, blue: 0.6)
    private static let plain = Color(white: 0.9)

    private let lines: [[(String, Color)]] = [
        [("import", keyword), (" SwiftUI", plain)],
        [],
        [("/// A card that shows a capture thumbnail.", comment)],
        [("struct", keyword), (" CaptureCard", type), (": ", plain), ("View", type), (" {", plain)],
        [("    let", keyword), (" title: ", plain), ("String", type)],
        [("    let", keyword), (" image: ", plain), ("Image", type)],
        [("    @State private var", keyword), (" isHovering = ", plain), ("false", keyword)],
        [],
        [("    var", keyword), (" body: ", plain), ("some", keyword), (" View", type), (" {", plain)],
        [("        VStack", type), ("(alignment: .leading, spacing: ", plain), ("8", string), (") {", plain)],
        [("            image", plain)],
        [("                .resizable()", plain)],
        [("                .clipShape(", plain), ("RoundedRectangle", type), ("(cornerRadius: ", plain), ("12", string), ("))", plain)],
        [("            Text", type), ("(title)", plain)],
        [("                .font(.headline)", plain)],
        [("        }", plain)],
        [("        .scaleEffect(isHovering ? ", plain), ("1.03", string), (" : ", plain), ("1", string), (")", plain)],
        [("        .onHover { isHovering = $0 }", plain)],
        [("    }", plain)],
        [("}", plain)],
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: "EXPLORER").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                ForEach(["CaptureCard.swift", "ContentView.swift", "Theme.swift", "Assets"], id: \.self) { name in
                    HStack(spacing: 6) {
                        Image(systemName: name.hasSuffix(".swift") ? "swift" : "folder.fill")
                            .foregroundStyle(name.hasSuffix(".swift") ? Color.orange : Color.blue)
                        Text(verbatim: name).foregroundStyle(.white.opacity(name == "CaptureCard.swift" ? 0.95 : 0.6))
                    }
                    .font(.system(size: 12))
                }
                Spacer()
            }
            .padding(16)
            .frame(width: 200)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(red: 0.1, green: 0.11, blue: 0.13))

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "swift").foregroundStyle(.orange)
                    Text(verbatim: "CaptureCard.swift").foregroundStyle(.white.opacity(0.9))
                }
                .font(.system(size: 12))
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(Color(red: 0.14, green: 0.15, blue: 0.18))

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(lines.indices, id: \.self) { index in
                        HStack(spacing: 16) {
                            Text(verbatim: "\(index + 1)")
                                .foregroundStyle(.white.opacity(0.25))
                                .frame(width: 24, alignment: .trailing)
                            lines[index].reduce(Text(verbatim: "")) { $0 + Text(verbatim: $1.0).foregroundStyle($1.1) }
                        }
                        .font(.system(size: 14, design: .monospaced))
                    }
                }
                .padding(18)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.12, green: 0.13, blue: 0.16))
        }
        .environment(\.colorScheme, .dark)
    }
}
#endif
