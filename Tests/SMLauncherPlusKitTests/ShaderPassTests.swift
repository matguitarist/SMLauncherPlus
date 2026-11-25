import Foundation
import ProcessKit
import Testing

/// S-010: the launcher's filters render through real OpenGL the way the game draws them. With the
/// enhanced renderer the game hands a filter the picture already upscaled (InputSize 768×672 at scale 3,
/// wider in widescreen), so a filter must measure SNES pixels, not texels, to show its effect.
@Suite(.serialized) struct ShaderPassTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let passes = repo.appending(path: "Sources/SMLauncherPlus/Shaders/_passes")

    /// Builds Tests/Support/render_pass.c once per run (C stays out of the Swift test target).
    static let renderer: URL? = {
        let source = repo.appending(path: "Tests/Support/render_pass.c")
        let binary = FileManager.default.temporaryDirectory.appending(path: "render_pass-\(UUID().uuidString)")
        let clang = try? Shell.runSync("/usr/bin/clang", ["-O1", "-o", binary.path, source.path, "-framework", "OpenGL"])
        return clang?.succeeded == true ? binary : nil
    }()

    struct Render { var row: [Int]; var column: [Int] }

    static func render(_ pass: String, input: (Int, Int), output: (Int, Int), pattern: String = "flat", row: Int? = nil) throws -> Render {
        let renderer = try #require(renderer, "render_pass.c doesn't build")
        let run = try Shell.runSync(renderer.path, [passes.appending(path: "\(pass)-pass.glsl").path, "\(input.0)", "\(input.1)",
                                                    "\(output.0)", "\(output.1)", pattern] + (row.map { ["\($0)"] } ?? []))
        #expect(run.succeeded, "render_pass exited \(run.status) for \(pass)")
        var lines = run.text.split(separator: "\n").map { $0.split(separator: " ").dropFirst().compactMap { Int($0) } }
        while lines.count < 2 { lines.append([]) }
        return Render(row: lines[0], column: lines[1])
    }

    /// Darkest and brightest values in a strip, away from the edges.
    static func contrast(_ values: [Int]) -> Int {
        let middle = values.dropFirst(values.count / 4).dropLast(values.count / 4)
        return (middle.max() ?? 0) - (middle.min() ?? 0)
    }

    /// The SNES picture at scale 3, 4:3 and widescreen, and the plain 256×224 one.
    static let sizes: [(input: (Int, Int), output: (Int, Int))] = [
        ((768, 672), (768, 672)),
        ((1194, 672), (1194, 672)),
        ((256, 224), (768, 672)),
    ]

    @Test func lcdGridDrawsAGridAtEveryScale() throws {
        for size in Self.sizes {
            let render = try Self.render("lcd-grid", input: size.input, output: size.output)
            #expect(Self.contrast(render.row) > 30 && Self.contrast(render.column) > 30,
                    "no grid at input \(size.input): row contrast \(Self.contrast(render.row)), column \(Self.contrast(render.column))")
        }
    }

    @Test func crtSoftDrawsScanlinesAtEveryScale() throws {
        for size in Self.sizes {
            let render = try Self.render("crt-soft", input: size.input, output: size.output)
            #expect(Self.contrast(render.column) > 30, "no scanlines at input \(size.input): column contrast \(Self.contrast(render.column))")
        }
    }

    /// Sharp and Warm Composite work across neighboring SNES pixels: at scale 3 they must change the
    /// picture as much as at scale 1.
    @Test func sharpAndWarmCompositeAreAsStrongUpscaled() throws {
        for pass in ["sharp", "warm-composite"] {
            // SNES row 113, read from its middle texel row in the upscaled picture.
            let native = try Self.render(pass, input: (256, 224), output: (256, 224), pattern: "checker", row: 113)
            let upscaled = try Self.render(pass, input: (768, 672), output: (768, 672), pattern: "checker", row: 113 * 3 + 1)
            // Each SNES pixel's middle texel, so the two renders line up.
            let sampled = stride(from: 1, to: upscaled.row.count, by: 3).map { upscaled.row[$0] }
            let difference = zip(native.row, sampled).map { abs($0 - $1) }.max() ?? 255
            #expect(difference <= 8, "\(pass) upscaled differs from native by up to \(difference)")
        }
    }
}
