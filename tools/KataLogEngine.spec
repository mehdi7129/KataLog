# PyInstaller 6.22.3 helper bundle, copied to Contents/Helpers/KataLogEngine.app.
# Its pinned archive writers anonymize co_filename recursively for PYZ, scripts,
# and base_library.zip. build-engine.sh independently checks those archives.
import ast
from pathlib import Path
from PyInstaller.utils.hooks import copy_metadata

source = Path(SPECPATH)
parser_tree = ast.parse((source / "modules" / "analyzer.py").read_text())
parser_version = next(
    ast.literal_eval(node.value) for node in parser_tree.body
    if isinstance(node, ast.Assign)
    and any(isinstance(target, ast.Name) and target.id == "PARSER_VERSION" for target in node.targets)
)
a = Analysis(
    [str(source / "engine-entry.py")],
    pathex=[str(source / "modules")],
    binaries=[],
    datas=copy_metadata("pyulog"),
    hiddenimports=[path.stem for path in (source / "modules").glob("*.py")] + ["sqlite3", "ssl", "http.client", "lzma", "pyulog.libevents_parse.parser"],
    excludes=["pytest", "numpy.testing", "tkinter", "matplotlib", "pandas", "IPython", "setuptools"],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz, a.scripts, [], exclude_binaries=True,
    name="KataLogEngine", console=True, debug=False, strip=False, upx=False,
    target_arch="arm64", codesign_identity=None, entitlements_file=None,
    contents_directory="_internal",
)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name="KataLogEngine")
app = BUNDLE(
    coll, name="KataLogEngine.app", icon=str(source / "KataLog.icns"),
    version=parser_version, bundle_identifier="com.mehdiguiard.katalog.engine",
    info_plist={
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "15.0",
        "LSBackgroundOnly": True,
    },
)
