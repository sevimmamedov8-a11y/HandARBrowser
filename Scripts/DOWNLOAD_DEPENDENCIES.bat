@echo off
setlocal EnableExtensions
cd /d "%~dp0.."

title Hand AR Browser - dependency check

echo ============================================================
echo Hand AR Browser - dependency check
echo ============================================================
echo.
echo [OK] This project has NO third-party SDK downloads.
echo [OK] Camera       = AVFoundation
echo [OK] Hand tracking= Vision
echo [OK] Motion       = CoreMotion
echo [OK] Browser      = WebKit / WKWebView
echo [OK] UI           = UIKit
echo.
if exist "HandARBrowser.xcodeproj\project.pbxproj" (
  echo [OK] Xcode project found.
) else (
  echo [ERROR] HandARBrowser.xcodeproj\project.pbxproj is missing.
  echo.
  pause
  exit /b 1
)
if exist ".github\workflows\build-ipa.yml" (
  echo [OK] GitHub Actions workflow found.
) else (
  echo [ERROR] .github\workflows\build-ipa.yml is missing.
  echo.
  pause
  exit /b 1
)

echo.
echo You do not need a Mac to run this check.
echo GitHub Actions uses a macOS runner with Xcode to build the IPA.
echo.
pause
exit /b 0
