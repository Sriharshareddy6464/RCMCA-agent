from __future__ import annotations

import json
import os
from functools import lru_cache
from io import BytesIO

import numpy as np
from PIL import Image, UnidentifiedImageError


class VisionUnavailable(RuntimeError):
    pass


@lru_cache(maxsize=1)
def _session():
    model_path = os.getenv("VISION_MODEL_PATH", "").strip()
    if not model_path or not os.path.isfile(model_path):
        raise VisionUnavailable("VISION_MODEL_PATH must point to the fine-tuned ONNX model")
    try:
        import onnxruntime as ort
    except ImportError as exc:
        raise VisionUnavailable("onnxruntime is not installed") from exc
    providers = ["CPUExecutionProvider"]
    if "CUDAExecutionProvider" in ort.get_available_providers():
        providers.insert(0, "CUDAExecutionProvider")
    return ort.InferenceSession(model_path, providers=providers)


def _class_names(session) -> list[str]:
    configured = os.getenv("VISION_CLASS_NAMES", "").strip()
    if configured:
        try:
            decoded = json.loads(configured)
            if isinstance(decoded, list):
                return [str(name) for name in decoded]
            return [str(decoded[str(i)]) for i in range(len(decoded))]
        except (ValueError, KeyError, TypeError):
            return [name.strip() for name in configured.split(",") if name.strip()]
    metadata = session.get_modelmeta().custom_metadata_map
    try:
        names = json.loads(metadata.get("names", "{}"))
        if isinstance(names, list):
            return [str(name) for name in names]
        return [str(names[str(i)]) for i in range(len(names))]
    except (ValueError, KeyError, TypeError):
        raise VisionUnavailable("Configure VISION_CLASS_NAMES for this ONNX model")


def _iou(left: np.ndarray, right: np.ndarray) -> np.ndarray:
    x1 = np.maximum(left[0], right[:, 0])
    y1 = np.maximum(left[1], right[:, 1])
    x2 = np.minimum(left[2], right[:, 2])
    y2 = np.minimum(left[3], right[:, 3])
    intersection = np.maximum(0, x2 - x1) * np.maximum(0, y2 - y1)
    left_area = max(0, left[2] - left[0]) * max(0, left[3] - left[1])
    right_area = np.maximum(0, right[:, 2] - right[:, 0]) * np.maximum(0, right[:, 3] - right[:, 1])
    return intersection / np.maximum(left_area + right_area - intersection, 1e-8)


def _decode(output: np.ndarray, labels: list[str], confidence: float, nms: float):
    rows = np.squeeze(output)
    if rows.ndim != 2:
        raise VisionUnavailable(f"Unsupported ONNX output shape: {output.shape}")
    if rows.shape[0] in (6, 4 + len(labels)) and rows.shape[1] > rows.shape[0]:
        rows = rows.T
    # NMS-enabled exports use [x1, y1, x2, y2, confidence, class_id].
    if rows.shape[-1] == 6:
        boxes = rows[:, :4].astype(np.float32)
        scores = rows[:, 4].astype(np.float32)
        class_ids = rows[:, 5].astype(np.int64)
    else:
        if rows.shape[-1] != 4 + len(labels):
            raise VisionUnavailable("Model output class count does not match VISION_CLASS_NAMES")
        center = rows[:, :4].astype(np.float32)
        boxes = np.column_stack((
            center[:, 0] - center[:, 2] / 2,
            center[:, 1] - center[:, 3] / 2,
            center[:, 0] + center[:, 2] / 2,
            center[:, 1] + center[:, 3] / 2,
        ))
        class_scores = rows[:, 4:].astype(np.float32)
        class_ids = class_scores.argmax(axis=1)
        scores = class_scores[np.arange(len(class_ids)), class_ids]

    valid = (scores >= confidence) & (class_ids >= 0) & (class_ids < len(labels))
    boxes, scores, class_ids = boxes[valid], scores[valid], class_ids[valid]
    selected: list[int] = []
    for class_id in np.unique(class_ids):
        indices = np.where(class_ids == class_id)[0]
        indices = indices[np.argsort(scores[indices])[::-1]]
        while len(indices):
            current = int(indices[0])
            selected.append(current)
            indices = indices[1:][_iou(boxes[current], boxes[indices[1:]]) <= nms]
    return boxes[selected], scores[selected], class_ids[selected]


def _letterbox(image: Image.Image, side: int) -> tuple[np.ndarray, float, int, int]:
    width, height = image.size
    scale = min(side / width, side / height)
    resized = image.resize((round(width * scale), round(height * scale)), Image.Resampling.BILINEAR)
    pad_x = (side - resized.width) // 2
    pad_y = (side - resized.height) // 2
    canvas = Image.new("RGB", (side, side), (114, 114, 114))
    canvas.paste(resized, (pad_x, pad_y))
    array = np.asarray(canvas, dtype=np.float32) / 255.0
    return array.transpose(2, 0, 1)[None], scale, pad_x, pad_y


def assess_image(image_bytes: bytes) -> dict:
    session = _session()
    labels = _class_names(session)
    try:
        image = Image.open(BytesIO(image_bytes))
    except (UnidentifiedImageError, OSError) as exc:
        raise ValueError("Uploaded evidence is not a supported image") from exc
    if image.width < 32 or image.height < 32:
        raise ValueError("Image dimensions must be at least 32 by 32 pixels")
    if image.width * image.height > 25_000_000:
        raise ValueError("Image dimensions must not exceed 25 megapixels")
    image = image.convert("RGB")

    input_meta = session.get_inputs()[0]
    shape = input_meta.shape
    side = int(shape[-1]) if isinstance(shape[-1], int) else int(os.getenv("VISION_INPUT_SIZE", "640"))
    tensor, scale, pad_x, pad_y = _letterbox(image, side)
    raw_outputs = session.run(None, {input_meta.name: tensor})
    boxes, scores, class_ids = _decode(
        raw_outputs[0], labels,
        float(os.getenv("VISION_CONFIDENCE_THRESHOLD", "0.35")),
        float(os.getenv("VISION_NMS_THRESHOLD", "0.45")),
    )
    detections = []
    for box, score, class_id in zip(boxes, scores, class_ids):
        x1, y1, x2, y2 = box
        coords = [
            max(0.0, min(float(image.width), (float(x1) - pad_x) / scale)),
            max(0.0, min(float(image.height), (float(y1) - pad_y) / scale)),
            max(0.0, min(float(image.width), (float(x2) - pad_x) / scale)),
            max(0.0, min(float(image.height), (float(y2) - pad_y) / scale)),
        ]
        detections.append({"label": labels[int(class_id)], "confidence": round(float(score), 4), "box": coords})

    severity = None
    if detections:
        thresholds = [float(x) for x in os.getenv("VISION_SEVERITY_AREA_THRESHOLDS", "0.01,0.03,0.08,0.2").split(",")]
        if len(thresholds) != 4 or sorted(thresholds) != thresholds:
            raise VisionUnavailable("VISION_SEVERITY_AREA_THRESHOLDS must contain four ascending ratios")
        max_area = max(
            ((item["box"][2] - item["box"][0]) * (item["box"][3] - item["box"][1]))
            / (image.width * image.height)
            for item in detections
        )
        severity = 1 + sum(max_area >= threshold for threshold in thresholds)

    return {
        "model": os.path.basename(os.getenv("VISION_MODEL_PATH", "configured-onnx-model")),
        "image_width": image.width,
        "image_height": image.height,
        "detections": detections,
        "severity_estimate": severity,
        "severity_method": "largest_detection_area_ratio_heuristic",
    }
