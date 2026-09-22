---
name: verify-app
description: Use when asked to run, launch, screenshot, or visually verify the Accounting iOS app in the Simulator, or to reset its seeded database.
---

# Verify App in Simulator

Build → terminate → reinstall → launch → check screen with `describe-ui` → tap by accessibility label → screenshot. Never guess tap coordinates; never pass `CODE_SIGNING_ALLOWED=NO`.

## Commands

```bash
cd /Users/innei/git/innei-repo/accounting-ios
S=<session scratchpad dir>                          # set this; screenshots go here
xcodegen generate                                   # Accounting.xcodeproj is gitignored
DEST='platform=iOS Simulator,name=iPhone 17 Pro'
xcodebuild -project Accounting.xcodeproj -scheme Accounting -destination "$DEST" -derivedDataPath DerivedData build 2>&1 | grep -E "error:|BUILD"
# optional, package tests only:
xcodebuild -project Accounting.xcodeproj -scheme Accounting -destination "$DEST" -derivedDataPath DerivedData test 2>&1 | grep -E "error:|✘|✔ Test run|TEST"

xcrun simctl boot "iPhone 17 Pro" 2>/dev/null; xcrun simctl bootstatus "iPhone 17 Pro" -b
UDID=$(xcrun simctl list devices booted -j | python3 -c "import json,sys; print([d['udid'] for v in json.load(sys.stdin)['devices'].values() for d in v if d['state']=='Booted'][0])")
xcrun simctl terminate booted dev.innei.Accounting 2>/dev/null
xcrun simctl uninstall booted dev.innei.Accounting  # only when you need a fresh DB (Debug seed runs on empty DB)
xcrun simctl install booted DerivedData/Build/Products/Debug-iphonesimulator/Accounting.app
xcrun simctl launch booted dev.innei.Accounting
# chat page with a real provider (Debug only, no Keychain needed):
SIMCTL_CHILD_AGENT_PROVIDER=openai SIMCTL_CHILD_AGENT_BASE_URL="$OPENAI_PROXY_URL" SIMCTL_CHILD_AGENT_MODEL=gpt-4o-mini SIMCTL_CHILD_AGENT_API_KEY="$OPENAI_API_KEY" xcrun simctl launch booted dev.innei.Accounting
open -a Simulator                                   # only if the user wants to watch; screenshots work without it

axe describe-ui --udid $UDID | grep '"AXLabel" : "'   # confirm you are on the ledger list and read labels
axe tap --label "日本旅行 2026.09, JPY" --udid $UDID   # list rows are "name, currency"
axe tap --label "Ask Agent…" --udid $UDID; axe tap -x 200 -y 810 --udid $UDID   # open chat, focus composer
axe type "How much did we spend?" --udid $UDID; axe tap --label "Up" --udid $UDID   # ASCII only; "Up" is the send button
axe swipe --start-x 200 --start-y 700 --end-x 200 --end-y 150 --udid $UDID
xcrun simctl io booted screenshot "$S/activity.png" 2>/dev/null   # then Read the PNG
```

## Gotchas

| Symptom | Fix |
|---|---|
| App is not on the ledger list after launch | Old process survived. `terminate` then `launch` again; re-check with `describe-ui`. |
| Tap did nothing | Coordinates missed. Use `--label`; get labels from `describe-ui`. |
| "Apple 账户验证" dialog covers the app | `axe tap --label "以后" --udid $UDID`, then retry. |
| Seed data missing or stale | Uninstall before install; seed only runs when the DB has no ledger. |
| `osascript` / System Events clicks | Don't. They don't reach the Simulator; `axe` does. |
| `No display specified` on screenshot | Harmless stderr noise. |
| `axe type` fails on Chinese | It only types ASCII. Ask in English. |
| App crashed | `ls -t ~/Library/Logs/DiagnosticReports/Accounting-*.ips \| head -1`, read `faultingThread` frames from the JSON body. |
| Build says `'v26' is unavailable` | Package platforms use `.iOS("26.0")`, not `.v26`. |

Seed data lives in `App/Sources/DebugSeed.swift`; bundle id `dev.innei.Accounting`; DB at the app's Application Support `ledger.sqlite`.
