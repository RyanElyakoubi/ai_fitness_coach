import Flutter
import UIKit
import AVFoundation
import Photos

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller: FlutterViewController = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(name: "video_utils",
                                       binaryMessenger: controller.binaryMessenger)

    channel.setMethodCallHandler { call, result in
      if call.method == "ensureLocalAndDuration" {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String
        else { result(FlutterError(code: "bad_args", message: "Missing path", details: nil)); return }

        let url = URL(fileURLWithPath: path)
        VideoUtils.ensureLocalFile(from: url) { ensureResult in
          switch ensureResult {
          case .failure(let err):
            result(FlutterError(code: "ensure_failed", message: err.localizedDescription, details: nil))
          case .success(let localURL):
            let ms = VideoUtils.preciseDurationMs(url: localURL)
            result(["path": localURL.path, "durationMs": ms])
          }
        }
      } else if call.method == "durationMs" {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String
        else { result(FlutterError(code: "bad_args", message: "Missing path", details: nil)); return }
        let url = URL(fileURLWithPath: path)
        let ms = VideoUtils.preciseDurationMs(url: url)
        result(ms)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    GeneratedPluginRegistrant.register(with: self)
    // VideoMeta.register(with: self.registrar(forPlugin: "video_meta")!) // Temporarily disabled
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

// MARK: - VideoUtils
final class VideoUtils {
  static func preciseDurationMs(url: URL) -> Int64 {
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let dur = asset.duration
    let ms = CMTimeGetSeconds(dur) * 1000.0
    return Int64(ms.rounded())
  }

  /// Ensure the URL points to a local, readable file. If it's a Photos URL (iCloud),
  /// export a local copy into tmp and return that path.
  static func ensureLocalFile(from original: URL, completion: @escaping (Result<URL, Error>) -> Void) {
    // If it's already a file:// path that exists and is readable, return directly
    if original.isFileURL, FileManager.default.isReadableFile(atPath: original.path) {
      completion(.success(original))
      return
    }

    // Try to resolve through PHAsset if possible (iOS 14+ picker)
    // We expect Flutter's picker to give us a local file already, but we harden this.
    let assets = PHAsset.fetchAssets(withALAssetURLs: [original], options: nil)
    guard let asset = assets.firstObject else {
      completion(.failure(NSError(domain: "VideoUtils", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unresolvable video URL"])))
      return
    }

    let options = PHVideoRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = true

    PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, audioMix, info in
      if let error = info?[PHImageErrorKey] as? Error {
        completion(.failure(error))
        return
      }
      guard let avUrlAsset = avAsset as? AVURLAsset else {
        completion(.failure(NSError(domain: "VideoUtils", code: -2, userInfo: [NSLocalizedDescriptionKey: "No AVURLAsset"])))
        return
      }
      // Copy to a tmp mp4 to avoid sandbox issues
      let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rc_local_\(UUID().uuidString).mp4")
      do {
        try FileManager.default.copyItem(at: avUrlAsset.url, to: tmp)
        completion(.success(tmp))
      } catch {
        // Fallback: export via AVAssetExportSession to a compatible H.264 MP4
        guard let exporter = AVAssetExportSession(asset: avUrlAsset, presetName: AVAssetExportPresetHighestQuality) else {
          completion(.failure(error))
          return
        }
        exporter.outputFileType = .mp4
        exporter.outputURL = tmp
        exporter.exportAsynchronously {
          if exporter.status == .completed {
            completion(.success(tmp))
          } else {
            completion(.failure(exporter.error ?? NSError(domain: "VideoUtils", code: -3, userInfo: [NSLocalizedDescriptionKey: "Export failed"])))
          }
        }
      }
    }
  }
}
