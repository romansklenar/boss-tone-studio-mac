# PyInstaller build of the app bundle; run through `make app`. Roland's web app and the recoloured icon come from
# build/ (`make roland-assets`, packaging/make_icon.py) and are never committed.
import sys
import tomllib
from pathlib import Path

ROOT = Path(SPECPATH).parent
sys.path.insert(0, str(ROOT))
from bts.__main__ import APP_NAME  # noqa: E402

VERSION = tomllib.loads((ROOT / "pyproject.toml").read_text())["project"]["version"]

analysis = Analysis(
    [str(ROOT / "bts/__main__.py")],
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
    version=VERSION,
    info_plist={
        "CFBundleDisplayName": APP_NAME,
        "CFBundleVersion": VERSION,
        "LSMinimumSystemVersion": "14.0",  # = MACOSX_DEPLOYMENT_TARGET in mise.toml
        "NSHighResolutionCapable": True,
    },
)
