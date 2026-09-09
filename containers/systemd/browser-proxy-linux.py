#!/usr/bin/env python3
"""Lazy on-demand browser proxy for host Chrome on alps (Linux).

Runs directly as a systemd --user service for the `hermes` user (see
modules/dev/browser-proxy-linux.nix) and exposes a stable localhost CDP
endpoint for the Hermes agent:

    PROXY_PORT   (default 3333) - Hermes points browser.cdp_url here.
    BROWSER_PORT (default 3334) - Chrome's own DevTools port (loopback).

This is the direct-install replacement for the joy-stack
browser-proxy.container + hermes-browser image pair: the same lazy
proxy/forward/idle-stop behaviour as the overlay's browser-proxy.py, but it
launches Google Chrome installed on the Arch host (not a sidecar container)
with the same stealth flags the fleet relies on - clean UA (no
"HeadlessChrome" leak), --headless=new, WebGL/Vulkan GPU, and a persistent
profile. No podman, no container image, no Windows interop.

Chrome ownership and the single-instance invariant
--------------------------------------------------
The proxy owns exactly ONE Chrome: the instance launched with the dedicated
--user-data-dir marker (CHROME_USER_DATA_DIR). It never touches the
captain's browsing Chrome, whose processes do not carry that marker. If the
CDP port already answers, the proxy reuses the running Chrome rather than
launching a second; on idle timeout it stops only the Chrome it launched
(via its recorded PID). Concurrent CDP requests are serialized by a lock so
they cannot spawn duplicates.

Downloads layout (keeps the joy-brain skills' documented paths true)
--------------------------------------------------------------------
The container mounted the shared `hermes-browser-data` volume at the agent's
`~/chrome-downloads/` AND at Chrome's `--user-data-dir`, so the agent read
browser downloads at `~/chrome-downloads/downloads/` (see joy-brain skills
system/hermes-infrastructure and software/operate-browser). Running Chrome
as hermes on the host, the profile root IS `~/chrome-downloads/` and
downloads land at `~/chrome-downloads/downloads/` - the same paths, without
a volume and without the container's cross-uid permission dance (Chrome now
runs as hermes itself, not uid 999).

Chrome 152 removed --remote-debugging-address, so Chrome binds its DevTools
server to 127.0.0.1 only. That is fine here: the proxy and Chrome are on the
same host, and the proxy connects to 127.0.0.1:BROWSER_PORT directly.
"""

import asyncio
import os
import re
import signal
import subprocess
import time
import urllib.request

PROXY_PORT = int(os.environ.get("PROXY_PORT", "3333"))
BROWSER_PORT = int(os.environ.get("BROWSER_PORT", "3334"))
CHROME_BIN = os.environ.get("CHROME_BIN", "google-chrome-stable")
# Chrome profile root == the agent's ~/chrome-downloads/ (see module docstring).
CHROME_USER_DATA_DIR = os.environ.get(
    "CHROME_USER_DATA_DIR", os.path.expanduser("~/chrome-downloads")
)
CHROME_DOWNLOAD_DIR = os.environ.get(
    "CHROME_DOWNLOAD_DIR", os.path.join(CHROME_USER_DATA_DIR, "downloads")
)
IDLE_TIMEOUT = int(os.environ.get("IDLE_TIMEOUT", "3600"))
BROWSER_STOP_TIMEOUT = 5

active_connections = 0
last_activity = time.time()
shutting_down = False
_browser_lock = asyncio.Lock()
_browser_proc = None


def log(msg):
    print(f"[proxy] {msg}", flush=True)


def _chrome_version():
    try:
        out = subprocess.run(
            [CHROME_BIN, "--version"], capture_output=True, text=True, timeout=5
        ).stdout
        m = re.search(r"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+", out)
        if m:
            return m.group(0)
    except Exception:
        pass
    return None


def _clean_ua():
    """Build a clean UA from the installed Chrome version so "HeadlessChrome"
    never leaks into navigator.userAgent (the container's
    docker-entrypoint-browser.sh does the same)."""
    version = _chrome_version()
    if not version:
        return None
    return (
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
        f"(KHTML, like Gecko) Chrome/{version} Safari/537.36"
    )


async def browser_running():
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{BROWSER_PORT}/json/version", timeout=2
        ):
            return True
    except Exception:
        return False


async def launch_chrome():
    global _browser_proc
    args = [
        CHROME_BIN,
        "--headless=new",
        f"--user-data-dir={CHROME_USER_DATA_DIR}",
        f"--download-default-directory={CHROME_DOWNLOAD_DIR}",
        "--disable-blink-features=AutomationControlled",
        f"--remote-debugging-port={BROWSER_PORT}",
        "--remote-allow-origins=*",
        "--disable-dev-shm-usage",
        "--window-size=1920,1080",
        "--lang=en-US,en",
        "--use-angle=vulkan",
        "--enable-features=Vulkan",
        "--force-color-profile=srgb",
        "--num-raster-threads=4",
        "--no-first-run",
        "--no-default-browser-check",
    ]
    ua = _clean_ua()
    if ua:
        args.append(f"--user-agent={ua}")
    try:
        # Keep a reference to the process object so its returncode can be read
        # later (avoids a zombie) and so idle-stop can signal exactly this PID.
        _browser_proc = subprocess.Popen(
            args,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        log(f"Launched host Chrome (pid={_browser_proc.pid}, port={BROWSER_PORT})")
        return True
    except OSError as exc:
        log(f"Chrome launch failed: {exc}")
        return False


async def ensure_browser_running():
    async with _browser_lock:
        if await browser_running():
            return True
        if not await launch_chrome():
            return False
        for _ in range(30):
            try:
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{BROWSER_PORT}/json/version", timeout=2
                ):
                    return True
            except Exception:
                await asyncio.sleep(0.5)
        return False


async def stop_browser():
    global _browser_proc
    if _browser_proc is not None and _browser_proc.poll() is None:
        log(f"Stopping host Chrome (pid={_browser_proc.pid})")
        _browser_proc.terminate()
        try:
            _browser_proc.wait(timeout=BROWSER_STOP_TIMEOUT)
        except subprocess.TimeoutExpired:
            _browser_proc.kill()
            _browser_proc.wait()
    _browser_proc = None


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


async def proxy_handler(reader, writer):
    global active_connections, last_activity
    active_connections += 1
    last_activity = time.time()
    peer = writer.get_extra_info("peername")
    log(f"Connect {peer} (active={active_connections})")
    try:
        try:
            cr, cw = await asyncio.open_connection("127.0.0.1", BROWSER_PORT)
        except (ConnectionRefusedError, OSError):
            log("Browser not running - starting...")
            if not await ensure_browser_running():
                writer.close()
                await writer.wait_closed()
                return
            cr, cw = await asyncio.open_connection("127.0.0.1", BROWSER_PORT)

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
            log(f"Idle {idle_for:.0f}s - stopping browser")
            await stop_browser()
            last_activity = time.time()


async def main():
    global shutting_down
    log("Starting up...")

    loop = asyncio.get_running_loop()
    shutdown_event = asyncio.Event()

    async def handle_signal(sig_name):
        global shutting_down
        if shutting_down:
            return
        shutting_down = True
        log(f"Received {sig_name} - stopping browser")
        await stop_browser()
        shutdown_event.set()

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(
            sig, lambda s=sig.name: asyncio.create_task(handle_signal(s))
        )

    # Chrome is started lazily on the first CDP connection, matching the
    # container's on-demand behaviour (nothing to clean up at boot).
    asyncio.create_task(idle_monitor())

    server = await asyncio.start_server(proxy_handler, "127.0.0.1", PROXY_PORT)
    addr = server.sockets[0].getsockname()
    log(f"Listening on {addr} -> host Chrome :{BROWSER_PORT}")
    log(f"Idle timeout: {IDLE_TIMEOUT}s")

    async with server:
        await shutdown_event.wait()

    log("Shut down.")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
