import json
import os
import re
import sys

path = sys.argv[1]
profiles = json.loads(os.environ["IOS_PROFILE_MAP"])
team = os.environ["APPLE_TEAM_ID"]
text = open(path).read()
patched = set()


def patch(match):
    block = match.group(0)
    bundle = re.search(r"PRODUCT_BUNDLE_IDENTIFIER = \"?([^;\"]+)\"?;", block)
    if "name = Release;" not in block or not bundle or bundle.group(1) not in profiles:
        return block
    identifier = bundle.group(1)
    for key in ("CODE_SIGN_STYLE", "CODE_SIGN_IDENTITY", "DEVELOPMENT_TEAM", "PROVISIONING_PROFILE_SPECIFIER"):
        block = re.sub(rf"\n\s*\"?{key}(\[[^\]]*\])?\"? = [^;]*;", "", block)
    settings = (
        f'\n\t\t\t\tCODE_SIGN_STYLE = Manual;'
        f'\n\t\t\t\tCODE_SIGN_IDENTITY = "Apple Distribution";'
        f'\n\t\t\t\tDEVELOPMENT_TEAM = {team};'
        f'\n\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = "{profiles[identifier]}";'
    )
    patched.add(identifier)
    return block.replace("buildSettings = {", "buildSettings = {" + settings, 1)


text = re.sub(r"isa = XCBuildConfiguration;.*?name = [A-Za-z]+;", patch, text, flags=re.S)
missing = set(profiles) - patched
if missing:
    sys.exit(f"Could not apply signing to: {', '.join(sorted(missing))}")
open(path, "w").write(text)
