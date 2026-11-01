#!/usr/bin/env python3
"""Dependency-free OpenStep project validator. Does not compile Swift."""
from pathlib import Path
from collections import Counter
import json
import plistlib
import re
import struct
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]

class OpenStep:
    def __init__(self, source):
        pattern = r'\s+|/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,"/]+|/'
        self.tokens = []
        end = 0
        for m in re.finditer(pattern, source, re.S):
            if m.start() != end:
                raise ValueError("Invalid OpenStep token")
            end = m.end()
            t = m.group()
            if not t.isspace() and not t.startswith(("//", "/*")):
                self.tokens.append(t)
        assert end == len(source), "Unparsed OpenStep text"
        self.i = 0
    def take(self, expected=None):
        assert self.i < len(self.tokens), "Unexpected end of OpenStep"
        t = self.tokens[self.i]
        self.i += 1
        assert expected is None or t == expected, f"Expected {expected}, got {t}"
        return t
    def value(self):
        t = self.take()
        if t == "{":
            result = {}
            while self.tokens[self.i] != "}":
                key = self.value()
                assert isinstance(key, str) and key not in result, "Duplicate dictionary key"
                self.take("=")
                result[key] = self.value()
                self.take(";")
            self.take("}")
            return result
        if t == "(":
            result = []
            while self.tokens[self.i] != ")":
                result.append(self.value())
                if self.tokens[self.i] != ")":
                    self.take(",")
            self.take(")")
            return result
        assert t not in ("}", ")", ";", "=", ","), "Unexpected delimiter"
        return json.loads(t) if t.startswith('"') else t
    def parse(self):
        result = self.value()
        assert self.i == len(self.tokens), "Trailing OpenStep tokens"
        return result

def validate():
    project = OpenStep((ROOT / "MikaWeb.xcodeproj/project.pbxproj").read_text()).parse()
    objects = project["objects"]
    def obj(key, isa=None):
        assert key in objects, f"Dangling reference: {key}"
        result = objects[key]
        assert not isa or result["isa"] == isa, f"Wrong object type: {key}"
        return result
    # Validate every standard object-reference field, including arrays.
    single = {"rootObject", "mainGroup", "productRefGroup", "productReference", "buildConfigurationList", "fileRef", "target", "targetProxy", "containerPortal"}
    multiple = {"children", "targets", "buildPhases", "buildRules", "dependencies", "files", "buildConfigurations"}
    for value in [project] + list(objects.values()):
        for key, v in value.items():
            if key in single:
                obj(v)
            elif key in multiple:
                for ref in v:
                    obj(ref)
    p = obj(project["rootObject"], "PBXProject")
    assert len(p["targets"]) == 1, "Expected one target"
    tid = p["targets"][0]
    target = obj(tid, "PBXNativeTarget")
    assert target["name"] == "MikaWeb" and target["productType"] == "com.apple.product-type.application"
    assert obj(target["productReference"])["path"] == "MikaWeb.app"
    required = {
        "PRODUCT_BUNDLE_IDENTIFIER": "com.jigaoyi.mikaweb", "INFOPLIST_FILE": "MikaWeb/Info.plist",
        "GENERATE_INFOPLIST_FILE": "NO", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SWIFT_VERSION": "5.0",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "TARGETED_DEVICE_FAMILY": "1,2",
        "DEVELOPMENT_TEAM": "6566672L5G", "MARKETING_VERSION": "0.1.0",
    }
    for owner in [p, target]:
        configs = [obj(c, "XCBuildConfiguration") for c in obj(owner["buildConfigurationList"], "XCConfigurationList")["buildConfigurations"]]
        assert {c["name"] for c in configs} == {"Debug", "Release"}
        if owner is target:
            for c in configs:
                for key, value in required.items():
                    assert c["buildSettings"].get(key) == value, f"{c['name']}: {key}"
    print("PASS: OpenStep syntax, object references, single app target, Debug/Release settings")

    paths = {}
    visited = set()
    def walk(key, parent):
        assert key not in visited, f"Duplicate group/file membership: {key}"
        visited.add(key)
        item = obj(key)
        if item["isa"] == "PBXGroup":
            base = parent / item.get("path", "")
            for child in item.get("children", []):
                walk(child, base)
        elif item["isa"] == "PBXFileReference" and item.get("sourceTree") != "BUILT_PRODUCTS_DIR":
            path = parent / item["path"]
            assert path.exists(), f"Missing file: {path}"
            paths[key] = path
    walk(p["mainGroup"], ROOT)
    file_ids = {k for k,v in objects.items() if v["isa"] == "PBXFileReference"}
    assert file_ids <= visited, "Orphan file reference"
    phases = [obj(x) for x in target["buildPhases"]]
    source_phases = [x for x in phases if x["isa"] == "PBXSourcesBuildPhase"]
    resource_phases = [x for x in phases if x["isa"] == "PBXResourcesBuildPhase"]
    assert len(source_phases) == len(resource_phases) == 1
    def phase_paths(phase):
        return [paths[obj(x, "PBXBuildFile")["fileRef"]] for x in phase["files"]]
    sources = phase_paths(source_phases[0])
    actual = set((ROOT / "MikaWeb").rglob("*.swift"))
    assert set(sources) == actual and all(n == 1 for n in Counter(sources).values()), "Swift sources missing or duplicated"
    refs = [path for path in paths.values() if path.suffix == ".swift"]
    assert Counter(refs) == Counter(sources), "Swift file references must occur exactly once"
    builds = [x for phase in phases for x in phase.get("files", [])]
    assert set(builds) == {k for k,v in objects.items() if v["isa"] == "PBXBuildFile"} and len(builds) == len(set(builds)), "Orphan or duplicated build file"
    resources = phase_paths(resource_phases[0])
    assert set(resources) == {ROOT / "MikaWeb/Assets.xcassets", ROOT / "MikaWeb/Resources/test-news.html", ROOT / "MikaWeb/Resources/test-form.html"} and len(resources) == 3
    asset_id = next(k for k,v in paths.items() if v.name == "Assets.xcassets")
    assert obj(asset_id)["lastKnownFileType"] == "folder.assetcatalog"
    print(f"PASS: {len(sources)} Swift sources referenced and compiled exactly once; asset catalog and 2 HTML resources")

    scheme = ET.parse(ROOT / "MikaWeb.xcodeproj/xcshareddata/xcschemes/MikaWeb.xcscheme").getroot()
    for ref in scheme.iter("BuildableReference"):
        assert ref.attrib["BlueprintIdentifier"] == tid
        assert ref.attrib["ReferencedContainer"] == "container:MikaWeb.xcodeproj"
        assert ref.attrib["BuildableName"] == "MikaWeb.app"
    for tag, config in [("LaunchAction","Debug"),("TestAction","Debug"),("ProfileAction","Release"),("AnalyzeAction","Debug"),("ArchiveAction","Release")]:
        assert scheme.find(tag).attrib["buildConfiguration"] == config
    assert scheme.find("BuildAction/BuildActionEntries/BuildActionEntry").attrib["buildForArchiving"] == "YES"
    info = plistlib.loads((ROOT / "MikaWeb/Info.plist").read_bytes())
    assert info["CFBundleDisplayName"] == "Mika Web"
    assert info["CFBundleIdentifier"] == "$(PRODUCT_BUNDLE_IDENTIFIER)"
    assert info["NSAppTransportSecurity"] == {"NSAllowsArbitraryLoadsInWebContent": True}
    assert info["UILaunchScreen"] == {}
    assert info["UIApplicationSceneManifest"] == {"UIApplicationSupportsMultipleScenes": False}
    assert set(info["UISupportedInterfaceOrientations"]) == {"UIInterfaceOrientationPortrait","UIInterfaceOrientationLandscapeLeft","UIInterfaceOrientationLandscapeRight"}
    assert "UIInterfaceOrientationPortraitUpsideDown" in info["UISupportedInterfaceOrientations~ipad"]
    print("PASS: shared scheme, Info.plist, web-content-only ATS, single scene and orientations")

    for name in ["LICENSE", "NOTICE"]:
        assert (ROOT/name).stat().st_size > 0
    assert "Apache License" in (ROOT/"LICENSE").read_text()
    assert "非官方" in (ROOT/"NOTICE").read_text()
    assets = ROOT/"MikaWeb/Assets.xcassets"
    assert json.loads((assets/"Contents.json").read_text())["info"]["version"] == 1
    icons = assets/"AppIcon.appiconset"
    entries = json.loads((icons/"Contents.json").read_text())["images"]
    expected = {("iphone",s,c) for s in ["20x20","29x29","40x40","60x60"] for c in ["2x","3x"]}
    expected |= {("ipad",s,c) for s in ["20x20","29x29","40x40","76x76"] for c in ["1x","2x"]}
    expected |= {("ipad","83.5x83.5","2x"),("ios-marketing","1024x1024","1x")}
    assert {(e["idiom"],e["size"],e["scale"]) for e in entries} >= expected, "Incomplete icon slots"
    for e in entries:
        data = (icons/e["filename"]).read_bytes()
        assert data[:8] == b'\x89PNG\r\n\x1a\n'
        width,height = struct.unpack(">II",data[16:24])
        size = [float(x) for x in e["size"].split("x")]
        scale = float(e["scale"][:-1])
        assert (width,height) == tuple(int(x*scale) for x in size), f"Wrong PNG size: {e['filename']}"
    assert "scripts/validate_project.py" in (ROOT/"codemagic.yaml").read_text()
    print(f"PASS: LICENSE, NOTICE, {len(entries)} icon PNGs and Codemagic validator path")
    print("PASS: static project validation complete (no Swift compilation performed)")

if __name__ == "__main__":
    try:
        validate()
    except (AssertionError, ValueError, KeyError, IndexError, OSError, ET.ParseError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
