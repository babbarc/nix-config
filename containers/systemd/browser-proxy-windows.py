#!/usr/bin/env python3
"""Lazy on-demand CDP proxy for the captain's Windows Chrome (WSL interop).

Runs inside a rootless-podman container with host networking (see the
matching browser-proxy-windows.container quadlet), and exposes a stable
localhost CDP endpoint for a Hermes agent in NixOS-WSL:

    PROXY_PORT  (default 3333)  - Hermes points browser.cdp_url here.

Why the reverse tunnel instead of proxying straight to the WSL gateway
----------------------------------------------------------------------
The naive design - launch Windows Chrome with
--remote-debugging-port=9222 --remote-debugging-address=0.0.0.0 and proxy
CDP to http://<wsl-gateway>:9222 - does not work on this host, for two
reasons:

1. Chrome 152 removed the --remote-debugging-address switch entirely
   (verified: the string is absent from chrome.dll; only
   remote-debugging-port / remote-debugging-pipe / remote-debugging-targets
   remain), so Chrome always binds its DevTools HTTP server to 127.0.0.1
   and ignores 0.0.0.0. WSL2 cannot reach Windows's loopback.
2. This WSL2 NAT host's Windows Firewall drops WSL->Windows inbound
   connections (Public profile, no WSL allow rules), and netsh portproxy
   needs elevation, which the interop user does not have.

So the proxy never reaches Chrome over the gateway. Instead it drives a
small Windows-side helper (powershell.exe + an Add-Type C# socket bridge)
that makes OUTBOUND connections back into WSL through WSL2's localhost
forwarding (which works unprivileged and is not firewalled) and bridges
them to Chrome's 127.0.0.1:9222.

Data path per client connection:

    Hermes -> localhost:3333                         (proxy listener)
    proxy  -> powershell.exe Start-Process helper   (detached, on Windows)
    helper -> 127.0.0.1:9222                        (Windows Chrome)
    helper -> 127.0.0.1:PIPE_PORT                   (WSL2 localhost forwarding)
           -> WSL PIPE_PORT                         (proxy pipe listener)
    proxy  accepts on PIPE_PORT and pipes the two ends together.

The WSL gateway IP is resolved at runtime for diagnostics only; nothing in
the data path hardcodes it (the helper reaches WSL via 127.0.0.1, and the
Windows-side powershell.exe/chrome.exe paths are resolved from the standard
Windows locations, not from the gateway address).

Chrome ownership and the single-instance invariant
--------------------------------------------------
The proxy OWNS exactly one Windows Chrome: the instance launched with its
dedicated --user-data-dir marker (CHROME_USER_DATA_DIR). It never touches
the captain's browsing Chrome, whose processes do not carry that marker.

Before launching, the proxy checks - under an asyncio lock, through
powershell.exe - whether (a) its marker Chrome is already running, or
(b) any other Chrome already owns CHROME_PORT. If either is true it REUSES
that Chrome instead of launching a second, so there is never more than one
Chrome with remote debugging on CHROME_PORT. On idle timeout it stops
exactly its marker Chrome (and nothing else). Concurrent CDP requests are
serialized by the same lock, so they cannot spawn duplicates.
"""

import asyncio
import base64
import os
import re
import signal
import subprocess
import time

PROXY_PORT = int(os.environ.get("PROXY_PORT", "3333"))
PIPE_PORT = int(os.environ.get("PIPE_PORT", "9223"))
CHROME_PORT = int(os.environ.get("CHROME_PORT", "9222"))
CHROME_USER_DATA_DIR = os.environ.get(
    "CHROME_USER_DATA_DIR", r"C:\Users\Public\Hermes\ChromeProfile"
)
IDLE_TIMEOUT = int(os.environ.get("IDLE_TIMEOUT", "3600"))

# Linux path the proxy itself invokes for interop (must exist inside the
# container via the /mnt/c bind mount).
POWERSHELL = os.environ.get(
    "POWERSHELL", "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
)
# Windows path used *inside* PowerShell scripts (e.g. Start-Process), since
# those run on Windows and need the native path form.
POWERSHELL_WIN = os.environ.get(
    "POWERSHELL_WIN", r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
)

active_connections = 0
last_activity = time.time()
shutting_down = False
_chrome_lock = asyncio.Lock()
pipe_queue = asyncio.Queue()


def log(msg):
    print(f"[proxy] {msg}", flush=True)


def ps_quote(s: str) -> str:
    """Quote a value as a PowerShell single-quoted string literal."""
    return "'" + s.replace("'", "''") + "'"


def ps_encode(script: str) -> str:
    """Encode a PowerShell script for -EncodedCommand (UTF-16LE base64)."""
    return base64.b64encode(script.encode("utf-16-le")).decode()


def build(template: str, **kwargs) -> str:
    """Fill __PLACEHOLDER__ slots in a raw PowerShell/C# template."""
    for key, value in kwargs.items():
        template = template.replace(f"__{key}__", str(value))
    return template


# Windows-side helper: bridges Windows Chrome's loopback CDP port to a WSL
# ingress port via WSL2 localhost forwarding. Connects Chrome first so a
# failed Chrome connect never creates a dangling ingress connection.
HELPER_PS = r'''
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net.Sockets;
using System.Threading;
public static class CdpBridge {
  static void Copy(Stream src, Stream dst) {
    byte[] buf = new byte[65536];
    try {
      int n;
      while ((n = src.Read(buf, 0, buf.Length)) > 0) {
        dst.Write(buf, 0, n);
        dst.Flush();
      }
    } catch (Exception) {}
    try { dst.Close(); } catch (Exception) {}
  }
  public static void Run(int chromePort, int pipePort) {
    var chrome = new TcpClient();
    chrome.Connect("127.0.0.1", chromePort);
    var pipe = new TcpClient();
    pipe.Connect("127.0.0.1", pipePort);
    chrome.NoDelay = true;
    pipe.NoDelay = true;
    var a = chrome.GetStream();
    var b = pipe.GetStream();
    var t1 = new Thread(() => Copy(a, b));
    var t2 = new Thread(() => Copy(b, a));
    t1.IsBackground = true;
    t2.IsBackground = true;
    t1.Start();
    t2.Start();
    t1.Join();
    t2.Join();
  }
}
'@
[CdpBridge]::Run(__CHROME_PORT__, __PIPE_PORT__)
'''

CHROME_LAUNCH_PS = r'''
$chromeCandidates = @(
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
)
$chrome = $chromeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { Write-Output 'CHROME_NOT_FOUND'; exit 1 }
$profile = __PROFILE__
$args = @(
  '--remote-debugging-port=__CHROME_PORT__',
  '--remote-debugging-address=0.0.0.0',
  "--user-data-dir=$profile",
  '--no-first-run',
  '--no-default-browser-check',
  '--remote-allow-origins=*'
)
$p = Start-Process -FilePath $chrome -ArgumentList $args -PassThru
Write-Output $p.Id
'''

# Single status probe that encodes the ownership state machine. Output is one
# of: NONE, OURS_STARTING, OURS, FOREIGN, PORT_TAKEN.
#
#   NONE           - no listener on CHROME_PORT and no marker Chrome process.
#   OURS_STARTING  - marker Chrome process exists but is not listening yet.
#   OURS           - marker Chrome owns the CHROME_PORT listener (ready).
#   FOREIGN        - a chrome.exe WITHOUT our marker owns CHROME_PORT.
#   PORT_TAKEN     - a non-chrome process owns CHROME_PORT.
CHROME_STATUS_PS = r'''
$port = __CHROME_PORT__
$dir = __PROFILE__
$listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($listener) {
  $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $($listener.OwningProcess)" -ErrorAction SilentlyContinue
  $cmd = $owner.CommandLine
  if ($owner.Name -eq 'chrome.exe' -and $cmd -and $cmd.Contains($dir)) {
    Write-Output 'OURS'
  } elseif ($owner.Name -eq 'chrome.exe') {
    Write-Output 'FOREIGN'
  } else {
    Write-Output 'PORT_TAKEN'
  }
} else {
  $mine = Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($dir) }
  if ($mine) { Write-Output 'OURS_STARTING' } else { Write-Output 'NONE' }
}
'''

STOP_CHROME_PS = r'''
$dir = __PROFILE__
Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine.Contains($dir) } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Write-Output 'STOPPED'
'''


async def powershell(script: str, timeout: float = 60):
    """Run a PowerShell script via WSL interop. Returns (stdout, stderr)."""
    try:
        proc = await asyncio.create_subprocess_exec(
            POWERSHELL,
            "-NoProfile",
            "-NonInteractive",
            "-EncodedCommand",
            ps_encode(script),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except OSError as exc:
        return "", f"powershell launch failed: {exc}"
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        return stdout.decode(errors="replace"), stderr.decode(errors="replace")
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return "", f"powershell timed out after {timeout}s"


async def chrome_status() -> str:
    stdout, _ = await powershell(
        build(
            CHROME_STATUS_PS,
            PROFILE=ps_quote(CHROME_USER_DATA_DIR),
            CHROME_PORT=CHROME_PORT,
        ),
        timeout=30,
    )
    for status in ("NONE", "OURS_STARTING", "OURS", "FOREIGN", "PORT_TAKEN"):
        if status in stdout:
            return status
    return "NONE"


async def launch_chrome() -> bool:
    stdout, _ = await powershell(
        build(
            CHROME_LAUNCH_PS,
            PROFILE=ps_quote(CHROME_USER_DATA_DIR),
            CHROME_PORT=CHROME_PORT,
        ),
        timeout=60,
    )
    if "CHROME_NOT_FOUND" in stdout:
        log("Windows Chrome executable not found")
        return False
    pid = stdout.strip().splitlines()[-1] if stdout.strip() else "?"
    log(f"Launched Windows Chrome (pid={pid}, port={CHROME_PORT})")
    return True


async def ensure_chrome_running() -> bool:
    """Make a Chrome with remote debugging on CHROME_PORT available.

    Runs under _chrome_lock so concurrent CDP requests serialize and can
    never launch two Chromes. Reuses an existing Chrome (ours by marker, or
    a foreign Chrome already on the port) rather than launching a duplicate.
    """
    async with _chrome_lock:
        launched = False
        stuck_starting = 0
        for _ in range(60):
            status = await chrome_status()
            if status == "OURS":
                return True
            if status == "FOREIGN":
                # Another Chrome already owns the port. Reuse it and do NOT
                # stop it on idle - it is not ours. If we already launched a
                # marker Chrome that lost the port race, remove that useless
                # duplicate so exactly one Chrome remains.
                if launched:
                    await stop_chrome()
                log(f"Foreign Chrome already owns CDP port {CHROME_PORT} - reusing it")
                return True
            if status == "PORT_TAKEN":
                log(f"CDP port {CHROME_PORT} is held by a non-Chrome process - refusing to start")
                return False
            if status == "NONE":
                if launched:
                    log("Windows Chrome exited unexpectedly - relaunching")
                    launched = False
                    stuck_starting = 0
                if not await launch_chrome():
                    return False
                launched = True
                stuck_starting = 0
            elif status == "OURS_STARTING":
                stuck_starting += 1
                if stuck_starting > 20:
                    # Our marker Chrome exists but never bound the port (a
                    # crashed/leftover instance). Kill it and relaunch clean.
                    log("Chrome stuck starting - killing our instance and relaunching")
                    await stop_chrome()
                    launched = False
                    stuck_starting = 0
            await asyncio.sleep(0.5)
        log("Windows Chrome did not become ready in time")
        return False


async def stop_chrome() -> None:
    """Stop exactly our marker Chrome; never touches the captain's Chrome."""
    await powershell(
        build(STOP_CHROME_PS, PROFILE=ps_quote(CHROME_USER_DATA_DIR)), timeout=60
    )


async def launch_helper() -> None:
    """Detached, per-connection Windows helper that bridges Chrome -> WSL."""
    helper = build(HELPER_PS, CHROME_PORT=CHROME_PORT, PIPE_PORT=PIPE_PORT)
    helper_b64 = ps_encode(helper)
    launcher = (
        "$p = Start-Process -FilePath "
        + ps_quote(POWERSHELL_WIN)
        + " -ArgumentList @('-NoProfile','-NonInteractive','-WindowStyle','Hidden',"
        + "'-EncodedCommand','"
        + helper_b64
        + "') -WindowStyle Hidden -PassThru; Write-Output $p.Id"
    )
    stdout, _ = await powershell(launcher, timeout=30)
    log(f"helper pid={stdout.strip()}")


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


async def pipe_accept_handler(reader, writer):
    # Every accepted connection here is a helper's reverse pipe. Hand it to a
    # waiting client; pairing order is irrelevant because every pipe leads to
    # an equivalent Chrome connection.
    await pipe_queue.put((reader, writer))


async def proxy_handler(reader, writer):
    global active_connections, last_activity
    active_connections += 1
    last_activity = time.time()
    peer = writer.get_extra_info("peername")
    log(f"Connect {peer} (active={active_connections})")
    try:
        if not await ensure_chrome_running():
            log("Windows Chrome unavailable - closing client")
            writer.close()
            await writer.wait_closed()
            return

        await launch_helper()
        try:
            pipe_reader, pipe_writer = await asyncio.wait_for(pipe_queue.get(), timeout=15)
        except asyncio.TimeoutError:
            log("Helper did not connect a reverse pipe - closing client")
            writer.close()
            await writer.wait_closed()
            return

        await asyncio.gather(forward(reader, pipe_writer), forward(pipe_reader, writer))
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
        # Only stop OUR marker Chrome. A foreign Chrome we may be reusing is
        # left untouched (status FOREIGN / PORT_TAKEN / NONE -> no stop).
        status = await chrome_status()
        if status in ("OURS", "OURS_STARTING"):
            log(f"Idle {idle_for:.0f}s - stopping Windows Chrome")
            await stop_chrome()
            last_activity = time.time()


def gateway_from_proc():
    """Fallback gateway resolution from /proc/net/route (no ip binary)."""
    try:
        with open("/proc/net/route") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 3 and parts[1] == "00000000":
                    raw = bytes.fromhex(parts[2])
                    if len(raw) == 4:
                        return ".".join(str(b) for b in reversed(raw))
    except Exception:
        pass
    return None


def get_wsl_gateway() -> str:
    """Resolve the WSL gateway at runtime. Diagnostics only - never a data path."""
    env = os.environ.get("WSL_GATEWAY")
    if env:
        return env
    try:
        out = subprocess.run(
            ["ip", "route", "show", "default"], capture_output=True, text=True, timeout=5
        ).stdout
        match = re.search(r"\bvia\s+(\S+)", out)
        if match:
            return match.group(1)
    except Exception:
        pass
    return gateway_from_proc() or "unknown"


async def main():
    global shutting_down
    log("Starting up...")
    log(f"WSL gateway (diagnostics only): {get_wsl_gateway()}")

    loop = asyncio.get_running_loop()
    shutdown_event = asyncio.Event()

    async def handle_signal(sig_name):
        global shutting_down
        if shutting_down:
            return
        shutting_down = True
        log(f"Received {sig_name} - stopping Windows Chrome")
        await stop_chrome()
        shutdown_event.set()

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(
            sig, lambda s=sig.name: asyncio.create_task(handle_signal(s))
        )

    pipe_server = await asyncio.start_server(pipe_accept_handler, "0.0.0.0", PIPE_PORT)
    log(f"Pipe ingress on 0.0.0.0:{PIPE_PORT} (Windows helper connects here)")

    asyncio.create_task(idle_monitor())

    server = await asyncio.start_server(proxy_handler, "127.0.0.1", PROXY_PORT)
    addr = server.sockets[0].getsockname()
    log(f"Listening on {addr} -> Windows Chrome :{CHROME_PORT}")
    log(f"Idle timeout: {IDLE_TIMEOUT}s")

    async with server, pipe_server:
        await shutdown_event.wait()

    log("Shut down.")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
