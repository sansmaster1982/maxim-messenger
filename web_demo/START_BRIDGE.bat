@echo off
chcp 65001 >nul
echo ============================================
echo   MAX bridge  (browser ^<-^> api.oneme.ru)
echo ============================================
echo.
echo Listening on ws://127.0.0.1:8765
echo Open max_interface.html in a browser and paste your auth-token.
echo Press Ctrl+C to stop.
echo.
cd /d "%~dp0"
python bridge.py
pause
