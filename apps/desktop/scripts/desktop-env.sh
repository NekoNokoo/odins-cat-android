#!/bin/zsh

set -euo pipefail

export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

java_home_is_21() {
  local candidate="${1:-}"
  local version_line=""
  if [[ -z "$candidate" || ! -x "$candidate/bin/java" ]]; then
    return 1
  fi
  version_line="$("$candidate/bin/java" -version 2>&1 | /usr/bin/head -n 1)"
  [[ "$version_line" == *'"21.'* || "$version_line" == *'"21"'* ]]
}

detect_java21_home() {
  local configured="${JAVA21_HOME:-}"
  local candidates=(
    "$configured"
    "${JAVA_HOME:-}"
    "$HOME/.local/java/jdk-21.0.10+7/Contents/Home"
    "/Applications/IntelliJ IDEA.app/Contents/jbr/Contents/Home"
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  )
  local candidate=""
  for candidate in "${candidates[@]}"; do
    if java_home_is_21 "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  if [[ -x /usr/libexec/java_home ]]; then
    candidate="$(/usr/libexec/java_home -v 21 2>/dev/null || true)"
    if java_home_is_21 "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  return 1
}

if DETECTED_JAVA21_HOME="$(detect_java21_home)"; then
  export JAVA_HOME="$DETECTED_JAVA21_HOME"
  export PATH="$JAVA_HOME/bin:$PATH"
fi

exec "$@"
