@echo off
setlocal enabledelayedexpansion

echo === Gibber Web Build ^& Deploy ===
echo.

set SCRIPT_DIR=%~dp0
set PROJECT_ROOT=%SCRIPT_DIR%..

echo [1/3] Building Flutter web...
cd /d "%PROJECT_ROOT%"
call flutter build web --release --web-renderer canvaskit
if %errorlevel% neq 0 (
    echo Flutter build failed!
    exit /b 1
)

echo.
echo [2/3] Copying build to backend web directory...
set WEB_DIR=%PROJECT_ROOT%\gibber-backend\web
if not exist "%WEB_DIR%" mkdir "%WEB_DIR%"
del /q "%WEB_DIR%\*" 2>nul
for /d %%d in ("%WEB_DIR%\*") do rmdir /s /q "%%d" 2>nul
xcopy /s /y /q "%PROJECT_ROOT%\build\web\*" "%WEB_DIR%\"

echo.
echo [3/3] Rebuilding Docker containers...
cd /d "%PROJECT_ROOT%\gibber-backend"

echo   Stopping existing containers...
docker compose down 2>nul

echo   Building backend image...
docker compose build --no-cache
if %errorlevel% neq 0 (
    echo Docker build failed!
    exit /b 1
)

echo   Starting containers...
docker compose up -d

echo.
echo === Deployment complete ===
echo   Backend API: http://localhost:8080
echo   XMPP WebSocket: ws://localhost:5280/xmpp-websocket
echo   Web app: http://localhost:8080 (served by backend)
echo.
echo   For production with Caddy (TLS):
echo   docker compose --profile caddy up -d
echo.
echo   Health check: curl http://localhost:8080/health