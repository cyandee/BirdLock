"""Read-only sound library shared by both platforms; persist asset IDs, never bundle paths."""
import json
from pathlib import Path

from .paths import resource_dir


def directory():
    for root in (resource_dir() / "audio", Path(__file__).resolve().parents[3] / "SharedResources" / "Audio"):
        if (root / "library.json").is_file():
            return root
    return None


def assets():
    root = directory()
    if root is None:
        return []
    try:
        entries = json.loads((root / "library.json").read_text(encoding="utf-8"))
        return [e for e in entries if Path(e["file"]).name == e["file"] and ".." not in e["file"] and (root / e["file"]).is_file()]
    except (OSError, ValueError, KeyError, TypeError):
        return []


def asset_path(asset_id):
    root = directory()
    return next((str(root / e["file"]) for e in assets() if e["id"] == canonical_id(asset_id)), "")


def canonical_id(asset_id):
    return {"sony-10":"sony-a1m2-10", "sony-20":"sony-a1m2-30"}.get(asset_id, asset_id)


def burst_assets():
    return [e for e in assets() if e.get("kind") == "burst"]


def cameras():
    return list(dict.fromkeys((e["cameraID"],e["camera"]) for e in burst_assets()))
