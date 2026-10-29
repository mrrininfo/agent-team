#!/bin/zsh
# Builds dist/AgentTeam.app (app + `agentteam` helper side by side in Contents/MacOS).
set -euo pipefail
cd "$(dirname "$0")"
swift run -c release AgentTeamChecks
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=dist/AgentTeam.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/AgentTeamApp" "$BIN/agentteam" "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Agent Team</string>
  <key>CFBundleDisplayName</key><string>Agent Team</string>
  <key>CFBundleIdentifier</key><string>local.agentteam.app</string>
  <key>CFBundleExecutable</key><string>AgentTeamApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force --deep -s - "$APP"
echo "Built $APP"
