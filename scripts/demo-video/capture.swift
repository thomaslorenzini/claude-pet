// Records the built-in display with ScreenCaptureKit, keeping only the wallpaper and the windows of
// one process (Claude Pet). Nothing else from the desktop reaches the file: other apps, desktop icons,
// widgets, the real menu bar and the real cursor are all filtered out by the capture itself.
//
//   capture <pid,pid...> <out.mov> [--still out.png] [--wallpaper-only]
//
// The pids are Claude Pet and the fake menu bar (menubar.swift).
//
// Records until the file `<out.mov>.stop` appears (the driver creates it), then writes
// `<out.mov>.json` with the host time of the first frame, so driver logs can be aligned on it.
import AVFoundation
import Foundation
import ImageIO
import QuartzCore
import ScreenCaptureKit
import UniformTypeIdentifiers

let args = CommandLine.arguments
let pids = args.count > 1 ? args[1].split(separator: ",").compactMap { Int32($0) } : []
guard args.count >= 3, !pids.isEmpty else {
    FileHandle.standardError.write("usage: capture <pid,pid...> <out.mov> [--still out.png]\n".data(using: .utf8)!)
    exit(2)
}
let outURL = URL(fileURLWithPath: args[2])
let stillPath = args.firstIndex(of: "--still").map { args[$0 + 1] }
/// The bare wallpaper, used in post as the reference under the fake menu bar.
let wallpaperOnly = args.contains("--wallpaper-only")

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

/// Wallpaper + the pet's windows. Built from apps (not a window list) so windows the pet opens later
/// (request card, menu bar panel) are captured too.
func makeFilter() async throws -> (SCContentFilter, SCDisplay) {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) ?? content.displays.first
    else { throw NSError(domain: "capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display"]) }
    let apps = content.applications.filter { pids.contains($0.processID) }
    guard apps.count == pids.count
    else { throw NSError(domain: "capture", code: 2, userInfo: [NSLocalizedDescriptionKey: "pids \(pids) not all found"]) }
    // On macOS 26+ the wallpaper is a window of WindowManager; older systems draw it from the Dock.
    let wallpaperWindows = content.windows.filter {
        ($0.owningApplication?.bundleIdentifier == "com.apple.WindowManager" || $0.owningApplication?.bundleIdentifier == "com.apple.dock")
            && ($0.title ?? "").hasPrefix("Wallpaper")
    }
    guard let owner = wallpaperWindows.first?.owningApplication
    else { throw NSError(domain: "capture", code: 3, userInfo: [NSLocalizedDescriptionKey: "wallpaper window not found"]) }
    // Everything else the wallpaper's owner draws (Stage Manager strips, the Dock itself) stays out.
    let others = content.windows.filter { $0.owningApplication?.processID == owner.processID && !wallpaperWindows.contains($0) }
    log("wallpaper: \(owner.applicationName) windows \(wallpaperWindows.map(\.windowID)), excluded \(others.map(\.windowID))")
    return (SCContentFilter(display: display, including: wallpaperOnly ? [owner] : apps + [owner], exceptingWindows: others), display)
}

func configuration(_ display: SCDisplay, filter: SCContentFilter) -> SCStreamConfiguration {
    let c = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    c.width = Int(CGFloat(display.width) * scale)
    c.height = Int(CGFloat(display.height) * scale)
    c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    c.showsCursor = false
    c.pixelFormat = kCVPixelFormatType_32BGRA
    c.colorSpaceName = CGColorSpace.sRGB
    c.queueDepth = 8
    return c
}

final class Recorder: NSObject, SCStreamOutput {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    var firstPTS: CMTime?
    var firstHost: Double = 0
    var last: (CVPixelBuffer, CMTime)?
    var frames = 0
    let queue = DispatchQueue(label: "rec")

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // HEVC at a high bitrate: visually lossless for flat UI, ten times smaller than ProRes.
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 120_000_000, AVVideoExpectedSourceFrameRateKey: 60],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = sb.imageBuffer else { return }
        // Only complete frames carry new pixels; idle ones repeat the previous image.
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        let pts = sb.presentationTimeStamp
        if firstPTS == nil {
            firstPTS = pts
            // The stream's clock is the host clock: the same as the driver's CACurrentMediaTime().
            firstHost = pts.seconds
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
        }
        if input.isReadyForMoreMediaData { adaptor.append(pb, withPresentationTime: pts); frames += 1 }
        last = (pb, pts)
    }

    func finish(at host: Double) async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            queue.async {
                // Repeat the last image at the stop time, so a still ending is not cut short.
                if let (pb, pts) = self.last, let first = self.firstPTS {
                    let end = CMTime(seconds: host, preferredTimescale: first.timescale)
                    if end > pts, self.input.isReadyForMoreMediaData { self.adaptor.append(pb, withPresentationTime: end) }
                }
                k.resume()
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}

Task {
    do {
        let (filter, display) = try await makeFilter()
        let config = configuration(display, filter: filter)
        if let stillPath {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: stillPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
            log("still \(image.width)x\(image.height) -> \(stillPath)")
            exit(0)
        }
        let rec = try Recorder(url: outURL, width: config.width, height: config.height)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(rec, type: .screen, sampleHandlerQueue: rec.queue)
        try await stream.startCapture()
        log("recording \(config.width)x\(config.height) -> \(outURL.path)")
        let stopFile = outURL.path + ".stop"
        try? FileManager.default.removeItem(atPath: stopFile)
        while !FileManager.default.fileExists(atPath: stopFile) { try await Task.sleep(nanoseconds: 50_000_000) }
        let stopHost = CACurrentMediaTime()
        try await stream.stopCapture()
        await rec.finish(at: stopHost)
        let meta: [String: Any] = ["first_frame_host": rec.firstHost, "stop_host": stopHost, "frames": rec.frames,
                                   "width": config.width, "height": config.height, "point_scale": filter.pointPixelScale]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: outURL.path + ".json"))
        log("done: \(rec.frames) frames, \(String(format: "%.1f", stopHost - rec.firstHost)) s")
        exit(0)
    } catch {
        log("capture failed: \(error.localizedDescription)")
        exit(1)
    }
}
dispatchMain()
