#!/usr/bin/env python3
"""
不用手机也能测 server 的小工具 (wss/TLS)。
用法:  python test_client.py [wss://127.0.0.1:8765]
流程:  TLS 握手 -> hello(带令牌) -> 等 ready(鉴权通过) -> ping/pong -> 输入一行文字 -> 敲回车。

默认信任本机生成的自签名证书(.sidekey_cert.pem, 当成 CA 校验), 并自动读取令牌(.sidekey_token),
**不**关闭 TLS 校验。先把光标放到一个文本框(如「备忘录」)里, 再运行, 就能看到字被打出来。
"""
import asyncio
import json
import os
import ssl
import sys

import websockets

HERE = os.path.dirname(os.path.abspath(__file__))
CERT_FILE = os.path.join(HERE, ".sidekey_cert.pem")
TOKEN_FILE = os.path.join(HERE, ".sidekey_token")


def _ssl_context():
    """信任本机自签名证书(把它当 CA), 但跳过主机名匹配 —— 证书 CN=Sidekey 不含 IP,
    这是「受控校验」: 仍校验证书本身, 不是简单关掉 TLS。找不到证书才退回仅加密(并提醒)。"""
    ctx = ssl.create_default_context()
    if os.path.exists(CERT_FILE):
        ctx.load_verify_locations(CERT_FILE)
        ctx.check_hostname = False
    else:
        print("⚠️  找不到 .sidekey_cert.pem(连远程?)→ 退回「仅加密不校验证书」, 只用于本地诊断")
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _token():
    try:
        return open(TOKEN_FILE, encoding="utf-8").read().strip()
    except OSError:
        return ""


async def main():
    url = sys.argv[1] if len(sys.argv) > 1 else "wss://127.0.0.1:8765"
    print(f"连接 {url} ...")
    async with websockets.connect(url, ssl=_ssl_context()) as ws:
        print("服务端 hello_ack:", await ws.recv())
        await ws.send(json.dumps({"v": 1, "type": "hello", "name": "test_client", "token": _token()}))
        # 等 ready(鉴权通过); 中途可能夹杂 agent_status 推送, 忽略即可。
        while True:
            msg = json.loads(await ws.recv())
            t = msg.get("type")
            if t == "ready":
                print("✅ 鉴权通过 ready:", msg)
                break
            if t == "error":
                print("❌ 失败:", msg)
                return
        await ws.send(json.dumps({"v": 1, "type": "ping"}))
        print("收到:", await ws.recv())
        print("3 秒后开始打字, 请把光标放到一个文本框里...")
        await asyncio.sleep(3)
        await ws.send(json.dumps({"v": 1, "type": "text", "text": "hello from sidekey "}))
        await ws.send(json.dumps({"v": 1, "type": "key", "code": "enter"}))
        await ws.send(json.dumps({"v": 1, "type": "key", "code": "c", "mods": ["primary"]}))
        print("已发送: 文字 + 回车 + Cmd/Ctrl+C")
        await asyncio.sleep(0.5)


if __name__ == "__main__":
    asyncio.run(main())
