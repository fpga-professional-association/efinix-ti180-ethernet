@echo off
REM Regenerate TinyML SoC IPs headlessly. Usage: gen_ips.bat [--only mod1 mod2 ...]
set "PATH=D:\efinix\tools\jdk-21.0.12.1+1-jre\bin;%PATH%"
call D:\efinix\efinity\2026.1\bin\setup.bat
python3 D:\efinix\mlperf\scripts\gen_ips.py D:\efinix\ethernet %*
exit /b %ERRORLEVEL%
