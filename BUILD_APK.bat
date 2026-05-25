@echo off
chcp 65001 > nul
setlocal

echo ===============================================
echo   Maxim — сборка debug APK для Android
echo ===============================================
echo.

REM Этот скрипт открывает чистую cmd-сессию у тебя на ПК — JDK здесь
REM получит нормальные права на NIO Pipe, и Gradle отработает как надо.
REM Внутри bash-сессии Claude Code это падало с UDS-ошибкой; в твоей
REM пользовательской cmd-сессии — пройдёт.

cd /d "%~dp0"

if defined ANDROID_HOME goto sdk_ok
if exist "%LOCALAPPDATA%\Android\Sdk" (
    set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
    set "ANDROID_SDK_ROOT=%LOCALAPPDATA%\Android\Sdk"
)
:sdk_ok

echo Использую Android SDK: %ANDROID_HOME%
echo.

where flutter > nul 2>&1
if errorlevel 1 (
    echo ОШИБКА: flutter не найден в PATH.
    echo Добавь C:\flutter\bin (или путь к Flutter SDK^) в системный PATH.
    pause
    exit /b 1
)

echo Шаг 1/3: flutter pub get
call flutter pub get
if errorlevel 1 (
    echo ОШИБКА pub get. Подробности выше.
    pause
    exit /b 1
)

echo.
echo Шаг 2/3: flutter build apk --debug
echo (первая сборка может занять 3-8 минут — скачивается Gradle и зависимости)
call flutter build apk --debug
if errorlevel 1 (
    echo.
    echo ОШИБКА сборки. Подробности выше.
    pause
    exit /b 1
)

echo.
echo Шаг 3/3: артефакт
set "APK=%~dp0build\app\outputs\flutter-apk\app-debug.apk"
if exist "%APK%" (
    echo.
    echo ✓ APK собран:
    echo   %APK%
    echo.
    for %%I in ("%APK%") do echo   Размер: %%~zI байт
    echo.
    echo Открываю папку...
    explorer /select,"%APK%"
) else (
    echo ВНИМАНИЕ: build вернул успех, но APK не найден по ожидаемому пути:
    echo   %APK%
)

echo.
pause
