#!/usr/bin/env python3
"""miyu-watchd —— Apple Watch /watch 中继（计算全在电脑，表上只收纯文本）。

职责（HTTP，127.0.0.1:8310）：
  * GET  /watch/            手表页面（单文件、零外部依赖、无任何 JS 库）
  * GET  /watch/api/state   会话列表 + 当前会话（转发 miyu /api/bootstrap）
  * POST /watch/api/send    把表上的原文**原样**发给 miyu 自己的 /api/turns
  * GET  /watch/api/status  轮询回合；完成后把回复 md→纯文本、按屏宽折行再下发
  * GET  /watch/api/history 历史消息（同样处理后下发）
  * GET  /watch/api/auth-status、POST /watch/api/login
                             登录中继（/watch_ai 前缀同样可用），密码只过手不落地

鉴权完全复用 Miyu WebUI：请求自带 cookie，watchd 只做搬运与计算，
不保存任何凭据；cookie 失效应答 401，表上重新登录即可。
"""
import json
import os
import re
import sqlite3
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

MIYU = os.environ.get("WATCH_MIYU", "http://127.0.0.1:8300")
HOST = os.environ.get("WATCH_HOST", "127.0.0.1")
PORT = int(os.environ.get("WATCH_PORT", "8310"))
ROOT = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(ROOT, "index.html")


def _pv():
    """页面版本号=文件 mtime：注入页面供"过期自动刷新"比对。"""
    try:
        return str(int(os.path.getmtime(PAGE)))
    except OSError:
        return "0"
LOG = os.path.expanduser("~/.miyu/cache/logs/watchd.log")

# 进行中的回合：key=(sid, since) → SSE 攒出来的流式正文
PENDING = {}
PENDING_LOCK = threading.Lock()


def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except OSError:
        pass


# ---------------------------------------------------------------- 上游 miyu

def miyu_call(method, path, cookie="", body=None, timeout=25, with_headers=False):
    """带表的 cookie 直接问 miyu(8300)。返回 (status, bytes[, headers])。"""
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(MIYU + path, data=data, method=method)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if cookie:
        req.add_header("Cookie", cookie)
    def pack(status, resp):
        raw = resp.read()
        if not with_headers:
            return status, raw
        return status, raw, resp.headers
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return pack(resp.status, resp)
    except urllib.error.HTTPError as exc:
        if not with_headers:
            return exc.code, exc.read()
        return exc.code, exc.read(), exc.headers
    except Exception as exc:                      # 网络层问题，不要炸整个服务
        raw = str(exc).encode("utf-8", "replace")
        return (0, raw, None) if with_headers else (0, raw)


def jload(raw):
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        return None


def err_msg(raw, fallback):
    j = jload(raw)
    if isinstance(j, dict):
        e = j.get("error")
        if isinstance(e, dict) and e.get("message"):
            return str(e["message"])
    return fallback


# ------------------------------------------------- md → 纯文本（电脑上算好）

# 围栏代码块：开栏允许带语言，闭栏必须独占一行（代码里出现 ``` 也不打断）。
FENCE_RE = re.compile(r"^[ \t]*```[^\n]*\n((?:.*\n)*?)[ \t]*```[ \t]*$", re.M)


def md2plain(s):
    blocks = []

    def stash(m):
        blocks.append(m.group(1))
        return f"\x00CB{len(blocks) - 1}\x00"

    def stash_text(text):
        blocks.append(text)
        return f"\x00CB{len(blocks) - 1}\x00"

    # 反斜杠转义先摘出来，避免 \*被粗体规则吃掉
    escapes = []

    def stash_esc(m):
        escapes.append(m.group(1))
        return f"\x00E{len(escapes) - 1}\x00"

    s = re.sub(r"\\([\\`*_{}\[\]()#+\-.!|~<>])", stash_esc, s)
    s = FENCE_RE.sub(stash, s)
    # 没闭合的围栏：剩余部分整体当代码
    s = re.sub(r"^[ \t]*```[^\n]*\n([\s\S]*)$",
               lambda m: stash_text(m.group(1)), s, flags=re.M)
    s = re.sub(r"`([^`\n]+)`", r"\1", s)
    # 图片 → [图 标题]；链接 → 文字 (网址)
    s = re.sub(
        r"!\[([^\]]*)\]\(([^)]+)\)",
        lambda m: ("[图 " + m.group(1) + "]" if m.group(1) else "[图]"),
        s,
    )

    def link(m):
        txt, url = m.group(1), m.group(2)
        if url.startswith("data:"):
            return txt
        return txt if txt == url else f"{txt} ({url})"

    s = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, s)
    s = re.sub(r"<((?:https?|ftp)://[^>\s]+)>", r"\1", s)
    s = re.sub(r"^#{1,6}\s*", "", s, flags=re.M)          # 标题
    s = re.sub(r"\*\*\*(.+?)\*\*\*", r"\1", s)
    s = re.sub(r"___(.+?)___", r"\1", s)
    s = re.sub(r"\*\*(.+?)\*\*", r"\1", s)
    s = re.sub(r"__(.+?)__", r"\1", s)
    s = re.sub(r"\*(\S|\S.*?\S)\*", r"\1", s)
    s = re.sub(r"_(\S|\S.*?\S)_", r"\1", s)
    s = re.sub(r"~~(.+?)~~", r"\1", s)
    s = re.sub(r"^>\s?", "┆ ", s, flags=re.M)              # 引用
    s = re.sub(r"^\s*([-*_])\s*(\1\s*){2,}$", "──", s, flags=re.M)  # 分隔线

    def tableline(m):
        cells = [c.strip() for c in m.group(0).strip().strip("|").split("|")]
        if all(re.fullmatch(r":?-{2,}:?", c or "-") for c in cells):
            return ""
        return " · ".join(cells)

    s = re.sub(r"^[ \t]*\|.*\|[ \t]*$", tableline, s, flags=re.M)
    s = re.sub(r"^(\s*)[*+]\s", r"\1- ", s, flags=re.M)
    s = re.sub(
        r"^(\s*)- \[([ xX])\]\s",
        lambda m: f"{m.group(1)}- [{'✓' if m.group(2).lower() == 'x' else ' '}] ",
        s,
        flags=re.M,
    )
    s = re.sub(r"</?(?:[a-zA-Z][a-zA-Z0-9]*)[^>]*>", "", s)
    for a, b in (("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"),
                 ("&gt;", ">"), ("&quot;", '"'), ("&#39;", "'"), ("&#x27;", "'")):
        s = s.replace(a, b)
    s = re.sub(r"\n{3,}", "\n\n", s)

    def unstash(m):
        return blocks[int(m.group(1))].rstrip("\n")

    s = re.sub(r"\x00CB(\d+)\x00", unstash, s)
    s = re.sub(r"\x00E(\d+)\x00", lambda m: escapes[int(m.group(1))], s)
    return s.strip()


NO_LEAD = set("，。、！？；：）】》」』”’),.;:!?]}、·│")


def charw(c):
    o = ord(c)
    if (0x1100 <= o <= 0x115F or 0x2E80 <= o <= 0xA4CF or 0xAC00 <= o <= 0xD7A3
            or 0xF900 <= o <= 0xFAFF or 0xFE30 <= o <= 0xFE4F
            or 0xFF00 <= o <= 0xFF60 or 0xFFE0 <= o <= 0xFFE6
            or 0x3000 <= o <= 0x303F):
        return 2
    return 1


def wrap_line(line, budget):
    line = line.replace("\t", "    ").rstrip()
    indent = re.match(r" *", line).group(0)
    body = line[len(indent):]
    out, cur, cw = [], "", 0
    for ch in body:
        w = charw(ch)
        if cw + w > budget and cur:
            if ch in NO_LEAD and cw + w <= budget + 2:
                cur += ch
                cw += w
                continue
            out.append(indent + cur)
            cur = "" if ch == " " else ch
            cw = 0 if ch == " " else w
        else:
            cur += ch
            cw += w
    out.append(indent + cur)
    return out


def wrap(text, budget):
    out = []
    for line in text.split("\n"):
        out.extend(wrap_line(line, budget))
    return "\n".join(out)


def process(text, w=None, fs=None):
    """md → 纯文本 + 按表屏宽度折行。宽度单位：CJK=2，半角=1。"""
    budget = 26
    try:
        if w and fs:
            budget = max(12, int(float(w) / (float(fs) * 0.52)))
    except (TypeError, ValueError):
        pass
    out = wrap(md2plain(str(text)), budget)
    if len(out) > 12000:
        out = out[:12000] + "\n…（太长，已截断）"
    return out


# ------------------------------------------------ 流式（SSE 攒字）与灰字统计

def round_secs(turn):
    """一整轮耗时：assistant_timestamp - user_timestamp（兼容 ISO / 秒 / 毫秒）。"""
    def parse(v):
        if not v:
            return None
        s = str(v).strip().replace("Z", "+00:00")
        try:
            import datetime
            return datetime.datetime.fromisoformat(s).timestamp()
        except ValueError:
            try:
                f = float(v)
                return f / 1000.0 if f > 1e12 else f
            except ValueError:
                return None
    a, b = parse(turn.get("assistant_timestamp")), parse(turn.get("user_timestamp"))
    if a is None or b is None:
        return None
    d = a - b
    return d if 0 < d < 86400 else None


def tool_counts(turn):
    """tool_flow 里数调用次数：技能 / MCP / 普通工具。"""
    skills = mcp = tools = 0
    flow = turn.get("tool_flow") or []
    if isinstance(flow, list):
        for rnd in flow:
            for call in ((rnd or {}).get("calls") or []):
                name = str((call or {}).get("name") or "").lower()
                if "skill" in name:
                    skills += 1
                elif name.startswith("mcp") or "." in name or "__" in name:
                    mcp += 1
                else:
                    tools += 1
    return tools, skills, mcp


def fmt_meta(turn, ctx=None):
    """灰字统计：总词元 · 思考秒数 · 工具/技能/MCP 次数 · 平均词元每秒。"""
    parts = []
    try:
        tokens = int(turn.get("token_total") or 0)
    except (TypeError, ValueError):
        tokens = 0
    est = bool(turn.get("token_usage_estimated"))
    secs = round_secs(turn)
    tools, skills, mcp = tool_counts(turn)
    if tokens > 0:
        parts.append(("约" if est else "") + f"{tokens}词元")
    if secs:
        parts.append(f"{secs:.1f}秒")
    names = _tool_names(turn)
    if names:                                   # 优先报名字："调用了什么"比"几次"有用
        parts.append("调用:" + "、".join(names[:3]) + ("等" if len(names) > 3 else ""))
    else:
        used = [x for x in (f"工具{tools}" if tools else "",
                            f"技能{skills}" if skills else "",
                            f"MCP{mcp}" if mcp else "") if x]
        if used:
            parts.append("·".join(used) + "次")
    if tokens > 0 and secs:
        parts.append(f"{tokens / secs:.1f}词元/秒")
    if ctx:
        try:
            parts.append(f"上下文{int(round(ctx['ratio'] * 100))}%")
        except (KeyError, TypeError, ValueError):
            pass
    return " · ".join(parts)


def _ctx_info(cookie, sid):
    """本会话上下文占用：{used, window, ratio}，拿不到回 None。"""
    if not sid:
        return None
    st, raw = miyu_call("GET", f"/api/sessions/{sid}/context", cookie)
    if st != 200:
        return None
    j = jload(raw) or {}
    try:
        used = int(j.get("context_tokens") or 0)
        window = int(j.get("context_window") or 0)
    except (TypeError, ValueError):
        return None
    if window <= 0:
        return None
    return {"used": used, "window": window, "ratio": round(used / window, 4)}


WATCH_USER = os.environ.get("WATCH_USER", "user")
DB_PATH = os.path.expanduser(f"~/.miyu/home/{WATCH_USER}/conversation.db")
ORDER_FILE = os.path.expanduser("~/.miyu/watch/order.json")
SEEN_VER_FILE = os.path.expanduser("~/.miyu/watch/seen_ver")
LATEST_URL = "http://127.0.0.1/boapp/bowatch/latest"   # 本机 jing-http，免证书


def _order_list():
    try:
        with open(ORDER_FILE, "r", encoding="utf-8") as f:
            v = json.load(f)
        return [str(x) for x in v if x] if isinstance(v, list) else []
    except (OSError, ValueError):
        return []


def apply_order(sessions):
    """长按手排的顺序优先于活动时间序；没见过的会话按原序追加到尾部。
    （表上 storage 被禁，顺序必须落 watchd 的盘。）"""
    order = _order_list()
    if not order:
        return sessions
    rank = {sid: i for i, sid in enumerate(order)}
    pinned = sorted([s for s in sessions if s.get("id") in rank],
                    key=lambda s: rank[s["id"]])
    rest = [s for s in sessions if s.get("id") not in rank]
    return pinned + rest


def api_reorder(payload):
    """长按移动：把 sid 插到 before 之前（before 空 = 置顶）。"""
    sid = str(payload.get("sid") or "")
    before = str(payload.get("before") or "")
    if not sid:
        return 400, {"error": {"message": "缺 sid"}}
    order = [x for x in _order_list() if x != sid]
    if before and before in order:
        order.insert(order.index(before), sid)
    else:
        order.insert(0, sid)
    try:
        with open(ORDER_FILE, "w", encoding="utf-8") as f:
            json.dump(order, f)
    except OSError:
        return 500, {"error": {"message": "顺序写不进盘"}}
    return 200, {"ok": 1}


def api_updatecheck():
    """悄悄检测 bowatch 新版：拉 latest（纯文本版本号或 {version,notes}），
    与见过的版本比对，每版只报一次；任何失败都静默——它是"悄悄"的。"""
    try:
        req = urllib.request.Request(LATEST_URL,
                                     headers={"Host": "jing.top"})
        with urllib.request.urlopen(req, timeout=5) as r:
            raw = r.read(4096).decode("utf-8", "replace").strip()
    except Exception:
        return 200, {"has_new": 0}
    latest = notes = ""
    try:
        j = json.loads(raw)
        latest = str(j.get("version") or "")
        notes = str(j.get("notes") or "")[:120]
    except ValueError:
        latest = raw[:32]
    if not latest:
        return 200, {"has_new": 0}
    try:
        with open(SEEN_VER_FILE, "r", encoding="utf-8") as f:
            seen = f.read().strip()
    except OSError:
        seen = ""
    if latest == seen:
        return 200, {"has_new": 0, "latest": latest}
    try:
        with open(SEEN_VER_FILE, "w", encoding="utf-8") as f:
            f.write(latest)
    except OSError:
        pass
    return 200, {"has_new": 1, "latest": latest, "notes": notes}


def _authed(cookie):
    """登录校验：真 miyu 没有 /api/status（那是假 miyu 的端点，404 遗毒），
    用 /api/bootstrap——watchd 全线都在用它，稳。"""
    st, _raw = miyu_call("GET", "/api/bootstrap", cookie)
    return st == 200


def _tool_names(turn):
    """tool_flow 里收工具调用名（去重保序）→ 表端"调用了什么"。"""
    names, seen = [], set()
    flow = (turn or {}).get("tool_flow") or []
    if isinstance(flow, list):
        for rnd in flow:
            for call in ((rnd or {}).get("calls") or []):
                n = str((call or {}).get("name") or "").strip()
                if n and n not in seen:
                    seen.add(n)
                    names.append(n)
    return names


def _full_text(turn):
    """多段生成的完整正文：tool_flow 各轮非空 assistant_content + 最终段。
    分段回合（中间插工具调用）只有最后一段在 turns.assistant_content，
    中间段全在 tool_flow 里——不拼就丢半截话，而且流式 delta 是全量、
    定稿帧反而缩水，越看越少。WebUI 是逐段渲染的，我们拼成一段下发。"""
    parts = []
    flow = (turn or {}).get("tool_flow") or []
    if isinstance(flow, list):
        for rnd in flow:
            s = str((rnd or {}).get("assistant_content") or "").strip()
            if s:
                parts.append(s)
    tail = str((turn or {}).get("assistant_content") or "").strip()
    if tail:
        parts.append(tail)
    return "\n\n".join(parts)


def _think_n(turn):
    try:
        return len(str((turn or {}).get("assistant_reasoning") or "").strip())
    except (TypeError, ValueError):
        return 0


def _fmt_ts(iso):
    """ISO(UTC) → 本地 YY/M/D:HH:MM（分享日志用）；空/坏回 None"""
    if not iso:
        return None
    try:
        from datetime import datetime
        dt = datetime.fromisoformat(str(iso)).astimezone()
        return f"{dt.year % 100}/{dt.month}/{dt.day}:{dt.hour:02d}:{dt.minute:02d}"
    except Exception:
        return None


def _inline_images(sid, seq):
    """一条回合的内联图（AI 工具生成，BLOB 在 turn_inline_media）→
    [media_id, ...]。本地库直读；拿不到回空表，绝不拖累消息主链路。
    ⚠ miyu API 的 turn 对象**不带 turn_id 键**（全隐藏），回合的真身
    标识是 (session_id, seq)——JOIN 回 turns 表拿 media。"""
    if not sid or not seq:
        return []
    try:
        con = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, timeout=2)
        try:
            rows = con.execute(
                "SELECT m.media_id FROM turn_inline_media m "
                "JOIN turns t ON t.turn_id = m.turn_id "
                "WHERE t.session_id=? AND t.seq=? AND m.kind='image' "
                "ORDER BY m.call_id, m.seq",
                (str(sid), int(seq))).fetchall()
        finally:
            con.close()
        return [int(r[0]) for r in rows]
    except sqlite3.Error:
        return []


def sse_reader(cookie, sid, key, after_id, entry):
    """订阅 miyu 的 /api/events，把本回合的 assistant.delta 攒进 entry。"""
    try:
        req = urllib.request.Request(
            f"{MIYU}/api/events?after={max(0, int(after_id or 0))}",
            headers={"Cookie": cookie, "Accept": "text/event-stream"})
        with urllib.request.urlopen(req, timeout=320) as resp:
            name = data = None
            eid = "0"
            for raw in resp:                       # 行式读取，流式友好
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                if line == "":
                    if name or data:
                        try:
                            obj = json.loads(data) if data else {}
                        except ValueError:
                            obj = {}
                        rid = str(obj.get("run_id") or "")
                        if entry.get("run_id") and rid and rid != entry["run_id"]:
                            pass                                   # 别的回合
                        elif name == "run.started" and not entry.get("run_id"):
                            if str(obj.get("session_id") or "") == sid or not obj.get("session_id"):
                                entry["run_id"] = rid
                        elif name == "assistant.delta":
                            if (entry.get("run_id") in (None, rid)) and (
                                    rid == entry.get("run_id") or str(obj.get("session_id") or "") == sid):
                                d = obj.get("delta")
                                if isinstance(d, str) and d:
                                    entry["text"] += d
                        elif name in ("run.completed", "run.cancelled", "run.failed"):
                            if (rid == entry.get("run_id")
                                    or str(obj.get("session_id") or "") == sid):
                                entry["ended"] = True
                                return
                    name = data = None
                elif line.startswith("event:"):
                    name = line[6:].strip()
                elif line.startswith("data:"):
                    data = line[5:].strip()
                elif line.startswith("id:"):
                    eid = line[3:].strip()
    except Exception as exc:
        log(f"SSE sid={sid}: {type(exc).__name__}: {exc}")
    finally:
        entry["ended"] = True                      # 线程收工；正文仍由快照定稿


def pending_put(key, entry):
    now = time.time()
    with PENDING_LOCK:
        for k in [k for k, v in PENDING.items() if now - v.get("t", 0) > 900]:
            PENDING.pop(k, None)                   # 顺手清僵尸
        PENDING[key] = entry


def pending_get(key):
    with PENDING_LOCK:
        return PENDING.get(key)


def pending_pop(key):
    with PENDING_LOCK:
        return PENDING.pop(key, None)


# ------------------------------------------------------------------ API 处理

def _epoch(v):
    """会话活动时间：ISO 时间戳 / 秒 / 毫秒 → epoch 秒。"""
    if v is None or v == "":
        return None
    if isinstance(v, (int, float)):
        return v / 1000.0 if v > 1e12 else float(v)
    try:
        import datetime
        return datetime.datetime.fromisoformat(str(v).strip().replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def pick_latest(boot, raw_sessions):
    """进页面该落在哪条会话：正在跑的回合 > 最后活动时间 > miyu 当前会话。"""
    live = ""
    for r in boot.get("runs") or []:
        if isinstance(r, dict) and r.get("run_id") and r.get("session_id"):
            live = str(r["session_id"])           # 有回合在跑，那就是最新的
            break
    if live:
        return live
    best_id, best_t = "", None
    for s in raw_sessions:
        if not isinstance(s, dict):
            continue
        if s.get("parent_session_id") or str(s.get("kind") or "") == "subagent":
            continue                              # 子代理会话不当落点
        ts = [t for t in (_epoch(s.get(k)) for k in
                          ("updated_at", "last_request_at", "last_activity_at",
                           "last_used_at", "timestamp")) if t is not None]
        if not ts:
            continue
        m = max(ts)
        if best_t is None or m > best_t:
            best_t, best_id = m, str(s.get("session_id") or "")
    if best_id:
        return best_id
    return str(boot.get("current_session_id") or "")


def api_state(cookie):
    status, raw = miyu_call("GET", "/api/bootstrap", cookie)
    if status == 401:
        return 401, {"auth": 0, "error": {"message": "登录已过期"}}
    if status != 200:
        return 502, {"error": {"message": err_msg(raw, f"miyu {status or '不可达'}")}}
    j = jload(raw) or {}
    raw_sessions = j.get("sessions") or []
    sessions = []
    for s in raw_sessions:
        if not isinstance(s, dict):
            continue
        sessions.append({
            "id": str(s.get("session_id") or ""),
            "name": str(s.get("name") or "新会话")[:60],
            "preview": str(s.get("last_user_content") or "")[:80],
            "mode": str(s.get("mode") or "normal"),
        })
    sessions = apply_order(sessions)          # 长按手排优先（落点逻辑不受影响）
    persona = j.get("persona") or {}
    account = j.get("account") or {}
    cur = pick_latest(j, raw_sessions)
    return 200, {
        "auth": 1,
        "pv": _pv(),
        "current": cur,
        "ctx": _ctx_info(cookie, cur),
        "persona": str(persona.get("name") or "Miyu"),
        "sessions": sessions,
        "account": {
            "username": str(account.get("username") or ""),
            "display_name": str(account.get("display_name") or ""),
            "admin": bool(account.get("admin")),
        },
    }


def max_seq(turns):
    best = 0
    for t in turns or []:
        try:
            best = max(best, int(t.get("seq") or 0))
        except (TypeError, ValueError):
            pass
    return best


def api_send(cookie, payload):
    text = payload.get("text")
    if not isinstance(text, str) or text == "":
        return 400, {"error": {"message": "消息不能为空"}}
    sid = str(payload.get("sid") or "")
    status, raw = miyu_call("GET", "/api/bootstrap", cookie)
    if status == 401:
        return 401, {"auth": 0, "error": {"message": "登录已过期"}}
    if status != 200:
        return 502, {"error": {"message": err_msg(raw, "拿不到会话信息")}}
    boot = jload(raw) or {}
    if not sid:
        sid = str(boot.get("current_session_id") or "")
    after_id = boot.get("latest_event_id") or 0
    # 发送前记下基线 seq：之后第一条新回合就是表上这条
    status, raw = miyu_call("GET", f"/api/sessions/{sid}/turns?limit=2", cookie)
    if status == 401:
        return 401, {"auth": 0, "error": {"message": "登录已过期"}}
    since = max_seq((jload(raw) or {}).get("turns")) if status == 200 else 0
    # 原样照发：不做任何 md 转换、不裁剪
    status, raw = miyu_call(
        "POST", "/api/turns", cookie,
        {"content": text, "session_id": sid} if sid else {"content": text},
    )
    if status == 401:
        return 401, {"auth": 0, "error": {"message": "登录已过期"}}
    if status not in (200, 202):            # miyu 接受回合时回202（假miyu当年回200，骗了本鲸）
        return status or 502, {"error": {"message": err_msg(raw, "发送失败")}}
    run_id = str((jload(raw) or {}).get("run_id") or "") or None
    key = (sid, since)
    entry = {"run_id": run_id, "text": "", "ended": False, "t": time.time()}
    pending_put(key, entry)
    threading.Thread(target=sse_reader, args=(cookie, sid, key, after_id, entry),
                     daemon=True).start()
    return 200, {"ok": 1, "sid": sid, "since": since}


def api_status(cookie, qs):
    sid = str(qs.get("sid", [""])[0])
    try:
        since = int(qs.get("since", ["0"])[0] or 0)
    except ValueError:
        since = 0
    w, fs = qs.get("w", [None])[0], qs.get("fs", [None])[0]
    status, raw = miyu_call("GET", f"/api/sessions/{sid}/turns?limit=6", cookie)
    if status == 401:
        return 401, {"auth": 0, "error": {"message": "登录已过期"}}
    if status != 200:
        return 502, {"error": {"message": err_msg(raw, "读取回合失败")}}
    j = jload(raw) or {}
    turns = sorted(j.get("turns") or [], key=lambda t: max_seq([t]))
    mine = [t for t in turns if max_seq([t]) > since]
    key = (sid, since)
    entry = pending_get(key)
    partial = entry["text"] if entry else ""
    turn = mine[-1] if mine else None
    if turn is None:
        # 快照里还没出现这条（可能在排队），SSE 若已在吐字就先给流式文本
        if partial:
            return 200, {"state": "running", "text": process(partial, w, fs)}
        return 200, {"state": "waiting"}
    if str(turn.get("status") or "") != "completed":
        tools, skills, mcp = tool_counts(turn)
        names = _tool_names(turn)
        if names:
            live = "生成中 · 调用 " + "、".join(names[:3]) + ("等" if len(names) > 3 else "")
        elif (tools + skills + mcp):
            live = f"生成中 · 已调工具{tools + skills + mcp}次"
        else:
            live = ""
        if partial:
            return 200, {"state": "running", "text": process(partial, w, fs), "live": live}
        return 200, {"state": "running", "live": live}
    pending_pop(key)
    text = _full_text(turn)
    if not text.strip() and partial:
        text = partial                          # 落库漏了就拿 SSE 攒的兜底
    if not text.strip():
        text = "（这轮没有正文，可能在网页版等你回答）"
    ctx = _ctx_info(cookie, sid)
    obj = {"state": "done", "text": process(text, w, fs),
           "meta": fmt_meta(turn, ctx), "ctx": ctx}
    obj["ts"] = _fmt_ts(turn.get("assistant_timestamp"))
    tn = _think_n(turn)
    if tn:
        obj["think_n"] = tn
    obj["seq"] = max_seq([turn])
    mids = _inline_images(sid, obj["seq"])
    if mids:
        obj["images"] = mids
    return 200, obj


def api_stream(handler, cookie, qs):
    """SSE 快照流（表端 EventSource 逐字刷新用）：
    本地攒字 2s 一刷；每 4s 或 SSE 线程收工时走完整 api_status
    （含落库定稿与灰字 meta）。先做一次完整状态完成鉴权，未发头前
    401/502 走普通 JSON。
    ⚠ 页面侧已改成"2s 轮询为主干、SSE 只当首字加速器"——真表浏览器
    （iOS WebKit 壳）的 EventSource 会静默挂死：连接200、无消息、无
    onerror、兜底 bail 也不跑。此流因此降级为锦上添花，坏掉不影响收活。"""
    sid = str(qs.get("sid", [""])[0])
    w, fs = qs.get("w", [None])[0], qs.get("fs", [None])[0]
    try:
        since = int(qs.get("since", ["0"])[0] or 0)
    except ValueError:
        since = 0
    st, obj = api_status(cookie, qs)
    if st != 200 or obj.get("auth") == 0:
        handler._json(obj, st or 502)
        return
    handler.send_response(200)
    handler.send_header("Content-Type", "text/event-stream; charset=utf-8")
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("Connection", "keep-alive")
    handler.send_header("X-Accel-Buffering", "no")     # nginx 别缓冲
    handler.end_headers()

    def emit(payload):
        handler.wfile.write(
            ("data: " + json.dumps(payload, ensure_ascii=False) + "\r\n\r\n")
            .encode("utf-8"))
        handler.wfile.flush()

    handler.close_connection = True              # 发完终态立刻收线，别占隧道
    emit(obj)
    if obj.get("state") not in ("running", "waiting"):
        return
    key = (sid, since)
    last = json.dumps(obj, ensure_ascii=False)
    deadline = time.time() + 330
    last_full = beats = time.time()
    while time.time() < deadline:
        time.sleep(1.0)                          # 1秒粒度（用户定档）
        entry = pending_get(key)
        now = time.time()
        if entry is None or entry.get("ended") or now - last_full >= 4.0:
            st, obj = api_status(cookie, qs)          # 定稿/灰字走全量
            last_full = now
        else:
            obj = {"state": "running", "text": process(entry["text"], w, fs)}
        s = json.dumps(obj, ensure_ascii=False)
        if s != last:
            emit(obj)
            last = s
            beats = now
        if obj.get("state") not in ("running", "waiting"):
            return
        if now - beats >= 20:                          # 心跳：保隧道/nginx 不掐线
            handler.wfile.write(b": hb\r\n\r\n")
            handler.wfile.flush()
            beats = now
    emit({"state": "timeout"})


def api_history(cookie, qs):
    sid = str(qs.get("sid", [""])[0])
    try:
        n = min(40, max(1, int(qs.get("n", ["20"])[0] or 20)))
    except ValueError:
        n = 20
    w, fs = qs.get("w", [None])[0], qs.get("fs", [None])[0]
    status, raw = miyu_call("GET", f"/api/sessions/{sid}/turns?limit={n}", cookie)
    if status == 401:
        return 401, {"auth": 0, "error": {"message": "登录已过期"}}
    if status != 200:
        return 502, {"error": {"message": err_msg(raw, "读取历史失败")}}
    turns = sorted((jload(raw) or {}).get("turns") or [], key=lambda t: max_seq([t]))
    messages = []
    for t in turns:
        u = str(t.get("user_content") or "")
        a = _full_text(t)
        if u:
            messages.append({"role": "u", "text": u, "ts": _fmt_ts(t.get("user_timestamp"))})
        if a.strip():
            msg = {"role": "a", "text": process(a, w, fs)}
            msg["ts"] = _fmt_ts(t.get("assistant_timestamp"))
            meta = fmt_meta(t)
            if meta:
                msg["meta"] = meta
            mids = _inline_images(sid, max_seq([t]))
            if mids:
                msg["images"] = mids
            tn = _think_n(t)
            if tn:
                msg["think_n"] = tn
            msg["seq"] = max_seq([t])
            messages.append(msg)
    return 200, {"messages": messages}


def api_newsession(cookie):
    """新建一条会话（走 miyu 自己的 POST /api/sessions）。"""
    status, raw = miyu_call("POST", "/api/sessions", cookie, {})
    if status == 401:
        return 401, {"auth": 0, "error": {"message": "登录已过期"}}
    if status not in (200, 201, 202):        # miyu 建会话回201
        return status or 502, {"error": {"message": err_msg(raw, "建会话失败")}}
    rec = (jload(raw) or {}).get("session") or {}
    return 200, {"id": str(rec.get("session_id") or ""),
                 "name": str(rec.get("name") or "新会话")}


# ------------------------------------------------------------- 会话模型选择

def resolve_latest_sid(cookie):
    """空 sid 时解析最新会话；失败返回 (None, (状态码, 错误体))。"""
    st, raw = miyu_call("GET", "/api/bootstrap", cookie)
    if st == 401:
        return None, (401, {"auth": 0, "error": {"message": "登录已过期"}})
    if st != 200:
        return None, (502, {"error": {"message": f"取会话列表失败 HTTP {st}"}})
    boot = jload(raw) or {}
    sid = pick_latest(boot, boot.get("sessions") or [])
    if not sid:
        return None, (400, {"error": {"message": "没有可用会话"}})
    return sid, None


def api_models_list(cookie, sid):
    """模型目录（懒加载由页面控制）+ 本会话当前覆盖。"""
    st, raw = miyu_call("GET", "/api/config", cookie)
    if st == 401:
        return 401, {"auth": 0, "error": {"message": "登录已过期"}}
    if st != 200:
        return st or 502, {"error": {"message": err_msg(raw, "读配置失败")}}
    cfg = ((jload(raw) or {}).get("config") or {})
    seen, models = set(), []
    for p in cfg.get("providers") or []:
        if not isinstance(p, dict):
            continue
        pid = str(p.get("id") or p.get("provider_id") or "")
        for m in p.get("models") or []:
            name = str(m.get("model") if isinstance(m, dict) else m or "")
            full = f"{pid}/{name}"
            if pid and name and full not in seen:
                seen.add(full)
                models.append(full)
    cur = None
    if sid:
        st2, raw2 = miyu_call("GET", f"/api/sessions/{sid}/models", cookie)
        if st2 == 200:
            cur = (jload(raw2) or {}).get("model_override")
    return 200, {"models": models, "current": cur}


def api_models_current(cookie, sid):
    """只取本会话覆盖（几字节，开机/切会话时刷一行字用，别拉全目录）。"""
    st, raw = miyu_call("GET", f"/api/sessions/{sid}/models", cookie)
    if st == 401:
        return 401, {"auth": 0, "error": {"message": "登录已过期"}}
    if st != 200:
        return st or 502, {"error": {"message": err_msg(raw, "读模型失败")}}
    return 200, {"current": (jload(raw) or {}).get("model_override")}


def api_models_set(cookie, payload):
    sid = str(payload.get("sid") or "")
    if not sid:
        sid, err = resolve_latest_sid(cookie)
        if err:
            return err
    pid = str(payload.get("pid") or "")
    model = str(payload.get("model") or "")
    models = ([{"provider_id": pid, "model": model}] if pid and model else [])
    st, raw = miyu_call("PUT", f"/api/sessions/{sid}/models", cookie,
                        {"models": models})
    if st == 401:
        return 401, {"auth": 0, "error": {"message": "登录已过期"}}
    if st != 200:
        return st or 502, {"error": {"message": err_msg(raw, "换模型失败")}}
    return 200, {"model_override": (jload(raw) or {}).get("model_override"),
                 "sid": sid}


def api_delsession(cookie, payload):
    """删除会话：miyu DELETE /api/sessions/{id}。正在跑回合的不许删
    （WebUI 看着的那条被删会拿回执里的 fallback 顶替）。"""
    sid = str(payload.get("sid") or "")
    if not sid:
        # 删除绝不兜底解析"最新会话"——手滑删掉刚活跃的那条太危险，宁可拒绝
        return 400, {"error": {"message": "缺 sid：删除必须指名道姓"}}
    st, raw = miyu_call("GET", f"/api/sessions/{sid}/turns?limit=1", cookie)
    if st == 401:
        return 401, {"auth": 0, "error": {"message": "登录已过期"}}
    if st == 200:
        ts = (jload(raw) or {}).get("turns") or []
        if ts and str(ts[-1].get("status") or "") in ("running", "queued"):
            return 409, {"error": {"message": "这条会话正有回合在跑，等它说完再删"}}
    st, raw = miyu_call("DELETE", f"/api/sessions/{sid}", cookie)
    if st == 401:
        return 401, {"auth": 0, "error": {"message": "登录已过期"}}
    if st != 200:
        return st or 502, {"error": {"message": err_msg(raw, "删除失败")}}
    fb = (jload(raw) or {}).get("fallback") or {}
    return 200, {"ok": 1, "sid": sid,
                 "fallback": {"id": str(fb.get("session_id") or ""),
                              "name": str(fb.get("name") or "新会话")}}




def api_rename(cookie, payload):
    """重命名会话：miyu PATCH /api/sessions/{sid} {name}。"""
    sid = str(payload.get("sid") or "")
    name = str(payload.get("name") or "").strip()
    if not sid:
        return 400, {"error": {"message": "缺 sid：重命名必须指名道姓"}}
    if not name:
        return 400, {"error": {"message": "缺 name：新名字不能为空"}}
    st, raw = miyu_call("PATCH", f"/api/sessions/{sid}", cookie, {"name": name})
    if st == 401:
        return 401, {"auth": 0, "error": {"message": "登录已过期"}}
    if st != 200:
        return st or 502, {"error": {"message": err_msg(raw, "重命名失败")}}
    return 200, {"ok": 1, "sid": sid, "name": name}


# ------------------------------------------------- 立即压缩（无视阈值硬压）

PWFILE = os.path.expanduser(os.environ.get("WATCH_PWFILE", "~/.miyu/watch/.webpw"))


def _summary_count(sid):
    """会话里摘要回合的数量：daemon 自己折叠了也算压缩成功。"""
    try:
        db = sqlite3.connect(
            DB_PATH,
            timeout=5)
        try:
            return db.execute(
                "SELECT count(*) FROM turns WHERE session_id=? AND is_summary=1",
                (sid,)).fetchone()[0]
        finally:
            db.close()
    except Exception:
        return -1


def force_compact(sid):
    """热改 context 参数 → 触发压缩 → 秒级窗口内还原。
    用 .webpw 里的密码自己登录拿 cookie，全程不经表、不经调用方。
    压缩资格按"回合发生时"的配置盖章，所以要在强制配置下塞一轮极小
    对话重盖章；daemon 常在那轮完成时自己就折叠了，CLI 只是兜底。
    返回 (是否真的压了, CLI/过程输出)。"""
    cfg_path = os.path.expanduser("~/.miyu/config/config.jsonc")
    try:
        saved_cfg = open(cfg_path, "rb").read()   # PUT 会重写文件，留原件还魂
    except OSError:
        saved_cfg = None
    try:
        pw = open(PWFILE, encoding="utf-8").read().strip()
    except OSError:
        raise RuntimeError("无密码文件 ~/.miyu/watch/.webpw，无法强制压缩")
    status, raw, headers = miyu_call(
        "POST", "/api/auth/login", "",
        {"username": WATCH_USER, "password": pw}, with_headers=True)
    if status != 204:
        raise RuntimeError(f"中继登录失败 HTTP {status}")
    sc = headers.get("Set-Cookie") if headers else ""
    m = re.search(r"miyu_session=([^;]+)", sc)
    if not m:
        raise RuntimeError("登录响应没有会话 cookie")
    jcookie = "miyu_session=" + m.group(1)
    status, raw = miyu_call("GET", "/api/config", jcookie)
    if status != 200:
        raise RuntimeError(f"读配置失败 HTTP {status}")
    cfg = jload(raw) or {}
    def payload(conf):
        return {"config": conf, "secrets": {},
                "prompts": cfg.get("prompts", {}), "reset_conversation": False}
    force = json.loads(json.dumps(cfg.get("config") or {}))
    force.setdefault("context", {})
    force["context"]["compact_at_ratio"] = 0.1
    force["context"]["compact_tail_tokens"] = 1
    st, _ = miyu_call("PUT", "/api/config", jcookie, payload(force))
    if st != 200:
        raise RuntimeError(f"热改配置失败 HTTP {st}")
    try:
        s0 = _summary_count(sid)
        st, raw = miyu_call("GET", f"/api/sessions/{sid}/turns?limit=500",
                            jcookie)
        before = len((jload(raw) or {}).get("turns") or [])
        for _ in range(150):        # 会话正忙就等它空下来再塞这轮
            st, raw = miyu_call("POST", "/api/turns", jcookie,
                                {"content": "嗯。", "session_id": sid})
            if st != 409:
                break
            time.sleep(2)
        for _ in range(150):        # 等注入的这轮真正落地跑完
            st, raw = miyu_call("GET", f"/api/sessions/{sid}/turns?limit=500",
                                jcookie)
            ts = (jload(raw) or {}).get("turns") or []
            if (len(ts) > before and ts[-1].get("user_content") == "嗯。"
                    and ts[-1].get("status") in ("completed", "cancelled",
                                                 "failed")):
                break
            time.sleep(2)
        open(cfg_path, "w").write(
            json.dumps(force, ensure_ascii=False, indent=2))
        r = subprocess.run(["/usr/bin/miyu", "session", "compact", sid],
                           capture_output=True, text=True, timeout=600)
        out = (r.stdout + r.stderr).strip()[-200:] or "(无输出)"
        s1 = _summary_count(sid)
        ok = ("已压缩" in out) or (s0 >= 0 and s1 > s0)
        return ok, out
    finally:
        miyu_call("PUT", "/api/config", jcookie, payload(cfg.get("config") or {}))
        if saved_cfg is not None:
            try:
                open(cfg_path, "wb").write(saved_cfg)
            except OSError:
                pass


def api_compact(cookie, payload):
    sid = str(payload.get("sid") or "")
    if not sid:
        sid, err = resolve_latest_sid(cookie)   # 抢跑空sid：解析最新会话
        if err:
            return err
    if payload.get("force"):
        st, _ = miyu_call("GET", "/api/status?sid=" + sid, cookie)
        if st == 401:
            return 401, {"auth": 0, "error": {"message": "登录已过期"}}
        if st != 200:
            return 502, {"error": {"message": f"校验登录失败 HTTP {st}"}}
        try:
            ok, out = force_compact(sid)
        except Exception as exc:
            return 502, {"error": {"message": f"强制压缩失败：{exc}"}}
        return 200, {"compacted": bool(ok), "forced": 1, "detail": out}
    status, raw = miyu_call("POST", "/api/conversation/compact", cookie,
                            {"session_id": sid})
    if status == 401:
        return 401, {"auth": 0, "error": {"message": "登录已过期"}}
    if status != 200:
        return status or 502, {"error": {"message": err_msg(raw, "压缩失败")}}
    res = (jload(raw) or {}).get("result") or {}
    return 200, {"compacted": bool(res.get("compacted"))}


# ------------------------------------------------------- 登录中继（多域名用）

def api_auth_status():
    status, raw = miyu_call("GET", "/api/auth/status")
    if status != 200:
        return status or 502, {"error": {"message": err_msg(raw, "拿不到登录信息")}}
    return 200, jload(raw) or {}


def api_login(raw_body):
    """把表上填的账号密码原样转给 miyu /api/auth/login，Set-Cookie 透传回去。
    密码只在这一次请求里过手，不写日志、不落盘。"""
    try:
        req = urllib.request.Request(
            MIYU + "/api/auth/login", data=raw_body, method="POST",
            headers={"Accept": "application/json", "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            status, raw, headers = resp.status, resp.read(), resp.headers
    except urllib.error.HTTPError as exc:
        status, raw, headers = exc.code, exc.read(), exc.headers
    except Exception as exc:
        return 502, [], json.dumps({"error": {"message": f"miyu 不可达: {exc}"}},
                                   ensure_ascii=False).encode("utf-8")
    extra = [("Set-Cookie", sc)
             for sc in ((headers.get_all("Set-Cookie") or []) if headers else [])]
    return status, extra, (raw if raw else b"{}")


def api_logout(cookie):
    """转发 miyu /api/auth/logout，把清 cookie 的 Set-Cookie 原样带回。"""
    try:
        req = urllib.request.Request(MIYU + "/api/auth/logout", data=b"", method="POST",
                                     headers={"Accept": "application/json",
                                              "Content-Type": "application/json"})
        if cookie:
            req.add_header("Cookie", cookie)
        with urllib.request.urlopen(req, timeout=15) as resp:
            status, headers = resp.status, resp.headers
    except urllib.error.HTTPError as exc:
        status, headers = exc.code, exc.headers
    except Exception as exc:
        return 502, [], json.dumps({"error": {"message": f"miyu 不可达: {exc}"}},
                                   ensure_ascii=False).encode("utf-8")
    extra = [("Set-Cookie", sc)
             for sc in ((headers.get_all("Set-Cookie") or []) if headers else [])]
    if status == 204:                 # 204 不许带正文，我们回 {"ok":1}，改成 200
        status = 200
    return status, extra, b'{"ok":1}'


# ------------------------------------------------------------------ HTTP 层

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "watchd"

    def log_message(self, fmt, *args):
        try:
            ua = self.headers.get("User-Agent", "-")
            log(f"{self.client_address[0]} {fmt % args} | {ua[:120]}")
        except Exception:
            pass

    def _send(self, status, body, ctype, extra=()):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _json(self, obj, status=200):
        self._send(status, json.dumps(obj, ensure_ascii=False).encode("utf-8"),
                   "application/json; charset=utf-8")

    def _page(self):
        try:
            with open(PAGE, "rb") as fh:
                body = fh.read()
        except OSError:
            self._json({"error": {"message": "页面缺失"}}, 500)
            return
        body = body.replace(b"__PV__", _pv().encode("ascii"))
        self._send(200, body, "text/html; charset=utf-8", extra=(
            ("Content-Security-Policy",
             "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
             "connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'self'"),
            ("X-Content-Type-Options", "nosniff"),
        ))

    def _dispatch(self, method):
        parsed = urlparse(self.path)
        path, qs = parsed.path, parse_qs(parsed.query)
        cookie = self.headers.get("Cookie", "") or ""
        try:
            # 入口前缀：/watch（隧道）与 /watch_ai（自建反代前缀）
            base = rest = None
            for b in ("/watch_ai", "/watch"):
                if path == b or path.startswith(b + "/"):
                    base, rest = b, path[len(b):] or "/"
                    break
            if base is None:
                self._json({"error": {"message": "not found"}}, 404)
                return
            if rest == "/":
                self._page()
                return
            if rest == "/index.html":
                self._page()
                return
            if rest == "/api/auth-status" and method == "GET":
                st, obj = api_auth_status()
                self._json(obj, st)
                return
            if rest == "/api/login" and method == "POST":
                length = min(8192, int(self.headers.get("Content-Length") or 0))
                st, extra, body = api_login(self.rfile.read(length) if length else b"{}")
                self._send(st, body, "application/json; charset=utf-8", extra=extra)
                return
            if rest == "/api/logout" and method == "POST":
                st, extra, body = api_logout(cookie)
                self._send(st, body, "application/json; charset=utf-8", extra=extra)
                return
            if rest == "/api/state" and method == "GET":
                st, obj = api_state(cookie)
                self._json(obj, st)
                return
            if rest == "/api/send" and method == "POST":
                length = min(65536, int(self.headers.get("Content-Length") or 0))
                raw = self.rfile.read(length) if length else b""
                try:
                    payload = json.loads(raw.decode("utf-8", "replace"))
                except ValueError:
                    self._json({"error": {"message": "请求体不是 JSON"}}, 400)
                    return
                if not isinstance(payload, dict):
                    self._json({"error": {"message": "请求体不是对象"}}, 400)
                    return
                st, obj = api_send(cookie, payload)
                self._json(obj, st)
                return
            if rest == "/api/status" and method == "GET":
                st, obj = api_status(cookie, qs)
                self._json(obj, st)
                return
            if rest == "/api/stream" and method == "GET":
                api_stream(self, cookie, qs)
                return
            if rest == "/api/history" and method == "GET":
                st, obj = api_history(cookie, qs)
                self._json(obj, st)
                return
            if rest == "/api/new-session" and method == "POST":
                st, obj = api_newsession(cookie)
                self._json(obj, st)
                return
            if rest == "/api/compact" and method == "POST":
                length = min(65536, int(self.headers.get("Content-Length") or 0))
                raw = self.rfile.read(length) if length else b""
                try:
                    payload = json.loads(raw.decode("utf-8", "replace"))
                except ValueError:
                    payload = {}
                if not isinstance(payload, dict):
                    payload = {}
                st, obj = api_compact(cookie, payload)
                self._json(obj, st)
                return
            if rest == "/api/models" and method == "GET":
                sid0 = str(qs.get("sid", [""])[0])
                if qs.get("lite"):
                    st, obj = api_models_current(cookie, sid0)
                else:
                    st, obj = api_models_list(cookie, sid0)
                self._json(obj, st)
                return
            if rest == "/api/ctx" and method == "GET":
                self._json({"ctx": _ctx_info(cookie,
                                             str(qs.get("sid", [""])[0]))}, 200)
                return
            if rest == "/api/camimg" and method == "GET":
                # 摄像头快照：miyu 鉴权后直接吐 /tmp/cam1.jpg 字节
                if not _authed(cookie):
                    self.send_response(401)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                snap = "/tmp/cam1.jpg"
                try:
                    with open(snap, "rb") as f:
                        data = f.read()
                    self.send_response(200)
                    self.send_header("Content-Type", "image/jpeg")
                    self.send_header("Content-Length", str(len(data)))
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    self.wfile.write(data)
                except OSError:
                    self.send_response(404)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                return
            if rest == "/api/img" and method == "GET":
                # 内联图字节：鉴权走 miyu，内容本地库直读
                # （表端点了才加载 <img>，cookie 同源自动带）
                if not _authed(cookie):
                    self.send_response(401)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                try:
                    mid = int(str(qs.get("mid", ["0"])[0] or 0))
                except ValueError:
                    mid = 0
                row = None
                if mid:
                    try:
                        con = sqlite3.connect(f"file:{DB_PATH}?mode=ro",
                                              uri=True, timeout=2)
                        try:
                            row = con.execute(
                                "SELECT mime, data FROM turn_inline_media "
                                "WHERE media_id=? AND kind='image'",
                                (mid,)).fetchone()
                        finally:
                            con.close()
                    except sqlite3.Error:
                        row = None
                if not row or not row[1]:
                    self.send_response(404)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                data = bytes(row[1])
                self.send_response(200)
                self.send_header("Content-Type", str(row[0] or "image/png"))
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "private, max-age=3600")
                self.end_headers()
                self.wfile.write(data)
                return
            if rest == "/api/think" and method == "GET":
                # 思考内容按需取：不点不发。miyu 事件总线没有 reasoning
                # 增量（只有 assistant.delta/tool_flow），思考定稿才落库，
                # 所以流式期间这里本来就空——定稿后点开才有东西。
                if not _authed(cookie):
                    self._json({"auth": 0, "error": {"message": "登录已过期"}}, 401)
                    return
                tsid = str(qs.get("sid", [""])[0])
                try:
                    tseq = int(str(qs.get("seq", ["0"])[0] or 0))
                except ValueError:
                    tseq = 0
                w2, fs2 = qs.get("w", [None])[0], qs.get("fs", [None])[0]
                reason = ""
                if tsid and tseq:
                    try:
                        con = sqlite3.connect(f"file:{DB_PATH}?mode=ro",
                                              uri=True, timeout=2)
                        try:
                            row = con.execute(
                                "SELECT assistant_reasoning FROM turns "
                                "WHERE session_id=? AND seq=?",
                                (tsid, tseq)).fetchone()
                        finally:
                            con.close()
                        if row:
                            reason = str(row[0] or "")
                    except sqlite3.Error:
                        pass
                self._json({"think": process(reason.strip(), w2, fs2)}, 200)
                return
            if rest == "/api/models" and method == "POST":
                length = min(65536, int(self.headers.get("Content-Length") or 0))
                raw = self.rfile.read(length) if length else b""
                try:
                    payload = json.loads(raw.decode("utf-8", "replace"))
                except ValueError:
                    payload = {}
                if not isinstance(payload, dict):
                    payload = {}
                st, obj = api_models_set(cookie, payload)
                self._json(obj, st)
                return
            if rest == "/api/delsession" and method == "POST":
                length = min(65536, int(self.headers.get("Content-Length") or 0))
                raw = self.rfile.read(length) if length else b""
                try:
                    payload = json.loads(raw.decode("utf-8", "replace"))
                except ValueError:
                    payload = {}
                if not isinstance(payload, dict):
                    payload = {}
                st, obj = api_delsession(cookie, payload)
                self._json(obj, st)
                return
            if rest == "/api/rename" and method == "POST":
                length = min(65536, int(self.headers.get("Content-Length") or 0))
                raw = self.rfile.read(length) if length else b""
                try:
                    payload = json.loads(raw.decode("utf-8", "replace"))
                except ValueError:
                    payload = {}
                if not isinstance(payload, dict):
                    payload = {}
                st, obj = api_rename(cookie, payload)
                self._json(obj, st)
                return
            if rest == "/api/reorder" and method == "POST":
                if not _authed(cookie):
                    self._json({"auth": 0, "error": {"message": "登录已过期"}}, 401)
                    return
                length = min(65536, int(self.headers.get("Content-Length") or 0))
                raw = self.rfile.read(length) if length else b""
                try:
                    payload = json.loads(raw.decode("utf-8", "replace"))
                except ValueError:
                    payload = {}
                if not isinstance(payload, dict):
                    payload = {}
                st, obj = api_reorder(payload)
                self._json(obj, st)
                return
            if rest == "/api/updatecheck" and method == "GET":
                if not _authed(cookie):
                    self._json({"auth": 0, "error": {"message": "登录已过期"}}, 401)
                    return
                st, obj = api_updatecheck()
                self._json(obj, st)
                return
            self._json({"error": {"message": "not found"}}, 404)
        except Exception as exc:                 # 单请求出错不影响服务
            log(f"ERROR {type(exc).__name__}: {exc}")
            try:
                self._json({"error": {"message": f"内部错误: {exc}"}}, 500)
            except Exception:
                pass

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")


def main():
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True
    log(f"LISTEN {HOST}:{PORT} -> miyu {MIYU}")
    print(f"miyu-watchd on {HOST}:{PORT} -> {MIYU}", flush=True)
    srv.serve_forever(poll_interval=0.5)


if __name__ == "__main__":
    main()
