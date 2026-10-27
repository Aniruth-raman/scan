#!/usr/bin/env python
"""Extract frames + page masks from SmartDoc 2015 Challenge 1.

The dataset (https://zenodo.org/records/1230218, CC BY 4.0) unpacks into
``backgroundXX/<doc><NNN>.avi`` clips plus ``backgroundXX_gt/<doc><NNN>.gt.xml``
per-frame quadrilaterals.

Output layout (what train.py consumes):

    <out>/images/<clip>_<frame>.jpg   RGB/BGR frame, full resolution
    <out>/masks/<clip>_<frame>.png    255 = page, 0 = background
    <out>/train.txt, val.txt          one "images/...jpg" path per line

Usage:
    python prepare_dataset.py --data C:/data/smartdoc --out C:/data/smartdoc_ready
"""
import argparse
import os
import glob
import xml.etree.ElementTree as ET

import cv2
import numpy as np


def parse_gt(xml_path):
    """Return {frame_index (1-based): [tl, tr, br, bl]} for accepted frames."""
    root = ET.parse(xml_path).getroot()
    out = {}
    for fr in root.iter("frame"):
        if fr.get("rejected") == "true":
            continue
        pts = {
            p.get("name"): (float(p.get("x")), float(p.get("y")))
            for p in fr.iter("point")
        }
        if all(k in pts for k in ("tl", "tr", "br", "bl")):
            out[int(fr.get("index"))] = [pts["tl"], pts["tr"], pts["br"], pts["bl"]]
    return out


def find_video(gt_path, data_root):
    """Locate the .avi/.mp4 that a .gt.xml belongs to.

    Clip names repeat across backgrounds (``background01/datasheet001.avi`` and
    ``background02/datasheet001.avi``), so the match is scoped to the same
    ``backgroundXX`` folder the ground truth came from.
    """
    stem = os.path.basename(gt_path).replace(".gt.xml", "")
    bg = os.path.basename(os.path.dirname(gt_path))
    if bg.endswith("_gt"):
        bg = bg[:-3]
    for ext in (".avi", ".mp4"):
        hits = glob.glob(os.path.join(data_root, "**", bg, stem + ext), recursive=True)
        if hits:
            return hits[0]
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--data", required=True, help="unpacked SmartDoc 2015 root")
    ap.add_argument("--out", required=True, help="output dir for images/masks")
    ap.add_argument("--stride", type=int, default=2,
                    help="keep every Nth accepted frame (default 2)")
    ap.add_argument("--val-background", default="background03",
                    help="background held out for validation (default background03)")
    args = ap.parse_args()

    img_dir = os.path.join(args.out, "images")
    msk_dir = os.path.join(args.out, "masks")
    os.makedirs(img_dir, exist_ok=True)
    os.makedirs(msk_dir, exist_ok=True)

    gts = sorted(glob.glob(os.path.join(args.data, "**", "*.gt.xml"), recursive=True))
    if not gts:
        raise SystemExit(f"no *.gt.xml under {args.data} — extract the dataset first")

    def background(p):
        name = os.path.basename(os.path.dirname(p))
        return name[:-3] if name.endswith("_gt") else name

    backgrounds = sorted({background(p) for p in gts})
    val_bg = args.val_background if args.val_background in backgrounds else backgrounds[-1]
    print(f"backgrounds: {backgrounds}  -> validation: {val_bg}")

    train, val = [], []
    kept = 0
    for gi, gt_path in enumerate(gts):
        bg = background(gt_path)
        is_val = bg == val_bg
        frames = parse_gt(gt_path)
        if not frames:
            continue
        video = find_video(gt_path, args.data)
        if video is None:
            print(f"  !! no video for {gt_path}")
            continue

        cap = cv2.VideoCapture(video)
        if not cap.isOpened():
            print(f"  !! cannot open {video}")
            continue
        clip = os.path.splitext(os.path.basename(video))[0]
        idx = 0
        while True:
            ok, frame = cap.read()
            if not ok:
                break
            gt_index = idx + 1
            quad = frames.get(gt_index)
            if quad is not None and idx % args.stride == 0:
                name = f"{clip}_{gt_index:05d}"
                h, w = frame.shape[:2]
                mask = np.zeros((h, w), np.uint8)
                poly = np.round(np.array(quad, np.float32)).astype(np.int32)
                cv2.fillPoly(mask, [poly], 255)
                cv2.imwrite(os.path.join(img_dir, name + ".jpg"), frame,
                            [cv2.IMWRITE_JPEG_QUALITY, 90])
                cv2.imwrite(os.path.join(msk_dir, name + ".png"), mask)
                (val if is_val else train).append(f"images/{name}.jpg")
                kept += 1
            idx += 1
        cap.release()

    with open(os.path.join(args.out, "train.txt"), "w") as f:
        f.write("\n".join(train) + "\n")
    with open(os.path.join(args.out, "val.txt"), "w") as f:
        f.write("\n".join(val) + "\n")

    print(f"wrote {kept} frames: train {len(train)}, val {len(val)}")
    print(f"val background: {args.val_background}")


if __name__ == "__main__":
    main()
