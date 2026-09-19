@echo off
REM One-click full-stack launcher: backend (Spring Boot) + frontend (Vite).
REM Double-click this file to start everything.

set ROOT=%~dp0

echo Starting Docker infra (postgres, redis, rabbitmq, elasticsearch, gorse)...
cd /d "%ROOT%backend"
docker compose up -d

echo Starting backend (Spring Boot) in a new window...
start "Luvax Backend" cmd /k "cd /d "%ROOT%backend" && mvnw spring-boot:run"

echo Starting frontend (Vite) in a new window...
start "Luvax Frontend" cmd /k "cd /d "%ROOT%frontend" && npm run dev"

echo.
echo Backend:  http://localhost:8080
echo Frontend: http://localhost:5173
echo Both are starting in separate windows. Close those windows to stop them.
pause
