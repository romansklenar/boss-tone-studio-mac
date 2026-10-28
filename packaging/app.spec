# PyInstaller build of the app bundle; run through `make app`. Roland's web app and the recoloured icon come from
# build/ (`make roland-assets`, packaging/make_icon.py) and are never committed.
from pathlib import Path

ROOT = Path(SPECPATH).parent
APP_NAME = "BOSS TONE STUDIO for KATANA MkII (Apple Silicon)"

analysis = Analysis(
    [str(ROOT / "packaging/launcher.py")],
    pathex=[str(ROOT)],
    datas=[(str(ROOT / "build/roland/html"), "roland-html")],
)
executable = EXE(
    PYZ(analysis.pure),
    analysis.scripts,
    exclude_binaries=True,
    name=APP_NAME,
    console=False,
    target_arch="arm64",
)
collected = COLLECT(executable, analysis.binaries, analysis.datas, name=APP_NAME)
app = BUNDLE(
    collected,
    name=f"{APP_NAME}.app",
    icon=str(ROOT / "build/AppIcon.icns"),
    bundle_identifier="local.boss-tone-studio-mac.katana-mk2",
    version="0.1.0",
    info_plist={
        "CFBundleDisplayName": APP_NAME,
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
    },
)
