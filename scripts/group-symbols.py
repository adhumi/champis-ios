# /// script
# requires-python = ">=3.12"
# dependencies = ["skia-python==144.1"]
# ///
"""Symboles des familles du sélecteur d'espèce : un SF Symbol maison par groupe du référentiel.

Chaque glyphe est dessiné ici au trait dans une boîte 100 x 100 (mode "s" = trait, "f" = plein).
Le script épaissit les traits, fusionne les contours et écrit dans Champis/Assets.xcassets un
`Group-<groupe>.symbolset` au gabarit SF Symbols (graisse Regular, échelle M, la seule que Xcode exige ; les autres graisses
et échelles en sont dérivées par le système). Le menu affiche `Group-<id>` s'il existe : un groupe
nouveau du référentiel n'a pas d'icône tant que son glyphe n'est pas ajouté ici.

    uv run scripts/group-symbols.py [chemin/vers/champis]

Avec le chemin du référentiel, vérifie aussi que chaque groupe de species/*.json a son glyphe.
"""

import json
import math
import re
import sys
from pathlib import Path

import skia

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Champis" / "Assets.xcassets"
PREFIX = "Group-"

STROKE = 5.4  # épaisseur du trait dans la boîte 100 x 100 (7,5 unités du gabarit, comme un symbole Regular)
SCALE = 1.39  # boîte 100 -> unités du gabarit (un symbole M en fait environ 125)
CAP_HEIGHT = 70.459  # hauteur de capitale du gabarit : le glyphe est centré dessus
MARGIN = 6.0

GLYPHS: dict[str, list[tuple[str, str]]] = {}
GLYPHS["cepes"] = [
    (
        "M14 50 C14 28 31 14 50 14 C69 14 86 28 86 50 C86 54 83 56 79 56 L21 56 C17 56 14 54 14 50 Z",
        "s",
    ),
    (
        "M40 56 C39 65 29 70 29 79 C29 86 38 89 50 89 C62 89 71 86 71 79 C71 70 61 65 60 56",
        "s",
    ),
]
GLYPHS["bolets_bais"] = [
    (
        "M11 45 C11 30 29 20 50 20 C71 20 89 30 89 45 C89 53 70 59 50 59 C30 59 11 53 11 45 Z",
        "s",
    ),
    ("M12 44 Q50 52 88 44", "s"),
    (
        "M43 59 C43 70 41 79 40 86 C40 88 41 89 43 89 L57 89 C59 89 60 88 60 86 C59 79 57 70 57 59",
        "s",
    ),
]
GLYPHS["nonnettes"] = [
    (
        "M13 50 C15 30 31 16 50 16 C69 16 85 30 87 50 C87 54 84 56 80 56 L20 56 C16 56 13 54 13 50 Z",
        "s",
    ),
    ("M27 38 Q32 28 42 24", "s"),
    ("M44 56 L43 86 C43 88 44 89 46 89 L54 89 C56 89 57 88 57 86 L56 56", "s"),
    ("M44 66 L35 75", "s"),
    ("M56 66 L65 75", "s"),
]
GLYPHS["girolles"] = [
    (
        "M11 32 C17 21 27 30 36 25 C45 20 53 30 63 24 C72 19 83 22 89 32 C85 48 64 56 60 72 L58 86 C58 88 57 89 55 89 L45 89 C43 89 42 88 42 86 L40 72 C36 56 15 48 11 32 Z",
        "s",
    ),
    ("M33 43 C40 49 44 55 46 63", "s"),
    ("M67 43 C60 49 56 55 54 63", "s"),
]
GLYPHS["trompettes"] = [
    (
        "M50 14 C72 14 89 19 89 26 C89 33 72 38 50 38 C28 38 11 33 11 26 C11 19 28 14 50 14 Z",
        "s",
    ),
    ("M36 25 Q50 32 64 25", "s"),
    (
        "M15 32 C30 44 43 60 45 86 C45 88 46 89 48 89 L52 89 C54 89 55 88 55 86 C57 60 70 44 85 32",
        "s",
    ),
]
GLYPHS["chanterelles"] = [
    (
        "M20 30 C25 20 41 20 50 28 C59 20 75 20 80 30 C77 40 64 45 56 47 C56 60 61 74 58 86 C58 88 57 89 55 89 L49 89 C47 89 46 88 46 86 C48 74 44 60 44 47 C36 45 23 40 20 30 Z",
        "s",
    ),
]
GLYPHS["pieds_de_mouton"] = [
    (
        "M10 44 C10 28 26 15 44 19 C56 11 80 18 88 34 C92 42 89 49 82 49 L18 49 C13 49 10 48 10 44 Z",
        "s",
    ),
    (
        "M42 49 C42 66 38 78 40 86 C40 88 41 89 43 89 L61 89 C63 89 64 88 64 86 C64 78 62 66 64 49",
        "s",
    ),
    ("M19 58 L19 63", "s"),
    ("M30 58 L30 65", "s"),
    ("M75 58 L75 65", "s"),
    ("M85 58 L85 62", "s"),
]
GLYPHS["lactaires"] = [
    (
        "M11 33 C11 26 20 22 29 25 C38 28 43 34 50 34 C57 34 62 28 71 25 C80 22 89 26 89 33 C89 44 70 52 58 54 L58 86 C58 88 57 89 55 89 L45 89 C43 89 42 88 42 86 L42 54 C30 52 11 44 11 33 Z",
        "s",
    ),
    (
        "M80 58 C84 64 87 68 87 72 C87 76 84 79 80 79 C76 79 73 76 73 72 C73 68 76 64 80 58 Z",
        "f",
    ),
]
GLYPHS["russules"] = [
    (
        "M9 45 C13 28 33 21 50 25 C67 21 87 28 91 45 C78 55 64 58 58 58 L42 58 C36 58 22 55 9 45 Z",
        "s",
    ),
    ("M43 55 L29 42", "s"),
    ("M57 55 L71 42", "s"),
    ("M50 54 L50 38", "s"),
    ("M42 58 L42 86 C42 88 43 89 45 89 L55 89 C57 89 58 88 58 86 L58 58", "s"),
]
GLYPHS["pieds_bleus"] = [
    (
        "M9 46 C15 36 29 30 39 28 C45 21 55 21 61 28 C71 30 85 36 91 46 C85 53 75 46 67 52 C59 57 41 57 33 52 C25 46 15 53 9 46 Z",
        "s",
    ),
    (
        "M44 56 C44 66 37 74 37 81 C37 87 42 89 50 89 C58 89 63 87 63 81 C63 74 56 66 56 56",
        "s",
    ),
]
GLYPHS["grisets"] = [
    ("M12 52 C22 40 38 24 50 15 C62 24 78 40 88 52 C76 58 24 58 12 52 Z", "s"),
    ("M50 30 L50 45", "s"),
    ("M36 40 L29 48", "s"),
    ("M64 40 L71 48", "s"),
    ("M45 57 L44 86 C44 88 45 89 47 89 L53 89 C55 89 56 88 56 86 L55 57", "s"),
]


def parse(d: str) -> skia.Path:
    """Tracé SVG réduit aux commandes absolues M, L, Q, C et Z, celles des glyphes ci-dessus."""
    path = skia.Path()
    tokens = re.findall(r"[MLQCZ]|-?\d+(?:\.\d+)?", d)
    i = 0
    while i < len(tokens):
        cmd = tokens[i]
        n = {"M": 2, "L": 2, "Q": 4, "C": 6, "Z": 0}[cmd]
        args = [float(t) for t in tokens[i + 1 : i + 1 + n]]
        i += 1 + n
        match cmd:
            case "M":
                path.moveTo(*args)
            case "L":
                path.lineTo(*args)
            case "Q":
                path.quadTo(*args)
            case "C":
                path.cubicTo(*args)
            case "Z":
                path.close()
    return path


def conic_weight(pts: list[skia.Point]) -> float:
    """Poids d'un arc de cercle (bout ou angle rond) : le cosinus du demi-angle parcouru."""
    a, b = pts[1] - pts[0], pts[2] - pts[1]
    return math.cos(
        math.atan2(a.x() * b.y() - a.y() * b.x(), a.x() * b.x() + a.y() * b.y()) / 2
    )


def serialize(path: skia.Path) -> str:
    """Tracé SVG d'un contour ; les coniques (bouts ronds) deviennent des quadratiques."""

    def xy(*points: skia.Point) -> str:
        return " ".join(f"{p.x():.3f} {p.y():.3f}" for p in points)

    out = []
    for verb, pts in skia.Path.Iter(path, False):
        if verb == skia.Path.kMove_Verb:
            out.append("M" + xy(pts[0]))
        elif verb == skia.Path.kLine_Verb:
            out.append("L" + xy(pts[1]))
        elif verb == skia.Path.kQuad_Verb:
            out.append("Q" + xy(pts[1], pts[2]))
        elif verb == skia.Path.kCubic_Verb:
            out.append("C" + xy(pts[1], pts[2], pts[3]))
        elif verb == skia.Path.kConic_Verb:
            quads = skia.Path.ConvertConicToQuads(
                pts[0], pts[1], pts[2], conic_weight(pts), 1
            )
            for k in range(1, len(quads), 2):
                out.append("Q" + xy(quads[k], quads[k + 1]))
        elif verb == skia.Path.kClose_Verb:
            out.append("Z")
    return " ".join(out)


def outline(parts: list[tuple[str, str]]) -> skia.Path:
    """Contour plein du glyphe : traits épaissis (bouts et angles ronds), le tout fusionné."""
    paint = skia.Paint(Style=skia.Paint.kStroke_Style, StrokeWidth=STROKE)
    paint.setStrokeCap(skia.Paint.kRound_Cap)
    paint.setStrokeJoin(skia.Paint.kRound_Join)
    merged = skia.Path()
    for d, mode in parts:
        path = parse(d)
        if mode == "s":
            filled = skia.Path()
            paint.getFillPath(path, filled)
            path = filled
        merged = skia.Op(merged, path, skia.PathOp.kUnion_PathOp)
    return oriented(merged)


def oriented(merged: skia.Path) -> skia.Path:
    """La fusion rend un tracé pair-impair ; le gabarit se lit en non nul. Chaque contour est donc
    tourné selon sa profondeur : un sens pour les pleins, l'autre pour les creux."""
    contours: list[tuple[skia.Path, list[skia.Point]]] = []
    for verb, pts in skia.Path.Iter(merged, False):
        if verb == skia.Path.kMove_Verb:
            contours.append((skia.Path(), [pts[0]]))
            contours[-1][0].moveTo(pts[0])
            continue
        path, points = contours[-1]
        if verb == skia.Path.kLine_Verb:
            path.lineTo(pts[1])
        elif verb == skia.Path.kQuad_Verb:
            path.quadTo(pts[1], pts[2])
        elif verb == skia.Path.kCubic_Verb:
            path.cubicTo(pts[1], pts[2], pts[3])
        elif verb == skia.Path.kConic_Verb:
            path.conicTo(pts[1], pts[2], conic_weight(pts))
        elif verb == skia.Path.kClose_Verb:
            path.close()
            continue
        points.append(pts[-1])
    out = skia.Path()
    for i, (path, points) in enumerate(contours):
        start = points[0]
        depth = sum(
            other.contains(start.x(), start.y())
            for j, (other, _) in enumerate(contours)
            if j != i
        )
        area = sum(
            a.x() * b.y() - b.x() * a.y()
            for a, b in zip(points, points[1:] + points[:1])
        )
        if (area > 0) == (depth % 2 == 0):
            out.addPath(path)
        else:
            out.reverseAddPath(path)
    return out


def template(group: str, parts: list[tuple[str, str]]) -> str:
    path = outline(parts)
    # boîte 100 -> gabarit : centre vertical à mi-hauteur de capitale, bord gauche sur la marge
    matrix = skia.Matrix.Scale(SCALE, SCALE)
    matrix.postTranslate(0, -CAP_HEIGHT / 2 - 50 * SCALE)
    path.transform(matrix)
    bounds = path.computeTightBounds()
    path.offset(MARGIN - bounds.left(), 0)
    width = bounds.width() + 2 * MARGIN
    d = serialize(path)
    x = 1391.3
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!-- Écrit par scripts/group-symbols.py : ne pas modifier à la main. -->
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" width="3300" height="2200">
 <g id="Notes">
  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
  <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.3.0</text>
  <text id="descriptive-name" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1969)">{PREFIX}{group}</text>
 </g>
 <g id="Guides">
  <line id="Baseline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="696" y2="696"/>
  <line id="Capline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="625.541" y2="625.541"/>
  <line id="Baseline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1126" y2="1126"/>
  <line id="Capline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1055.54" y2="1055.54"/>
  <line id="Baseline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1556" y2="1556"/>
  <line id="Capline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1485.54" y2="1485.54"/>
  <line id="left-margin-Regular-M" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="{x:.3f}" x2="{x:.3f}" y1="1030.79" y2="1150.12"/>
  <line id="right-margin-Regular-M" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="{x + width:.3f}" x2="{x + width:.3f}" y1="1030.79" y2="1150.12"/>
 </g>
 <g id="Symbols">
  <g id="Regular-M" transform="matrix(1 0 0 1 {x:.3f} 1126)">
   <path d="{d}"/>
  </g>
 </g>
</svg>
"""


def referential_groups(root: Path) -> set[str]:
    groups = set()
    for file in sorted((root / "species").glob("*.json")):
        group = json.loads(file.read_text()).get("group")
        if group:
            groups.add(group["id"])
    return groups


def main() -> None:
    for old in ASSETS.glob(f"{PREFIX}*.symbolset"):
        for file in old.iterdir():
            file.unlink()
        old.rmdir()
    for group, parts in sorted(GLYPHS.items()):
        folder = ASSETS / f"{PREFIX}{group}.symbolset"
        folder.mkdir()
        name = f"{PREFIX}{group}.svg"
        (folder / name).write_text(template(group, parts))
        contents = {
            "info": {"author": "xcode", "version": 1},
            "symbols": [{"filename": name, "idiom": "universal"}],
        }
        (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    print(f"{len(GLYPHS)} symboles écrits dans {ASSETS.relative_to(ROOT)}")
    if len(sys.argv) > 1:
        missing = referential_groups(Path(sys.argv[1])) - set(GLYPHS)
        extra = set(GLYPHS) - referential_groups(Path(sys.argv[1]))
        if missing or extra:
            raise SystemExit(
                f"groupes sans glyphe : {sorted(missing)} ; glyphes sans groupe : {sorted(extra)}"
            )


if __name__ == "__main__":
    main()
