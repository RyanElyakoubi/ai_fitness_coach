import Foundation
import AVFoundation
import Flutter

class VideoMeta {
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "video_meta", binaryMessenger: registrar.messenger())
        channel.setMethodCallHandler { call, result in
            if call.method == "getMeta", let args = call.arguments as? [String: Any],
               let path = args["path"] as? String {
                result(getMeta(for: path))
            } else {
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static func getMeta(for path: String) -> [String: Any] {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let durationSec = CMTimeGetSeconds(asset.duration)
        var fps: Double = 0
        if let track = asset.tracks(withMediaType: .video).first {
            fps = track.nominalFrameRate == 0 ? 0 : Double(track.nominalFrameRate)
        }
        // Orientation (portrait vs landscape) via preferredTransform
        var orientation = "unknown"
        if let track = asset.tracks(withMediaType: .video).first {
            let t = track.preferredTransform
            if (t.a == 0 && t.b == 1.0 && t.c == -1.0 && t.d == 0) {
                orientation = "portrait"
            } else if (t.a == 0 && t.b == -1.0 && t.c == 1.0 && t.d == 0) {
                orientation = "portraitUpsideDown"
            } else if (t.a == 1.0 && t.b == 0 && t.c == 0 && t.d == 1.0) {
                orientation = "landscapeRight"
            } else if (t.a == -1.0 && t.b == 0 && t.c == 0 && t.d == -1.0) {
                orientation = "landscapeLeft"
            }
        }
        return [
            "durationMs": Int(max(0, durationSec * 1000)),
            "fps": fps,
            "orientation": orientation
        ]
    }
}
