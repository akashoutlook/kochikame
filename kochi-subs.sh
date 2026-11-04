#!/bin/bash
#
# kochi-subs.sh — batch English subtitles for Kochikame episodes.
#
#   Server (SSH) → download → Whisper large-v3 (Japanese) → fixes → Claude (English)
#
# Usage:
#   kochi-subs.sh            # list all episodes, pick one or many
#   kochi-subs.sh 02         # list only episodes whose filename contains "02"
#
# At the prompt you can enter:
#   5            one episode
#   1 4 7        several
#   10-20        a range (mix freely: "1 3 10-20")
#   new          every listed episode that doesn't have English subtitles yet
#   all          every listed episode
#
# Output, next to each video in LOCAL_DIR:
#   <episode>.ja.srt   Japanese transcript (after fixes)
#   <episode>.en.srt   English subtitles (IINA/VLC load this automatically)
#
# Safe to stop (Ctrl+C) and re-run: finished episodes are skipped, a finished
# Japanese transcript is reused, and an interrupted translation resumes.
#

# ============================ CONFIG ============================
# --- Server ---
REMOTE_USER="user"
REMOTE_HOST="192.168.1.1"
REMOTE_PORT="22"
REMOTE_PASS="Password"        # Leave empty to use an SSH key (recommended)
REMOTE_DIR="remote-directory"
UPLOAD_SUBS=1         # 1 = copy the .ja.srt/.en.srt back next to the video on the server
KEEP_VIDEO=0          # 0 = delete the local .mp4 after subtitles are made

# --- Local paths ---
LOCAL_DIR="$HOME/Downloads/Kochikame"
BASE="$HOME/subtitlekochikame"
BIN="$BASE/venv/bin"
TERMS="$BASE/kochikame_terms.txt"
FIXES="$BASE/kochikame_fixes.txt"   # WRONG::RIGHT pairs applied to the Japanese

# --- Whisper ---
WHISPER_MODEL="mlx-community/whisper-large-v3-mlx"
INITIAL_PROMPT="両津勘吉、大原部長、秋本麗子、中川圭一、亀有公園前派出所、葛飾区、柴又、浅草寺、佃煮、署"
SILENCE_THRESHOLD=2

# --- Claude ---
CLAUDE_MODEL="claude-haiku-5-5"
MOVIENAME="Kochira Katsushika-ku Kameari Kōen-mae Hashutsujo (Kochikame)"
DESCRIPTION="Comedy about Kankichi Ryotsu, a lazy, scheming police officer at the Kameari Park police box in Tokyo. Chief Ohara is his strict boss; Reiko and Nakagawa are rich young officers."
INSTRUCTION="The Japanese is an automatic speech-to-text transcript and contains misheard words. When a word makes no sense, infer the intended word from context (e.g. 戦争時 is likely 浅草寺, 五章だから is likely 後生だから)."
MIN_BATCH=10
MAX_BATCH=20
TRANSLATE_ATTEMPTS=2
# ================================================================

# Keep the Mac awake for the whole run
if [ -z "$KOCHI_CAFFEINATED" ]; then
  export KOCHI_CAFFEINATED=1
  exec caffeinate -i "$0" "$@"
fi

set -o pipefail

die()  { echo "Error: $*" >&2; exit 1; }
step() { echo "  -> $*"; }

ssh_cmd() {
  if [ -n "$REMOTE_PASS" ]; then
    SSHPASS="$REMOTE_PASS" sshpass -e ssh -p "$REMOTE_PORT" \
      -o ConnectTimeout=10 "$REMOTE_USER@$REMOTE_HOST" "$@"
  else
    ssh -p "$REMOTE_PORT" -o ConnectTimeout=10 -o BatchMode=yes \
      "$REMOTE_USER@$REMOTE_HOST" "$@"
  fi
}

CURRENT_PART=""
cleanup() { [ -n "$CURRENT_PART" ] && rm -f "$CURRENT_PART"; }
trap cleanup EXIT

# ---------- Pre-flight checks ----------
command -v ffmpeg  >/dev/null || die "ffmpeg not found"
command -v ffprobe >/dev/null || die "ffprobe not found"
[ -x "$BIN/mlx_whisper" ]    || die "mlx_whisper not found in $BIN"
[ -x "$BIN/claude-subtrans" ] || die "claude-subtrans launcher not found in $BIN"
[ -f "$TERMS" ] || die "Glossary not found: $TERMS"
if [ -n "$REMOTE_PASS" ]; then
  command -v sshpass >/dev/null || die "sshpass not found (brew install hudochenkov/sshpass/sshpass)"
fi

if [ -z "$ANTHROPIC_API_KEY" ] && [ -f "$BASE/.anthropic_key" ]; then
  ANTHROPIC_API_KEY=$(tr -d '[:space:]' < "$BASE/.anthropic_key")
fi
[ -n "$ANTHROPIC_API_KEY" ] || die "ANTHROPIC_API_KEY is not set (add it to ~/.zshrc)"

SDK_VER=$("$BIN/python" -c "import anthropic; print(anthropic.__version__)" 2>/dev/null) \
  || die "anthropic SDK not installed in the venv"
case "$SDK_VER" in
  0.*) ;;
  *) die "anthropic SDK is $SDK_VER; llm-subtrans needs 0.x. Fix with:
  $BIN/pip install 'anthropic>=0.105.0,<1'" ;;
esac

# Create a starter fixes file if there isn't one
if [ ! -f "$FIXES" ]; then
  cat > "$FIXES" <<'EOF'
# Whisper mishearings to correct before translation.
# One per line: WRONG::RIGHT   (lines starting with # are ignored)
差し出し人::差出人
出品人::差出人
米さん::よねさん
袋さん::お袋さん
全略::前略
頼りがない::便りがない
五章だから::後生だから
御所だから::後生だから
戦争時::浅草寺
柴畑::柴又
柴端::柴又
書の方::署の方
お聖母::お歳暮
つくだり::佃煮
EOF
  echo "Created starter fixes file: $FIXES"
fi

mkdir -p "$LOCAL_DIR" "$BASE/logs"

# ---------- Fetch episode list ----------
echo "Connecting to $REMOTE_HOST ..."
REMOTE_DIR_Q=$(printf %q "$REMOTE_DIR")
LIST=$(ssh_cmd "find $REMOTE_DIR_Q -type f \\( -iname '*.mp4' -o -iname '*.en.srt' \\) | sort") \
  || die "Could not list episodes on the server (check IP, login, REMOTE_DIR)"

REMOTE_SUBS=$(printf '%s\n' "$LIST" | grep -i '\.en\.srt$' || true)

FILTER="${1:-}"
EPISODES=()
NAMES=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in *.mp4|*.MP4) ;; *) continue ;; esac
  base="${line##*/}"
  if [ -z "$FILTER" ] || [[ "$base" == *"$FILTER"* ]]; then
    EPISODES+=("$line")
    NAMES+=("${base%.*}")
  fi
done <<< "$LIST"

COUNT=${#EPISODES[@]}
[ "$COUNT" -gt 0 ] || die "No episodes found${FILTER:+ matching \"$FILTER\"}"

has_subs() {   # $1 = index
  local name="${NAMES[$1]}" remote="${EPISODES[$1]}"
  [ -f "$LOCAL_DIR/$name.en.srt" ] && return 0
  printf '%s\n' "$REMOTE_SUBS" | grep -Fxq "${remote%.*}.en.srt" && return 0
  return 1
}

# ---------- Show list ----------
echo
echo "Episodes ($COUNT)   ✓ = English subtitles already exist"
for ((i = 0; i < COUNT; i++)); do
  mark=""
  has_subs "$i" && mark="  ✓"
  printf "%4d) %s%s\n" $((i + 1)) "${NAMES[$i]}" "$mark"
done

# ---------- Read selection ----------
echo
echo "Enter episode numbers: e.g.  5   |   1 4 7   |   10-20   |   new   |   all"
read -r -p "> " ANSWER
[ -n "$ANSWER" ] || die "Nothing selected"

SEL=()
set -f
for tok in $ANSWER; do
  if [ "$tok" = "all" ]; then
    for ((i = 0; i < COUNT; i++)); do SEL+=("$i"); done
  elif [ "$tok" = "new" ]; then
    for ((i = 0; i < COUNT; i++)); do has_subs "$i" || SEL+=("$i"); done
  elif [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
    { [ "$a" -ge 1 ] && [ "$b" -le "$COUNT" ] && [ "$a" -le "$b" ]; } \
      || die "Invalid range: $tok (valid: 1-$COUNT)"
    for ((n = a; n <= b; n++)); do SEL+=($((n - 1))); done
  elif [[ "$tok" =~ ^[0-9]+$ ]]; then
    { [ "$tok" -ge 1 ] && [ "$tok" -le "$COUNT" ]; } || die "Invalid number: $tok (valid: 1-$COUNT)"
    SEL+=($((tok - 1)))
  else
    die "Didn't understand: $tok"
  fi
done
set +f

# Remove duplicates, keep order
UNIQ=()
for s in "${SEL[@]}"; do
  dup=0
  for u in "${UNIQ[@]}"; do [ "$u" = "$s" ] && dup=1 && break; done
  [ "$dup" -eq 0 ] && UNIQ+=("$s")
done
SEL=("${UNIQ[@]}")
[ "${#SEL[@]}" -gt 0 ] || die "Nothing to do (all selected episodes already have subtitles?)"

echo
echo "Queued ${#SEL[@]} episode(s):"
for s in "${SEL[@]}"; do echo "   ${NAMES[$s]}"; done
read -r -p "Start? [Y/n] " go
[[ "$go" =~ ^[Nn] ]] && { echo "Cancelled."; exit 0; }

LOG="$BASE/logs/kochi-subs-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
echo "Log: $LOG"

# ---------- Steps ----------
download() {   # $1 remote path, $2 local path
  local rq part
  rq=$(printf %q "$1")
  part="$2.part"
  CURRENT_PART="$part"
  if command -v pv >/dev/null; then
    local size
    size=$(ssh_cmd "stat -c %s -- $rq") || return 1
    ssh_cmd "cat -- $rq" | pv -s "$size" > "$part" || return 1
  else
    ssh_cmd "cat -- $rq" > "$part" || return 1
  fi
  mv "$part" "$2"
  CURRENT_PART=""
}

upload() {     # $1 local file, $2 remote path
  local rq
  rq=$(printf %q "$2")
  ssh_cmd "cat > $rq" < "$1"
}

transcribe() { # $1 video, $2 work dir  → $2/raw.srt
  local ch wav="$2/audio.wav"
  ch=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels \
    -of csv=p=0 "$1" | head -1)
  if [ "${ch:-1}" -ge 2 ]; then
    ffmpeg -y -loglevel error -i "$1" -vn -af "pan=mono|c0=FL" -ar 16000 "$wav" || return 1
  else
    ffmpeg -y -loglevel error -i "$1" -vn -ac 1 -ar 16000 "$wav" || return 1
  fi
  "$BIN/mlx_whisper" "$wav" \
    --model "$WHISPER_MODEL" \
    --language ja \
    --initial-prompt "$INITIAL_PROMPT" \
    --condition-on-previous-text False \
    --word-timestamps True \
    --hallucination-silence-threshold "$SILENCE_THRESHOLD" \
    --output-format srt \
    --output-dir "$2" \
    --output-name raw > "$2/whisper.log" 2>&1 || { tail -20 "$2/whisper.log"; return 1; }
  rm -f "$wav"
  [ -s "$2/raw.srt" ]
}

apply_fixes() { # $1 in, $2 out
  "$BIN/python" - "$FIXES" "$1" "$2" <<'PYEOF'
import sys
fixes, src, dst = sys.argv[1:4]
pairs = []
for line in open(fixes, encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#") or "::" not in line:
        continue
    a, b = line.split("::", 1)
    if a.strip():
        pairs.append((a.strip(), b.strip()))
text = open(src, encoding="utf-8").read()
total = 0
for a, b in pairs:
    n = text.count(a)
    if n:
        text = text.replace(a, b)
        total += n
open(dst, "w", encoding="utf-8").write(text)
print(f"     applied {total} fix(es)")
PYEOF
}

translate() {  # $1 work dir: $1/ja.srt → $1/en.srt
  local attempt
  for ((attempt = 1; attempt <= TRANSLATE_ATTEMPTS; attempt++)); do
    [ "$attempt" -gt 1 ] && step "retrying untranslated lines (attempt $attempt)"
    "$BIN/claude-subtrans" "$1/ja.srt" \
      -k "$ANTHROPIC_API_KEY" \
      -m "$CLAUDE_MODEL" \
      -l English \
      -o "$1/en.srt" \
      --moviename "$MOVIENAME" \
      --description "$DESCRIPTION" \
      --instruction "$INSTRUCTION" \
      --terminology "$TERMS" \
      --preprocess --postprocess \
      --minbatchsize "$MIN_BATCH" --maxbatchsize "$MAX_BATCH" \
      --project > "$1/translate.log" 2>&1
    grep -E "Translation status" "$1/translate.log" | tail -1 | sed 's/^/     /'
    if [ -s "$1/en.srt" ] && ! grep -qE "Translation status: (incomplete|failed)" "$1/translate.log"; then
      return 0
    fi
  done
  return 1
}

process_episode() {  # $1 index
  local i="$1"
  local name="${NAMES[$i]}" remote="${EPISODES[$i]}"
  local mp4="$LOCAL_DIR/$name.mp4"
  local ja="$LOCAL_DIR/$name.ja.srt"
  local en="$LOCAL_DIR/$name.en.srt"
  local work="$LOCAL_DIR/.work/$name"

  if [ -f "$en" ]; then
    step "English subtitles already exist, skipping"
    return 0
  fi
  mkdir -p "$work"

  if [ ! -f "$ja" ]; then
    if [ ! -f "$mp4" ]; then
      step "downloading"
      download "$remote" "$mp4" || { echo "     download failed"; return 1; }
    fi
    step "transcribing with Whisper (this is the slow part)"
    transcribe "$mp4" "$work" || { echo "     transcription failed"; return 1; }
    step "applying fixes"
    apply_fixes "$work/raw.srt" "$ja" || return 1
  else
    step "Japanese transcript exists, reusing it"
  fi

  [ -f "$work/ja.srt" ] || cp "$ja" "$work/ja.srt"
  step "translating with $CLAUDE_MODEL"
  translate "$work" || { echo "     translation incomplete — see $work/translate.log"; return 1; }
  mv "$work/en.srt" "$en"
  rm -rf "$work"

  if [ "$UPLOAD_SUBS" = "1" ]; then
    step "uploading subtitles to server"
    local rbase="${remote%.*}"
    upload "$ja" "$rbase.ja.srt" && upload "$en" "$rbase.en.srt" \
      || echo "     upload failed (subtitles are still saved locally)"
  fi

  if [ "$KEEP_VIDEO" = "0" ] && [ -f "$mp4" ]; then
    rm -f "$mp4"
  fi
  return 0
}

# ---------- Run the queue ----------
OK=()
FAILED=()
TOTAL=${#SEL[@]}
n=0
RUN_START=$SECONDS

for s in "${SEL[@]}"; do
  n=$((n + 1))
  echo
  echo "[$n/$TOTAL] ${NAMES[$s]}"
  t0=$SECONDS
  if process_episode "$s"; then
    OK+=("${NAMES[$s]}")
    echo "  done in $(( (SECONDS - t0) / 60 )) min"
  else
    FAILED+=("${NAMES[$s]}")
  fi
done

# ---------- Summary ----------
echo
echo "========================================"
echo "Finished in $(( (SECONDS - RUN_START) / 60 )) min"
echo "Succeeded: ${#OK[@]}   Failed: ${#FAILED[@]}"
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "Failed (re-run the script to resume them):"
  for f in "${FAILED[@]}"; do echo "   $f"; done
fi
echo "Subtitles are in: $LOCAL_DIR"
echo "Log: $LOG"
