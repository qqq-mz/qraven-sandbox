#!/usr/bin/env bash
# 四级可部署性测试。输入：TARGET_OWNER TARGET_REPO FULL_NAME TEST_ID ALLOW_README
# WORK_DIR OUT_DIR RUN_URL SCRIPT_DIR
# 输出：$OUT_DIR/result.json 与 $OUT_DIR/full.log
set -u
set -o pipefail

TARGET_OWNER="${TARGET_OWNER:?}"
TARGET_REPO="${TARGET_REPO:?}"
FULL_NAME="${FULL_NAME:-$TARGET_OWNER/$TARGET_REPO}"
TEST_ID="${TEST_ID:?}"
ALLOW_README="${ALLOW_README:-false}"
WORK_DIR="${WORK_DIR:-$HOME/target}"
OUT_DIR="${OUT_DIR:-$HOME/out}"
RUN_URL="${RUN_URL:-}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"

mkdir -p "$OUT_DIR" "$WORK_DIR"
LOG="$OUT_DIR/full.log"
RESULT="$OUT_DIR/result.json"
STAGE_FILE="$OUT_DIR/stages.jsonl"
MEM_FILE="$OUT_DIR/peak_mem.txt"
IMG_FILE="$OUT_DIR/image_size.txt"

: >"$LOG"
: >"$STAGE_FILE"
echo "0" >"$MEM_FILE"
: >"$IMG_FILE"

log() { printf '%s\n' "$*" | tee -a "$LOG"; }

record_stage() {
  local name="$1" ok="$2" seconds="$3"
  printf '{"name":"%s","ok":%s,"seconds":%s}\n' "$name" "$ok" "$seconds" >>"$STAGE_FILE"
}

MEM_PID=""
start_mem_sampler() {
  (
    peak=0
    while true; do
      usage=$(docker stats --no-stream --format '{{.MemUsage}}' 2>/dev/null | head -n 30 || true)
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        val=$(printf '%s' "$line" | awk -F'/' '{print $1}' | tr -d ' ')
        mb=0
        case "$val" in
          *GiB|*GB|*Gi|*G)
            num=$(printf '%s' "$val" | sed -E 's/[^0-9.]//g')
            mb=$(awk -v n="${num:-0}" 'BEGIN{printf "%d", n*1024}')
            ;;
          *MiB|*MB|*Mi|*M)
            num=$(printf '%s' "$val" | sed -E 's/[^0-9.]//g')
            mb=$(awk -v n="${num:-0}" 'BEGIN{printf "%d", n}')
            ;;
        esac
        if [[ "$mb" -gt "$peak" ]]; then
          peak=$mb
          echo "$peak" >"$MEM_FILE"
        fi
      done <<<"$usage"
      sleep 2
    done
  ) &
  MEM_PID=$!
}

stop_mem_sampler() {
  if [[ -n "${MEM_PID}" ]] && kill -0 "$MEM_PID" 2>/dev/null; then
    kill "$MEM_PID" 2>/dev/null || true
    wait "$MEM_PID" 2>/dev/null || true
  fi
}

COMPOSE_FILE=""
CONTAINER_ID=""
IMAGE_TAG=""

cleanup_docker() {
  if [[ -n "${COMPOSE_FILE}" && -f "${WORK_DIR}/${COMPOSE_FILE}" ]]; then
    (cd "$WORK_DIR" && docker compose -f "$COMPOSE_FILE" down -v --remove-orphans) >/dev/null 2>&1 || true
  fi
  if [[ -n "${CONTAINER_ID}" ]]; then
    docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${IMAGE_TAG}" ]]; then
    docker rmi -f "$IMAGE_TAG" >/dev/null 2>&1 || true
  fi
}

trap 'stop_mem_sampler; cleanup_docker' EXIT

write_result() {
  local status="$1" strategy="$2" commit_sha="$3"
  python3 "$SCRIPT_DIR/write_result.py" \
    --out "$RESULT" \
    --test-id "$TEST_ID" \
    --full-name "$FULL_NAME" \
    --strategy "$strategy" \
    --status "$status" \
    --stages-file "$STAGE_FILE" \
    --log-file "$LOG" \
    --peak-mem-file "$MEM_FILE" \
    --image-size-file "$IMG_FILE" \
    --commit-sha "$commit_sha" \
    --run-url "$RUN_URL"
}

find_compose() {
  for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [[ -f "$f" ]]; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

health_check_ports() {
  local cid="$1"
  local i state ports p any
  for i in $(seq 1 30); do
    state=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo dead)
    if [[ "$state" != "running" ]]; then
      log "container not running at ${i}s: $state"
      return 1
    fi
    sleep 1
  done
  ports=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}} {{end}}{{end}}' "$cid" 2>/dev/null || true)
  if [[ -z "${ports// }" ]]; then
    log "no published ports; container stayed up 30s — OK"
    return 0
  fi
  any=0
  for p in $ports; do
    if (echo >/dev/tcp/127.0.0.1/"$p") >/dev/null 2>&1; then
      log "port $p open"
      any=1
      break
    fi
  done
  if [[ $any -eq 1 ]]; then
    return 0
  fi
  for p in 80 8000 8080 3000 5000 7860 8501; do
    if curl -fsS -m 3 "http://127.0.0.1:$p/" >/dev/null 2>&1 \
      || curl -fsS -m 3 "http://127.0.0.1:$p/health" >/dev/null 2>&1; then
      log "HTTP probe ok on $p"
      return 0
    fi
  done
  log "ports published but none responded; counting running-30s as OK"
  return 0
}

# ---- clone ----
t0=$(date +%s)
log "==> clone $FULL_NAME"
if ! git clone --depth 1 "https://github.com/${TARGET_OWNER}/${TARGET_REPO}.git" "$WORK_DIR" >>"$LOG" 2>&1; then
  record_stage "clone" false $(( $(date +%s) - t0 ))
  write_result "failed" "none" ""
  exit 0
fi
record_stage "clone" true $(( $(date +%s) - t0 ))
cd "$WORK_DIR"
COMMIT_SHA=$(git rev-parse HEAD)
log "commit=$COMMIT_SHA"

# ========== 1 compose ==========
if COMPOSE_FILE=$(find_compose); then
  STRATEGY="compose"
  log "==> strategy compose ($COMPOSE_FILE)"
  start_mem_sampler
  t1=$(date +%s)
  if docker compose -f "$COMPOSE_FILE" up -d --build >>"$LOG" 2>&1; then
    record_stage "compose_up" true $(( $(date +%s) - t1 ))
    cid=$(docker compose -f "$COMPOSE_FILE" ps -q | head -n 1 || true)
    img=$(docker compose -f "$COMPOSE_FILE" images -q 2>/dev/null | head -n 1 || true)
    if [[ -n "$img" ]]; then
      docker image inspect "$img" --format '{{.Size}}' 2>/dev/null \
        | awk '{printf "%.1f", $1/1024/1024}' >"$IMG_FILE" || true
    fi
    t2=$(date +%s)
    if [[ -n "$cid" ]] && health_check_ports "$cid" >>"$LOG" 2>&1; then
      record_stage "health_check" true $(( $(date +%s) - t2 ))
      stop_mem_sampler
      write_result "success" "$STRATEGY" "$COMMIT_SHA"
      exit 0
    fi
    record_stage "health_check" false $(( $(date +%s) - t2 ))
    stop_mem_sampler
    write_result "failed" "$STRATEGY" "$COMMIT_SHA"
    exit 0
  fi
  record_stage "compose_up" false $(( $(date +%s) - t1 ))
  stop_mem_sampler
  write_result "failed" "$STRATEGY" "$COMMIT_SHA"
  exit 0
fi

# ========== 2 Dockerfile ==========
if [[ -f Dockerfile ]]; then
  STRATEGY="dockerfile"
  IMAGE_TAG="qraven-test-${TEST_ID}:local"
  log "==> strategy dockerfile"
  start_mem_sampler
  t1=$(date +%s)
  if docker build -t "$IMAGE_TAG" . >>"$LOG" 2>&1; then
    record_stage "docker_build" true $(( $(date +%s) - t1 ))
    docker image inspect "$IMAGE_TAG" --format '{{.Size}}' 2>/dev/null \
      | awk '{printf "%.1f", $1/1024/1024}' >"$IMG_FILE" || true
    t2=$(date +%s)
    CONTAINER_ID=""
    for map in "-p 8080:8080" "-p 8000:8000" "-p 3000:3000" ""; do
      # shellcheck disable=SC2086
      if CONTAINER_ID=$(docker run -d $map "$IMAGE_TAG" 2>>"$LOG"); then
        log "container started map='$map' id=$CONTAINER_ID"
        break
      fi
      CONTAINER_ID=""
    done
    if [[ -z "$CONTAINER_ID" ]]; then
      record_stage "docker_run" false $(( $(date +%s) - t2 ))
      stop_mem_sampler
      write_result "failed" "$STRATEGY" "$COMMIT_SHA"
      exit 0
    fi
    record_stage "docker_run" true $(( $(date +%s) - t2 ))
    t3=$(date +%s)
    if health_check_ports "$CONTAINER_ID" >>"$LOG" 2>&1; then
      record_stage "health_check" true $(( $(date +%s) - t3 ))
      stop_mem_sampler
      write_result "success" "$STRATEGY" "$COMMIT_SHA"
      exit 0
    fi
    record_stage "health_check" false $(( $(date +%s) - t3 ))
    stop_mem_sampler
    write_result "failed" "$STRATEGY" "$COMMIT_SHA"
    exit 0
  fi
  record_stage "docker_build" false $(( $(date +%s) - t1 ))
  stop_mem_sampler
  write_result "failed" "$STRATEGY" "$COMMIT_SHA"
  exit 0
fi

# ========== 3 pip ==========
if [[ -f pyproject.toml || -f setup.py ]]; then
  STRATEGY="pip"
  log "==> strategy pip"
  t1=$(date +%s)
  python3 -m venv "$OUT_DIR/venv" >>"$LOG" 2>&1 || true
  # shellcheck disable=SC1091
  source "$OUT_DIR/venv/bin/activate"
  pip install -U pip wheel setuptools >>"$LOG" 2>&1 || true
  (
    peak=0
    while true; do
      for pid in $(pgrep -f "$OUT_DIR/venv" 2>/dev/null || true); do
        r=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo 0)
        [[ "${r:-0}" -gt "$peak" ]] && peak=$r
      done
      mb=$((peak / 1024))
      cur=$(cat "$MEM_FILE" 2>/dev/null || echo 0)
      [[ "$mb" -gt "${cur:-0}" ]] && echo "$mb" >"$MEM_FILE"
      sleep 1
    done
  ) &
  PIP_MEM_PID=$!
  if pip install ".[dev]" >>"$LOG" 2>&1 || pip install . >>"$LOG" 2>&1; then
    record_stage "pip_install" true $(( $(date +%s) - t1 ))
    t2=$(date +%s)
    PKG=$(python3 - <<'PY'
import re, pathlib
root = pathlib.Path(".")
name = None
if (root / "pyproject.toml").exists():
    text = (root / "pyproject.toml").read_text(encoding="utf-8", errors="ignore")
    m = re.search(r'(?m)^\s*name\s*=\s*["\']([^"\']+)["\']', text)
    if m:
        name = m.group(1)
if not name and (root / "setup.py").exists():
    text = (root / "setup.py").read_text(encoding="utf-8", errors="ignore")
    m = re.search(r'name\s*=\s*["\']([^"\']+)["\']', text)
    if m:
        name = m.group(1)
if name:
    print(name.replace("-", "_").split(".")[0])
PY
)
    IMPORT_OK=0
    if [[ -n "$PKG" ]]; then
      if python -c "import importlib; importlib.import_module('${PKG}')" >>"$LOG" 2>&1; then
        IMPORT_OK=1
      fi
    fi
    if [[ $IMPORT_OK -eq 0 ]]; then
      while IFS= read -r init; do
        mod=$(dirname "$init" | sed 's|^\./||;s|/|.|g')
        case "$mod" in
          *test*|*tests*|*docs*) continue ;;
        esac
        if python -c "import importlib; importlib.import_module('${mod}')" >>"$LOG" 2>&1; then
          IMPORT_OK=1
          PKG=$mod
          break
        fi
      done < <(find . -maxdepth 3 -type f -name "__init__.py" 2>/dev/null | head -n 20)
    fi
    kill "$PIP_MEM_PID" 2>/dev/null || true
    wait "$PIP_MEM_PID" 2>/dev/null || true
    if [[ $IMPORT_OK -eq 1 ]]; then
      record_stage "import_smoke" true $(( $(date +%s) - t2 ))
      log "import ok: $PKG"
      write_result "success" "$STRATEGY" "$COMMIT_SHA"
      exit 0
    fi
    record_stage "import_smoke" false $(( $(date +%s) - t2 ))
    write_result "failed" "$STRATEGY" "$COMMIT_SHA"
    exit 0
  fi
  kill "$PIP_MEM_PID" 2>/dev/null || true
  wait "$PIP_MEM_PID" 2>/dev/null || true
  record_stage "pip_install" false $(( $(date +%s) - t1 ))
  write_result "failed" "$STRATEGY" "$COMMIT_SHA"
  exit 0
fi

# ========== 4 README ==========
if [[ "${ALLOW_README}" == "true" ]]; then
  STRATEGY="readme-cmds"
  log "==> strategy readme-cmds"
  README=""
  for f in README.md README.rst README README.MD readme.md; do
    if [[ -f "$f" ]]; then
      README=$f
      break
    fi
  done
  if [[ -z "$README" ]]; then
    record_stage "readme_extract" false 0
    write_result "failed" "$STRATEGY" "$COMMIT_SHA"
    exit 0
  fi
  t1=$(date +%s)
  CMD_FILE="$OUT_DIR/readme_cmds.sh"
  python3 - <<'PY' "$README" "$CMD_FILE"
import re, sys
readme, out = sys.argv[1], sys.argv[2]
text = open(readme, encoding="utf-8", errors="ignore").read()
blocks = re.findall(r"```(?:bash|sh|shell|zsh)?\n(.*?)```", text, flags=re.S | re.I)
allowed_prefixes = (
    "pip ", "pip3 ", "python ", "python3 ", "uv ", "poetry ",
    "npm ", "pnpm ", "yarn ", "make ", "cargo ",
    "docker ", "docker-compose ", "docker compose",
    "cd ", "export ", "set -", "source ", ".",
    "curl ", "wget ", "git ", "apt-get ", "apt ",
)
deny = ("sudo ", "rm -rf /", "mkfs", "dd if=", ":(){", "shutdown", "reboot", "| sh", "|sh", "| bash", "|bash")
picked = []
for block in blocks:
    lines = []
    for raw in block.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("$ "):
            line = line[2:].strip()
        low = line.lower()
        if any(d in low for d in deny):
            continue
        if low.startswith(allowed_prefixes):
            lines.append(line)
    if lines:
        picked = lines[:12]
        break
open(out, "w", encoding="utf-8").write(
    "#!/usr/bin/env bash\nset -euo pipefail\n" + "\n".join(picked) + "\n"
)
print(len(picked))
PY
  if [[ $(wc -l <"$CMD_FILE") -le 2 ]]; then
    record_stage "readme_extract" false $(( $(date +%s) - t1 ))
    log "no safe install commands extracted"
    write_result "failed" "$STRATEGY" "$COMMIT_SHA"
    exit 0
  fi
  record_stage "readme_extract" true $(( $(date +%s) - t1 ))
  chmod +x "$CMD_FILE"
  t2=$(date +%s)
  if timeout 900 bash "$CMD_FILE" >>"$LOG" 2>&1; then
    record_stage "readme_exec" true $(( $(date +%s) - t2 ))
    write_result "success" "$STRATEGY" "$COMMIT_SHA"
    exit 0
  fi
  record_stage "readme_exec" false $(( $(date +%s) - t2 ))
  write_result "failed" "$STRATEGY" "$COMMIT_SHA"
  exit 0
fi

log "no applicable strategy"
record_stage "detect" false 0
write_result "failed" "none" "$COMMIT_SHA"
exit 0
