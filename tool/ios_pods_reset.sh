#!/usr/bin/env bash
set -euo pipefail

echo "🧹 Starting iOS CocoaPods reset..."

cd ios

# Close any open Xcode workspace
echo "📱 Closing Xcode..."
osascript -e 'tell application "Xcode" to quit' || true

# Full clean
echo "🗑️  Cleaning build artifacts..."
rm -rf Pods Podfile.lock Runner.xcworkspace
rm -rf ~/Library/Developer/Xcode/DerivedData/*
xcrun simctl shutdown all || true

# Clean Flutter build cache
echo "🧽 Cleaning Flutter cache..."
cd ..
flutter clean
flutter pub get
cd ios

# Ensure Ruby and CocoaPods env
echo "🔧 Setting up environment..."
export LANG=en_US.UTF-8

# Update CocoaPods repo
echo "📦 Updating CocoaPods repo..."
pod repo update

# Install pods with deterministic settings
echo "⚙️  Installing CocoaPods..."
echo "Using system CocoaPods..."
pod install

echo "✅ CocoaPods reset complete!"
echo "📱 You can now open Runner.xcworkspace in Xcode"
