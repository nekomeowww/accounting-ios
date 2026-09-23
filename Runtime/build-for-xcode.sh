#!/bin/sh
set -eu
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$SRCROOT/Runtime"
if ! cmp -s package-lock.json node_modules/.accounting-lock; then
  npm ci --ignore-scripts --no-audit --no-fund
  cp package-lock.json node_modules/.accounting-lock
fi
npm run build
mkdir -p "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/AgentRuntime"
cp dist/agent.js "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/AgentRuntime/agent.js"
