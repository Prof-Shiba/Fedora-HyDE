from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
from typing import Any, List


DEBUG = "--debug" in sys.argv[1:] or os.environ.get("HYPR_ALTAB_DEBUG", "0") == "1"
NOTIFY = os.environ.get("HYPR_ALTAB_NOTIFY", "1") != "0"
if "--notify" in sys.argv[1:]:
    NOTIFY = True
if "--no-notify" in sys.argv[1:]:
    NOTIFY = False
PREV = "--prev" in sys.argv[1:]
STATE_DIR = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "hypr-altab")
STATE_FILE = os.path.join(STATE_DIR, "state")
PREVIEW_DIR = os.path.join(STATE_DIR, "previews")
_PREVIEW_NEXT_ENV = os.environ.get("HYPR_ALTAB_PREVIEW_NEXT")
PREVIEW_NEXT = int(_PREVIEW_NEXT_ENV) if _PREVIEW_NEXT_ENV is not None else -1
HIS = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
XDG_RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
SOCKET_PATH = os.path.join(XDG_RUNTIME_DIR, "hypr", HIS, ".socket.sock")


def log(msg: str) -> None:
    if DEBUG:
        print(f"[hypr-altab] {msg}", file=sys.stderr, flush=True)


def run(cmd: List[str]) -> subprocess.CompletedProcess[str]:
    log(f"run: {' '.join(cmd)}")
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if DEBUG and (proc.stdout or proc.stderr):
        if proc.stdout:
            log(f"stdout: {proc.stdout.strip()}")
        if proc.stderr:
            log(f"stderr: {proc.stderr.strip()}")
    return proc


def hyprctl_raw(command: str) -> str:
    if not HIS:
        log("HYPRLAND_INSTANCE_SIGNATURE not set")
        return ""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.connect(SOCKET_PATH)
            sock.sendall(command.encode("utf-8"))
            sock.shutdown(socket.SHUT_WR)
            data = sock.recv(10_000_000)
            return data.decode("utf-8", errors="replace")
    except OSError as exc:
        log(f"socket error: {exc}")
        return ""


def hyprctl_json(command: str) -> Any:
    raw = hyprctl_raw(command)
    if not raw:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return None


def focus_addr(addr: str) -> None:
    if not addr:
        log("focus_addr called with empty address")
        return
    hyprctl_raw(f"dispatch focuswindow address:{addr}")


def preview_path(addr: str) -> str:
    safe = addr.replace("0x", "").replace(":", "")
    return os.path.join(PREVIEW_DIR, f"{safe}.png")


def capture_preview(addr: str) -> None:
    if not addr:
        return
    if not shutil.which("grimblast"):
        return
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    path = preview_path(addr)
    run(["grimblast", "save", "active", path])


def read_state() -> dict[str, Any]:
    if not os.path.exists(STATE_FILE):
        return {}
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {}


def build_notify(addr: str) -> tuple[str, str, str | None]:
    clients = hyprctl_json("j/clients")
    if not isinstance(clients, list):
        return "", "", None
    match = next((c for c in clients if c.get("address") == addr), None)
    if not match:
        return "", "", None
    title = match.get("title") or "(untitled)"
    klass = match.get("class") or "unknown"
    ws = (match.get("workspace") or {}).get("name") or "?"
    body = f"{title}\n{klass}  •  {ws}"
    icon = preview_path(addr)
    return klass, body, icon if os.path.exists(icon) else None


def notify_preview_pair(current_addr: str, next_addrs: List[str]) -> None:
    if not shutil.which("notify-send"):
        return
    for offset, addr in enumerate(next_addrs, start=1):
        title, body, icon = build_notify(addr)
        if title:
            cmd = ["notify-send", title, body, "-t", "1500", "-r", str(6 + offset)]
            if icon:
                cmd.extend(["-i", icon])
            run(cmd)
    title, body, icon = build_notify(current_addr)
    if title:
        cmd = ["notify-send", title, body, "-t", "2000", "-r", "6"]
        if icon:
            cmd.extend(["-i", icon])
        run(cmd)


def write_state(state: dict[str, Any]) -> None:
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(STATE_FILE, "w", encoding="utf-8") as handle:
        json.dump(state, handle)


def clear_state() -> None:
    try:
        os.remove(STATE_FILE)
    except OSError:
        pass


def get_active_address() -> str:
    active = hyprctl_json("j/activewindow")
    if isinstance(active, dict):
        return active.get("address") or ""
    return ""


def build_history() -> List[str]:
    clients = hyprctl_json("j/clients")
    if not isinstance(clients, list):
        return []
    filtered = [
        c
        for c in clients
        if c.get("mapped") is True and ((c.get("hidden") is False) or (c.get("grouped") or []))
    ]
    ordered = sorted(
        [c for c in filtered if isinstance(c.get("focusHistoryID"), int)],
        key=lambda c: c.get("focusHistoryID"),
    )
    return [c.get("address") for c in ordered if c.get("address")]


def main() -> int:
    if "--cancel" in sys.argv[1:]:
        clear_state()
        return 0
    if "--apply" in sys.argv[1:]:
        state = read_state()
        addr = state.get("addr", "")
        log(f"apply: target={addr}")
        if addr:
            focus_addr(addr)
            capture_preview(addr)
        clear_state()
        return 0

    state = read_state()
    history = state.get("list") if isinstance(state.get("list"), list) else None
    if not history:
        history = build_history()
        if len(history) < 2:
            log("not enough windows in focus history")
            return 0

    if PREV:
        idx = int(state.get("idx", 0)) - 1
        if idx <= 0:
            idx = len(history) - 1
    else:
        idx = int(state.get("idx", 0)) + 1
        if idx >= len(history):
            idx = 1

    target = history[idx]
    next_targets: List[str] = []
    preview_count = PREVIEW_NEXT if PREVIEW_NEXT > 0 else max(1, len(history) - 1)
    if len(history) > 1 and preview_count > 0:
        for step in range(1, preview_count + 1):
            if PREV:
                next_idx = idx - step
                if next_idx <= 0:
                    next_idx = len(history) - 1 - ((step - idx) % max(1, len(history) - 1))
            else:
                next_idx = idx + step
                if next_idx >= len(history):
                    next_idx = 1 + (next_idx - len(history)) % max(1, len(history) - 1)
            next_targets.append(history[next_idx])
    log(f"preview: idx={idx} target={target} count={len(history)} active={get_active_address()}")
    write_state({"idx": idx, "addr": target, "list": history})
    if NOTIFY:
        notify_preview_pair(target, next_targets)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
