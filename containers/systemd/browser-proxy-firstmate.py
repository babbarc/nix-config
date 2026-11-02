#!/usr/bin/env python3
"""Lazy on-demand browser proxy — listener on PROXY_PORT, Chromium on BROWSER_PORT
(default 3333/3334). Designed to run in a separate container with host networking.
Starts/stops Chromium container on-demand, proxies CDP traffic through, and
opens every page a CDP client creates in its own window (see PAGE_PER_WINDOW).
"""

import asyncio
import contextlib
import http.client
import json
import os
import signal
import time
import urllib.request

PROXY_PORT = int(os.environ.get("PROXY_PORT", "3333"))
BROWSER_PORT = int(os.environ.get("BROWSER_PORT", "3334"))
CONTAINER_NAME = os.environ.get("CONTAINER_NAME", "hermes-browser")
CONTAINER_IMAGE = os.environ.get("CONTAINER_IMAGE", "localhost/hermes-browser:latest")
BROWSER_VOLUME = os.environ.get("BROWSER_VOLUME", "hermes-browser-data")
IDLE_TIMEOUT = int(os.environ.get("IDLE_TIMEOUT", "3600"))
# IANA zone for the browser's Intl/Date clock (passed as TZ to the Chrome
# container). Set it to where the egress IP geolocates; empty keeps the
# image default, UTC.
BROWSER_TZ = os.environ.get("BROWSER_TZ", "")
# Open every page a CDP client creates in its own window: Target.createTarget is
# rewritten to newWindow=true, at 0,0 unless the client placed it. Under
# --headless=new a tab that is not its window's active tab - what
# browser_harness's new_tab() makes (background=True, never activated) - reports
# outerWidth/outerHeight 0 and visibilityState "hidden"; the only tab in a window
# is always visible at --window-size. "0" makes the proxy a plain byte pipe.
PAGE_PER_WINDOW = os.environ.get("PAGE_PER_WINDOW", "1") != "0"
BROWSER_STOP_TIMEOUT = 5
active_connections = 0
last_activity = time.time()
shutting_down = False
_browser_lock = asyncio.Lock()


def log(msg):
    print(f"[proxy] {msg}", flush=True)


async def podman(*args, timeout=30):
    proc = await asyncio.create_subprocess_exec(
        "podman", *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        if proc.returncode != 0:
            err = stderr.decode().strip()
            if err:
                log(f"podman {args[0]}: {err}")
        return stdout.decode()
    except TimeoutError:
        proc.kill()
        await proc.wait()
        log(f"podman {args[0]} timed out after {timeout}s")
        return ""


async def browser_running():
    out = await podman("ps", "--filter", f"name=^{CONTAINER_NAME}$", "--format", "{{.Status}}", timeout=10)
    return "Up" in out


def devtools_ready():
    """True once Chrome answers /json/version. Blocking: run it off the event loop."""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{BROWSER_PORT}/json/version", timeout=2):
            return True
    except (OSError, http.client.HTTPException):
        return False


async def ensure_browser_running():
    async with _browser_lock:
        if await browser_running():
            return True

        await podman("start", CONTAINER_NAME, timeout=30)
        if not await browser_running():
            await podman("rm", "-f", "-t", "1", CONTAINER_NAME, timeout=15)
            await podman(
                "run", "-d",
                "--name", CONTAINER_NAME,
                "--network", "host",
                "--security-opt", "seccomp=unconfined",
                "--device", "/dev/dri/renderD128",
                *(["-e", f"TZ={BROWSER_TZ}"] if BROWSER_TZ else []),
                "-v", f"{BROWSER_VOLUME}:/home/chrome/devtools-profile",
                CONTAINER_IMAGE,
                "--headless=new",
                "--user-data-dir=/home/chrome/devtools-profile",
                "--download-default-directory=/home/chrome/devtools-profile/downloads",
                "--disable-blink-features=AutomationControlled",
                f"--remote-debugging-port={BROWSER_PORT}",
                "--remote-debugging-address=0.0.0.0",
                "--remote-allow-origins=*",
                "--disable-dev-shm-usage",
                "--window-size=1920,1080",
                "--ozone-override-screen-size=1920,1080",
                "--lang=en-GB,en",
                "--accept-lang=en-GB,en",
                "--use-angle=vulkan",
                "--enable-features=Vulkan",
                "--force-color-profile=srgb",
                "--num-raster-threads=4",
                "--no-first-run",
                "--no-default-browser-check",
                timeout=30,
            )

        for _ in range(30):
            if await asyncio.to_thread(devtools_ready):
                return True
            await asyncio.sleep(0.5)
        return False


def rewrite_create_target(text):
    """Return CDP command `text` rewritten per PAGE_PER_WINDOW when it is a
    Target.createTarget that would open a tab, else None (forward unchanged)."""
    if b'"Target.createTarget"' not in text:
        return None
    try:
        msg = json.loads(text)
    except ValueError:
        return None
    if not isinstance(msg, dict) or msg.get("method") != "Target.createTarget":
        return None
    params = msg.get("params")
    # A hidden target cannot have a window; an explicit new window keeps the
    # client's own placement.
    if not isinstance(params, dict) or params.get("hidden") or params.get("newWindow"):
        return None
    params["newWindow"] = True
    if not params.keys() & {"left", "top", "windowState"}:
        params.update(left=0, top=0)
    return json.dumps(msg, ensure_ascii=False, separators=(",", ":")).encode()


def is_websocket_upgrade(head):
    for line in head.split(b"\r\n")[1:]:
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"upgrade" and value.strip().lower() == b"websocket":
            return True
    return False


def strip_ws_extensions(head):
    """Drop Sec-WebSocket-Extensions so Chrome never negotiates permessage-deflate:
    compressed frames could not be inspected for Target.createTarget."""
    return b"\r\n".join(
        line for line in head.split(b"\r\n")
        if line.partition(b":")[0].strip().lower() != b"sec-websocket-extensions"
    )


def ws_mask(data, key):
    """XOR `data` with a 4-byte WebSocket masking key (masking == unmasking)."""
    if not data:
        return data
    n = len(data)
    stream = (key * (n // 4 + 1))[:n]
    return (int.from_bytes(data, "big") ^ int.from_bytes(stream, "big")).to_bytes(n, "big")


def ws_client_text_frame(payload):
    """A complete, masked client->server text frame carrying `payload`."""
    n = len(payload)
    if n < 126:
        size = bytes([0x80 | n])
    elif n < 1 << 16:
        size = bytes([0x80 | 126]) + n.to_bytes(2, "big")
    else:
        size = bytes([0x80 | 127]) + n.to_bytes(8, "big")
    key = os.urandom(4)
    return bytes([0x81]) + size + key + ws_mask(payload, key)


async def close_writer(writer):
    with contextlib.suppress(OSError):
        writer.close()
        await writer.wait_closed()


async def forward(src, dst):
    global last_activity
    try:
        while True:
            data = await asyncio.wait_for(src.read(65536), timeout=3600)
            if not data:
                break
            dst.write(data)
            await dst.drain()
            last_activity = time.time()
    except (TimeoutError, ConnectionResetError, BrokenPipeError, OSError):
        pass
    finally:
        await close_writer(dst)


async def forward_ws_frames(src, dst):
    """Client->Chrome WebSocket pump applying rewrite_create_target. Only
    complete, uncompressed, masked text frames are inspected; fragments, binary
    and control frames pass through byte-for-byte."""
    global last_activity

    async def read(n):
        return await asyncio.wait_for(src.readexactly(n), timeout=3600)

    try:
        while True:
            head = await read(2)
            size = head[1] & 0x7F
            ext = b""
            if size >= 126:
                ext = await read(2 if size == 126 else 8)
                size = int.from_bytes(ext, "big")
            key = await read(4) if head[1] & 0x80 else b""
            payload = await read(size)
            new = None
            if head[0] == 0x81 and key:  # FIN + text, no RSV (compression) bits
                new = rewrite_create_target(ws_mask(payload, key))
            if new is None:
                dst.write(head + ext + key + payload)
            else:
                dst.write(ws_client_text_frame(new))
                log("Target.createTarget -> own window")
            await dst.drain()
            last_activity = time.time()
    except (asyncio.IncompleteReadError, TimeoutError,
            ConnectionResetError, BrokenPipeError, OSError):
        pass
    finally:
        await close_writer(dst)


async def forward_client(src, dst):
    """Client->Chrome pump. With PAGE_PER_WINDOW, a connection whose first HTTP
    request is a WebSocket upgrade (a CDP session) gets forward_ws_frames;
    anything else (/json/version, /json/list) is piped raw. CDP clients open a
    fresh connection for the WebSocket, so only the first request is inspected."""
    if PAGE_PER_WINDOW:
        try:
            head = await asyncio.wait_for(src.readuntil(b"\r\n\r\n"), timeout=3600)
        except asyncio.IncompleteReadError as e:
            head = e.partial  # EOF before a full head: forward() below sees the EOF
        except asyncio.LimitOverrunError:
            head = b""  # oversized head stays buffered for the raw pipe
        except (TimeoutError, OSError):
            await close_writer(dst)
            return
        if is_websocket_upgrade(head):
            dst.write(strip_ws_extensions(head))
            await forward_ws_frames(src, dst)
            return
        dst.write(head)
    await forward(src, dst)


async def proxy_handler(reader, writer):
    global active_connections, last_activity
    active_connections += 1
    last_activity = time.time()
    peer = writer.get_extra_info("peername")
    log(f"Connect {peer} (active={active_connections})")
    try:
        try:
            cr, cw = await asyncio.open_connection("127.0.0.1", BROWSER_PORT)
        except ConnectionRefusedError:
            log("Browser not running — starting...")
            ok = await ensure_browser_running()
            if not ok:
                writer.close()
                await writer.wait_closed()
                return
            cr, cw = await asyncio.open_connection("127.0.0.1", BROWSER_PORT)

        await asyncio.gather(forward_client(reader, cw), forward(cr, writer))
    finally:
        active_connections -= 1
        log(f"Disconnect {peer} (active={active_connections})")


async def idle_monitor():
    global last_activity
    while not shutting_down:
        await asyncio.sleep(30)
        idle_for = time.time() - last_activity
        if idle_for < IDLE_TIMEOUT:
            continue
        if await browser_running():
            log(f"Idle {idle_for:.0f}s — stopping browser")
            await podman("stop", "-t", str(BROWSER_STOP_TIMEOUT), CONTAINER_NAME,
                         timeout=BROWSER_STOP_TIMEOUT + 10)
            last_activity = time.time()


async def main():
    log("Starting up...")

    # Register signal handlers immediately so SIGTERM/SIGINT are caught even
    # during the slow ensure_browser_running() startup polling.
    loop = asyncio.get_running_loop()
    shutdown_event = asyncio.Event()

    async def _handle_signal(sig_name):
        global shutting_down
        if shutting_down:
            return
        shutting_down = True
        log(f"Received {sig_name} — stopping browser")
        await podman("stop", "-t", str(BROWSER_STOP_TIMEOUT), CONTAINER_NAME,
                     timeout=BROWSER_STOP_TIMEOUT + 10)
        shutdown_event.set()

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(
            sig,
            lambda s=sig.name: asyncio.create_task(_handle_signal(s)),
        )

    # Remove any stale browser container (running or stopped) for a clean start.
    # -t 1: only wait 1s for SIGTERM before SIGKILL so rm completes quickly.
    # --ignore: suppress the error when no container exists yet.
    await podman("rm", "-f", "-t", "1", "--ignore", CONTAINER_NAME, timeout=15)

    ok = await ensure_browser_running()
    log(
        f"Browser ready on :{BROWSER_PORT}"
        if ok
        else "Browser start failed (will retry on demand)"
    )

    asyncio.create_task(idle_monitor())

    server = await asyncio.start_server(proxy_handler, "127.0.0.1", PROXY_PORT)
    addr = server.sockets[0].getsockname()
    log(f"Listening on {addr} → :{BROWSER_PORT}")
    log(f"Idle timeout: {IDLE_TIMEOUT}s")
    log(f"Page per window: {'on' if PAGE_PER_WINDOW else 'off'}")

    async with server:
        await shutdown_event.wait()

    log("Shut down.")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
