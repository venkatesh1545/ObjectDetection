from flask import Flask, request, jsonify
from flask_cors import CORS  # ✅ CORS support added
import cv2
import numpy as np
from ultralytics import YOLO
import logging
import os

# Create logs folder if it doesn't exist
os.makedirs("logs", exist_ok=True)

# Set up logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('logs/app.log', encoding='utf-8'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

app = Flask(__name__)
CORS(app)  # ✅ Enable CORS for all routes and origins

# Load YOLOv8 model
try:
    model = YOLO("yolov8m.pt")
    logger.info("✅ YOLOv8 model loaded successfully")
except Exception as e:
    logger.error(f"❌ Failed to load YOLOv8 model: {e}")
    raise

# Health check route
@app.route('/', methods=['GET'])
def home():
    return "<h2>✅ Object Detection Server Running</h2><p>Use POST /detect with image</p>"

# Detection route
@app.route('/detect', methods=['POST'])
def detect_objects():
    try:
        if 'video_frame' not in request.files:
            return jsonify({"error": "No video frame provided"}), 400

        file = request.files['video_frame']
        npimg = np.frombuffer(file.read(), np.uint8)
        frame = cv2.imdecode(npimg, cv2.IMREAD_COLOR)

        if frame is None:
            return jsonify({"error": "Invalid frame data"}), 400

        # Run YOLO inference
        results = model(frame, conf=0.5, iou=0.7, imgsz=640)

        detections = []
        for result in results:
            for box in result.boxes:
                x1, y1, x2, y2 = map(int, box.xyxy[0])
                conf = float(box.conf)
                cls = int(box.cls)
                label = model.names[cls]
                detections.append({
                    "label": label,
                    "confidence": conf,
                    "bbox": [x1, y1, x2, y2]
                })

        logger.info(f"Detected {len(detections)} object(s)")
        return jsonify({"detections": detections})

    except Exception as e:
        logger.error(f"❌ Error processing frame: {e}")
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
