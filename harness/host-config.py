#!/usr/bin/env python3
# host-config.py — idempotently merge contai's keys into VSCodium's JSONC config
# files (argv.json, settings.json) WITHOUT clobbering the user's other settings
# or comments. Zero third-party dependencies: stdlib only, so it stays auditable
# and needs no install step.
#
# Why it exists: start.sh must leave the desktop editor fully configured with no
# manual copy-paste, and must stay correct after `docker compose down -v` (the
# connection token regenerates) or a VSCodium update. So the config is *written*,
# idempotently, on every run — never just printed.
#
# Usage:
#   host-config.py enable-proposed-api <extId> [--argv PATH]
#   host-config.py set-host --name N --host H --port P --token T \
#                           --folder-name FN --folder-path FP [--settings PATH]
#   host-config.py paths        # print the resolved argv.json / settings.json paths
#
# A no-op (config already current) exits 0; only real failures exit non-zero.

import argparse
import json
import os
import re
import sys


# ---- default file locations per OS ----

def default_argv_path():
    # Same on Linux, macOS, and Windows for VSCodium (OSS).
    return os.path.expanduser(os.path.join('~', '.vscode-oss', 'argv.json'))


def default_settings_path():
    if sys.platform == 'darwin':
        base = os.path.expanduser('~/Library/Application Support')
    elif sys.platform.startswith('win'):
        base = os.environ.get('APPDATA', os.path.expanduser('~'))
    else:
        base = os.environ.get('XDG_CONFIG_HOME', os.path.expanduser('~/.config'))
    return os.path.join(base, 'VSCodium', 'User', 'settings.json')


# ---- JSONC helpers: comment/trailing-comma tolerant, comment-preserving edits ----

def _str_end(s, i):
    # s[i] == '"'; return the index just past the closing quote.
    j, n = i + 1, len(s)
    while j < n:
        c = s[j]
        if c == '\\':
            j += 2
            continue
        if c == '"':
            return j + 1
        j += 1
    return n


def _skip_ws_comments(s, i):
    n = len(s)
    while i < n:
        c = s[i]
        if c in ' \t\r\n':
            i += 1
        elif c == '/' and i + 1 < n and s[i + 1] == '/':
            k = s.find('\n', i)
            i = n if k < 0 else k
        elif c == '/' and i + 1 < n and s[i + 1] == '*':
            k = s.find('*/', i + 2)
            i = n if k < 0 else k + 2
        else:
            break
    return i


def _value_end(s, i):
    # i is at the first char of a JSON value; return the index just past it.
    n = len(s)
    c = s[i]
    if c == '"':
        return _str_end(s, i)
    if c in '{[':
        depth, j, in_str = 0, i, False
        while j < n:
            ch = s[j]
            if in_str:
                if ch == '\\':
                    j += 2
                    continue
                if ch == '"':
                    in_str = False
                j += 1
                continue
            if ch == '"':
                in_str = True
            elif ch == '/' and j + 1 < n and s[j + 1] == '/':
                k = s.find('\n', j)
                j = n if k < 0 else k
                continue
            elif ch == '/' and j + 1 < n and s[j + 1] == '*':
                k = s.find('*/', j + 2)
                j = n if k < 0 else k + 2
                continue
            elif ch in '{[':
                depth += 1
            elif ch in '}]':
                depth -= 1
                if depth == 0:
                    return j + 1
            j += 1
        return n
    # primitive (number/true/false/null)
    j = i
    while j < n and s[j] not in ',}]' and s[j] not in ' \t\r\n':
        j += 1
    return j


def _find_root_open(s):
    i = _skip_ws_comments(s, 0)
    return i if i < len(s) and s[i] == '{' else -1


def _find_top_key(s, key):
    # Return (value_start, value_end) for a top-level "key", else (None, None).
    open_i = _find_root_open(s)
    if open_i < 0:
        return None, None
    i, n = open_i + 1, len(s)
    while True:
        i = _skip_ws_comments(s, i)
        if i >= n or s[i] == '}':
            return None, None
        if s[i] == ',':
            i += 1
            continue
        if s[i] != '"':
            return None, None  # malformed — do not guess
        kend = _str_end(s, i)
        kname = json.loads(s[i:kend])
        j = _skip_ws_comments(s, kend)
        if j >= n or s[j] != ':':
            i = kend
            continue
        vstart = _skip_ws_comments(s, j + 1)
        vend = _value_end(s, vstart)
        if kname == key:
            return vstart, vend
        i = vend


def _loads_jsonc(s):
    out, i, n, in_str = [], 0, len(s), False
    while i < n:
        c = s[i]
        if in_str:
            out.append(c)
            if c == '\\':
                if i + 1 < n:
                    out.append(s[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
        elif c == '/' and i + 1 < n and s[i + 1] == '/':
            k = s.find('\n', i)
            i = n if k < 0 else k
            continue
        elif c == '/' and i + 1 < n and s[i + 1] == '*':
            k = s.find('*/', i + 2)
            i = n if k < 0 else k + 2
            continue
        else:
            out.append(c)
        i += 1
    txt = re.sub(r',(\s*[}\]])', r'\1', ''.join(out)).strip()
    return json.loads(txt) if txt else None


def get_value(text, key):
    vs, ve = _find_top_key(text, key)
    return _loads_jsonc(text[vs:ve]) if vs is not None else None


def _detect_indent(text):
    m = re.search(r'\n([ \t]+)\S', text)
    return m.group(1) if m else '    '


def _line_indent_at(text, pos):
    ls = text.rfind('\n', 0, pos) + 1
    return re.match(r'[ \t]*', text[ls:pos]).group(0)


def _fmt_value(value, unit, base_indent):
    indent = None if unit == '\t' else len(unit)
    raw = json.dumps(value, indent=indent, ensure_ascii=False)
    if unit == '\t' and '\n' in raw:
        raw = json.dumps(value, indent=1, ensure_ascii=False)
        raw = re.sub(r'^( +)', lambda m: '\t' * len(m.group(1)), raw, flags=re.M)
    if '\n' not in raw:
        return raw
    lines = raw.split('\n')
    return lines[0] + '\n' + '\n'.join(base_indent + ln for ln in lines[1:])


def set_top_level_key(text, key, value):
    if not text.strip():
        text = '{}'
    unit = _detect_indent(text)
    vs, ve = _find_top_key(text, key)
    if vs is not None:
        base = _line_indent_at(text, vs)
        return text[:vs] + _fmt_value(value, unit, base) + text[ve:]
    open_i = _find_root_open(text)
    after = open_i + 1
    rest = _skip_ws_comments(text, after)
    empty = rest < len(text) and text[rest] == '}'
    val = _fmt_value(value, unit, unit)
    if empty:
        # Normalize the whitespace between the braces so the closer stays on its own line.
        return text[:after] + '\n' + unit + json.dumps(key) + ': ' + val + '\n' + text[rest:]
    ins = '\n' + unit + json.dumps(key) + ': ' + val + ','
    return text[:after] + ins + text[after:]


def _read(path):
    if os.path.exists(path):
        with open(path, encoding='utf-8') as f:
            return f.read()
    return ''


def _write(path, text):
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    if not text.endswith('\n'):
        text += '\n'
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)


# ---- subcommands ----

def cmd_enable_proposed_api(args):
    path = args.argv or default_argv_path()
    text = _read(path)
    cur = get_value(text, 'enable-proposed-api')
    if cur is None:
        cur = []
    if not isinstance(cur, list):
        print(f"host-config: 'enable-proposed-api' in {path} is not an array; "
              "leaving it untouched.", file=sys.stderr)
        return 2
    if args.ext_id in cur:
        print(f"argv.json: enable-proposed-api already lists {args.ext_id} (no change).")
        return 0
    cur.append(args.ext_id)
    _write(path, set_top_level_key(text, 'enable-proposed-api', cur))
    print(f"argv.json: added {args.ext_id} to enable-proposed-api  ->  {path}")
    return 0


def cmd_set_host(args):
    path = args.settings or default_settings_path()
    text = _read(path)
    cur = get_value(text, 'contai.hosts')
    if cur is None:
        cur = []
    if not isinstance(cur, list):
        print(f"host-config: 'contai.hosts' in {path} is not an array; "
              "leaving it untouched.", file=sys.stderr)
        return 2
    entry = {
        'name': args.name,
        'host': args.host,
        'port': int(args.port),
        'connectionToken': args.token,
        'folders': [{'name': args.folder_name, 'path': args.folder_path}],
    }
    replaced = False
    for i, h in enumerate(cur):
        if isinstance(h, dict) and h.get('name') == args.name:
            if h == entry:
                print(f"settings.json: contai.hosts['{args.name}'] already current (no change).")
                return 0
            cur[i] = entry
            replaced = True
            break
    if not replaced:
        cur.append(entry)
    _write(path, set_top_level_key(text, 'contai.hosts', cur))
    verb = 'updated' if replaced else 'added'
    print(f"settings.json: {verb} contai.hosts['{args.name}'] (token refreshed)  ->  {path}")
    return 0


def cmd_paths(args):
    print(f"argv.json     {default_argv_path()}")
    print(f"settings.json {default_settings_path()}")
    return 0


def main(argv):
    p = argparse.ArgumentParser(prog='host-config.py', description=__doc__)
    sub = p.add_subparsers(dest='cmd', required=True)

    a = sub.add_parser('enable-proposed-api')
    a.add_argument('ext_id')
    a.add_argument('--argv')
    a.set_defaults(func=cmd_enable_proposed_api)

    s = sub.add_parser('set-host')
    for flag in ('name', 'host', 'port', 'token', 'folder-name', 'folder-path'):
        s.add_argument('--' + flag, required=True, dest=flag.replace('-', '_'))
    s.add_argument('--settings')
    s.set_defaults(func=cmd_set_host)

    sub.add_parser('paths').set_defaults(func=cmd_paths)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
