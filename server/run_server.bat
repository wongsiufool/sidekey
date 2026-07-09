@echo off
chcp 65001 >nul
title Sidekey 电脑端
cd /d "%~dp0"

REM 轻量版: 不打包成 exe, 直接双击运行 (需要装了 Python)。
REM 第一次双击会自动装好环境, 之后双击就直接启动。

if not exist ".venv\Scripts\python.exe" (
  py --version >nul 2>&1
  if errorlevel 1 (
    echo [错误] 没找到 Python。请先到 python.org 安装 ^(勾选 Add python.exe to PATH^)。
    pause
    exit /b 1
  )
  echo 第一次运行, 正在安装环境 (需要联网, 稍等)...
  py -m venv .venv
  .venv\Scripts\pip install -r requirements.txt
)

echo 启动 Sidekey 电脑端...
.venv\Scripts\python sidekey_server.py
pause
