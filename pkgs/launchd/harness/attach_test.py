#!/usr/bin/env python3
"""Drive `<pull> session attach NAME` in a real PTY: type, check ls shows it attached,
detach with ctrl-\\, then attach again and check the session-ended path via kill."""
import os, pty, select, subprocess, sys, time

exe = sys.argv[1:]  # e.g. ['/path/launchd-harness'] or ['pull']
name = os.environ.get("SESSION", "sh1")

def read_until(fd, needle, timeout=5.0):
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            if needle in buf:
                return buf, True
    return buf, False

def attach():
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(exe[0], exe + ["session", "attach", name])
    return pid, fd

pid, fd = attach()
time.sleep(0.5)
os.write(fd, b"echo attached-$((40+2))\r")
out, ok = read_until(fd, b"attached-42")
print("typed+echoed:", ok)
ls = subprocess.run(exe + ["session", "ls"], capture_output=True, text=True).stdout
print("ls while attached:", [l for l in ls.splitlines() if l.startswith(name)])
os.write(fd, b"\x1c")
out, ok = read_until(fd, b"[detached from " + name.encode() + b"]")
print("detached msg:", ok)
_, status = os.waitpid(pid, 0)
print("attach exit:", os.waitstatus_to_exitcode(status))

pid, fd = attach()
out, ok = read_until(fd, b"attached-42")  # redraw shows the earlier screen
print("redraw on reattach:", ok)
subprocess.run(exe + ["session", "kill", name], check=True)
out, ok = read_until(fd, b"ended]")
print("ended msg:", ok, repr(out[-80:]))
_, status = os.waitpid(pid, 0)
print("attach exit:", os.waitstatus_to_exitcode(status))
