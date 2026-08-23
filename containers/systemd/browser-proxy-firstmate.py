#!/usr/bin/env python3
"""Lazy on-demand browser proxy — listener on PROXY_PORT, Chromium on BROWSER_PORT
(default 3333/3334). Designed to run in a separate container with host networking.
Starts/stops Chromium container on-demand, proxies CDP traffic through.
"""

import asyncio
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
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        log(f"podman {args[0]} timed out after {timeout}s")
        return ""


async def browser_running():
    out = await podman("ps", "--filter", f"name=^{CONTAINER_NAME}$", "--format", "{{.Status}}", timeout=10)
    return "Up" in out


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
                "--lang=en-US,en",
                "--use-angle=vulkan",
                "--enable-features=Vulkan",
                "--force-color-profile=srgb",
                "--num-raster-threads=4",
                "--no-first-run",
                "--no-default-browser-check",
                timeout=30,
            )

        for _ in range(30):
            try:
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{BROWSER_PORT}/json/version", timeout=2
                ):
                    return True
            except Exception:
                await asyncio.sleep(0.5)
        return False


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
            except (asyncio.TimeoutError, ConnectionResetError, BrokenPipeError, OSError):
                pass
            finally:
                try:
                    dst.close()
                    await dst.wait_closed()
                except Exception:
                    pass

        await asyncio.gather(forward(reader, cw), forward(cr, writer))
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
    global shutting_down
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

    async with server:
        await shutdown_event.wait()

    log("Shut down.")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
