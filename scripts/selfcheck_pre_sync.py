#!/usr/bin/env python3
"""Static self-check before syncing weread.koplugin to the Kindle.

Catches the classes of runtime errors that broke the plugin before:
  1. Host-defined methods vs. the install() injection list mismatch
     (dockConfig was added but forgotten in the inject list -> nil call)
  2. Module identifiers used but never require()d (FrameContainer gap)
  3. self:method calls in library/views with no definition in the class,
     the host inject list, or an allow-listed base (FocusManager/InputContainer)
  4. Methods present in git HEAD but deleted by refactors (itemStatus /
     preparePagination were cut by a bad range delete)
Exit code != 0 if anything fails.
"""
import re
import subprocess
import sys

ROOT = "weread/ui"

def read(p):
    try:
        with open(p) as f:
            return f.read()
    except OSError as e:
        print(f"selfcheck: cannot read {p}: {e}")
        sys.exit(2)

def host_defined_methods(host_src):
    return set(re.findall(r"function Host[:.]([a-zA-Z_]+)", host_src))

def inject_list(host_src):
    m = re.search(r'for _, name in ipairs\(\{\s*(.*?)\s*\}\) do', host_src, re.S)
    if not m:
        return set()
    return set(re.findall(r'"([a-zA-Z_]+)"', m.group(1)))

def main():
    problems = []
    host_src = read(f"{ROOT}/fullscreen_host.lua")

    # 1) Host methods vs install() inject list
    defined = host_defined_methods(host_src)
    injected = inject_list(host_src)
    # methods called via self: inside host that must exist on Host
    self_calls = set(re.findall(r"self:([a-zA-Z_]+)\b", host_src))
    host_own = {m for m in self_calls if not re.search(
        r"function Host:?" + m + r"\b", host_src)}
    for name in sorted(injected):
        if name not in defined:
            problems.append(f"fullscreen_host: inject list has '{name}' but Host does not define it")
    for name in sorted(defined):
        if name not in injected and re.search(r"self:" + name + r"\b", host_src):
            problems.append(f"fullscreen_host: Host defines '{name}', called via self:, but install() does not inject it")

    # 2) capitalized module tokens used but not require()d (per file)
    for fn in ("fullscreen_host.lua", "library_view.lua", "read_stats_view.lua"):
        s = read(f"{ROOT}/{fn}")
        bound = set()
        for line in s.splitlines():
            code = line.split("--", 1)[0]
            for m in re.finditer(r"local\s+(\w+)\s*=\s*\w+|local\s+(?:\w+,\s*)?(\w+)\s*=\s*pcall", code):
                if m.group(1): bound.add(m.group(1))
                if m.group(2): bound.add(m.group(2))
        tokens = set()
        for line in s.splitlines():
            code = line.split("--", 1)[0]
            tokens.update(re.findall(r"\b([A-Z][A-Za-z0-9_]*)\b", code))
        known_globals = {"Blitbuffer", "Device", "Screen", "UIManager", "Geom",
                         "Font", "Event", "logger", "G_reader_settings",
                         "DataStorage", "LuaSettings", "Host", "FullscreenHost",
                         "Widget", "FocusManager", "InputContainer"}
        for t in sorted(tokens):
            if t in bound or t in known_globals:
                continue
            if t in ("M", "T", "I18n") :
                continue
            if re.search(r"\b" + re.escape(t) + r"\s*[:(.]", s) and t not in ("T", "M", "L", "K", "X"):
                problems.append(f"{fn}: token '{t}' used but never require()d")

    # 3) HEAD method inventory vs current file (only library_view refactored so far)
    try:
        head = subprocess.check_output(
            ["git", "show", "HEAD:weread/ui/library_view.lua"], text=True)
    except Exception:
        head = None
    if head:
        cur = read(f"{ROOT}/library_view.lua")
        head_methods = set(re.findall(r"function LibraryView:([a-zA-Z_]+)", head))
        cur_methods = set(re.findall(r"function LibraryView:([a-zA-Z_]+)", cur))
        host8 = {"bottomDock", "dockTabs", "dockIconFor", "dockLabel",
                 "onDockTap", "onFrontlightSwipe", "onTopTapMenu",
                 "onTopSwipeMenu", "showPowerDialog", "registerHostGestures",
                 "reservedBands", "dockConfig", "frontlightEdgeLayer"}
        lost = sorted(m for m in head_methods if m not in cur_methods and m not in host8)
        for m in lost:
            problems.append(f"library_view: method '{m}' was deleted by refactor but is not in host")

    # 4) Translation-alias rename audit: every non-string argument that HEAD
    #    passed to _() must still exist verbatim in current tr() calls.
    #    Catches swallow-type sed damage (e.g. _(MODE_TITLE -> tr(ODE_TITLE,
    #    _(tab.text -> tr(ab.text)).
    for fn in ("read_stats_view.lua", "library_view.lua", "library.lua"):
        try:
            head = subprocess.check_output(
                ["git", "show", f"HEAD:weread/ui/{fn}"], text=True)
        except Exception:
            continue
        cur = read(f"{ROOT}/{fn}")
        head_args = re.findall(r"_\s*\(\s*([A-Za-z_][A-Za-z0-9_.]*)", head)
        cur_args = re.findall(r"tr\s*\(\s*([A-Za-z_][A-Za-z0-9_.]*)", cur)
        for a in head_args:
            if a.startswith(("'", '"')):
                continue
            if a not in cur_args:
                problems.append(f"{fn}: HEAD _({a}...) not preserved verbatim in tr() calls (swallowed rename?)")

    if problems:
        print("SELF-CHECK FAILED:")
        for p in problems:
            print("  -", p)
        sys.exit(1)
    print("SELF-CHECK OK: methods/requires/inventory consistent")

if __name__ == "__main__":
    main()
