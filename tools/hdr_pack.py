#!/usr/bin/env python3
"""Package four HDR quality levels from one validated set of WGSL files."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import tomllib
from zipfile import ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parent.parent
LEVELS = ("low", "medium", "high", "ultra")
# Only deviations from the authored High manifest. Low retains refraction and
# sky reflections; setting SSR to zero skips the march, not the scene snapshot.
OPTIONS = {
    "low": {"ssr_strength": 0.0, "contact_strength": 0.0, "ray_strength": 0.0,
            "glow_filter_radius": 1, "cloud_steps": 8, "aurora_steps": 4},
    "medium": {"ssr_steps": 32, "shadow_tent_radius": 4, "ray_steps": 8, "glow_filter_radius": 1},
    "high": {},
    "ultra": {"cloud_steps": 32, "ray_steps": 32, "aurora_steps": 16},
}

def one(text, pattern, substitute):
    out, count = re.subn(pattern, substitute, text, flags=re.MULTILINE)
    if count != 1:
        raise ValueError(f"Expected one match, found {count}: {pattern}")
    return out

def preset_manifest(text, level):
    if level == "high":
        return text
    src = tomllib.loads(text)
    for key, value in (("name", f"Aurora Shaders — {level.title()} (HDR)"), ("id", f"aurora_hdr_{level}")):
        text = one(text, rf'^{key} = "{re.escape(src[key])}"$', f'{key} = "{value}"')
    text = one(text, '^quality = "high"$', f'quality = "{level}"')
    for key, value in OPTIONS[level].items():
        pat = r'(\[\[options\]\]\nid = "'+key+r'"(?:(?!\[\[)[\s\S])*?\ndefault = )[^\n]+'
        text = one(text, pat, lambda m: m[1]+str(value))
    if level == "low":
        for stage in ("cloud-volume", "cloud-temporal"):
            pat = r'(\[\[post\]\]\nfile = "post/'+stage+r'\.wgsl"\nname = "[^"]+"\nresolution_divisor = )2$'
            text = one(text, pat, lambda m: m[1]+"4")
    cfg = tomllib.loads(text)
    actual = {opt["id"]:opt["default"] for opt in cfg["options"]}
    if cfg["sun_shadows"]["quality"] != level or any(actual[k]!=v for k,v in OPTIONS[level].items()):
        raise ValueError(f"Incorrect {level} recipe")
    return text

def medium_rain_material(text):
    # Keep the 64-block reach and the six refinement steps at a hit.
    text = one(text, r'^    for \(var step = 1; step <= ssr_steps; step \+= 1\) \{$',
               '    let steps = i32(round(mix(f32(ssr_steps), f32(min(ssr_steps, 24)), clamp(frame.rain, 0.0, 1.0))));\n'
               '    for (var step = 1; step <= steps; step += 1) {')
    return one(text, r'^        let fraction = f32\(step\) / f32\(ssr_steps\);$',
               '        let fraction = f32(step) / f32(steps);')


def build(sdk):
    src = ROOT/"packs/aurora_reflections"
    manifest = (src/"horizon-shaders.toml").read_text()
    version = tomllib.loads(manifest)["version"]
    dist = ROOT/"dist"
    dist.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".hdr-build-", dir=dist) as temp:
        tmp = Path(temp)
        archives = []
        for level in LEVELS:
            source = src
            if level != "high":
                source = tmp/level
                shutil.copytree(src,source)
                (source/"horizon-shaders.toml").write_text(preset_manifest(manifest,level))
                if level == "medium":
                    material = source/"material.wgsl"
                    material.write_text(medium_rain_material(material.read_text()))
            prefix = "aurora-reflections" if level == "high" else f"aurora-{level}"
            target = tmp/(prefix+"-"+version+".hshader")
            for cmd in (["check",source],["pack",source,"--out",target],["check",target]):
                subprocess.run([sdk,*cmd],check=True)
            archives.append(target)
        # A distribution envelope only; Horizon loads the four inner .hshader files.
        bundle = tmp/f"Aurora-HDR-presets-{version}.zip"
        with ZipFile(bundle, "w") as z:
            for target in archives:
                z.writestr(ZipInfo(target.name),target.read_bytes())
        for target in [*archives,bundle]:
            os.replace(target,dist/target.name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True, help="Path to the compatible horizon-shader binary.")
    build(parser.parse_args().sdk.resolve())
