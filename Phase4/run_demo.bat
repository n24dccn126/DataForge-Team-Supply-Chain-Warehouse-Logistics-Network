@echo off
cd /d "%~dp0"
echo ============================================================
echo   Team DATAFORGE — Supply Chain & Warehouse Logistics Demo
echo   Starting Flask App connected to MySQL 8.0...
echo ============================================================
if not exist ".env" (
    echo [!] File .env chua ton tai. Dang copy tu .env.example...
    copy ".env.example" ".env" >nul
    echo [!] Hay mo file .env va dien MYSQL_PASSWORD cua ban, sau do chay lai!
    notepad ".env"
    pause
    exit /b 1
)
where uv >nul 2>nul
if %errorlevel%==0 (
    uv run app.py
) else if exist ".venv\Scripts\python.exe" (
    ".venv\Scripts\python.exe" app.py
) else (
    python app.py
)
pause
