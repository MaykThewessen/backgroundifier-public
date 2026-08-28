//
//  main.swift
//  bgify
//
//  Command line interface to the Backgroundifier processor.
//
//  Usage: bgify -i input.jpg -o output.jpg -w 2880 -h 1800 [options]
//  2026 upgrade by Mayk Thewessen.
//

import AppKit

let versionNumber = "2.0.0"

struct Usage {
    static let text = """
    Backgroundifier \(versionNumber)
    Copyright (c) 2015-2016 Alexei Baboulevitch
    2026 upgrade by Mayk Thewessen
    http://backgroundifier.archagon.net

    Usage: bgify [options]

      -i, --input <path>                 Path to the input image. (required)
      -o, --output <path>                Path to the output image; the extension picks the
                                         format: jpg, png, or tiff. (required)
      -w, --width <pixels>               Output image width. (required)
      -h, --height <pixels>              Output image height. (required)
      -c, --color <hex|auto>             Use a color for the background instead of the default
                                         blur. Give a hex color like 1A2B3C, or 'auto' to pick
                                         one based on the image.
      --shadow_alpha <value>             Shadow alpha. Default: \(ProcessorParameters.default.shadowAlpha)
      --min_edge_gap_height_ratio <value>
                                         Minimum edge gap as a ratio of output size.
                                         Default: \(ProcessorParameters.default.minimumEdgeGapToHeightRatio)
      --blur_constant <value>            (Advanced) Blur radius per pixel of output height.
                                         Default: \(ProcessorParameters.default.blurConstant)
      --shadow_constant <value>          (Advanced) Shadow radius per pixel of output height.
                                         Default: \(ProcessorParameters.default.shadowConstant)
      --target_bg_scale <value>          (Advanced) Target background scale.
                                         Default: \(ProcessorParameters.default.targetBackgroundScale)
      --max_stretch_scale <value>        (Advanced) Maximum stretch scale of the input.
                                         Default: \(ProcessorParameters.default.maximumStretchScale)
      --max_blur_radius <value>          (Advanced) Maximum blur radius, in case too high of a
                                         radius creates a blank background.
                                         Default: \(ProcessorParameters.default.maximumBlurRadius)
      -u, --usage, --help                Print this message.
    """
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    exit(code)
}

// MARK: - Argument parsing

struct Arguments {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    // long name -> short name
    private static let valueOptions: [String: String?] = [
        "input": "i", "output": "o", "width": "w", "height": "h", "color": "c",
        "shadow_alpha": nil, "min_edge_gap_height_ratio": nil, "blur_constant": nil,
        "shadow_constant": nil, "target_bg_scale": nil, "max_stretch_scale": nil,
        "max_blur_radius": nil,
        // injected by Xcode when run from the IDE; accepted and ignored
        "NSDocumentRevisionsDebugMode": nil,
    ]
    private static let boolOptions: [String: String?] = ["usage": "u", "help": nil]

    init(_ arguments: [String]) {
        var shortToLong: [String: String] = [:]
        for (long, short) in Self.valueOptions.merging(Self.boolOptions, uniquingKeysWith: { a, _ in a }) {
            if let short { shortToLong[short] = long }
        }

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            index += 1

            let name: String
            if argument.hasPrefix("--") {
                name = String(argument.dropFirst(2))
            }
            else if argument.hasPrefix("-") {
                let short = String(argument.dropFirst(1))
                guard let long = shortToLong[short] else {
                    fail("unknown option \(argument)\n\n\(Usage.text)", code: EX_USAGE)
                }
                name = long
            }
            else {
                fail("unexpected argument \(argument)\n\n\(Usage.text)", code: EX_USAGE)
            }

            if Self.boolOptions.keys.contains(name) {
                flags.insert(name)
            }
            else if Self.valueOptions.keys.contains(name) {
                guard index < arguments.count else {
                    fail("missing value for --\(name)", code: EX_USAGE)
                }
                values[name] = arguments[index]
                index += 1
            }
            else {
                fail("unknown option --\(name)\n\n\(Usage.text)", code: EX_USAGE)
            }
        }
    }

    var isEmpty: Bool { values.isEmpty && flags.isEmpty }
    func has(_ name: String) -> Bool { flags.contains(name) }
    func string(_ name: String) -> String? { values[name] }

    func int(_ name: String) -> Int? {
        guard let raw = values[name] else { return nil }
        guard let value = Int(raw) else {
            fail("invalid integer for --\(name): \(raw)", code: EX_USAGE)
        }
        return value
    }

    func double(_ name: String, default defaultValue: Double) -> Double {
        guard let raw = values[name] else { return defaultValue }
        guard let value = Double(raw) else {
            fail("invalid number for --\(name): \(raw)", code: EX_USAGE)
        }
        return value
    }
}

// MARK: - Main

let arguments = Arguments(CommandLine.arguments)

if arguments.isEmpty || arguments.has("usage") || arguments.has("help") {
    print(Usage.text)
    exit(EX_USAGE)
}

guard
    let input = arguments.string("input"),
    let output = arguments.string("output"),
    let width = arguments.int("width"),
    let height = arguments.int("height")
else {
    fail("missing required options (input, output, width, height)\n\n\(Usage.text)", code: EX_USAGE)
}

var blur = true
var color: NSColor? = nil

if let colorValue = arguments.string("color") {
    blur = false
    if colorValue != "auto" {
        guard let parsed = NSColor(hexString: colorValue) else {
            fail("invalid value for --color: \(colorValue); use a hex color like 1A2B3C or 'auto'", code: EX_USAGE)
        }
        color = parsed
    }
}

let defaults = ProcessorParameters.default
let parameters = ProcessorParameters(
    blurConstant: CGFloat(arguments.double("blur_constant", default: defaults.blurConstant)),
    shadowConstant: CGFloat(arguments.double("shadow_constant", default: defaults.shadowConstant)),
    minimumEdgeGapToHeightRatio: CGFloat(arguments.double("min_edge_gap_height_ratio", default: defaults.minimumEdgeGapToHeightRatio)),
    targetBackgroundScale: CGFloat(arguments.double("target_bg_scale", default: defaults.targetBackgroundScale)),
    maximumStretchScale: CGFloat(arguments.double("max_stretch_scale", default: defaults.maximumStretchScale)),
    maximumBlurRadius: CGFloat(arguments.double("max_blur_radius", default: defaults.maximumBlurRadius)),
    shadowAlpha: CGFloat(arguments.double("shadow_alpha", default: defaults.shadowAlpha))
)

let supportedExtensions: [String: NSBitmapImageRep.FileType] = [
    "jpeg": .jpeg, "jpg": .jpeg, "png": .png, "tiff": .tiff, "tif": .tiff,
]

let outputURL = URL(fileURLWithPath: output)
guard let fileType = supportedExtensions[outputURL.pathExtension.lowercased()] else {
    fail("output filename does not have a supported extension; supported extensions include jpeg, png, and tiff", code: EX_DATAERR)
}

do {
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
}
catch {
    fail("could not create output directory. If you're running this utility from the sandbox, you can only output to your Pictures directory.", code: EX_CANTCREAT)
}

guard let inputData = try? Data(contentsOf: URL(fileURLWithPath: input)) else {
    fail("could not retrieve data from input. If you're running this utility from the sandbox, you can only get input from your Pictures directory.", code: EX_NOINPUT)
}

guard let image = NSImage(data: inputData) else {
    fail("could not create image from input", code: EX_DATAERR)
}

print("Processing \(input)...")

guard let imageRep = processImage(image, resolution: CGSize(width: width, height: height), blur: blur, color: color, parameters: parameters) else {
    fail("could not process image", code: EX_DATAERR)
}

let properties: [NSBitmapImageRep.PropertyKey: Any] = (fileType == .jpeg) ? [.compressionFactor: 0.75] : [:]
guard let outputData = imageRep.representation(using: fileType, properties: properties) else {
    fail("could not create data from output image", code: EX_DATAERR)
}

do {
    try outputData.write(to: outputURL, options: .atomic)
    print("Done! Output to \(output)")
    exit(EX_OK)
}
catch {
    fail("could not write output data. If you're running this utility from the sandbox, you can only write output to your Pictures directory.", code: EX_CANTCREAT)
}
