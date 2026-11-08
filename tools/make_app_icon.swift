// Erzeugt das App-Icon (Liquid-Glass-Stil) samt Top-Shelf-Bildern und Vorschau reproduzierbar
// mit Core Graphics und Core Image. Kein Bilddienst, keine Vorlagen: alles wird aus Formeln gezeichnet.
//
// Aufruf aus dem Repo-Wurzelverzeichnis:
//   swift tools/make_app_icon.swift                    # Standardvariante in den Assets-Katalog, alle Vorschauen
//   swift tools/make_app_icon.swift --variant globus   # andere Variante in den Assets-Katalog schreiben
//   swift tools/make_app_icon.swift --preview-only     # nur docs/icon/ neu erzeugen, Katalog nicht anfassen
//
// Ausgabe:
//   _Project/Browser/Assets.xcassets/App Icon & Top Shelf Image.brandassets/…  (Ebenen + Top Shelf, 1x/2x)
//   docs/icon/preview.png              Vorschau der Variante im Katalog (Icon groß, Ebenen, Top Shelf)
//   docs/icon/variante-<name>.png      Vorschau jeder anderen Variante
//
// tvOS-Icons sind geschichtete Bildstapel (Parallax). Icon Composer (.icon) unterstützt tvOS nicht,
// deshalb backt das Skript den Glas-Look (Lichtbrechung, Lichtkante, Tiefe) in drei Ebenen:
//   Hinten: Farbverlauf (Farben aus dem Regenbogen-Glow der App)
//   Mitte:  Glasscheibe mit gebrochenem, weichgezeichnetem Hintergrund, Lichtkante und Schatten
//   Vorne:  Symbol (Kompassnadel mit Umlaufbahn bzw. Globusraster) mit Glanz und Schlagschatten
import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO

// MARK: - Grundlagen

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ciContext = CIContext(options: [
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    .outputColorSpace: srgb,
    .useSoftwareRenderer: true, // gleiche Ausgabe auf jedem Mac
])

enum Variant: String, CaseIterable {
    case nadel   // Glas-Kompassnadel mit Umlaufbahn um die Glasscheibe
    case globus  // Globusraster auf der Glasscheibe
    var title: String {
        switch self {
        case .nadel: return "Variante „Nadel“ – Kompassnadel mit Umlaufbahn"
        case .globus: return "Variante „Globus“ – Glasglobus mit Raster"
        }
    }
}

/// Standard im Assets-Katalog.
let defaultVariant = Variant.nadel

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [r, g, b, a])!
}

func white(_ a: CGFloat) -> CGColor { color(1, 1, 1, a) }
func black(_ a: CGFloat) -> CGColor { color(0, 0, 0, a) }

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

func makeContext(_ w: Int, _ h: Int, opaque: Bool = false) -> CGContext {
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: srgb, bitmapInfo: info)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    return ctx
}

func draw(_ w: Int, _ h: Int, opaque: Bool = false, _ body: (CGContext) -> Void) -> CGImage {
    let ctx = makeContext(w, h, opaque: opaque)
    body(ctx)
    return ctx.makeImage()!
}

func render(_ image: CIImage, _ w: Int, _ h: Int) -> CGImage {
    ciContext.createCGImage(image, from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: srgb)!
}

/// Gaußscher Weichzeichner; `clamp` für randlose Flächen (Hintergrund), sonst läuft der Rand transparent aus.
func blur(_ img: CGImage, _ radius: CGFloat, clamp: Bool = false) -> CGImage {
    guard radius > 0.01 else { return img }
    var ci = CIImage(cgImage: img)
    if clamp { ci = ci.clampedToExtent() }
    let out = ci.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
    return render(out, img.width, img.height)
}

/// Zeichnet etwas in eine eigene Ebene, zeichnet sie weich und legt sie in `ctx`.
func softLayer(_ ctx: CGContext, blurRadius: CGFloat, alpha: CGFloat = 1, _ body: (CGContext) -> Void) {
    let img = blur(draw(ctx.width, ctx.height, body), blurRadius)
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    ctx.restoreGState()
}

func writePNG(_ img: CGImage, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    precondition(CGImageDestinationFinalize(dest), "PNG nicht geschrieben: \(url.path)")
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
}

// MARK: - Geometrie des Emblems

/// Mittelpunkt und Radius der Glasscheibe in Pixeln (y nach oben, wie Core Graphics).
struct Emblem {
    var c: CGPoint
    var r: CGFloat
}

/// Umlaufbahn (Variante „Nadel“): geneigte Ellipse um die Scheibe.
struct Orbit {
    let e: Emblem
    var rx: CGFloat { e.r * 1.36 }
    var ry: CGFloat { e.r * 0.34 }
    let tilt: CGFloat = 16 * .pi / 180
    var width: CGFloat { e.r * 0.085 }

    func point(_ t: CGFloat) -> CGPoint {
        let x = rx * cos(t), y = ry * sin(t)
        return CGPoint(x: e.c.x + x * cos(tilt) - y * sin(tilt), y: e.c.y + x * sin(tilt) + y * cos(tilt))
    }

    /// Bogen von t0 bis t1 (Bogenmaß) als Pfad.
    func arc(_ t0: CGFloat, _ t1: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let n = 240
        for i in 0...n {
            let p = point(t0 + (t1 - t0) * CGFloat(i) / CGFloat(n))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    // Vorderer Teil: untere Hälfte (zum Betrachter), mit kleiner Überlappung an den Enden.
    var front: CGPath { arc(.pi - 0.10, 2 * .pi + 0.10) }
    var back: CGPath { arc(0, .pi) }
}

// MARK: - Palette (aus BrowserGlowView.rainbowColors abgeleitet, für den Hintergrund satter/dunkler)

struct Blob {
    let u: CGFloat, v: CGFloat // Lage relativ zur Fläche (0…1, v nach oben)
    let radius: CGFloat        // relativ zur längeren Kante
    let color: CGColor
}

let blobs: [Blob] = [
    Blob(u: 0.10, v: 0.95, radius: 0.62, color: color(0.56, 0.32, 0.96)),  // Violett
    Blob(u: 0.88, v: 1.00, radius: 0.55, color: color(0.97, 0.38, 0.70)),  // Pink
    Blob(u: 1.00, v: 0.12, radius: 0.55, color: color(1.00, 0.58, 0.33)),  // Orange
    Blob(u: 0.62, v: -0.05, radius: 0.40, color: color(1.00, 0.40, 0.50)), // Koralle
    Blob(u: 0.00, v: 0.05, radius: 0.55, color: color(0.22, 0.52, 1.00)),  // Blau
    Blob(u: 0.30, v: 0.40, radius: 0.30, color: color(0.30, 0.74, 1.00)),  // Himmelblau
]

/// Die Glow-Farben der App, Reihenfolge wie in BrowserGlowView.
let rainbow: [(CGFloat, CGFloat, CGFloat)] = [
    (0.74, 0.51, 0.95), (0.96, 0.45, 0.74), (1.00, 0.40, 0.47), (1.00, 0.73, 0.44),
    (0.55, 0.62, 1.00), (0.35, 0.78, 1.00), (0.74, 0.51, 0.95),
]

/// Kegelverlauf aus schmalen Tortenstücken (Core Graphics hat auf macOS keinen eigenen).
func drawConic(_ ctx: CGContext, center: CGPoint, radius: CGFloat, _ stops: [(CGFloat, CGFloat, CGFloat)]) {
    let n = 720
    for i in 0..<n {
        let t = CGFloat(i) / CGFloat(n) * CGFloat(stops.count - 1)
        let k = min(Int(t), stops.count - 2), f = t - CGFloat(k)
        let a = stops[k], b = stops[k + 1]
        ctx.setFillColor(color(a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f))
        let a0 = CGFloat(i) / CGFloat(n) * 2 * .pi + .pi / 4, a1 = (CGFloat(i) + 1.2) / CGFloat(n) * 2 * .pi + .pi / 4
        ctx.move(to: center)
        ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
        ctx.closePath()
        ctx.fillPath()
    }
}

// MARK: - Hinten: Farbverlauf

func renderBack(_ w: Int, _ h: Int) -> CGImage {
    let W = CGFloat(w), H = CGFloat(h), L = max(W, H)
    let raw = draw(w, h, opaque: true) { ctx in
        // Grundton: tiefes Indigo, damit Glas und Weiß darauf leuchten.
        ctx.drawLinearGradient(gradient([(0, color(0.20, 0.20, 0.62)), (1, color(0.40, 0.14, 0.52))]),
                               start: CGPoint(x: 0, y: 0), end: CGPoint(x: W, y: H), options: [])
        for b in blobs {
            let p = CGPoint(x: b.u * W, y: b.v * H)
            let comps = b.color.components!
            ctx.drawRadialGradient(gradient([(0, b.color), (0.55, color(comps[0], comps[1], comps[2], 0.55)),
                                             (1, color(comps[0], comps[1], comps[2], 0))]),
                                   startCenter: p, startRadius: 0, endCenter: p, endRadius: b.radius * L,
                                   options: [])
        }
        // Leichte Abdunklung zur Mitte unten, gibt dem Glas einen ruhigen Untergrund.
        let m = CGPoint(x: W / 2, y: H * 0.35)
        ctx.drawRadialGradient(gradient([(0, color(0.10, 0.06, 0.32, 0.30)), (1, color(0.10, 0.06, 0.32, 0))]),
                               startCenter: m, startRadius: 0, endCenter: m, endRadius: 0.5 * L, options: [])
    }
    return blur(raw, 0.04 * H, clamp: true)
}

// MARK: - Mitte: Glasscheibe

func drawOrbitStroke(_ ctx: CGContext, _ o: Orbit, _ path: CGPath, front: Bool) {
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    // Glasröhre: weißer Körper, oben heller Glanzstreifen.
    ctx.addPath(path)
    ctx.setLineWidth(o.width)
    ctx.setStrokeColor(front ? white(0.95) : white(0.70))
    ctx.strokePath()
    ctx.restoreGState()
    if front {
        // Glanz auf der Oberseite der Röhre: dünne Linie, leicht nach oben versetzt.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: o.width * 0.18)
        ctx.addPath(path)
        ctx.setLineCap(.round)
        ctx.setLineWidth(o.width * 0.32)
        ctx.setStrokeColor(white(1))
        ctx.strokePath()
        ctx.restoreGState()
        // Untere Kante etwas getönt (Lichtbrechung des Hintergrunds).
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -o.width * 0.30)
        ctx.addPath(path)
        ctx.setLineCap(.round)
        ctx.setLineWidth(o.width * 0.22)
        ctx.setStrokeColor(color(1.0, 0.80, 0.86, 0.85))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

func renderMiddle(_ w: Int, _ h: Int, _ e: Emblem, back: CGImage, variant: Variant) -> CGImage {
    let full = CGRect(x: 0, y: 0, width: w, height: h)
    let disc = circle(e.c, e.r)
    let orbit = Orbit(e: e)

    // Was hinter der Scheibe liegt (Hintergrund plus hinterer Bahnbogen), wird gebrochen.
    let behind = draw(w, h, opaque: true) { ctx in
        ctx.draw(back, in: full)
        if variant == .nadel { drawOrbitStroke(ctx, orbit, orbit.back, front: false) }
    }
    let lens = CIImage(cgImage: behind).clampedToExtent()
        .applyingFilter("CIBumpDistortion", parameters: [
            kCIInputCenterKey: CIVector(x: e.c.x, y: e.c.y),
            kCIInputRadiusKey: e.r * 1.02,
            kCIInputScaleKey: 0.55,
        ])
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: e.r * 0.07])
        .applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1.30, kCIInputBrightnessKey: 0.07, kCIInputContrastKey: 1.04,
        ])
    let refracted = render(lens, w, h)

    return draw(w, h) { ctx in
        // Schatten der Scheibe auf dem Hintergrund (Licht von oben links).
        softLayer(ctx, blurRadius: e.r * 0.10, alpha: 0.55) { s in
            s.setFillColor(color(0.10, 0.02, 0.25, 1))
            s.fillEllipse(in: circle(e.c + CGPoint(x: e.r * 0.05, y: -e.r * 0.09), e.r * 0.98))
        }
        if variant == .nadel { drawOrbitStroke(ctx, orbit, orbit.back, front: false) }

        // Glaskörper: gebrochener Hintergrund.
        ctx.saveGState()
        ctx.addEllipse(in: disc)
        ctx.clip()
        ctx.draw(refracted, in: full)
        // Milchigkeit
        ctx.setFillColor(white(0.10))
        ctx.fill(disc)
        // Lichteinfall von oben links, nach unten rechts auslaufend.
        ctx.drawLinearGradient(gradient([(0, white(0.42)), (0.45, white(0.06)), (1, white(0))]),
                               start: e.c + CGPoint(x: -e.r * 0.75, y: e.r * 0.75),
                               end: e.c + CGPoint(x: e.r * 0.45, y: -e.r * 0.45), options: [])
        // Dicke des Glases: Rand leicht abgedunkelt.
        ctx.drawRadialGradient(gradient([(0, black(0)), (0.78, black(0)), (1, color(0.12, 0.02, 0.30, 0.28))]),
                               startCenter: e.c, startRadius: 0, endCenter: e.c, endRadius: e.r, options: [])
        ctx.restoreGState()

        // Innere Lichtsichel oben links (Lichtkante) …
        softLayer(ctx, blurRadius: e.r * 0.025) { s in
            s.addEllipse(in: disc.insetBy(dx: e.r * 0.03, dy: e.r * 0.03))
            s.addEllipse(in: circle(e.c + CGPoint(x: e.r * 0.07, y: -e.r * 0.07), e.r * 0.99))
            s.clip(using: .evenOdd)
            s.drawLinearGradient(gradient([(0, white(0.95)), (0.5, white(0.35)), (1, white(0))]),
                                 start: e.c + CGPoint(x: -e.r * 0.7, y: e.r * 0.7), end: e.c, options: [])
        }
        // … und gegenüber das austretende, warm gefärbte Licht.
        softLayer(ctx, blurRadius: e.r * 0.035) { s in
            s.addEllipse(in: disc.insetBy(dx: e.r * 0.04, dy: e.r * 0.04))
            s.addEllipse(in: circle(e.c + CGPoint(x: -e.r * 0.09, y: e.r * 0.09), e.r * 0.99))
            s.clip(using: .evenOdd)
            s.drawLinearGradient(gradient([(0, color(1.0, 0.78, 0.62, 0.85)), (0.6, color(1.0, 0.6, 0.8, 0.2)), (1, white(0))]),
                                 start: e.c + CGPoint(x: e.r * 0.7, y: -e.r * 0.7), end: e.c, options: [])
        }
        // Spiegelung: weiche, schräge Glanzellipse.
        softLayer(ctx, blurRadius: e.r * 0.05, alpha: 0.55) { s in
            s.translateBy(x: e.c.x - e.r * 0.36, y: e.c.y + e.r * 0.48)
            s.rotate(by: 35 * .pi / 180)
            s.setFillColor(white(1))
            s.fillEllipse(in: CGRect(x: -e.r * 0.42, y: -e.r * 0.13, width: e.r * 0.84, height: e.r * 0.26))
        }

        // Kante: dünner Lichtring mit Regenbogen-Dispersion …
        ctx.saveGState()
        ctx.addEllipse(in: disc)
        ctx.addEllipse(in: disc.insetBy(dx: e.r * 0.022, dy: e.r * 0.022))
        ctx.clip(using: .evenOdd)
        ctx.setAlpha(0.55)
        drawConic(ctx, center: e.c, radius: e.r * 1.1, rainbow)
        ctx.setAlpha(1)
        // … darüber weißes Licht oben links und schwächer unten rechts.
        ctx.drawLinearGradient(gradient([(0, white(1)), (0.42, white(0.15)), (0.6, white(0.1)), (1, white(0.75))]),
                               start: e.c + CGPoint(x: -e.r * 0.72, y: e.r * 0.72),
                               end: e.c + CGPoint(x: e.r * 0.72, y: -e.r * 0.72), options: [])
        ctx.restoreGState()
    }
}

// MARK: - Vorne: Symbol

/// Kompassnadel als Raute, Richtung `angle`, aus vier Facetten.
struct Needle {
    let e: Emblem
    let angle: CGFloat = 48 * .pi / 180
    var length: CGFloat { e.r * 0.84 }
    var halfWidth: CGFloat { e.r * 0.235 }
    var dir: CGPoint { CGPoint(x: cos(angle), y: sin(angle)) }
    var perp: CGPoint { CGPoint(x: -sin(angle), y: cos(angle)) } // zeigt nach oben links
    var north: CGPoint { e.c + dir * length }
    var south: CGPoint { e.c - dir * (length * 0.92) }
    var left: CGPoint { e.c + perp * halfWidth }
    var right: CGPoint { e.c - perp * halfWidth }

    func tri(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGPath {
        let p = CGMutablePath()
        p.move(to: a); p.addLine(to: b); p.addLine(to: c); p.closeSubpath()
        return p
    }

    var outline: CGPath {
        let p = CGMutablePath()
        p.move(to: north); p.addLine(to: left); p.addLine(to: south); p.addLine(to: right); p.closeSubpath()
        return p
    }
}

func fill(_ ctx: CGContext, _ path: CGPath, _ g: CGGradient, _ a: CGPoint, _ b: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func drawNeedle(_ ctx: CGContext, _ e: Emblem) {
    let n = Needle(e: e)
    let rounded = n.outline.copy(strokingWithWidth: e.r * 0.03, lineCap: .round, lineJoin: .round, miterLimit: 1)

    // Schlagschatten auf der Scheibe.
    softLayer(ctx, blurRadius: e.r * 0.05, alpha: 0.45) { s in
        s.translateBy(x: e.r * 0.05, y: -e.r * 0.08)
        s.setFillColor(color(0.12, 0.02, 0.28, 1))
        s.addPath(n.outline); s.fillPath()
        s.addPath(rounded); s.fillPath()
    }

    // Nordhälfte: helles, fast deckendes Glas, zwei Facetten.
    let northLit = n.tri(n.north, n.left, e.c)
    let northShade = n.tri(n.north, e.c, n.right)
    let southLit = n.tri(n.south, n.left, e.c)
    let southShade = n.tri(n.south, e.c, n.right)

    // Abgerundete Kontur in der jeweiligen Facettenfarbe, damit Spitzen nicht hart wirken.
    ctx.saveGState()
    ctx.addPath(rounded)
    ctx.setFillColor(white(0.55))
    ctx.fillPath()
    ctx.restoreGState()

    fill(ctx, northLit, gradient([(0, white(1)), (1, color(0.97, 0.95, 1.0, 1))]), n.north, e.c)
    fill(ctx, northShade, gradient([(0, color(0.93, 0.88, 1.0, 1)), (1, color(0.84, 0.78, 0.97, 1))]), n.north, e.c)
    // Südhälfte: klares, getöntes Glas.
    fill(ctx, southLit, gradient([(0, white(0.70)), (1, white(0.42))]), e.c, n.south)
    fill(ctx, southShade, gradient([(0, color(1.0, 0.82, 0.92, 0.55)), (1, color(1.0, 0.72, 0.86, 0.28))]), e.c, n.south)

    // Glanzkante entlang der beleuchteten Seiten.
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(white(0.95))
    ctx.setLineWidth(e.r * 0.016)
    ctx.move(to: n.south); ctx.addLine(to: n.left); ctx.addLine(to: n.north)
    ctx.strokePath()
    ctx.setStrokeColor(white(0.45))
    ctx.setLineWidth(e.r * 0.010)
    ctx.move(to: n.north); ctx.addLine(to: n.right); ctx.addLine(to: n.south)
    ctx.strokePath()
    // Grat in der Mitte (Längsachse) als feine Lichtlinie.
    ctx.setStrokeColor(white(0.8))
    ctx.setLineWidth(e.r * 0.008)
    ctx.move(to: n.north); ctx.addLine(to: n.south)
    ctx.strokePath()
    ctx.restoreGState()

    // Mittelstift: kleine Glasperle.
    let pin = circle(e.c, e.r * 0.075)
    ctx.saveGState()
    ctx.addEllipse(in: pin); ctx.clip()
    ctx.drawRadialGradient(gradient([(0, white(1)), (0.6, color(0.95, 0.90, 1.0, 1)), (1, color(0.70, 0.62, 0.92, 1))]),
                           startCenter: e.c + CGPoint(x: -e.r * 0.025, y: e.r * 0.025), startRadius: 0,
                           endCenter: e.c, endRadius: e.r * 0.075, options: [])
    ctx.restoreGState()
}

func drawGlobe(_ ctx: CGContext, _ e: Emblem) {
    let lw = e.r * 0.075
    let lines = CGMutablePath()
    let rr = e.r * 0.80
    // Längengrade: Mittellinie und zwei Ellipsen.
    lines.move(to: e.c + CGPoint(x: 0, y: rr)); lines.addLine(to: e.c + CGPoint(x: 0, y: -rr))
    lines.addEllipse(in: CGRect(x: e.c.x - rr * 0.52, y: e.c.y - rr, width: rr * 1.04, height: rr * 2))
    lines.addEllipse(in: circle(e.c, rr))
    // Breitengrade: Äquator und zwei gebogene Linien.
    lines.move(to: e.c + CGPoint(x: -rr, y: 0)); lines.addLine(to: e.c + CGPoint(x: rr, y: 0))
    for s in [CGFloat(1), -1] {
        let y = rr * 0.52 * s
        let x = sqrt(rr * rr - y * y)
        lines.move(to: e.c + CGPoint(x: -x, y: y))
        lines.addQuadCurve(to: e.c + CGPoint(x: x, y: y), control: e.c + CGPoint(x: 0, y: y - s * rr * 0.16))
    }
    let stroke = lines.copy(strokingWithWidth: lw, lineCap: .round, lineJoin: .round, miterLimit: 1)

    softLayer(ctx, blurRadius: e.r * 0.045, alpha: 0.45) { s in
        s.translateBy(x: e.r * 0.04, y: -e.r * 0.07)
        s.addPath(stroke); s.setFillColor(color(0.12, 0.02, 0.28, 1)); s.fillPath()
    }
    // Weißes Glas mit Verlauf von oben links.
    fill(ctx, stroke, gradient([(0, white(1)), (0.55, color(0.96, 0.93, 1.0, 0.96)), (1, color(1.0, 0.86, 0.92, 0.88))]),
         e.c + CGPoint(x: -rr, y: rr), e.c + CGPoint(x: rr, y: -rr))
    // Glanzlinie auf den Stegen.
    ctx.saveGState()
    ctx.addPath(stroke); ctx.clip()
    ctx.translateBy(x: -lw * 0.18, y: lw * 0.18)
    ctx.addPath(lines)
    ctx.setLineWidth(lw * 0.28)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(white(0.9))
    ctx.strokePath()
    ctx.restoreGState()
}

func renderFront(_ w: Int, _ h: Int, _ e: Emblem, variant: Variant) -> CGImage {
    draw(w, h) { ctx in
        switch variant {
        case .nadel:
            drawNeedle(ctx, e)
            let o = Orbit(e: e)
            softLayer(ctx, blurRadius: e.r * 0.04, alpha: 0.40) { s in
                s.translateBy(x: e.r * 0.04, y: -e.r * 0.07)
                s.addPath(o.front); s.setLineWidth(o.width); s.setLineCap(.round)
                s.setStrokeColor(color(0.12, 0.02, 0.28, 1)); s.strokePath()
            }
            drawOrbitStroke(ctx, o, o.front, front: true)
        case .globus:
            drawGlobe(ctx, e)
        }
    }
}

// MARK: - Zusammensetzen

struct IconLayers {
    let back: CGImage, middle: CGImage, front: CGImage
}

func iconEmblem(_ w: Int, _ h: Int) -> Emblem {
    Emblem(c: CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) * 0.5), r: CGFloat(h) * 0.33)
}

func renderIcon(_ w: Int, _ h: Int, _ variant: Variant) -> IconLayers {
    let e = iconEmblem(w, h)
    let back = renderBack(w, h)
    return IconLayers(back: back, middle: renderMiddle(w, h, e, back: back, variant: variant),
                      front: renderFront(w, h, e, variant: variant))
}

func flatten(_ layers: [CGImage], opaque: Bool = true) -> CGImage {
    let w = layers[0].width, h = layers[0].height
    return draw(w, h, opaque: opaque) { ctx in
        for l in layers { ctx.draw(l, in: CGRect(x: 0, y: 0, width: w, height: h)) }
    }
}

func systemFont(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont {
    NSFont.systemFont(ofSize: size, weight: weight) as CTFont
}

func drawText(_ ctx: CGContext, _ text: String, _ font: CTFont, _ fill: CGColor, at p: CGPoint) {
    let attr = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill,
    ])
    let line = CTLineCreateWithAttributedString(attr)
    ctx.saveGState()
    ctx.textPosition = p
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

/// Top Shelf: gleicher Hintergrund, Emblem rechts, Schriftzug links.
func renderTopShelf(_ w: Int, _ h: Int, _ variant: Variant) -> CGImage {
    let W = CGFloat(w), H = CGFloat(h)
    let e = Emblem(c: CGPoint(x: W - H * 1.05, y: H * 0.5), r: H * 0.34)
    let back = renderBack(w, h)
    let middle = renderMiddle(w, h, e, back: back, variant: variant)
    let front = renderFront(w, h, e, variant: variant)
    let text = draw(w, h) { ctx in
        let x = H * 0.42
        let title = systemFont(H * 0.17, .bold)
        let sub = systemFont(H * 0.062, .medium)
        softLayer(ctx, blurRadius: H * 0.02, alpha: 0.35) { s in
            drawText(s, "tvOS Browser", title, color(0.10, 0.02, 0.25), at: CGPoint(x: x + H * 0.008, y: H * 0.47))
        }
        drawText(ctx, "tvOS Browser", title, white(1), at: CGPoint(x: x, y: H * 0.48))
        drawText(ctx, "Das ganze Web auf dem großen Bildschirm", sub, white(0.85), at: CGPoint(x: x + H * 0.008, y: H * 0.34))
    }
    return flatten([back, middle, front, text])
}

// MARK: - Assets-Katalog

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let brand = root.appendingPathComponent("_Project/Browser/Assets.xcassets/App Icon & Top Shelf Image.brandassets")
let docs = root.appendingPathComponent("docs/icon")

func writeJSON(_ text: String, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
}

let info = """
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
"""

func imagesetJSON(_ files: [(String, String)]) -> String {
    let entries = files.map { "    {\n      \"filename\" : \"\($0.0)\",\n      \"idiom\" : \"tv\",\n      \"scale\" : \"\($0.1)\"\n    }" }
    return "{\n  \"images\" : [\n" + entries.joined(separator: ",\n") + "\n  ],\n" + info + "\n}\n"
}

func writeStack(_ name: String, sizes: [(Int, Int, String)], variant: Variant) {
    let stack = brand.appendingPathComponent("\(name).imagestack")
    try? FileManager.default.removeItem(at: stack)
    let layerNames = ["Front", "Middle", "Back"]
    var rendered: [String: [(CGImage, String)]] = [:]
    for (w, h, scale) in sizes {
        let l = renderIcon(w, h, variant)
        rendered["Back", default: []].append((l.back, scale))
        rendered["Middle", default: []].append((l.middle, scale))
        rendered["Front", default: []].append((l.front, scale))
    }
    for layer in layerNames {
        let dir = stack.appendingPathComponent("\(layer).imagestacklayer")
        let set = dir.appendingPathComponent("Content.imageset")
        var files: [(String, String)] = []
        for (img, scale) in rendered[layer]! {
            let file = "\(layer.lowercased())\(scale == "1x" ? "" : "@\(scale)").png"
            writePNG(img, set.appendingPathComponent(file))
            files.append((file, scale))
        }
        writeJSON(imagesetJSON(files), set.appendingPathComponent("Contents.json"))
        writeJSON("{\n" + info + "\n}\n", dir.appendingPathComponent("Contents.json"))
    }
    let layersJSON = layerNames.map { "    {\n      \"filename\" : \"\($0).imagestacklayer\"\n    }" }.joined(separator: ",\n")
    writeJSON("{\n" + info + ",\n  \"layers\" : [\n" + layersJSON + "\n  ]\n}\n", stack.appendingPathComponent("Contents.json"))
}

func writeTopShelf(_ name: String, w: Int, h: Int, variant: Variant) -> CGImage {
    let set = brand.appendingPathComponent("\(name).imageset")
    try? FileManager.default.removeItem(at: set)
    let one = renderTopShelf(w, h, variant)
    let two = renderTopShelf(w * 2, h * 2, variant)
    let base = name.lowercased().replacingOccurrences(of: " ", with: "-")
    writePNG(one, set.appendingPathComponent("\(base).png"))
    writePNG(two, set.appendingPathComponent("\(base)@2x.png"))
    writeJSON(imagesetJSON([("\(base).png", "1x"), ("\(base)@2x.png", "2x")]), set.appendingPathComponent("Contents.json"))
    return two
}

// MARK: - Vorschau

func roundedIcon(_ img: CGImage, radius: CGFloat) -> CGImage {
    draw(img.width, img.height) { ctx in
        let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.draw(img, in: r)
    }
}

/// Simuliert den fokussierten Zustand: Ebenen gegeneinander verschoben und vergrößert, Glanzlicht darüber.
func parallaxFrame(_ l: IconLayers, dx: CGFloat, dy: CGFloat) -> CGImage {
    let w = l.back.width, h = l.back.height
    let W = CGFloat(w), H = CGFloat(h)
    return draw(w, h, opaque: true) { ctx in
        for (img, depth, zoom) in [(l.back, 0.25, 1.06), (l.middle, 0.7, 1.08), (l.front, 1.2, 1.11)] as [(CGImage, CGFloat, CGFloat)] {
            let rw = W * zoom, rh = H * zoom
            ctx.draw(img, in: CGRect(x: (W - rw) / 2 + dx * depth * W, y: (H - rh) / 2 + dy * depth * H, width: rw, height: rh))
        }
        let p = CGPoint(x: W * (0.5 - dx * 4), y: H * (0.5 + dy * 4))
        ctx.drawRadialGradient(gradient([(0, white(0.22)), (1, white(0))]), startCenter: p, startRadius: 0,
                               endCenter: p, endRadius: W * 0.6, options: [])
    }
}

func checker(_ ctx: CGContext, _ r: CGRect, cell: CGFloat) {
    ctx.saveGState()
    ctx.clip(to: r)
    ctx.setFillColor(color(0.30, 0.30, 0.34))
    ctx.fill(r)
    ctx.setFillColor(color(0.22, 0.22, 0.26))
    var y = r.minY, row = 0
    while y < r.maxY {
        var x = r.minX + (row % 2 == 0 ? 0 : cell)
        while x < r.maxX { ctx.fill(CGRect(x: x, y: y, width: cell, height: cell)); x += cell * 2 }
        y += cell; row += 1
    }
    ctx.restoreGState()
}

func renderPreview(_ variant: Variant, large: IconLayers, small2x: IconLayers, shelfWide: CGImage) -> CGImage {
    let W = 2400, H = 2560
    let CH = CGFloat(H)
    // Hilfsfunktion: Rechteck mit y von oben.
    func R(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: CH - top - h, width: w, height: h) }
    let labelFont = systemFont(30, .semibold)
    let label = color(0.80, 0.80, 0.86)
    return draw(W, H, opaque: true) { ctx in
        ctx.setFillColor(color(0.075, 0.07, 0.10)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        drawText(ctx, "tvOS Browser – App-Icon", systemFont(56, .bold), white(1), at: CGPoint(x: 80, y: CH - 110))
        drawText(ctx, variant.title + (variant == defaultVariant ? " (Standard)" : ""), systemFont(34, .regular),
                 color(0.75, 0.75, 0.82), at: CGPoint(x: 80, y: CH - 160))

        // Großes Icon (App Store, 1280×768) mit Schatten.
        let big = R(80, 210, 1280, 768)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 60, color: black(0.6))
        ctx.draw(roundedIcon(flatten([large.back, large.middle, large.front]), radius: 768 * 0.075), in: big)
        ctx.restoreGState()
        drawText(ctx, "App Store / groß · 1280 × 768", labelFont, label, at: CGPoint(x: 80, y: CH - 1025))

        // Rechts: kleines Icon in Originalgröße (800×480 @2x, halbiert) und Fokus-Simulation.
        let flatSmall = roundedIcon(flatten([small2x.back, small2x.middle, small2x.front]), radius: 480 * 0.075)
        ctx.draw(flatSmall, in: R(1440, 210, 400, 240))
        drawText(ctx, "Home · 400 × 240 pt", labelFont, label, at: CGPoint(x: 1440, y: CH - 495))
        let focused = roundedIcon(parallaxFrame(small2x, dx: 0.012, dy: 0.010), radius: 480 * 0.075)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -30), blur: 50, color: black(0.7))
        ctx.draw(focused, in: R(1440, 560, 880, 528))
        ctx.restoreGState()
        drawText(ctx, "Fokus mit Parallax (simuliert)", labelFont, label, at: CGPoint(x: 1440, y: CH - 1135))

        // Ebenen einzeln.
        let names = ["Hinten · Farbverlauf", "Mitte · Glasscheibe", "Vorne · Symbol"]
        let imgs = [large.back, large.middle, large.front]
        for i in 0..<3 {
            let r = R(80 + CGFloat(i) * 760, 1190, 700, 420)
            checker(ctx, r, cell: 20)
            ctx.draw(imgs[i], in: r)
            drawText(ctx, names[i], labelFont, label, at: CGPoint(x: r.minX, y: CH - 1660))
        }

        // Top Shelf (breit).
        let shelf = R(80, 1720, 2240, 2240 * 720 / 2320)
        ctx.draw(shelfWide, in: shelf)
        drawText(ctx, "Top Shelf (breit) · 2320 × 720", labelFont, label, at: CGPoint(x: 80, y: CH - 1720 - shelf.height - 50))
    }
}

// MARK: - Ablauf

var chosen = defaultVariant
var previewOnly = false
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--variant":
        guard let v = args.next(), let variant = Variant(rawValue: v) else {
            fatalError("Unbekannte Variante. Möglich: \(Variant.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        chosen = variant
    case "--preview-only": previewOnly = true
    default: fatalError("Unbekanntes Argument \(a)")
    }
}

for variant in Variant.allCases {
    let isChosen = variant == chosen
    print("Variante \(variant.rawValue)\(isChosen ? " (Katalog)" : "") …")
    let large = renderIcon(1280, 768, variant)
    let small2x = renderIcon(800, 480, variant)
    let shelfWide: CGImage
    if isChosen && !previewOnly {
        writeStack("App Icon - Small", sizes: [(400, 240, "1x"), (800, 480, "2x")], variant: variant)
        writeStack("App Icon - Large", sizes: [(1280, 768, "1x")], variant: variant)
        shelfWide = writeTopShelf("Top Shelf Image Wide", w: 2320, h: 720, variant: variant)
        _ = writeTopShelf("Top Shelf Image", w: 1920, h: 720, variant: variant)
        // Alter Name aus dem Xcode-Vorlagenstand.
        try? FileManager.default.removeItem(at: brand.appendingPathComponent("Top Shelf Image Wide-1.imageset"))
    } else {
        shelfWide = renderTopShelf(2320, 720, variant)
    }
    let preview = renderPreview(variant, large: large, small2x: small2x, shelfWide: shelfWide)
    writePNG(preview, docs.appendingPathComponent(isChosen ? "preview.png" : "variante-\(variant.rawValue).png"))
    if isChosen { try? FileManager.default.removeItem(at: docs.appendingPathComponent("variante-\(variant.rawValue).png")) }
}

if !previewOnly {
    writeJSON("""
    {
      "assets" : [
        {
          "filename" : "App Icon - Large.imagestack",
          "idiom" : "tv",
          "role" : "primary-app-icon",
          "size" : "1280x768"
        },
        {
          "filename" : "App Icon - Small.imagestack",
          "idiom" : "tv",
          "role" : "primary-app-icon",
          "size" : "400x240"
        },
        {
          "filename" : "Top Shelf Image Wide.imageset",
          "idiom" : "tv",
          "role" : "top-shelf-image-wide",
          "size" : "2320x720"
        },
        {
          "filename" : "Top Shelf Image.imageset",
          "idiom" : "tv",
          "role" : "top-shelf-image",
          "size" : "1920x720"
        }
      ],
    \(info)
    }

    """, brand.appendingPathComponent("Contents.json"))
}
print("Fertig.")
