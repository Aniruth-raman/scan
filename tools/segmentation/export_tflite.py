#!/usr/bin/env python
"""Export a trained MobileNetV2-UNet to int8 TFLite for the app.

    python export_tflite.py --weights best.pth --size 256

Produces ``tflite_out/<name>_dynamic_range_quant.tflite`` (weights int8,
float activations) which runs on the app's existing ``tflite_flutter`` runtime
with no calibration set. For full-integer (activations too) add a calibration
folder and use ``-oiqt`` instead of ``-odrqt``.
"""
import argparse
import subprocess
import sys

import torch
import segmentation_models_pytorch as smp


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--weights", default="best.pth")
    ap.add_argument("--encoder", default="mobilenet_v2")
    ap.add_argument("--size", type=int, default=256)
    ap.add_argument("--onnx", default="doc_segmenter.onnx")
    ap.add_argument("--out", default="tflite_out")
    args = ap.parse_args()

    model = smp.Unet(encoder_name=args.encoder, encoder_weights=None,
                     in_channels=3, classes=1)
    model.load_state_dict(torch.load(args.weights, map_location="cpu"))
    model.eval()

    dummy = torch.randn(1, 3, args.size, args.size)
    torch.onnx.export(
        model, dummy, args.onnx,
        input_names=["input"], output_names=["mask"],
        opset_version=16,
        dynamic_axes={"input": {0: "batch"}, "mask": {0: "batch"}},
    )
    print(f"onnx: {args.onnx}")

    cmd = [sys.executable, "-m", "onnx2tf", "-i", args.onnx, "-o", args.out, "-odrqt"]
    print("running:", " ".join(cmd))
    subprocess.run(cmd, check=True)
    print(f"done: {args.out}  (pick the *_dynamic_range_quant.tflite)")


if __name__ == "__main__":
    main()
