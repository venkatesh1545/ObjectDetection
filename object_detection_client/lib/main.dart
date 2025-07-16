import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui_web' as ui;
import 'dart:html' as html; // Only for web
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'package:camera/camera.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Register webcam container for Flutter web
  if (kIsWeb) {
    ui.platformViewRegistry.registerViewFactory(
      'webcamContainer',
      (int viewId) => html.DivElement()..id = 'webcamContainer',
    );
  }

  final cameras = kIsWeb ? <CameraDescription>[] : await availableCameras();
  runApp(MyApp(cameras: cameras));
}

class MyApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  const MyApp({Key? key, required this.cameras}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: CameraScreen(cameras: cameras),
      debugShowCheckedModeBanner: false,
    );
  }
}

class CameraScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const CameraScreen({Key? key, required this.cameras}) : super(key: key);

  @override
  _CameraScreenState createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  List<dynamic> _detections = [];
  bool _isProcessing = false;
  final ImagePicker _picker = ImagePicker();
  html.VideoElement? _webcam;

  @override
  void initState() {
    super.initState();
    kIsWeb ? _initializeWebCamera() : _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    if (widget.cameras.isEmpty) {
      print('No cameras available on mobile');
      return;
    }
    _controller = CameraController(widget.cameras[0], ResolutionPreset.medium);
    await _controller!.initialize();
    if (!mounted) return;

    _controller!.startImageStream((CameraImage image) async {
      if (_isProcessing) return;
      _isProcessing = true;

      final bytes = await _convertCameraImage(image);
      await _sendFrameToServer(bytes);

      _isProcessing = false;
    });

    setState(() {});
  }

  Future<void> _initializeWebCamera() async {
    try {
      _webcam = html.VideoElement()
        ..width = 640
        ..height = 480
        ..autoplay = true
        ..muted = true
        ..style.objectFit = 'cover';

      final mediaDevices = html.window.navigator.mediaDevices;
      if (mediaDevices == null) {
        print('Camera access not supported in this browser');
        return;
      }

      final stream = await mediaDevices.getUserMedia({'video': true});
      _webcam!.srcObject = stream;

      html.document.getElementById('webcamContainer')?.children.clear();
      html.document.getElementById('webcamContainer')?.append(_webcam!);

      // Periodically send frames to server
      Future.doWhile(() async {
        await Future.delayed(Duration(seconds: 2));
        if (!_isProcessing && mounted) {
          _isProcessing = true;
          final bytes = await _captureWebFrame();
          await _sendFrameToServer(bytes);
          _isProcessing = false;
        }
        return mounted;
      });
    } catch (e) {
      print('Error initializing web camera: $e');
    }
  }

  Future<Uint8List> _captureWebFrame() async {
    final canvas = html.CanvasElement(width: 640, height: 480);
    final ctx = canvas.context2D;
    ctx.drawImage(_webcam!, 0, 0);
    final dataUrl = canvas.toDataUrl('image/jpeg');
    final base64 = dataUrl.split(',').last;
    return base64Decode(base64);
  }

  Future<Uint8List> _convertCameraImage(CameraImage image) async {
    final img.Image convertedImage = img.Image.fromBytes(
      width: image.width,
      height: image.height,
      bytes: image.planes[0].bytes.buffer,
      order: img.ChannelOrder.bgra,
    );
    return Uint8List.fromList(img.encodeJpg(convertedImage, quality: 85));
  }

  Future<void> _sendFrameToServer(Uint8List bytes) async {
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('http://192.168.1.69:5000/detect'), // Update your IP
      );
      request.files.add(http.MultipartFile.fromBytes(
        'video_frame',
        bytes,
        filename: 'frame.jpg',
      ));

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      final result = jsonDecode(responseBody);

      if (response.statusCode == 200) {
        setState(() {
          _detections = result['detections'] ?? [];
        });
      } else {
        print('Server error: ${result['error']}');
      }
    } catch (e) {
      print('Error sending frame: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return Scaffold(
        appBar: AppBar(title: const Text('Web Object Detection')),
        body: Center(
          child: Column(
            children: [
              const SizedBox(height: 20),
              const Text("Live camera feed from browser"),
              const SizedBox(height: 20),
              SizedBox(
                width: 640,
                height: 480,
                child: HtmlElementView(viewType: 'webcamContainer'),
              ),
              const SizedBox(height: 20),
              _detections.isNotEmpty
                  ? Column(
                      children: _detections
                          .map((d) => Text(
                              "${d['label']} - ${(d['confidence'] * 100).toStringAsFixed(1)}%"))
                          .toList(),
                    )
                  : const Text("No detections yet"),
            ],
          ),
        ),
      );
    }

    if (_controller == null || !_controller!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      body: Stack(
        children: [
          CameraPreview(_controller!),
          CustomPaint(
            painter: BoundingBoxPainter(
                _detections, _controller!.value.previewSize!),
            child: Container(),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    _webcam?.remove();
    super.dispose();
  }
}

class BoundingBoxPainter extends CustomPainter {
  final List<dynamic> detections;
  final Size previewSize;

  BoundingBoxPainter(this.detections, this.previewSize);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    for (var detection in detections) {
      final bbox = detection['bbox'];
      final label = detection['label'];
      final conf = detection['confidence'];

      final double scaleX = size.width / previewSize.width;
      final double scaleY = size.height / previewSize.height;
      final rect = Rect.fromLTRB(
        bbox[0] * scaleX,
        bbox[1] * scaleY,
        bbox[2] * scaleX,
        bbox[3] * scaleY,
      );

      canvas.drawRect(rect, paint);

      final textSpan = TextSpan(
        text: '$label (${(conf * 100).toStringAsFixed(1)}%)',
        style: const TextStyle(color: Colors.red, fontSize: 16),
      );
      textPainter.text = textSpan;
      textPainter.layout();
      textPainter.paint(canvas, Offset(rect.left, rect.top - 20));
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}
