#!/usr/bin/env bash
# =============================================================================
# Hermes Video Production Toolchain — installer
#
# Installs three OSS engines and wires them into Hermes Agent:
#   1. OpenScreen        — screen/window capture, on-device captions, GPU export
#   2. HyperFrames       — HTML/CSS/GSAP -> deterministic MP4, motion graphics
#   3. hermes-video-editing — headless post-processing + platform export
#
# Idempotent: safe to re-run. Re-running skips what is already installed.
#
# Usage:
#   bash install.sh              # full install
#   bash install.sh --core       # skip the heavy AI deps (whisper/torch)
#   bash install.sh --verify     # just verify what is present
#
# Env overrides:
#   HERMES_HOME=...             (default ~/.hermes)
#   OPENSCREEN_VERSION=2.1.2    (default: latest release)
#   NPM_GLOBAL=...              (default ~/.npm-global)
# =============================================================================
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
TOOLS_DIR="$HERMES_HOME/tools"
OPENSCREEN_DIR="$TOOLS_DIR/openscreen"
VIDEO_EDITING_DIR="$HERMES_HOME/video-editing"
NPM_GLOBAL="${NPM_GLOBAL:-$HOME/.npm-global}"

MODE="full"
case "${1:-}" in
  --core)  MODE="core" ;;
  --verify) MODE="verify" ;;
  "")      ;;
  -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

OS="$(uname -s)"
ARCH="$(uname -m)"

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
preflight() {
  log "Preflight"
  command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg not found — install it first (pacman -S ffmpeg / brew install ffmpeg)"
  command -v curl   >/dev/null 2>&1 || die "curl not found"
  command -v python3 >/dev/null 2>&1 || die "python3 not found"

  if [ "$OS" = "Linux" ]; then
    command -v node >/dev/null 2>&1 || die "node not found (HyperFrames needs Node 22+)"
    command -v npm  >/dev/null 2>&1 || die "npm not found"
  fi

  # Python for the video-editing venv: prefer 3.11–3.13 (best wheel support for
  # torch/opencv); 3.14 works for core but may lack wheels for some AI deps.
  PY=""
  for c in python3.13 python3.12 python3.11 python3; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
  [ -n "$PY" ] || die "no usable python3 found"
  ok "ffmpeg $(ffmpeg -version 2>/dev/null | head -1 | cut -d' ' -f3)"
  ok "python $($PY --version 2>&1 | awk '{print $2}')"
  [ "$OS" = "Linux" ] && ok "node $(node --version)"
}

# -----------------------------------------------------------------------------
# 1. OpenScreen
# -----------------------------------------------------------------------------
install_openscreen() {
  log "OpenScreen"
  # Source: https://github.com/getopenscreen/openscreen  (MIT)
  mkdir -p "$OPENSCREEN_DIR"

  if [ "$OS" = "Linux" ]; then
    if command -v openscreen >/dev/null 2>&1 && openscreen --help >/dev/null 2>&1; then
      ok "already installed: $(command -v openscreen)"; return 0
    fi

    local api url ver
    api="https://api.github.com/repos/getopenscreen/openscreen/releases/latest"
    if [ -n "${OPENSCREEN_VERSION:-}" ]; then
      api="https://api.github.com/repos/getopenscreen/openscreen/releases/tags/v$OPENSCREEN_VERSION"
    fi

    url="$(curl -sL "$api" | python3 -c "
import sys, json
d = json.load(sys.stdin)
want = '${OPENSCREEN_VERSION:-}'
for a in d.get('assets', []):
    n = a.get('name', '')
    if n.endswith('.AppImage') and (not want or want in n):
        print(a['browser_download_url']); break
")"
    [ -n "$url" ] || die "could not resolve an OpenScreen .AppImage URL"
    ver="$(curl -sL "$api" | python3 -c "import sys,json;print(json.load(sys.stdin).get('tag_name','?'))")"

    log "downloading OpenScreen $ver"
    curl -sL --progress-bar -o "$OPENSCREEN_DIR/openscreen.AppImage" "$url"
    chmod +x "$OPENSCREEN_DIR/openscreen.AppImage"

    mkdir -p "$HOME/.local/bin"
    printf '#!/usr/bin/env bash\nexec "%s/openscreen.AppImage" "$@"\n' "$OPENSCREEN_DIR" \
      > "$HOME/.local/bin/openscreen"
    chmod +x "$HOME/.local/bin/openscreen"
    export PATH="$HOME/.local/bin:$PATH"

    openscreen --help >/dev/null 2>&1 \
      && ok "OpenScreen $ver -> $OPENSCREEN_DIR/openscreen.AppImage" \
      || warn "OpenScreen installed but 'openscreen --help' did not respond"

    cat <<'NOTE'

  OpenScreen on Linux needs, for native capture:
    - xdg-desktop-portal (+ a backend: -gtk, -kde, or -wlr)
    - PipeWire (for system audio)
  Without them it falls back to browser capture with fewer features.
  Verify with:  openscreen sources --json
NOTE
    return 0
  fi

  # macOS
  if [ -d "/Applications/Openscreen.app" ]; then
    ok "already installed: /Applications/Openscreen.app"; return 0
  fi
  warn "macOS: download the .dmg from https://github.com/getopenscreen/openscreen/releases"
  warn "       drag OpenScreen into /Applications, then grant Screen Recording +"
  warn "       Accessibility in System Settings > Privacy & Security."
  warn "       The CLI is /Applications/Openscreen.app/Contents/MacOS/Openscreen"
}

# -----------------------------------------------------------------------------
# 2. HyperFrames
# -----------------------------------------------------------------------------
install_hyperframes() {
  log "HyperFrames"
  # Source: https://github.com/heygen-com/hyperframes  (Apache-2.0)
  export PATH="$NPM_GLOBAL/bin:$PATH"

  if command -v hyperframes >/dev/null 2>&1; then
    ok "already installed: $(hyperframes --version 2>&1 | head -1)"
  else
    npm install -g hyperframes || die "npm install -g hyperframes failed"
  fi

  grep -q 'npm-global/bin' "$HOME/.bashrc" 2>/dev/null \
    || echo "export PATH=\"$NPM_GLOBAL/bin:\$PATH\"" >> "$HOME/.bashrc"

  hyperframes browser ensure || warn "hyperframes browser ensure failed (needed for local rendering)"
  hyperframes skills update   || warn "hyperframes skills update failed"

  hyperframes doctor 2>&1 | grep -E '✗' \
    && warn "hyperframes doctor reports issues above" \
    || ok "hyperframes doctor clean"
}

# -----------------------------------------------------------------------------
# 3. hermes-video-editing
# -----------------------------------------------------------------------------
install_video_editing() {
  log "hermes-video-editing"
  # Source: https://github.com/argus-metis/hermes-video-editing  (MIT)

  if [ -d "$VIDEO_EDITING_DIR/.git" ]; then
    ok "repo present at $VIDEO_EDITING_DIR"
  else
    git clone --depth 1 https://github.com/argus-metis/hermes-video-editing.git "$VIDEO_EDITING_DIR" \
      || die "clone failed"
  fi

  local py=""
  for c in python3.13 python3.12 python3.11 python3; do
    if command -v "$c" >/dev/null 2>&1; then py="$c"; break; fi
  done

  [ -d "$VIDEO_EDITING_DIR/.venv" ] || "$py" -m venv "$VIDEO_EDITING_DIR/.venv"
  local PIP="$VIDEO_EDITING_DIR/.venv/bin/pip"

  "$PIP" install --quiet --upgrade pip

  local core="moviepy ffmpeg-python opencv-python-headless Pillow numpy"
  local ai="openai-whisper scenedetect[opencv] torch torchaudio"

  log "installing core deps"
  "$PIP" install --quiet $core || die "core deps failed"

  if [ "$MODE" != "core" ]; then
    log "installing AI deps (whisper, scenedetect, torch) — this is the large one"
    "$PIP" install --quiet $ai || warn "AI deps failed (core still works; captions/silence removal need these)"
  else
    warn "skipping AI deps (--core)"
  fi

  ln -sfn "$VIDEO_EDITING_DIR" "$HERMES_HOME/skills/video-editing"

  # Apply the interpreter + scenedetect patches (idempotent).
  if [ -f "$(dirname "$0")/patches/video-editing.py" ]; then
    python3 "$(dirname "$0")/patches/video-editing.py" "$VIDEO_EDITING_DIR" \
      || warn "patch step failed"
  fi

  "$VIDEO_EDITING_DIR/.venv/bin/python" -c "import moviepy, cv2" \
    && ok "video-editing venv ready" \
    || warn "venv import check failed"
}

# -----------------------------------------------------------------------------
# 4. Router skill
# -----------------------------------------------------------------------------
install_skill() {
  log "Router skill"
  local src; src="$(dirname "$0")/skills/video-toolchain"
  [ -d "$src" ] || { warn "skills/video-toolchain not found next to install.sh"; return 0; }
  mkdir -p "$HERMES_HOME/skills/video-toolchain"
  cp -R "$src/." "$HERMES_HOME/skills/video-toolchain/"
  ok "installed $HERMES_HOME/skills/video-toolchain/SKILL.md"
}

# -----------------------------------------------------------------------------
# 5. OpenScreen MCP wiring
# -----------------------------------------------------------------------------
wire_mcp() {
  log "OpenScreen MCP"
  local cfg="$HERMES_HOME/config.yaml"
  [ -f "$cfg" ] || { warn "no config.yaml at $cfg — add config/mcp.openscreen.yaml manually"; return 0; }

  if grep -qE '^[[:space:]]*openscreen:' "$cfg"; then
    ok "already configured in $cfg"; return 0
  fi

  local cmd="$HOME/.local/bin/openscreen"
  [ "$OS" = "Darwin" ] && cmd="/Applications/Openscreen.app/Contents/MacOS/Openscreen"

  # Edits the file as text (to keep the user's comments and layout), but only
  # for a block-style `mcp_servers:` mapping it understands, matching its
  # indentation. Anything else is left untouched for a manual merge. When
  # PyYAML is importable the result must parse and keep every existing server
  # before it is written. The original is kept as config.yaml.bak.
  local rc=0
  python3 - "$cfg" "$cmd" <<'PY' || rc=$?
import json, os, re, shutil, sys

path, cmd = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    src = f.read()
lines = src.splitlines()

def entry(ind):
    # JSON strings are valid YAML double-quoted scalars, so any path is safe.
    return [f"{ind}openscreen:", f"{ind * 2}command: {json.dumps(cmd)}",
            f"{ind * 2}args:", f"{ind * 2}  - mcp", f"{ind * 2}enabled: true"]

top = [i for i, l in enumerate(lines) if re.match(r"mcp_servers\s*:", l)]
if len(top) > 1:
    sys.exit("more than one top-level mcp_servers key")
if not top:
    if src and not src.endswith("\n"):
        src += "\n"
    new = src + "\nmcp_servers:\n" + "\n".join(entry("  ")) + "\n"
else:
    idx = top[0]
    if not re.match(r"mcp_servers\s*:\s*(#.*)?$", lines[idx]):
        sys.exit("mcp_servers is not a block mapping (inline value)")
    end = idx + 1
    while end < len(lines):
        l = lines[end]
        if l.strip() and not l[0].isspace() and not l.startswith("#"):
            break
        end += 1
    body = [i for i in range(idx + 1, end)
            if lines[i].strip() and lines[i][0].isspace() and not lines[i].lstrip().startswith("#")]
    if body:
        ind = re.match(r"[ ]*", lines[body[0]]).group(0)
        if not ind:
            sys.exit("could not determine the indentation of mcp_servers entries")
        if lines[body[0]].lstrip().startswith("- "):
            sys.exit("mcp_servers is a list, not a mapping")
        at = body[-1] + 1
    else:
        ind, at = "  ", idx + 1
    lines[at:at] = entry(ind)
    new = "\n".join(lines) + "\n"

try:
    import yaml
except ImportError:
    yaml = None
if yaml is not None:
    try:
        before = (yaml.safe_load(src) or {}).get("mcp_servers") or {}
        after = yaml.safe_load(new).get("mcp_servers")
    except Exception as e:
        sys.exit(f"edited config does not parse: {e}")
    if not isinstance(after, dict) or "openscreen" not in after \
            or any(k not in after for k in before):
        sys.exit("edited config would lose existing mcp_servers entries")

shutil.copy2(path, path + ".bak")
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(new)
os.replace(tmp, path)
PY
  if [ "$rc" -eq 0 ]; then
    ok "added mcp_servers.openscreen to $cfg (backup: $cfg.bak)"
  else
    warn "left $cfg unchanged — merge config/mcp.openscreen.yaml into mcp_servers by hand"
  fi
}

# -----------------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------------
verify() {
  log "Verification"
  local fail=0

  if command -v openscreen >/dev/null 2>&1 && openscreen --help >/dev/null 2>&1; then
    ok "openscreen CLI"
  else
    warn "openscreen CLI not responding"; fail=1
  fi

  if command -v hyperframes >/dev/null 2>&1; then
    ok "hyperframes $(hyperframes --version 2>&1 | head -1)"
  else
    warn "hyperframes not on PATH (add $NPM_GLOBAL/bin)"; fail=1
  fi

  if "$VIDEO_EDITING_DIR/.venv/bin/python" -c "import moviepy, cv2" 2>/dev/null; then
    ok "video-editing venv"
  else
    warn "video-editing venv incomplete"; fail=1
  fi

  [ -f "$HERMES_HOME/skills/video-toolchain/SKILL.md" ] \
    && ok "router skill" || { warn "router skill missing"; fail=1; }

  [ $fail -eq 0 ] && log "all engines verified" || warn "some checks failed — see above"
  return $fail
}

# -----------------------------------------------------------------------------
main() {
  preflight
  [ "$MODE" = "verify" ] && { verify; exit $?; }

  install_openscreen
  [ "$OS" = "Linux" ] && install_hyperframes
  install_video_editing
  install_skill
  wire_mcp

  echo
  verify
  echo
  log "Done. Start a new Hermes session so the MCP server and skills load."
  log "Then try:  'Record a 20s screen demo and export it as an MP4.'"
}

main "$@"
