#!/bin/zsh

set -euo pipefail

export JAVA_HOME="$HOME/.local/java/jdk-21.0.10+7/Contents/Home"
export ANDROID_HOME="$HOME/.local/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export NDK_HOME="$ANDROID_HOME/ndk/29.0.14206865"
export ANDROID_NDK_HOME="$NDK_HOME"
export NODE_HOME="$HOME/.local/node-v20.18.3-darwin-arm64/bin"
export PATH="$NODE_HOME:$HOME/.local/bin:$HOME/.cargo/bin:$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"

exec "$@"
