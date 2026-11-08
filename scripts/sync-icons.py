# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow", "numpy"]
# ///
"""Icônes de l'app tirées des planches du référentiel (shared/illustrations/<espèce>.jpg).

Pour chaque planche : le papier est ramené au blanc, le sujet recadré au centre (86 % du côté),
puis l'aquarelle reposée sur un fond crème commun aux dix icônes. Écrit dans Champis/Assets.xcassets :

- Icon-<espèce>.appiconset : icône alternative 1024 px, iOS et iPadOS (PNG sans alpha) ;
- IconPreview-<espèce>.imageset : aperçu du sélecteur (JPEG 300 px) ;
- IconPreview-champis.imageset : aperçu de l'icône principale, tiré de AppIcon-1024.png ;

et note le commit du référentiel dans Champis/Resources/ICONS_VERSION. Vérifie enfin que la liste
ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES du projet nomme exactement ces icônes.

    uv run scripts/sync-icons.py [chemin/vers/champis]

Spec › Produit › Étape C, lot C6 (icônes, 8 nov. 2026).
"""

import json
import re
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent.parent
ASSETS = HERE / "Champis" / "Assets.xcassets"
PROJECT = HERE / "Champis.xcodeproj" / "project.pbxproj"
VERSION = HERE / "Champis" / "Resources" / "ICONS_VERSION"

ICON_PX = 1024
PREVIEW_PX = 300
FILL = 0.86  # part du côté de l'icône occupée par le sujet
CREAM = np.array([0xF6, 0xF1, 0xE6]) / 255.0  # fond commun, un papier à peine teinté
INK = 0.08  # écart au papier au-delà duquel un pixel appartient au sujet

XCODE = {"author": "xcode", "version": 1}


def icon(path: Path) -> Image.Image:
    im = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255.0
    h, w, _ = im.shape
    b = max(8, w // 50)
    border = np.concatenate([a.reshape(-1, 3) for a in (im[:b], im[-b:], im[:, :b], im[:, -b:])])
    paper = np.median(border, axis=0)
    norm = np.clip(im / paper, 0, 1)  # papier → blanc, l'aquarelle garde ses valeurs relatives
    subject = (1 - norm.min(axis=2)) > INK
    rows = np.where(subject.sum(axis=1) > w * 0.004)[0]
    cols = np.where(subject.sum(axis=0) > h * 0.004)[0]
    y0, y1, x0, x1 = rows[0], rows[-1], cols[0], cols[-1]
    side = int(round(max(y1 - y0, x1 - x0) / FILL))
    top = int(round((y0 + y1) / 2 - side / 2))
    left = int(round((x0 + x1) / 2 - side / 2))
    square = np.ones((side, side, 3))
    sy0, sx0, sy1, sx1 = max(0, top), max(0, left), min(h, top + side), min(w, left + side)
    square[sy0 - top : sy1 - top, sx0 - left : sx1 - left] = norm[sy0:sy1, sx0:sx1]
    resized = Image.fromarray((square * 255).round().astype(np.uint8)).resize((ICON_PX, ICON_PX), Image.LANCZOS)
    out = np.asarray(resized, dtype=np.float64) / 255.0 * CREAM  # l'aquarelle « posée » sur le crème
    return Image.fromarray((out * 255).round().astype(np.uint8), "RGB")


def write_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def write_appiconset(name: str, image: Image.Image) -> None:
    folder = ASSETS / f"{name}.appiconset"
    folder.mkdir(exist_ok=True)
    for old in folder.glob("*.png"):
        old.unlink()
    image.save(folder / f"{name}.png", optimize=True)
    write_json(
        folder / "Contents.json",
        {
            "images": [{"filename": f"{name}.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
            "info": XCODE,
        },
    )


def write_preview(name: str, image: Image.Image) -> None:
    folder = ASSETS / f"{name}.imageset"
    folder.mkdir(exist_ok=True)
    for old in folder.glob("*.jpg"):
        old.unlink()
    image.convert("RGB").resize((PREVIEW_PX, PREVIEW_PX), Image.LANCZOS).save(folder / f"{name}.jpg", quality=90)
    write_json(folder / "Contents.json", {"images": [{"filename": f"{name}.jpg", "idiom": "universal"}], "info": XCODE})


def check_project(names: list[str]) -> bool:
    """La liste du projet (iphoneos et iphonesimulator) doit nommer exactement les icônes écrites."""
    text = PROJECT.read_text(encoding="utf-8")
    found = re.findall(r'"ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES\[sdk=[^\]]+\]" = "([^"]*)";', text)
    expected = " ".join(names)
    if found and all(f == expected for f in found):
        return True
    print("ECHEC  ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES du projet à mettre à jour (Debug et Release,", file=sys.stderr)
    print(f'       iphoneos et iphonesimulator) : "{expected}"', file=sys.stderr)
    return False


def main() -> int:
    referential = Path(sys.argv[1] if len(sys.argv) > 1 else HERE.parent / "champis").resolve()
    plates = sorted((referential / "shared" / "illustrations").glob("*.jpg"))
    if not plates:
        print(f"planches introuvables dans {referential}/shared/illustrations (passer le chemin du référentiel)", file=sys.stderr)
        return 1
    # une icône par planche ; les jeux d'une planche disparue sont retirés
    wanted = {f"Icon-{p.stem}" for p in plates}
    for stale in ASSETS.glob("Icon-*.appiconset"):
        if stale.stem not in wanted:
            for f in stale.iterdir():
                f.unlink()
            stale.rmdir()
    for stale in ASSETS.glob("IconPreview-*.imageset"):
        if stale.stem != "IconPreview-champis" and stale.stem.removeprefix("IconPreview-") not in {p.stem for p in plates}:
            for f in stale.iterdir():
                f.unlink()
            stale.rmdir()

    names = []
    for plate in plates:
        image = icon(plate)
        write_appiconset(f"Icon-{plate.stem}", image)
        write_preview(f"IconPreview-{plate.stem}", image)
        names.append(f"Icon-{plate.stem}")
        print(f"ok  Icon-{plate.stem}")
    write_preview("IconPreview-champis", Image.open(ASSETS / "AppIcon.appiconset" / "AppIcon-1024.png"))

    commit = subprocess.run(
        ["git", "-C", str(referential), "rev-parse", "--short", "HEAD"], capture_output=True, text=True
    ).stdout.strip() or "inconnu"
    VERSION.write_text(f"monorepo=adhumi/champis\ncommit={commit}\nsource=shared/illustrations\nicons={len(names)}\n")
    print(VERSION.read_text(), end="")
    return 0 if check_project(names) else 1


if __name__ == "__main__":
    sys.exit(main())
