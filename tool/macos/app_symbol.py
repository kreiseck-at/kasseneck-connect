#!/usr/bin/env python3
"""Zeichnet das Programmsymbol von Kasseneck Connect.app.

    python3 tool/macos/app_symbol.py              -> tool/macos/AppIcon.icns
    python3 tool/macos/app_symbol.py --png x.png  -> zusätzlich die 1024er Vorlage

Das Ergebnis ist eingecheckt: Bau und CI nehmen die fertige AppIcon.icns und
brauchen dieses Skript nicht. Nur wer das Symbol ändert, braucht Pillow und
iconutil (macOS).

Geometrie aus der Marke, Variante Kasse: auf einer 1024er Fläche ein
abgerundetes Quadrat mit 100 px Rand und 185 px Eckradius in #E7F0EF (der
macOS-Rahmen), mittig darauf das Signet mit 400 px Kantenlänge. Das Signet
steht im 48er-Raster: der Rahmen in #0F2B33, das Eckquadrat in #116B6B, ohne
Rundungen.
"""

import argparse
import math
import pathlib
import re
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

FLAECHE = "#E7F0EF"
ZEICHEN = "#0F2B33"
ECKE = "#116B6B"

LEINWAND = 1024
RAND = 100
RADIUS = 185
SIGNET = 400
RASTER = 48

# Pfade des Signets, wörtlich aus der Marke (nur M, H, V und Z).
RAHMEN = ("M0 0H48V30H42V6H0Z", "M0 6V48H30V42H6V6Z")
ECKFELD = "M30 30H48V48H30Z"

# Gezeichnet wird vierfach und dann verkleinert: so werden die Kanten des
# abgerundeten Quadrats glatt, ImageDraw selbst glättet nicht. Die Kanten des
# Signets fallen dabei auf ganze Pixel (400 / 48 * 6 = 50).
FAKTOR = 4

# Name im .iconset -> Kantenlänge in Pixeln (die Namen verlangt iconutil).
GROESSEN = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}


def eckpunkte(pfad):
    """Eckpunkte eines Pfads aus absoluten M/H/V-Befehlen im Raster."""
    punkte = []
    x = y = 0.0
    for befehl, zahlen in re.findall(r"([MHVZ])([^MHVZ]*)", pfad):
        werte = [float(z) for z in zahlen.replace(",", " ").split()]
        if befehl == "M":
            x, y = werte
        elif befehl == "H":
            (x,) = werte
        elif befehl == "V":
            (y,) = werte
        else:
            continue
        punkte.append((x, y))
    return punkte


def vorlage():
    """Das Symbol in vierfacher Größe, transparent außerhalb des Rahmens."""
    seite = LEINWAND * FAKTOR
    bild = Image.new("RGBA", (seite, seite), (0, 0, 0, 0))
    stift = ImageDraw.Draw(bild)

    # Rechteckkoordinaten zählen bei ImageDraw einschließlich des letzten
    # Pixels, deshalb rechts und unten eins weniger.
    innen = (LEINWAND - RAND) * FAKTOR - 1
    stift.rounded_rectangle(
        (RAND * FAKTOR, RAND * FAKTOR, innen, innen),
        radius=RADIUS * FAKTOR,
        fill=FLAECHE,
    )

    links = (LEINWAND - SIGNET) / 2 * FAKTOR
    einheit = SIGNET / RASTER * FAKTOR

    def flaeche(pfad, farbe):
        punkte = [(links + x * einheit, links + y * einheit) for x, y in eckpunkte(pfad)]
        fuelle(stift, punkte, farbe)

    for pfad in RAHMEN:
        flaeche(pfad, ZEICHEN)
    flaeche(ECKFELD, ECKE)
    return bild


def fuelle(stift, punkte, farbe):
    """Füllt ein Vieleck mit waagrechten und senkrechten Kanten.

    Ein Pixel gehört dazu, wenn seine Mitte innen liegt. ImageDraw.polygon
    nimmt die Pixel auf der rechten und unteren Kante mit; das Signet würde
    dadurch einen Viertelpixel breiter und an den Innenkanten grau.
    """
    senkrecht = [
        (a[0], min(a[1], b[1]), max(a[1], b[1]))
        for a, b in zip(punkte, punkte[1:] + punkte[:1])
        if a[0] == b[0]
    ]
    oben = math.floor(min(y for _, y in punkte))
    unten = math.ceil(max(y for _, y in punkte))
    for zeile in range(oben, unten):
        mitte = zeile + 0.5
        xs = sorted(x for x, y0, y1 in senkrecht if y0 <= mitte < y1)
        for von, bis in zip(xs[::2], xs[1::2]):
            erstes = math.ceil(von - 0.5)
            letztes = math.ceil(bis - 0.5) - 1
            if letztes >= erstes:
                stift.rectangle((erstes, zeile, letztes, zeile), fill=farbe)


def verkleinert(bild, kante):
    # Flächenmittel (BOX) statt Lanczos: keine Säume an den harten Kanten des
    # Signets. Vormultipliziert, sonst färbt das transparente Schwarz
    # außerhalb den Rand des Rahmens dunkel.
    return bild.convert("RGBa").resize((kante, kante), Image.BOX).convert("RGBA")


def main():
    hier = pathlib.Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=pathlib.Path, default=hier / "AppIcon.icns")
    parser.add_argument("--png", type=pathlib.Path, help="1024er Vorlage zusätzlich ablegen")
    args = parser.parse_args()

    gross = vorlage()
    if args.png:
        verkleinert(gross, LEINWAND).save(args.png)

    with tempfile.TemporaryDirectory() as temp:
        iconset = pathlib.Path(temp) / "AppIcon.iconset"
        iconset.mkdir()
        for name, kante in GROESSEN.items():
            verkleinert(gross, kante).save(iconset / name)
        subprocess.run(
            ["iconutil", "-c", "icns", "-o", str(args.out), str(iconset)],
            check=True,
        )
    print(f"Fertig: {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
