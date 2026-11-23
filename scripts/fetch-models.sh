#!/bin/bash
# Download the open ball model from Hugging Face and export the stock person and pose models.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
models="$root/PitchLensDockKit/Models"
venv="$root/.venv-models"
mkdir -p "$models"

# Overall progress: a bar of completed steps before each step, with the time spent so far.
total_steps=4
done_steps=0
bar() {
    local width=30
    local filled=$((done_steps * width / total_steps))
    printf '%s%s' "$(printf '%*s' "$filled" '' | tr ' ' '#')" "$(printf '%*s' "$((width - filled))" '' | tr ' ' '-')"
}
elapsed() { printf '%dm%02ds' $((SECONDS / 60)) $((SECONDS % 60)); }
progress() {
    printf '\n[%s] step %d/%d: %s (%s)\n' "$(bar)" $((done_steps + 1)) "$total_steps" "$1" "$(elapsed)"
    done_steps=$((done_steps + 1))
}

progress "Creating the Python environment"
python3 -m venv "$venv"

progress "Installing torch, ultralytics and coremltools (about 1 GB the first time)"
# Versions known to export correctly (newer torch breaks coremltools 9.0). numpy is
# pinned too: coremltools 9.0 fails on numpy >= 2.4 ("only 0-dimensional arrays can be
# converted to Python scalars"), and the Ultralytics Core ML export asks for <= 2.3.5.
# No --quiet, so pip shows a download bar per package.
"$venv/bin/pip" install --disable-pip-version-check --progress-bar on \
    huggingface_hub "torch==2.7.1" "torchvision==0.22.1" "ultralytics==8.4.153" "coremltools==9.0" \
    "numpy>=1.26,<=2.3.5"

progress "Downloading the box2boxcam ball model from Hugging Face"
"$venv/bin/python" - "$models" <<'PY'
import shutil, sys
from pathlib import Path
from huggingface_hub import snapshot_download

folder = Path(snapshot_download("Totorotibo84/box2boxcam-football-ball-detection",
                                allow_patterns=["box2boxcam-ball-v1.0.mlpackage/*"]))
target = Path(sys.argv[1]) / "PitchLensBallSmallV006.mlpackage"
if target.exists():
    shutil.rmtree(target)
shutil.copytree(folder / "box2boxcam-ball-v1.0.mlpackage", target)
print("wrote", target)
PY

progress "Exporting the person and pose models to Core ML"
(cd "$root/scripts" && "$venv/bin/python" export-person-models.py --destination "$models")

printf '\n[%s] done in %s: %s\n' "$(bar)" "$(elapsed)" "$models"
