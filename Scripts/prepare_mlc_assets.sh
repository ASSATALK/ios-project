#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_PATH="$REPO_ROOT/mlc-package-config.json"
DIST_DIR="$REPO_ROOT/dist"
MLC_SOURCE_DIR="${MLC_LLM_SOURCE_DIR:-}"
SKIP_PATCHES="${MLC_PREPARE_SKIP_PATCHES:-0}"

if [[ -z "$MLC_SOURCE_DIR" ]]; then
  if [[ -d "$REPO_ROOT/../mlc-llm" ]]; then
    MLC_SOURCE_DIR="$(cd "$REPO_ROOT/../mlc-llm" && pwd)"
    export MLC_LLM_SOURCE_DIR="$MLC_SOURCE_DIR"
  else
    cat <<'MSG'
[prepare_mlc_assets] MLC_LLM_SOURCE_DIR 환경 변수가 설정되어 있지 않습니다.
아래와 같이 mlc-llm 소스코드를 내려받고 환경 변수를 지정한 뒤 다시 실행하세요.
  git clone https://github.com/mlc-ai/mlc-llm.git ../mlc-llm
  export MLC_LLM_SOURCE_DIR="$(pwd)/../mlc-llm"
MSG
    exit 1
  fi
fi

if ! command -v mlc_llm &>/dev/null; then
  cat <<'MSG'
[prepare_mlc_assets] mlc_llm CLI를 찾을 수 없습니다.
다음 절차로 설치해 주세요.
  pip install --pre -U -f https://mlc.ai/wheels mlc-llm-nightly-cpu mlc-ai-nightly-cpu
MSG
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "[prepare_mlc_assets] python3 명령을 찾을 수 없습니다." >&2
  exit 1
fi

apply_text_patch() {
  local description="$1"
  local file="$2"
  local script="$3"

  if [[ ! -f "$file" ]]; then
    return
  fi

  python3 - "$description" "$file" "$script" <<'PY'
import pathlib
import sys

description = sys.argv[1]
path = pathlib.Path(sys.argv[2])
patch = sys.argv[3]

namespace = {}
exec(compile(patch, "<patch>", "exec"), namespace)
func = namespace["transform"]

original = path.read_text()
updated = func(original)

if original != updated:
    path.write_text(updated)
    print(f"[prepare_mlc_assets] 패치 적용: {description} -> {path}")
else:
    print(f"[prepare_mlc_assets] 패치 건너뜀(이미 적용됨): {description} -> {path}")
PY
}

apply_mlc_patches() {
  local root="$1"

  echo "[prepare_mlc_assets] mlc-llm 호환성 패치 적용 중..."

  local cmake_patch='def transform(text):
    import re
    pattern = re.compile(r"cmake_minimum_required\s*\(\s*VERSION\s*[0-9.]+\s*\)", re.IGNORECASE)
    return pattern.sub("cmake_minimum_required(VERSION 3.5...3.27)", text, count=1)
'

  apply_text_patch "cmake_minimum_required 범위 확장" \
    "$root/3rdparty/tokenizers-cpp/CMakeLists.txt" "$cmake_patch"
  apply_text_patch "cmake_minimum_required 범위 확장" \
    "$root/3rdparty/tokenizers-cpp/msgpack/CMakeLists.txt" "$cmake_patch"
  apply_text_patch "cmake_minimum_required 범위 확장" \
    "$root/3rdparty/tokenizers-cpp/sentencepiece/src/CMakeLists.txt" "$cmake_patch"

  local policy_patch='def transform(text):
    import re
    pattern = re.compile(r"(cmake\\s+[^\\n]*)(\\n)")
    def repl(match):
        line = match.group(1)
        if "-DCMAKE_POLICY_VERSION_MINIMUM" in line:
            return match.group(0)
        return f"{line} -DCMAKE_POLICY_VERSION_MINIMUM=3.5{match.group(2)}"
    return pattern.sub(repl, text, count=1)
'

  apply_text_patch "prepare_libs.sh 정책 플래그" \
    "$root/ios/prepare_libs.sh" "$policy_patch"

  local unwind_patch='def transform(text):
    import re
    pattern = re.compile(r"(\s)-lunwind(?=\b)")
    text, _ = pattern.subn("\\1", text)
    pattern_word = re.compile(r"(\s)unwind(?=[\s\)\"])")
    return pattern_word.sub("\\1", text)
'

  apply_text_patch "libunwind 제거" \
    "$root/3rdparty/tokenizers-cpp/CMakeLists.txt" "$unwind_patch"
  apply_text_patch "libunwind 제거" \
    "$root/3rdparty/tokenizers-cpp/msgpack/CMakeLists.txt" "$unwind_patch"
  apply_text_patch "libunwind 제거" \
    "$root/3rdparty/tokenizers-cpp/sentencepiece/src/CMakeLists.txt" "$unwind_patch"
}

if [[ "$SKIP_PATCHES" != "1" ]]; then
  apply_mlc_patches "$MLC_SOURCE_DIR"
else
  echo "[prepare_mlc_assets] MLC_PREPARE_SKIP_PATCHES=1 로 패치 단계를 건너뜁니다."
fi

mkdir -p "$DIST_DIR"

PACKAGE_ARGS=(
  "--package-config" "$CONFIG_PATH"
  "--output" "$DIST_DIR"
)

if [[ -n "$MLC_SOURCE_DIR" ]]; then
  PACKAGE_ARGS+=("--mlc-llm-source-dir" "$MLC_SOURCE_DIR")
fi

set -x
mlc_llm package "${PACKAGE_ARGS[@]}"
set +x

echo "[prepare_mlc_assets] 완료: dist/ 아래에 번들 및 라이브러리가 생성되었습니다."
