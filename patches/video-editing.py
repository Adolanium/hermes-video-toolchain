#!/usr/bin/env python3
"""Idempotent patches for the hermes-video-editing skill.

Two fixes the upstream skill needs on a current machine:

1. Interpreter isolation. The skill's commands say `python scripts/...`, but in a
   Hermes session `python` resolves to the Hermes environment. Installing
   moviepy/OpenCV/torch into that environment pollutes it, so the skill is
   repointed at a dedicated venv via a `$PY` variable.

2. scenedetect 0.7 compatibility. 0.7 renamed AdaptiveDetector's `threshold`
   argument to `adaptive_threshold`, so `scenes detect` crashed with a TypeError
   on every call. Tracked upstream as PR #2 in argus-metis/hermes-video-editing.

Safe to run repeatedly: each patch checks for its own marker first.
"""
import sys
from pathlib import Path

INTERPRETER_SECTION = """## Interpreter (required)

All commands below are written as `$PY scripts/…`. This skill's dependencies are
isolated in a dedicated venv — deliberately NOT the Hermes environment, which
must not be polluted by moviepy / OpenCV / torch. Set the interpreter once per
session, then run every command exactly as written:

```bash
PY="$HOME/.hermes/video-editing/.venv/bin/python"
"$PY" -c "import moviepy, cv2, whisper, scenedetect; print('video-editing deps OK')"
```

If the verify line fails, create the venv and install deps (see **Install** below).
"""

OLD_SCENEDETECT = "    scene_list = detect(str(inp), AdaptiveDetector(threshold=threshold))"
NEW_SCENEDETECT = """    # scenedetect 0.7 renamed AdaptiveDetector's `threshold` to `adaptive_threshold`.
    # Accept both so this works across versions (0.6 and earlier vs 0.7+).
    try:
        detector = AdaptiveDetector(adaptive_threshold=threshold)
    except TypeError:
        detector = AdaptiveDetector(threshold=threshold)
    scene_list = detect(str(inp), detector)"""


def patch_skill_md(path: Path) -> None:
    text = path.read_text()
    original = text

    if "$PY scripts/" not in text:
        text = text.replace("python scripts/", "$PY scripts/")

    if "## Interpreter (required)" not in text:
        marker = "# Video & Audio Editing Skill\n"
        if marker in text:
            text = text.replace(
                marker, marker + "\n" + INTERPRETER_SECTION, 1
            )
        else:
            # Fall back to inserting after the frontmatter.
            parts = text.split("---", 2)
            if len(parts) == 3:
                text = parts[0] + "---" + parts[1] + "---\n\n" + INTERPRETER_SECTION + parts[2].lstrip("\n")

    if text != original:
        path.write_text(text)
        print(f"  patched {path}")
    else:
        print(f"  already patched: {path}")


def patch_video_toolkit(path: Path) -> None:
    text = path.read_text()
    if "adaptive_threshold" in text:
        print(f"  already patched: {path}")
        return
    if OLD_SCENEDETECT not in text:
        print(f"  WARNING: scenedetect call site not found in {path} — upstream may have changed")
        return
    path.write_text(text.replace(OLD_SCENEDETECT, NEW_SCENEDETECT, 1))
    print(f"  patched {path}")


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    skill_md = root / "SKILL.md"
    toolkit = root / "scripts" / "video_toolkit.py"

    if skill_md.exists():
        patch_skill_md(skill_md)
    else:
        print(f"  WARNING: {skill_md} not found")

    if toolkit.exists():
        patch_video_toolkit(toolkit)
    else:
        print(f"  WARNING: {toolkit} not found")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
