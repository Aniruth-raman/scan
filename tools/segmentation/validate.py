#!/usr/bin/env python
"""Validate a trained page-segmenter (best.pth).

Reports mask Dice/IoU and mean corner error, and writes overlay images
(image + predicted quad in red + ground-truth quad in green) so you can see
where it fails.

    python validate.py --weights best.pth --data /content/ready --size 256 --out viz
"""
import argparse
import os
import glob

import cv2
import numpy as np
import torch
import segmentation_models_pytorch as smp

MEAN = np.array([0.485, 0.456, 0.406])
STD = np.array([0.229, 0.224, 0.225])


def order_quad(pts):
    """Order 4 points clockwise from the top-left (TL, TR, BR, BL)."""
    pts = np.asarray(pts, np.float32).reshape(4, 2)
    s = pts.sum(1)
    d = (pts[:, 0] - pts[:, 1])
    return np.array(
        [pts[np.argmin(s)], pts[np.argmax(d)], pts[np.argmax(s)], pts[np.argmin(d)]],
        np.float32,
    )


def mask_to_quad(mask):
    """Largest contour -> 4 corners (approxPolyDP, else minAreaRect)."""
    cnts, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not cnts:
        return None
    c = max(cnts, key=cv2.contourArea)
    if cv2.contourArea(c) < 16:
        return None
    peri = cv2.arcLength(c, True)
    approx = cv2.approxPolyDP(c, 0.02 * peri, True)
    if len(approx) == 4:
        return order_quad(approx)
    return order_quad(cv2.boxPoints(cv2.minAreaRect(c)))


def load_model(weights, size, device):
    model = smp.Unet(encoder_name="mobilenet_v2", encoder_weights=None,
                     in_channels=3, classes=1)
    model.load_state_dict(torch.load(weights, map_location=device))
    model.eval().to(device)
    return model


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--weights", default="best.pth")
    ap.add_argument("--data", default="/content/ready")
    ap.add_argument("--size", type=int, default=256)
    ap.add_argument("--out", default="viz")
    ap.add_argument("--limit", type=int, default=300)
    ap.add_argument("--threshold", type=float, default=0.5)
    args = ap.parse_args()

    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = load_model(args.weights, args.size, device)

    list_file = os.path.join(args.data, "val.txt")
    if not os.path.exists(list_file) or os.path.getsize(list_file) == 0:
        list_file = os.path.join(args.data, "train.txt")
    items = [l.strip() for l in open(list_file) if l.strip()][: args.limit]
    if not items:
        raise SystemExit(f"no images in {list_file}")

    os.makedirs(args.out, exist_ok=True)
    dices, ious, corner_errs, missed = [], [], [], 0

    for i, rel in enumerate(items):
        img_bgr = cv2.imread(os.path.join(args.data, rel))
        img = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB)
        gt = cv2.imread(os.path.join(args.data, rel.replace("images/", "masks/").replace(".jpg", ".png")), 0)
        h, w = gt.shape

        r = cv2.resize(img, (args.size, args.size)).astype(np.float32) / 255.0
        x = ((r - MEAN) / STD).transpose(2, 0, 1)[None]
        with torch.no_grad():
            logit = model(torch.from_numpy(x).float().to(device)).cpu().numpy()[0, 0]
        prob = 1.0 / (1.0 + np.exp(-logit))
        pred = (cv2.resize(prob, (w, h)) > args.threshold).astype(np.uint8) * 255
        gtb = (gt > 127).astype(np.uint8) * 255

        p, g = pred > 127, gtb > 127
        inter = (p & g).sum()
        dice = 2 * inter / (p.sum() + g.sum() + 1e-9)
        iou = inter / ((p | g).sum() + 1e-9)
        dices.append(dice)
        ious.append(iou)

        pq, gq = mask_to_quad(pred), mask_to_quad(gtb)
        if pq is None:
            missed += 1
        elif gq is not None:
            corner_errs.append(float(np.linalg.norm(pq - gq, axis=1).mean()))

        if i < 40:
            vis = img_bgr.copy()
            if gq is not None:
                cv2.polylines(vis, [gq.astype(np.int32)], True, (0, 255, 0), 2)
            if pq is not None:
                cv2.polylines(vis, [pq.astype(np.int32)], True, (0, 0, 255), 3)
            cv2.putText(vis, f"dice {dice:.3f}", (10, 34),
                        cv2.FONT_HERSHEY_SIMPLEX, 1.0, (255, 255, 255), 2)
            cv2.imwrite(os.path.join(args.out, os.path.basename(rel).replace(".jpg", ".png")), vis)

    dices = np.array(dices)
    print(f"\nimages evaluated : {len(dices)}  (device {device})")
    print(f"Dice  mean {dices.mean():.4f}  median {np.median(dices):.4f}  "
          f"min {dices.min():.4f}  p10 {np.percentile(dices, 10):.4f}")
    print(f"IoU   mean {np.mean(ious):.4f}")
    if corner_errs:
        print(f"corner error mean {np.mean(corner_errs):.1f} px  "
              f"median {np.median(corner_errs):.1f} px")
    print(f"missed (no quad): {missed}/{len(dices)}")
    print(f"Dice buckets: >=0.9 {np.mean(dices >= 0.9):.0%} | "
          f"0.7-0.9 {np.mean((dices >= 0.7) & (dices < 0.9)):.0%} | "
          f"<0.7 {np.mean(dices < 0.7):.0%}")
    print(f"overlays: {args.out}/")


if __name__ == "__main__":
    main()
