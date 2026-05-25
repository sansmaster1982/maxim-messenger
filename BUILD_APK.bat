@echo off
setlocal

echo ===============================================
echo   Maxim - build debug APK for Android
echo ===============================================
echo.

cd /d "%~dp0"

if not defined ANDROID_HOME (
    if exist "%LOCALAPPDATA%\Android\Sdk" (
        set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
        set "ANDROID_SDK_ROOT=%LOCALAPPDATA%\Android\Sdk"
    )
)

echo Android SDK: %ANDROID_HOME%
echo Project dir: %CD%
echo.

where flutter >nul 2>&1
if errorlevel 1 (
    echo ERROR: flutter not found in PATH.
    echo Add C:\flutter\bin to your system PATH.
    pause
    exit /b 1
)

echo Step 1/3: flutter pub get
call flutter pub get
if errorlevel 1 (
    echo ERROR at pub get. See output above.
    pause
    exit /b 1
)

echo.
echo Step 2/3: flutter build apk --debug
echo (First build can take 3-8 minutes - downloading Gradle and deps)
call flutter build apk --debug
if errorlevel 1 (
    echo.
    echo ERROR at build. See output above.
    pause
    exit /b 1
)

echo.
echo Step 3/3: artifact check
set "APK=%~dp0build\app\outputs\flutter-apk\app-debug.apk"
if exist "%APK%" (
    echo.
    echo SUCCESS: APK built
    echo   %APK%
    echo.
    for %%I in ("%APK%") do echo   Size: %%~zI bytes
    echo.
    echo Opening folder...
    explorer /select,"%APK%"
) else (
    echo WARNING: build returned OK, but APK not found at:
    echo   %APK%
)

echo.
pause
