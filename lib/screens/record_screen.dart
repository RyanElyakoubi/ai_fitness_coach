import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';
import '../ui/style.dart';
import '../widgets/frosted_mask_overlay.dart';

class RecordScreen extends StatefulWidget {
  static const routeName = '/';
  const RecordScreen({super.key});

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> with TickerProviderStateMixin {
  CameraController? _controller;
  late Future<void> _cameraInit;
  bool _noCamera = false;
  bool _recording = false;
  bool _controllerReady = false;
  DateTime? _start;
  Timer? _cap;
  Timer? _elapsedTimer;
  int _elapsedSeconds = 0;

  // Progress ring for recording
  static const Duration kMaxRecordDuration = Duration(minutes: 2);     // real cap (auto-stop)
  static const Duration kProgressRingDuration = Duration(seconds: 16); // visual speed (2.5× faster than 40s)
  late AnimationController _recAnim;     // 0..1 over kProgressRingDuration
  late AnimationController _fadeAnim;    // 0..1 for fade-out at lap end (~220ms)
  double _recProgress = 0.0;
  double _ringOpacity = 1.0;
  Timer? _autoStopTimer;               // enforces 2:00 cap
  bool _animsInitialized = false;

  @override
  void initState() {
    super.initState();
    
    if (!_animsInitialized) {
      _recAnim = AnimationController(vsync: this, duration: kProgressRingDuration)
        ..addListener(() {
          if (mounted) setState(() => _recProgress = _recAnim.value);
        })
        ..addStatusListener((status) async {
          if (!mounted) return;
          if (status == AnimationStatus.completed && _recording) {
            // Start fade-out at lap end
            _fadeAnim
              ..reset()
              ..forward();
          }
        });

      _fadeAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))
        ..addListener(() {
          if (mounted) setState(() => _ringOpacity = 1.0 - _fadeAnim.value);
        })
        ..addStatusListener((status) {
          if (!mounted) return;
          if (status == AnimationStatus.completed && _recording) {
            // After fade completes, reset opacity and restart a fresh lap
            _ringOpacity = 1.0;
            _recAnim
              ..reset()
              ..forward();
            setState(() {});
          }
        });

      _animsInitialized = true;
    }

    _init();
  }

  Future<void> _init() async {
    try {
      // Request permissions
      final cameraStatus = await Permission.camera.request();
      final micStatus = await Permission.microphone.request();
      
      if (cameraStatus.isDenied || micStatus.isDenied) {
        setState(() => _noCamera = true);
        return;
      }

      // Get available cameras
      final cams = await availableCameras();
      if (cams.isEmpty) {
        setState(() => _noCamera = true);
        return;
      }

      // Pick back camera (or first available)
      final cam = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );

      // Create and initialize controller
      _controller = CameraController(
        cam,
        ResolutionPreset.high,
        enableAudio: true,
        imageFormatGroup: ImageFormatGroup.bgra8888,
      );
      
      _cameraInit = _controller!.initialize();
      await _cameraInit;
      if (!mounted) return;
      setState(() => _controllerReady = true);
    } catch (e) {
      // Camera initialization failed, likely simulator
      setState(() => _noCamera = true);
    }
  }

  @override
  void dispose() {
    _autoStopTimer?.cancel();
    _fadeAnim.dispose();
    _recAnim.dispose();
    _cap?.cancel();
    _elapsedTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    if (_controller == null || _recording) return;

    try {
      await _controller!.startVideoRecording();
      setState(() {
        _recording = true;
        _start = DateTime.now();
        _elapsedSeconds = 0;
        _ringOpacity = 1.0;
        _recProgress = 0.0;
      });
      _fadeAnim.reset();
      _recAnim
        ..reset()
        ..forward();
      // Auto-stop guard at the real 2:00 cap
      _autoStopTimer?.cancel();
      _autoStopTimer = Timer(kMaxRecordDuration, () async {
        if (mounted && _recording) {
          await _stopRecording();
        }
      });

      // Start elapsed timer
      _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          _elapsedSeconds = DateTime.now().difference(_start!).inSeconds;
        });
      });

      // Auto-stop handled by animation controller at 2:00 mark
    } catch (e) {
      setState(() => _recording = false);
    }
  }

  Future<void> _stopRecording() async {
    if (_controller == null || !_recording) return;

    try {
      _cap?.cancel();
      _elapsedTimer?.cancel();
      
      final file = await _controller!.stopVideoRecording();
      
      _autoStopTimer?.cancel();
      _autoStopTimer = null;

      _recAnim.stop();
      _fadeAnim.stop();
      setState(() {
        _recording = false;
        _start = null;
        _elapsedSeconds = 0;
        _ringOpacity = 0.0;  // hide immediately on stop
        _recProgress = 0.0;
      });

      // Navigate to processing
      if (mounted) {
        Navigator.pushNamed(
          context,
          '/processing',
          arguments: {'videoPath': file.path},
        );
        // After navigating, reset visuals:
        _recAnim.reset();
        setState(() => _recProgress = 0.0);
      }
    } catch (e) {
      setState(() => _recording = false);
    }
  }

  Future<String> _copySampleToTemp() async {
    final bytes = await rootBundle.load('assets/sample_bench.mp4');
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/sample_bench.mp4');
    await f.writeAsBytes(bytes.buffer.asUint8List());
    return f.path;
  }

  Future<void> _useSampleVideo() async {
    try {
      final path = await _copySampleToTemp();
      if (mounted) {
        Navigator.pushNamed(
          context,
          '/processing',
          arguments: {'videoPath': path},
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to load sample video')),
        );
      }
    }
  }

  Future<void> _uploadVideo() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        final fileName = result.files.single.name;
        
        // Copy the selected file to temp directory
        final tempDir = await getTemporaryDirectory();
        final tempPath = p.join(tempDir.path, 'uploaded_$fileName');
        
        final sourceFile = File(filePath);
        final tempFile = await sourceFile.copy(tempPath);
        
        if (mounted) {
          Navigator.pushNamed(
            context,
            '/processing',
            arguments: {'videoPath': tempFile.path},
          );
        }
      }
    } on PlatformException catch (e) {
      final msg = e.message ?? '';
      if (mounted) {
        if (msg.contains('out of space') || msg.contains('No space')) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Your device is low on storage. Please free up space and try again.'),
              duration: Duration(seconds: 4),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to access selected video. Please try again.')),
          );
        }
      }
    } on FileSystemException catch (e) {
      if (mounted) {
        if (e.message.contains('No space')) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Your device is low on storage. Please free up space and try again.'),
              duration: Duration(seconds: 4),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to copy video. Please try again.')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to upload video. Please try again.')),
        );
      }
    }
  }

  void _showFilmingTips() {
    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('Filming Tips'),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('• 45° front-side angle'),
              Text('• Full body + bar in frame'),
              Text('• Phone ~2–3m away'),
              Text('• Good lighting'),
              Text('• Keep phone stable'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Got it'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCameraPreview() {
    if (!_controller!.value.isInitialized) {
      return const SizedBox.shrink();
    }
    // Use standard FittedBox with BoxFit.cover for normal zoom level
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: _controller!.value.previewSize!.height, // note: width/height swapped for camera
        height: _controller!.value.previewSize!.width,
        child: CameraPreview(_controller!),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final pad = MediaQuery.of(context).padding;

    final double sideMargin = 20;
    final double topGuide = pad.top + 82;       // unchanged (top stays put)
    // Increase height: was ~0.62, make it taller without touching the top
    final double windowHeight = size.height * 0.72; // expand downward

    // Clamp bottom so we don't collide with the home indicator
    final double maxBottom = size.height - (pad.bottom + 112); // leaves space for Upload
    final double desiredBottom = (topGuide + windowHeight).clamp(topGuide + 280, maxBottom);
    final Rect clearRect = Rect.fromLTWH(
      sideMargin,
      topGuide,
      size.width - sideMargin * 2,
      desiredBottom - topGuide,
    );

    // Record button sits inside the window near the bottom
    final double recordY = clearRect.bottom - 128; // 128 px above window bottom

    // Upload button centered between window bottom and device bottom
    final double uploadCenterY = (clearRect.bottom + (size.height - pad.bottom)) / 2;
    final double uploadTop = uploadCenterY - 28; // if your upload button is ~56px tall

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // 1) Camera full bleed
          if (_controller != null)
            FutureBuilder(
              future: _cameraInit,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.done && _controller!.value.isInitialized) {
                  return Positioned.fill(child: _buildCameraPreview());
                }
                return const SizedBox.shrink(); // fallback
              },
            ),

          // 2) Frosted mask outside the window
          FrostedMaskOverlay(
            clearRect: clearRect,
            radius: 24,
            blurSigma: 22,
            tint: const Color(0xCC0B0E17), // ~80% dark tint
          ),

          // 2.5) FormAI Logo at the top
          Positioned(
            top: pad.top + 20,
            left: 0,
            right: 0,
            child: Center(
              child: _FormAILogo(),
            ),
          ),

          // 3) Friendly, single-sentence guidance centered in the window
          if (!_recording)
            Positioned(
              left: clearRect.left + 16,
              right: clearRect.right - 16,
              top: clearRect.top + (clearRect.height / 2) - 14, // roughly vertically centered
              child: Text(
                "Keep your full body and the bar in view, with steady lighting.",
                textAlign: TextAlign.center,
                maxLines: 2,
                softWrap: true,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontWeight: FontWeight.w600,
                      shadows: const [
                        Shadow(blurRadius: 6, color: Colors.black54, offset: Offset(0, 1)),
                      ],
                    ),
              ),
            ),

          // 4) RECORD button (inside window)
          Positioned(
            top: recordY,
            left: 0,
            right: 0,
            child: Center(
              child: _CaptureButton(
                isRecording: _recording,
                enabled: (_controllerReady && !_recording) || _recording,
                onTap: () async {
                  if (_recording) {
                    await _stopRecording();
                  } else if (_controllerReady) {
                    await _startRecording();
                  } else {
                    _showSnack("Camera not available — try Upload Video");
                  }
                },
                progress: _recording ? _recProgress : 0.0,
                ringOpacity: _ringOpacity,
              ),
            ),
          ),

          // 5) UPLOAD button (centered between window bottom and safe area bottom)
          Positioned(
            top: uploadTop,
            left: 24,
            right: 24,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              child: _recording
                  ? const SizedBox(height: 52) // spacer to preserve layout
                  : _UploadButton(onTap: _onUploadPressed),
            ),
          ),

          // 6) Subtle stroke around clear window
          Positioned.fromRect(
            rect: clearRect,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    width: 1.2,
                    color: Colors.white.withValues(alpha: 0.10),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onUploadPressed() async {
    try {
      // Call your existing picker/upload flow
      await _uploadVideo();
    } catch (e) {
      _showSnack("Upload failed: $e");
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

// --- UI Helpers ---


class _CaptureButton extends StatelessWidget {
  final bool isRecording;
  final bool enabled;
  final VoidCallback onTap;
  final double progress; // 0..1
  final double ringOpacity; // 0..1 (fades at lap end)
  const _CaptureButton({
    required this.isRecording,
    required this.enabled,
    required this.onTap,
    required this.progress,
    required this.ringOpacity,
  });

  @override
  Widget build(BuildContext context) {
    const double size = 108.0;
    const double strokeW = 5.0;

    // We wrap the button with CustomPaint.foregroundPainter so the red arc renders ON TOP.
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          foregroundPainter: _ProgressRingPainter(
            progress: progress,
            strokeWidth: strokeW,
            color: const Color(0xFFFF4D4D).withValues(alpha: ringOpacity.clamp(0.0, 1.0)),
          ),
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: enabled
                    ? AppStyle.captureGradient
                    : const LinearGradient(colors: [Colors.grey, Colors.grey]),
                boxShadow: AppStyle.softGlow,
              ),
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    // circle (idle) → square (stop) when recording
                    borderRadius: BorderRadius.circular(isRecording ? 8 : 999),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UploadButton extends StatelessWidget {
  final VoidCallback onTap;
  const _UploadButton({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: AppStyle.glassCard.copyWith(
          boxShadow: AppStyle.softGlow,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.file_upload_outlined, color: Colors.white),
            SizedBox(width: 8),
            Text("Upload Video", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

class _FormAILogo extends StatelessWidget {
  const _FormAILogo();

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) => const LinearGradient(
        colors: [Color(0xFF7C3AED), Color(0xFFEC4899)], // App's gradient colors
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(bounds),
      child: const Text(
        'FormAI',
        style: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w800,
          color: Colors.white, // This will be masked by the gradient
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _ProgressRingPainter extends CustomPainter {
  final double progress;    // 0..1
  final double strokeWidth;
  final Color color;
  _ProgressRingPainter({
    required this.progress,
    required this.strokeWidth,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || color.a == 0) return;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - strokeWidth) / 2;

    // Start at 12 o'clock (−π/2), clockwise sweep
    final start = -math.pi / 2;
    final sweep = 2 * math.pi * progress;

    final red = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = strokeWidth
      ..color = color;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      start,
      sweep,
      false,
      red,
    );
  }

  @override
  bool shouldRepaint(covariant _ProgressRingPainter old) =>
      old.progress != progress ||
      old.strokeWidth != strokeWidth ||
      old.color != color;
}