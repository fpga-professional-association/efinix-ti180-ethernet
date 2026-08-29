@echo off
REM Regenerate ethernet project IPs headlessly with Efinity 2025.1 (vendor-pinned).
set "PATH=D:\efinix\tools\jdk-21.0.12.1+1-jre\bin;%PATH%"
call D:\efinix\efinity\2025.1\bin\setup.bat
python3 D:\efinix\mlperf\scripts\gen_ips.py D:\efinix\ethernet %*
exit /b %ERRORLEVEL%
