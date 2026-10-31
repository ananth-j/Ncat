@echo off
setlocal

set "TARGET_DIR=%~dp0build"

if exist "%TARGET_DIR%" (
    echo Deleting "%TARGET_DIR%"...
    rmdir /s /q "%TARGET_DIR%"
    echo [SUCCESS] Build folder deleted.
) else (
    echo [INFO] No build folder found at "%TARGET_DIR%".
)

endlocal
exit /b 0
