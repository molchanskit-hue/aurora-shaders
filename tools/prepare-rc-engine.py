"""Prepare a fresh, pinned Horizon source tree for the Aurora release candidate."""
import argparse
from pathlib import Path
import subprocess
import tempfile

BASE = "1f3ccb0fc3e593a6fe3a3c7da76d8e3d620e5b6d"
TREE = "e1767ef330e926e7db08c5e618937e61038bcc97"
PATCHES = ("water-api", "water-depth-api", "underwater-api", "sun-shadow-api", "shadow-quality-api",
           "atmosphere-api", "temporal-clouds-api", "lighting-api", "entity-lighting-api",
           "forest-api", "hdr-api", "forest-bench-pose")

def prepare(destination, source):
    engine = Path(__file__).resolve().parents[1] / "engine"
    destination = destination.absolute()
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(f"Choose a new directory: {destination}")
    if Path(source).is_dir():
        source = str(Path(source).resolve())
    with tempfile.TemporaryDirectory(dir=destination.parent) as tmp:
        tree = Path(tmp) / "horizon"
        subprocess.run(["git", "init", "-q", tree], check=True)
        git = ["git", "-C", tree]
        subprocess.run([*git, "fetch", "--quiet", "--depth=1", "--", source, BASE], check=True)
        subprocess.run([*git, "checkout", "--quiet", "--detach", BASE], check=True)
        for patch in PATCHES:
            subprocess.run([*git, "apply", "--index", "--whitespace=nowarn", engine/f"aurora-{patch}.patch"], check=True)
        actual = subprocess.check_output([*git, "write-tree"], text=True).strip()
        if actual != TREE:
            raise RuntimeError(f"Patched source differs from the tested tree: {actual}")
        tree.rename(destination)
    print(f"Horizon HDR source ready: {destination} ({TREE})")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--source", default="https://github.com/horizon-rust/horizon")
    args = parser.parse_args()
    prepare(args.destination, args.source)
