@echo off
chcp 65001 >nul
title Sidekey 打包工具
cd /d "%~dp0"
echo ============================================
echo    Sidekey 电脑端  --  一键打包成 exe
echo ============================================
echo.

py --version >nul 2>&1
if errorlevel 1 (
  echo [错误] 没找到 Python。
  echo        请先到 python.org 下载安装 Python 3.10 或更新版本,
  echo        安装时务必勾选 "Add python.exe to PATH", 然后重新双击本文件。
  echo.
  pause
  exit /b 1
)

echo [1/3] 创建打包用的临时环境...
py -m venv .buildenv

echo [2/3] 安装依赖和打包工具 (需要联网, 第一次较慢, 请耐心等待)...
.buildenv\Scripts\python -m pip install --upgrade pip >nul 2>&1
.buildenv\Scripts\pip install -r requirements.txt pyinstaller
if errorlevel 1 (
  echo.
  echo [错误] 依赖安装失败, 请检查网络后重新双击本文件。
  pause
  exit /b 1
)

echo [3/3] 正在打包成 exe (约 1-3 分钟, 请勿关闭窗口)...
rem 直接用修好的 SidekeyServer.spec 打包: 里面已显式收 cryptography/cffi/pystray 等
rem (惰性 import + 原生绑定, 漏了在干净机器上会闪退), 保证 bat 和 spec 一致、是同一份真相。
.buildenv\Scripts\pyinstaller --noconfirm SidekeyServer.spec

echo.
if exist "dist\SidekeyServer.exe" (
  copy /Y "dist\SidekeyServer.exe" "SidekeyServer.exe" >nul
  echo ============================================
  echo  [完成] 打包成功!
  echo.
  echo  文件就在这个文件夹里:   SidekeyServer.exe
  echo  以后直接双击 SidekeyServer.exe 就能启动, 不用再打包。
  echo  这个 exe 还能拷到别的 Windows 电脑上直接用 (那台不用装 Python)。
  echo ============================================
) else (
  echo  [失败] 没生成 exe。请把上面的报错内容截图发给开发者。
)
echo.
pause
