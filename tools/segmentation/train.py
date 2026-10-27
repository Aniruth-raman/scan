#!/usr/bin/env python
"""Train a MobileNetV2-UNet page segmenter on SmartDoc 2015.

Same architecture family as Lens's detector (MobileNetV2 encoder + decoder,
256x256 RGB -> 256x256 mask), sized for a phone.

    python train.py --data C:/data/smartdoc_ready --epochs 40 --size 256

Saves ``best.pth`` (highest validation Dice) next to the run.
"""
import argparse
import os

import cv2
import numpy as np
import torch
import torch.nn.functional as F
from torch.utils.data import Dataset, DataLoader

import albumentations as A
from albumentations.pytorch import ToTensorV2
import segmentation_models_pytorch as smp

MEAN = (0.485, 0.456, 0.406)
STD = (0.229, 0.224, 0.225)


class DocDataset(Dataset):
    def __init__(self, root, list_file, transform):
        self.root = root
        with open(list_file) as f:
            self.items = [line.strip() for line in f if line.strip()]
        self.transform = transform

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        rel = self.items[i]
        img = cv2.cvtColor(cv2.imread(os.path.join(self.root, rel)), cv2.COLOR_BGR2RGB)
        mask_path = os.path.join(self.root, rel.replace("images/", "masks/").replace(".jpg", ".png"))
        mask = cv2.imread(mask_path, 0)
        aug = self.transform(image=img, mask=mask)
        x = aug["image"]
        y = (aug["mask"] > 127).float().unsqueeze(0)
        return x, y


def transforms(size):
    train = A.Compose([
        A.LongestMaxSize(max_size=int(size * 1.5)),
        A.PadIfNeeded(min_height=int(size * 1.5), min_width=int(size * 1.5), border_mode=0),
        A.RandomCrop(height=size, width=size),
        A.Perspective(scale=(0.02, 0.08), p=0.5),
        A.HorizontalFlip(p=0.5),
        A.VerticalFlip(p=0.2),
        A.RandomBrightnessContrast(p=0.5),
        A.RandomGamma(p=0.5),
        A.GaussianBlur(p=0.2),
        A.Normalize(mean=MEAN, std=STD),
        ToTensorV2(),
    ])
    val = A.Compose([
        A.Resize(size, size),
        A.Normalize(mean=MEAN, std=STD),
        ToTensorV2(),
    ])
    return train, val


def dice_loss(logits, target):
    p = torch.sigmoid(logits)
    inter = (p * target).sum(dim=(1, 2, 3))
    union = p.sum(dim=(1, 2, 3)) + target.sum(dim=(1, 2, 3))
    return 1 - ((2 * inter + 1) / (union + 1)).mean()


@torch.no_grad()
def evaluate(model, loader, device):
    model.eval()
    dices, ious = [], []
    for x, y in loader:
        x, y = x.to(device), y.to(device)
        p = torch.sigmoid(model(x))
        pred = (p > 0.5).float()
        inter = (pred * y).sum(dim=(1, 2, 3))
        union = pred.sum(dim=(1, 2, 3)) + y.sum(dim=(1, 2, 3))
        dice = (2 * inter + 1) / (union + 1)
        iou = (inter + 1) / (pred.sum(dim=(1, 2, 3)) + y.sum(dim=(1, 2, 3)) - inter + 1)
        dices.append(dice.mean().item())
        ious.append(iou.mean().item())
    return float(np.mean(dices)), float(np.mean(ious))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--data", required=True)
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--size", type=int, default=256)
    ap.add_argument("--batch", type=int, default=32)
    ap.add_argument("--lr", type=float, default=1e-4)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--encoder", default="mobilenet_v2")
    ap.add_argument("--out", default="best.pth")
    args = ap.parse_args()

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"device: {device}")

    train_tf, val_tf = transforms(args.size)
    train_ds = DocDataset(args.data, os.path.join(args.data, "train.txt"), train_tf)
    val_ds = DocDataset(args.data, os.path.join(args.data, "val.txt"), val_tf)
    train_ld = DataLoader(train_ds, batch_size=args.batch, shuffle=True,
                          num_workers=args.workers, pin_memory=True, drop_last=True)
    val_ld = DataLoader(val_ds, batch_size=args.batch, shuffle=False,
                        num_workers=args.workers, pin_memory=True)

    model = smp.Unet(encoder_name=args.encoder, encoder_weights="imagenet",
                     in_channels=3, classes=1).to(device)
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.epochs)

    best = -1.0
    for epoch in range(1, args.epochs + 1):
        model.train()
        running = 0.0
        for x, y in train_ld:
            x, y = x.to(device), y.to(device)
            opt.zero_grad()
            logits = model(x)
            loss = F.binary_cross_entropy_with_logits(logits, y) + dice_loss(logits, y)
            loss.backward()
            opt.step()
            running += loss.item() * x.size(0)
        sched.step()
        dice, iou = evaluate(model, val_ld, device)
        print(f"epoch {epoch:03d}  loss {running / len(train_ds):.4f}  "
              f"val dice {dice:.4f}  val iou {iou:.4f}")
        if dice > best:
            best = dice
            torch.save(model.state_dict(), args.out)
            print(f"  saved {args.out} (dice {dice:.4f})")
    print(f"best val dice {best:.4f}")


if __name__ == "__main__":
    main()
