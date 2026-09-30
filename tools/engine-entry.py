#!/usr/bin/env python3
"""Portable entry point for the embedded KataLog Python engine.

Only the two compiled application modules may be dispatched. A script path is
accepted for compatibility with the development launcher, never read/executed.
"""
from __future__ import annotations

import importlib
import importlib.metadata
import json
from pathlib import PurePath
import sys


MODULES = {
    "analyzer.py": "analyzer", "analyzer": "analyzer",
    "gcs_collect.py": "gcs_collect", "gcs_collect": "gcs_collect", "gcs": "gcs_collect",
}


def runtime_info():
    """Import actual bundled dependencies; a version string alone is no check."""
    import numpy
    import pyulog
    import sqlite3
    import ssl
    import http.client
    import analyzer
    return {
        "protocol": 1,
        "parserVersion": analyzer.PARSER_VERSION,
        "python": ".".join(str(part) for part in sys.version_info[:3]),
        "numpy": numpy.__version__,
        "pyulog": importlib.metadata.version("pyulog"),
        "frozen": bool(getattr(sys, "frozen", False)),
    }


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    if args == ["--katalog-runtime-info"]:
        try:
            print(json.dumps(runtime_info(), ensure_ascii=False, allow_nan=False), flush=True)
            return 0
        except Exception as error:
            print(f"Moteur embarqué indisponible ({type(error).__name__}).", file=sys.stderr)
            return 1
    while args and args[0] in ("-u", "-B"):
        option = args.pop(0)
        if option == "-u":
            for stream in (sys.stdout, sys.stderr):
                if hasattr(stream, "reconfigure"):
                    stream.reconfigure(line_buffering=True, write_through=True)
    if not args:
        print("Usage: KataLogEngine [ -u ] [ -B ] analyzer|gcs_collect <arguments>", file=sys.stderr)
        return 2
    selector = args.pop(0)
    module_name = MODULES.get(PurePath(selector).name)
    if module_name is None:
        print("Commande moteur inconnue : choisir analyzer ou gcs_collect.", file=sys.stderr)
        return 2
    module = importlib.import_module(module_name)
    return module.main(args)


if __name__ == "__main__":
    raise SystemExit(main())
