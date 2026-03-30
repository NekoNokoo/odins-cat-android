#!/bin/zsh

set -euo pipefail

export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

JAVA21_HOME="$HOME/.local/java/jdk-21.0.10+7/Contents/Home"
if [[ -d "$JAVA21_HOME" ]]; then
  export JAVA_HOME="$JAVA21_HOME"
  export PATH="$JAVA_HOME/bin:$PATH"
fi

exec "$@"
