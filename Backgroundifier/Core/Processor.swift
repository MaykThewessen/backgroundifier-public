//
//  Processor.swift
//  Backgroundifier
//
//  Created by Alexei Baboulevitch on 2015-8-27.
//  Copyright (c) 2015 Alexei Baboulevitch. All rights reserved.
//
//  Modernized for Swift 5+ in 2026. Algorithm unchanged: the image is centered
//  over an enlarged, blurred (or flat-colored) copy of itself, with a soft shadow.
//  2026 upgrade by Mayk Thewessen.
//

import AppKit

struct ProcessorParameters {
    var blurConstant: CGFloat
    var shadowConstant: CGFloat
    var minimumEdgeGapToHeightRatio: CGFloat
    var targetBackgroundScale: CGFloat
    var maximumStretchScale: CGFloat
    var maximumBlurRadius: CGFloat
    var shadowAlpha: CGFloat

    static let `default` = ProcessorParameters(
        blurConstant: 200.0 / 2100.0,           // looks good at typical laptop resolutions
        shadowConstant: 78.0 / 2100.0,          // looks good at typical laptop resolutions
        minimumEdgeGapToHeightRatio: 0.125,
        targetBackgroundScale: 1.5,
        maximumStretchScale: 10000,             // functionally infinity
        maximumBlurRadius: 250,                 // above ~270-280 the vImage blur washes out to white
        shadowAlpha: 0.5
    )
}

/// Renders `image` onto a wallpaper of the given pixel resolution.
/// With `blur` the background is an enlarged, blurred copy of the image;
/// otherwise it is a flat color (`color`, or an auto-picked one when nil).
func processImage(_ image: NSImage, resolution: CGSize, blur: Bool, color: NSColor?, parameters: ProcessorParameters = .default) -> NSBitmapImageRep? {
    var actualColor: NSColor? = nil

    if !blur {
        if let color {
            actualColor = color
        }
        else {
            // resize image to one where the largest side is 800px, much faster to analyze
            let maxSize: CGFloat = 800
            let ratio = maxSize / max(image.size.width, image.size.height)
            let colorArt = SLColorArt(image: image, scaledSize: CGSize(width: image.size.width * ratio, height: image.size.height * ratio))
            actualColor = colorArt?.backgroundColor ?? NSColor.white
        }
    }

    let width = resolution.width
    let height = resolution.height

    let minimumHorizontalGap = parameters.minimumEdgeGapToHeightRatio * width
    let minimumVerticalGap = parameters.minimumEdgeGapToHeightRatio * height

    let baseViewFrame = CGRect(x: 0, y: 0, width: width, height: height)

    // fit the image inside the base frame, honoring the minimum edge gap
    var imageViewFrame = CGRect(x: 0, y: 0, width: image.size.width * parameters.maximumStretchScale, height: image.size.height * parameters.maximumStretchScale)

    var imageViewXScale: CGFloat = 1
    var imageViewYScale: CGFloat = 1

    if imageViewFrame.size.width > baseViewFrame.size.width - minimumHorizontalGap {
        imageViewXScale = (baseViewFrame.size.width - minimumHorizontalGap) / imageViewFrame.size.width
    }
    if imageViewFrame.size.height > baseViewFrame.size.height - minimumVerticalGap {
        imageViewYScale = (baseViewFrame.size.height - minimumVerticalGap) / imageViewFrame.size.height
    }

    let imageViewScale = min(imageViewXScale, imageViewYScale)

    var frame = CGRect(x: 0, y: 0, width: imageViewFrame.size.width * imageViewScale, height: imageViewFrame.size.height * imageViewScale)
    frame.origin = CGPoint(x: (baseViewFrame.size.width - frame.size.width) / 2.0, y: (baseViewFrame.size.height - frame.size.height) / 2.0)
    imageViewFrame = frame

    // the background frame: the image enlarged to at least cover the base frame
    let blurImageViewXScale = max(parameters.targetBackgroundScale, baseViewFrame.size.width / imageViewFrame.size.width)
    let blurImageViewYScale = max(parameters.targetBackgroundScale, baseViewFrame.size.height / imageViewFrame.size.height)

    let blurImageViewScale = max(blurImageViewXScale, blurImageViewYScale)

    var newFrame = CGRect(x: 0, y: 0, width: imageViewFrame.size.width * blurImageViewScale, height: imageViewFrame.size.height * blurImageViewScale)
    newFrame.origin = CGPoint(x: (baseViewFrame.size.width - newFrame.size.width) / 2.0, y: (baseViewFrame.size.height - newFrame.size.height) / 2.0)
    let blurImageViewFrame = newFrame

    func makeCanvas() -> NSBitmapImageRep? {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(baseViewFrame.size.width), pixelsHigh: Int(baseViewFrame.size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    }

    /// Runs `draw` with `rep` as the current graphics context.
    func render(into rep: NSBitmapImageRep, _ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw()
    }

    // PASS 1: paint the enlarged background (image or flat color)
    guard var backgroundRep = makeCanvas() else {
        return nil
    }

    render(into: backgroundRep) {
        // fill with white (just in case)
        NSColor.white.setFill()
        CGRect(x: 0, y: 0, width: backgroundRep.size.width, height: backgroundRep.size.height).fill()

        if let actualColor {
            actualColor.setFill()
            CGRect(x: 0, y: 0, width: blurImageViewFrame.size.width, height: blurImageViewFrame.size.height).fill()
        }
        else {
            let displayFrame = CGRect(x: 0, y: 0, width: backgroundRep.size.width, height: backgroundRep.size.height)
            let backgroundImageFrame = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)

            let translate = CGAffineTransform(translationX: displayFrame.origin.x - blurImageViewFrame.origin.x, y: displayFrame.origin.y - blurImageViewFrame.origin.y)
            let scale = CGAffineTransform(scaleX: displayFrame.size.width / blurImageViewFrame.size.width, y: displayFrame.size.height / blurImageViewFrame.size.height)
            let scaleOldNew = CGAffineTransform(scaleX: backgroundImageFrame.size.width / blurImageViewFrame.size.width, y: backgroundImageFrame.size.height / blurImageViewFrame.size.height)

            // Instead of painting the image into the blurImageViewFrame (which can be enormous in the case of thin + long images),
            // we can find the inverse transform and sample the correct viewport portion of the unresized image.
            let transform = scaleOldNew.inverted()
                .concatenating(scale)
                .concatenating(translate)
                .concatenating(scaleOldNew)

            let innerFrame = backgroundImageFrame.applying(transform)

            image.draw(in: displayFrame, from: innerFrame, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        }
    }

    // PASS 2: blur the background if needed
    if blur {
        let tintColor = NSColor(white: 1, alpha: 0.3)

        var blurRadius = parameters.blurConstant * resolution.height
        if blurRadius > parameters.maximumBlurRadius {
            blurRadius = parameters.maximumBlurRadius
        }
        if let blurredImageRep = NSImageEffects.imageRep(byApplyingBlurTo: backgroundRep, withRadius: blurRadius, tintColor: tintColor, saturationDeltaFactor: 1.8, maskImage: nil) {
            backgroundRep = blurredImageRep
        }
    }

    // PASS 3: composite background, shadow, and image into a fresh canvas.
    // A fresh canvas matters: a rep that NSImageEffects has already read via
    // CGImage caches that snapshot on modern AppKit, and drawing into it again
    // never reaches the encoded output.
    guard let outputImageRep = makeCanvas() else {
        return nil
    }

    render(into: outputImageRep) {
        backgroundRep.draw(in: CGRect(x: 0, y: 0, width: outputImageRep.size.width, height: outputImageRep.size.height))

        // center the image rect
        var imageRect = imageViewFrame
        imageRect.origin = CGPoint(x: (outputImageRep.size.width - imageRect.size.width) / 2.0, y: (outputImageRep.size.height - imageRect.size.height) / 2.0)

        // paint the shadow
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            let shadowPath = NSBezierPath(rect: imageRect)
            let shadowBlur = resolution.height * parameters.shadowConstant
            ctx.setShadow(offset: .zero, blur: shadowBlur, color: NSColor.black.withAlphaComponent(parameters.shadowAlpha).cgColor)
            shadowPath.fill()
            ctx.restoreGState()
        }

        // paint the image
        image.draw(in: imageRect)
    }

    return outputImageRep
}
