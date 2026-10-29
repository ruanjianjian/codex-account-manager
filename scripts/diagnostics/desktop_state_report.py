#!/usr/bin/env python3 -I
"""Read-only routing/switch state report for the machine where Codex stopped working.

Prints one JSON document. It never prints tokens, keys, e-mail addresses, prompts, log text or
file contents: account IDs appear only as short SHA-256 prefixes, and logs only as pattern counts.
It writes nothing, starts nothing and stops nothing.

    python3 -I scripts/diagnostics/desktop_state_report.py > ~/Desktop/codex-routing-state.json
"""
import base64, glob, hashlib, json, os, pathlib, plistlib, re, sqlite3, subprocess, time

H = pathlib.Path.home()
CODEX = pathlib.Path(os.environ.get("CODEX_HOME", H / ".codex"))
ROOTS = {"private": H / "Library/Application Support/CodexAccountManager",
         "public": H / "Library/Application Support/CodexAccountsPublic"}
PORTS = {"private": 18455, "public": 18456}


def tag(value):
    return hashlib.sha256(value.encode()).hexdigest()[:10] if value else None


def load(path):
    try:
        return json.loads(path.read_text())
    except Exception as error:
        return {"_unreadable": type(error).__name__} if path.exists() else None


def jwt_claims(token):
    try:
        part = token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
    except Exception:
        return {}


def credential(path):
    """Account and expiry facts only."""
    data = load(path)
    if not isinstance(data, dict) or "_unreadable" in (data or {}):
        return {"present": path.exists(), "readable": False}
    tokens = data.get("tokens") or {}
    claims = jwt_claims(tokens.get("access_token") or "")
    exp = claims.get("exp")
    st = path.stat()
    return {"present": True, "readable": True, "account": tag(tokens.get("account_id")),
            "token_claims_match_account": (claims.get("https://api.openai.com/auth") or {}).get("chatgpt_account_id") == tokens.get("account_id"),
            "access_expires_in_hours": round((exp - time.time()) / 3600, 1) if exp else None,
            "has_refresh_token": bool(tokens.get("refresh_token")), "api_key_mode": data.get("OPENAI_API_KEY") is not None,
            "mode_octal": oct(st.st_mode & 0o777), "symlink": path.is_symlink()}


def run(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return ""


def app_version(app):
    try:
        info = plistlib.loads((pathlib.Path(app) / "Contents/Info.plist").read_bytes())
        return {"path": str(app), "bundle_id": info.get("CFBundleIdentifier"), "version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion")}
    except Exception:
        return {"path": str(app), "unreadable": True}


report = {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "codex_home": str(CODEX)}

# Installed apps: official Codex desktop and every bundle that carries the gateway helper.
apps = [app_version(a) for a in ["/Applications/ChatGPT.app", "/Applications/Codex.app"] if pathlib.Path(a).exists()]
managers = [app_version(pathlib.Path(h).parents[1]) for h in
            glob.glob("/Applications/*.app/Contents/Helpers/AccountsGateway") + glob.glob(str(H / "Applications/*.app/Contents/Helpers/AccountsGateway"))]
cli = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
report["apps"] = {"codex_desktop": apps, "codex_cli": run(cli, "--version").strip() or None, "account_managers": managers}

# Processes and listeners: names, PIDs and our own helper's flags (paths only, no environment).
ps = run("/bin/ps", "-axo", "pid=,ppid=,command=")
procs = []
for line in ps.splitlines():
    if re.search(r"AccountsGateway|ChatGPT\.app/Contents/MacOS/ChatGPT$|codex app-server|CodexAccounts", line):
        pid, ppid, command = line.split(None, 2)
        if "AccountsGateway" in command:
            listen = re.search(r"--listen (\S+)", command)
            desktop = re.search(r"--desktop-auth (\S+)", command)
            command = "AccountsGateway listen=%s desktop_auth=%s" % (listen and listen.group(1), bool(desktop))
        elif "app-server" in command:
            command = "codex app-server"
        procs.append({"pid": int(pid), "ppid": int(ppid), "what": command[-120:]})
report["processes"] = procs
listeners = {}
for name, port in PORTS.items():
    out = run("/usr/sbin/lsof", "-nP", "-iTCP:%d" % port, "-sTCP:LISTEN", "-Fpc")
    listeners[str(port)] = [l[1:] for l in out.splitlines() if l.startswith("c")] or None
report["listeners"] = listeners

# What Codex will actually use: provider lines only, the bearer key reduced to its length.
config = CODEX / "config.toml"
top, block = {}, None
if config.exists():
    section = None
    for raw in config.read_text(errors="replace").splitlines():
        line = raw.strip()
        if line.startswith("["):
            section = line
            if line.startswith("[model_providers.codex_accounts_gateway]"):
                block = {}
            continue
        key = line.split("=", 1)[0].strip()
        if section is None and key in ("model_provider", "openai_base_url", "chatgpt_base_url", "cli_auth_credentials_store", "service_tier", "model"):
            top[key] = line.split("=", 1)[1].strip()
        elif section == "[model_providers.codex_accounts_gateway]" and "=" in line:
            value = line.split("=", 1)[1].strip()
            block[key] = "<redacted len=%d>" % (len(value) - 2) if key == "experimental_bearer_token" else value
report["codex_config"] = {"present": config.exists(), "top_level": top, "gateway_provider_table": block,
                          "points_at_local_gateway": "127.0.0.1" in top.get("openai_base_url", "")}
desktop = credential(CODEX / "auth.json")
report["desktop_login"] = desktop

# Each manager data directory: enrolment, receipt vs live login, gateway files and recent events.
for name, root in ROOTS.items():
    if not root.exists():
        report[name] = None
        continue
    state = load(root / "state.json") or {}
    slots = [s for s in (state.get("accounts") or []) if isinstance(s, dict)]
    enrolled = {tag(s.get("expectedAccountID")): s.get("id") for s in slots if s.get("expectedAccountID")}
    receipt = load(root / "desktop-switch/selection.json") or {}
    gw = root / "gateway"
    pool = load(gw / "pool.json") if (gw / "pool.json").exists() else None
    section = {
        "slots": len(slots), "enrolled": len(enrolled),
        "file_credentials": (root / "accounts").exists() and any((root / "accounts").glob("*/auth.json")),
        "desktop_login_enrolled_as": enrolled.get(desktop.get("account")),
        "switch_receipt": {"slot": receipt.get("slotID"), "account": tag(receipt.get("accountID")),
                           "matches_live_login": tag(receipt.get("accountID")) == desktop.get("account") if receipt else None},
        "switch_pending_marker": (root / "desktop-switch/pending").exists(),
        "slot_credentials": {s.get("id"): credential(root / "accounts" / s.get("id", "") / "auth.json") for s in slots if s.get("id")},
        "gateway": {"applied_marker": (gw / "config.gateway-applied").exists(), "backup_present": (gw / "config.before-gateway").exists(),
                    "local_key_length": len((gw / "local.key").read_text().strip()) if (gw / "local.key").exists() else None,
                    "pool": None if not isinstance(pool, dict) else {
                        "preferred": pool.get("preferred") or None,
                        "accounts": [{"slot": a.get("id"), "account": tag(a.get("accountID")), "available": a.get("available"),
                                      "expires_in_hours": round((a.get("expires", 0) - time.time()) / 3600, 1)} for a in pool.get("accounts") or []],
                        "clients": [{"slot": c.get("id"), "account": tag(c.get("accountID"))} for c in pool.get("clients") or []]},
                    "session_bindings": len(load(gw / "session-accounts.json") or {}) if (gw / "session-accounts.json").exists() else 0},
    }
    events = []
    for path in [gw / "requests.jsonl.previous", gw / "requests.jsonl"]:
        if path.exists():
            for line in path.read_text(errors="replace").splitlines():
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                events.append({k: e.get(k) for k in ("time", "kind", "status", "reason", "route", "account") if e.get(k) is not None})
    counts = {}
    for e in events[-500:]:
        key = "%s %s %s" % (e.get("kind"), e.get("status", ""), e.get("reason", ""))
        counts[key.strip()] = counts.get(key.strip(), 0) + 1
    section["gateway"]["recent_event_counts"] = counts
    section["gateway"]["last_events"] = [e for e in events if e.get("kind") != "finished"][-30:]
    report[name] = section

# Codex's own logs: counts of known failure signatures only, never the lines themselves.
patterns = {"gateway_401": "Invalid local gateway key", "gateway_409": "account-bound", "gateway_503_no_account": "No available account",
            "gateway_unreachable": "127.0.0.1:1845", "routing_discovery": "workspace routing", "refresh_failed": "could not be refreshed",
            "unsupported_route": "Unsupported gateway route", "encrypted_content_rejected": "could not be verified"}
log_counts = {}
db = CODEX / "logs_2.sqlite"
if db.exists():
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=2)
        tables = [r[0] for r in con.execute("select name from sqlite_master where type='table'")]
        for table in tables:
            cols = [r[1] for r in con.execute("pragma table_info('%s')" % table)]
            text = [c for c in cols if any(k in c.lower() for k in ("message", "body", "fields", "text"))]
            # Last three days only; the table can be large.
            recent = " and ts > %d" % (time.time() - 3 * 86400) if "ts" in cols else ""
            for name, needle in patterns.items():
                for c in text:
                    n = con.execute("select count(*) from '%s' where \"%s\" like ?%s" % (table, c, recent), ("%" + needle + "%",)).fetchone()[0]
                    if n:
                        log_counts[name] = log_counts.get(name, 0) + n
        con.close()
    except Exception as error:
        log_counts["_sqlite_error"] = type(error).__name__
for path in glob.glob(str(H / "Library/Logs/com.openai.codex/**/*.log"), recursive=True) + glob.glob(str(CODEX / "log/*.log")):
    try:
        text = pathlib.Path(path).read_text(errors="replace")[-4_000_000:]
    except Exception:
        continue
    for name, needle in patterns.items():
        n = text.count(needle)
        if n:
            log_counts[name] = log_counts.get(name, 0) + n
report["codex_log_signature_counts"] = log_counts
print(json.dumps(report, ensure_ascii=False, indent=2))
