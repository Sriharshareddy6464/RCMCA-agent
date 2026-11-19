# Local vision model artifacts

`road_damage.onnx` is a local-only starter artifact downloaded from [`peterhdd/pothole-detection-yolov8`](https://huggingface.co/peterhdd/pothole-detection-yolov8). The model card describes a YOLOv8s model with one class (`pothole`) and declares Apache-2.0. The ONNX file is ignored by Git and Docker build context; it is mounted read-only into the API at `/models/road_damage.onnx`.

Local artifact SHA-256: `91DD7DE7A110C61314EA19A958FCC85C7B3461CC6D60D87FEFC08B41AC6E32C5`

The ONNX custom metadata also contains `license: AGPL-3.0 License`, inherited from its Ultralytics export metadata. Keep this weight local until the model author confirms the intended artifact license. The model covers potholes only, was not validated on Hyderabad data, and is not the final multi-category severity model. Configure `VISION_CLASS_NAMES=["pothole"]` for this artifact. Severity from box area remains a heuristic pending calibration against labeled local images.
