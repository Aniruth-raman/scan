# Page-segmentation detector (training pipeline)

Reverse-engineering `lens.apk` showed its edge detection is not line segments or
corner heatmaps — it is a **MobileNetV2 semantic-segmentation model**
(`mnv2_ep42_wb_quant.ort`, `256×256×3 → 256×256×1` page mask). This directory
trains an equivalent open-source model and exports it to TFLite for the app.

None of this runs in the app; only the exported `.tflite` ships.

## 1. Dataset

**SmartDoc 2015 — Challenge 1** — "detect and segment document regions in
preview frames". A4 documents on real backgrounds, hand-held, with perspective,
motion/focus blur, lighting changes and partial occlusion. 120 clips,
~24,000 frames, per-frame quadrilateral ground truth.

- Download: <https://zenodo.org/records/1230218>
  - `sampleDataset.tar.gz` (20 MB) to try the pipeline
  - `testDataset.tar.gz` (1.4 GB) for the real run
- Licence: **CC BY 4.0** (commercial use allowed). Attribute by citing:
  > J.-C. Burie, J. Chazalon, M. Coustaty, S. Eskenazi, M. M. Luqman, M. Mehri,
  > N. Nayef, J.-M. Ogier, S. Prum, M. Rusinol: "ICDAR2015 Competition on
  > Smartphone Document Capture and OCR (SmartDoc)", ICDAR 2015.

## 2. Prepare

```bash
python prepare_dataset.py --data /path/to/unpacked_smartdoc --out /path/to/smartdoc_ready
```

Writes `images/*.jpg`, `masks/*.png` (255 = page), and `train.txt` / `val.txt`.
Frames are split by **background** (`--val-background`, default `background03`)
so validation is on an unseen surface, not just unseen frames of a seen clip.

## 3. Train

```bash
python train.py --data /path/to/smartdoc_ready --epochs 40 --size 256
```

`segmentation_models_pytorch` **UNet + MobileNetV2** (`encoder_weights=imagenet`),
256×256, BCE + Dice, AdamW + cosine. Saves `best.pth` on best validation Dice.
One consumer GPU should be a few hours; CPU will crawl.

The full `mobilenet_v2` UNet is **6.6 M parameters** (~7 MB as int8; Lens's own
model is 342 KB, so it is much smaller than ours). If you want to shrink it,
pass a lighter encoder (`--encoder efficientnet-lite0`, `mobilenet_v2_0.35` via
`timm`) or trim the UNet decoder channels; re-check accuracy on the val split.

## 4. Export

```bash
python export_tflite.py --weights best.pth --size 256
```

PyTorch → ONNX (opset 16) → TFLite, dynamic-range int8 by default (~2–5 MB).
Pick `tflite_out/*_dynamic_range_quant.tflite`.

## 5. Wire into the app

1. Copy the `.tflite` to `scan/assets/models/` (e.g. `document_mask.tflite`) and
   add it to `pubspec.yaml` assets.
2. In `document_detector.dart`, replace the M-LSD path with:
   - preprocess: resize frame → 256×256, ImageNet normalise (mean `0.485/0.456/0.406`,
     std `0.229/0.224/0.225`), keep NHWC;
   - run the model → `256×256×1` logits;
   - `sigmoid` → threshold (0.5) → largest connected component → contour →
     `minAreaRect`/4-point `approxPolyDP` → corners scaled to the frame;
   - return the existing `DocumentQuad`.
3. Keep the same `detectFromRgba` / `detectFromLuma` surface so the camera and
   crop stages do not change.

The model is fully convolutional, so it can be trained at 256 and still run at
other sizes if accuracy needs it.

## Notes

- `prepare_dataset.py` reads the GT XML `frame index` (1-based) against OpenCV's
  0-based `read()`, and skips `rejected="true"` frames.
- Albumentations APIs drift between versions; the transforms here use the stable
  subset (no `ImageCompression`). Add JPEG/blur/noise augmentation if your
  albumentations version supports it.
- Add MIDV-500 (`ftp://smartengines.com/midv-500/`) later for ID cards, or Doc3D
  (`huggingface.co/datasets/StonyBrook-CVLab/doc3D-dataset`, MIT) for synthetic
  volume, by pointing `prepare_dataset.py` at their masks.
