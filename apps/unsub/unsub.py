#!/usr/bin/env python3
"""unsub.py: unsubscribe from the email selected in Apple Mail.

Called by unsub.lua (Caps+U). Prints one JSON object on stdout:
  {"ok": bool, "sender": str, "method": str, "message": str, "open_url": str|null}
Progress and debug lines go to stderr.

Strategy, smartest first:
  1. RFC 8058 one-click: List-Unsubscribe-Post + https URL -> POST, done.
  2. mailto in List-Unsubscribe -> send the unsubscribe email from the
     account that received the message.
  3. Web unsubscribe page (header URL, else a link found in the body):
     fetch it, and if it is a confirm/preferences page, pick the
     "unsubscribe from everything" choice and submit it (OpenAI decides on
     unfamiliar pages; simple heuristics if no key). Follow up to 3 steps
     and verify the result page says you're unsubscribed.
  4. Anything it can't finish (JS-only page, captcha, login) -> returns
     open_url so the page opens in your browser.

--dry   decide and report the plan; no POST, no email, no page fetch.
--source FILE   use a saved .eml instead of Mail (testing).

Stdlib only; runs on /usr/bin/python3 (3.9).
"""

import email
import email.policy
import html
import http.cookiejar
import json
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from email.utils import getaddresses, parseaddr
from html.parser import HTMLParser

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/18.0 Safari/605.1.15")
OPENAI_URL = "https://api.openai.com/v1/responses"
OPENAI_MODEL = "gpt-5.4"           # same model Hone uses (--model overrides)
OPENAI_KEYCHAIN = "openai-refine"  # same key Hone uses
MAX_STEPS = 3
TIMEOUT = 20

SUCCESS_RE = re.compile(
    r"(successfully unsubscribed|you(?:'|’| ha)ve been (?:successfully )?(?:unsubscribed|removed)"
    r"|you(?:'|’| a)re (?:now |been )?unsubscribed|you are (?:now )?unsubscribed"
    r"|(?:have|has) been removed from|will no longer receive|won(?:'|’)t receive any more"
    r"|unsubscribe (?:was |is )?(?:successful|complete|confirmed)"
    r"|unsubscription (?:is )?(?:successful|complete|confirmed)"
    r"|(?:subscription|preferences) (?:has|have) been (?:cancel+ed|updated))",
    re.I)
UNSUB_WORD_RE = re.compile(r"unsub|opt[\s_-]?out|remove me|stop (?:all )?emails", re.I)
SUSPECT_RE = re.compile(r"captcha|recaptcha|hcaptcha|sign in to|log in to", re.I)


def log(*a):
    print("[unsub]", *a, file=sys.stderr, flush=True)


def finish(ok, sender, method, message, open_url=None):
    print(json.dumps({"ok": ok, "sender": sender, "method": method,
                      "message": message, "open_url": open_url}))
    sys.exit(0)


# --------------------------------------------------------------------------
# Mail
# --------------------------------------------------------------------------
SEP = "<<<UNSUB-SOURCE>>>"

FETCH_SCRIPT = f'''
tell application "Mail"
  set sel to selection
  if (count of sel) is 0 then return "ERR:none"
  if (count of sel) > 1 then return "ERR:many"
  set m to item 1 of sel
  set addrs to ""
  try
    repeat with a in (email addresses of (account of (mailbox of m)))
      set addrs to addrs & a & ","
    end repeat
  end try
  return addrs & linefeed & "{SEP}" & linefeed & (source of m)
end tell
'''


def osascript(script, timeout=30):
    p = subprocess.run(["/usr/bin/osascript", "-e", script],
                       capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip() or "osascript failed")
    return p.stdout


def fetch_selected():
    try:
        out = osascript(FETCH_SCRIPT)
    except subprocess.TimeoutExpired:
        finish(False, "", "error", "Mail didn't respond. If a permission prompt is open, allow it")
    except RuntimeError as e:
        msg = str(e)
        if "-1743" in msg or "not allowed" in msg.lower():
            finish(False, "", "error", "Allow Hammerspoon to control Mail: System Settings → "
                   "Privacy & Security → Automation")
        finish(False, "", "error", "Couldn't read the email from Mail: " + msg[:120])
    out = out.rstrip("\n")
    if out == "ERR:none":
        finish(False, "", "error", "No email selected in Mail")
    if out == "ERR:many":
        finish(False, "", "error", "Select just one email")
    head, _, src = out.partition("\n" + SEP + "\n")
    accounts = [a.strip().lower() for a in head.split(",") if a.strip()]
    return src, accounts


def send_mail(to, subject, body, sender, compose=False):
    def q(s):
        return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'
    sender_prop = f", sender:{q(sender)}" if sender else ""
    script = f'''
tell application "Mail"
  set m to make new outgoing message with properties {{subject:{q(subject)}, content:{q(body)}, visible:false{sender_prop}}}
  tell m to make new to recipient at end of to recipients with properties {{address:{q(to)}}}
  {"set visible of m to true" + chr(10) + "  activate" if compose else "send m"}
end tell
'''
    osascript(script)


# --------------------------------------------------------------------------
# Message parsing
# --------------------------------------------------------------------------
def parse_message(src):
    src = src.replace("\r\n", "\n").replace("\r", "\n")
    return email.message_from_string(src, policy=email.policy.default)


def header(msg, name):
    try:
        v = msg.get(name)
    except Exception:  # malformed header: fall back to raw
        v = msg.get_all(name, [None])[0] if hasattr(msg, "get_all") else None
    return str(v) if v is not None else ""


def sender_label(msg):
    name, addr = parseaddr(header(msg, "From"))
    return name or addr or "this sender"


def recipient_address(msg, accounts):
    """The address of yours this email was delivered to."""
    cands = []
    for h in ("Delivered-To", "X-Original-To", "To", "Cc"):
        cands += [a.lower() for _, a in getaddresses([header(msg, h)]) if a]
    for a in cands:
        if a in accounts:
            return a
    return accounts[0] if accounts else (cands[0] if cands else "")


def list_unsubscribe(msg):
    https = mailto = None
    for uri in re.findall(r"<\s*([^>]+?)\s*>", header(msg, "List-Unsubscribe")):
        uri = re.sub(r"\s+", "", uri)
        low = uri.lower()
        if not https and low.startswith(("https://", "http://")):
            https = uri
        elif not mailto and low.startswith("mailto:"):
            mailto = uri
    one_click = "one-click" in header(msg, "List-Unsubscribe-Post").lower()
    return https, mailto, one_click


def body_html_and_text(msg):
    html_part = text_part = ""
    for part in msg.walk():
        if part.is_multipart():
            continue
        ctype = part.get_content_type()
        if ctype not in ("text/html", "text/plain"):
            continue
        try:
            content = part.get_content()
        except Exception:
            payload = part.get_payload(decode=True) or b""
            content = payload.decode("utf-8", "replace")
        if ctype == "text/html" and not html_part:
            html_part = content
        elif ctype == "text/plain" and not text_part:
            text_part = content
    return html_part, text_part


def find_body_link(msg):
    html_body, text_body = body_html_and_text(msg)
    best = None
    for m in re.finditer(r'<a\b[^>]*?href\s*=\s*["\']?([^"\'\s>]+)[^>]*>(.*?)</a\s*>',
                         html_body, re.I | re.S):
        url = html.unescape(m.group(1))
        if not url.lower().startswith(("http://", "https://")):
            continue
        anchor = re.sub(r"<[^>]+>", " ", m.group(2))
        hay = url + " " + anchor
        if UNSUB_WORD_RE.search(hay):
            return url
        if not best and re.search(r"(manage|update|email|notification)s?[\s_-]*(preferences|subscriptions|settings)",
                                  hay, re.I):
            best = url
    if best:
        return best
    m = re.search(r"https?://[^\s\"'<>]*unsub[^\s\"'<>]*", text_body + " " + html_body, re.I)
    return html.unescape(m.group(0)) if m else None


def parse_mailto(uri):
    rest = uri[len("mailto:"):]
    addr, _, query = rest.partition("?")
    params = {k.lower(): v[0] for k, v in urllib.parse.parse_qs(query).items()}
    return (urllib.parse.unquote(addr), params.get("subject", "unsubscribe"),
            params.get("body", "unsubscribe"))


def host(url):
    return urllib.parse.urlparse(url).netloc or url


# --------------------------------------------------------------------------
# Web
# --------------------------------------------------------------------------
_jar = http.cookiejar.CookieJar()
_opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(_jar))


def http_request(url, data=None, method=None, extra_headers=None):
    headers = {"User-Agent": UA, "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
               "Accept-Language": "en-US,en;q=0.9"}
    headers.update(extra_headers or {})
    body = None
    if data is not None:
        body = urllib.parse.urlencode(data).encode() if not isinstance(data, bytes) else data
        headers.setdefault("Content-Type", "application/x-www-form-urlencoded")
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with _opener.open(req, timeout=TIMEOUT) as r:
            raw = r.read(2_000_000)
            charset = r.headers.get_content_charset() or "utf-8"
            return r.status, r.geturl(), raw.decode(charset, "replace")
    except urllib.error.HTTPError as e:
        raw = e.read(500_000) if hasattr(e, "read") else b""
        return e.code, url, raw.decode("utf-8", "replace")


class PageParser(HTMLParser):
    """Visible text plus a structured view of every form."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.text = []
        self.title = ""
        self.forms = []
        self._skip = 0
        self._in_title = False
        self._form = None
        self._label_for = None
        self._label_buf = None
        self._labels = {}
        self._select = None
        self._option = None
        self._button = None
        self._textarea = None
        self._wrapped_field = None

    def handle_starttag(self, tag, attrs):
        a = {k: (v if v is not None else "") for k, v in attrs}
        if tag in ("script", "style", "noscript", "template"):
            self._skip += 1
        elif tag == "title":
            self._in_title = True
        elif tag == "form":
            self._form = {"action": a.get("action", ""), "method": a.get("method", "get").lower(),
                          "fields": [], "buttons": []}
            self.forms.append(self._form)
        elif tag == "label":
            self._label_for = a.get("for")
            self._label_buf = []
        elif self._form is None:
            return
        elif tag == "input":
            t = a.get("type", "text").lower()
            if t in ("submit", "image"):
                self._form["buttons"].append({"name": a.get("name", ""), "value": a.get("value", ""),
                                              "text": a.get("value", "") or a.get("alt", "")})
            elif t not in ("button", "reset", "file"):
                f = {"name": a.get("name", ""), "type": t, "value": a.get("value", ""),
                     "checked": "checked" in a, "id": a.get("id", "")}
                if self._label_buf is not None and not self._label_for:
                    f["_wrapped"] = True
                    self._wrapped_field = f
                self._form["fields"].append(f)
        elif tag == "select":
            self._select = {"name": a.get("name", ""), "type": "select", "options": [],
                            "id": a.get("id", ""), "value": None}
            self._form["fields"].append(self._select)
        elif tag == "option" and self._select is not None:
            self._option = {"value": a.get("value"), "text": "", "selected": "selected" in a}
            self._select["options"].append(self._option)
        elif tag == "textarea":
            self._textarea = {"name": a.get("name", ""), "type": "textarea", "value": "",
                              "id": a.get("id", "")}
            self._form["fields"].append(self._textarea)
        elif tag == "button":
            t = a.get("type", "submit").lower()
            if t == "submit":
                self._button = {"name": a.get("name", ""), "value": a.get("value", ""), "text": ""}
                self._form["buttons"].append(self._button)

    def handle_endtag(self, tag):
        if tag in ("script", "style", "noscript", "template"):
            self._skip = max(0, self._skip - 1)
        elif tag == "title":
            self._in_title = False
        elif tag == "form":
            self._form = None
        elif tag == "label":
            txt = " ".join("".join(self._label_buf or []).split())
            if self._label_for:
                self._labels[self._label_for] = txt
            elif getattr(self, "_wrapped_field", None) is not None:
                self._wrapped_field["label"] = txt
                self._wrapped_field = None
            self._label_for = None
            self._label_buf = None
        elif tag == "select":
            self._select = None
        elif tag == "option":
            if self._option is not None and self._option["value"] is None:
                self._option["value"] = self._option["text"].strip()
            self._option = None
        elif tag == "button":
            self._button = None
        elif tag == "textarea":
            self._textarea = None

    def handle_data(self, data):
        if self._skip:
            return
        if self._in_title:
            self.title += data
        if self._label_buf is not None:
            self._label_buf.append(data)
        if self._option is not None:
            self._option["text"] += data
        if self._button is not None:
            self._button["text"] += data
        if self._textarea is not None:
            self._textarea["value"] += data
        self.text.append(data)

    def result(self):
        for form in self.forms:
            for f in form["fields"]:
                if f.get("id") and f["id"] in self._labels:
                    f["label"] = self._labels[f["id"]]
                f.pop("_wrapped", None)
            for b in form["buttons"]:
                b["text"] = " ".join(b["text"].split())
        text = " ".join(" ".join(self.text).split())
        return {"title": " ".join(self.title.split()), "text": text, "forms": self.forms}


def parse_page(page_html):
    p = PageParser()
    try:
        p.feed(page_html)
        p.close()
    except Exception as e:  # malformed HTML; keep what we have
        log("html parse error", e)
    return p.result()


def default_form_data(form):
    pairs = []
    for f in form["fields"]:
        name = f.get("name")
        if not name:
            continue
        t = f["type"]
        if t in ("checkbox", "radio"):
            if f.get("checked"):
                pairs.append((name, f.get("value") or "on"))
        elif t == "select":
            opts = f["options"]
            sel = next((o for o in opts if o["selected"]), opts[0] if opts else None)
            if sel is not None:
                pairs.append((name, sel["value"]))
        else:
            pairs.append((name, f.get("value", "")))
    return pairs


def apply_overrides(pairs, overrides):
    for name, val in (overrides or {}).items():
        pairs = [(n, v) for n, v in pairs if n != name]
        if val is None or val is False:
            continue
        vals = val if isinstance(val, list) else [val]
        pairs += [(name, "on" if v is True else str(v)) for v in vals]
    return pairs


def submit_form(page_url, form, overrides, button_index):
    pairs = apply_overrides(default_form_data(form), overrides)
    buttons = form["buttons"]
    if button_index is not None and 0 <= button_index < len(buttons):
        b = buttons[button_index]
        if b.get("name"):
            pairs.append((b["name"], b.get("value", "")))
    action = urllib.parse.urljoin(page_url, form["action"] or page_url)
    log("submit", form["method"], host(action), [n for n, _ in pairs])
    if form["method"] == "post":
        return http_request(action, data=pairs)
    sep = "&" if "?" in action else "?"
    return http_request(action + sep + urllib.parse.urlencode(pairs))


# --------------------------------------------------------------------------
# LLM judgment
# --------------------------------------------------------------------------
def openai_key():
    try:
        p = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", OPENAI_KEYCHAIN, "-w"],
                           capture_output=True, text=True, timeout=10)
        return p.stdout.strip() or None
    except Exception:
        return None


SYSTEM_PROMPT = """You operate an email-unsubscribe web page on the user's behalf.
Goal: stop ALL marketing/newsletter email from this sender to the user's address.
You get the page's visible text and its forms (fields, options, submit buttons, indexed from 0).
Reply with JSON only:
{"status": "done" | "submit" | "needs_user",
 "form": <form index or null>,
 "button": <button index within that form or null>,
 "set": {<field name>: <value | list of values | null to uncheck/clear>},
 "reason": "<short>"}
Rules:
- "done" if the page already confirms the user is unsubscribed/removed.
- "submit" with the form/button that unsubscribes from everything. Prefer "unsubscribe from all"
  over pausing, reducing frequency, or snoozing. In preference-center forms, uncheck every
  subscription checkbox and/or check the "unsubscribe from all" box.
- If an email field is required and empty, set it to the user's address given below. Never enter any
  other personal data, passwords, or free-text reasons (leave optional reason fields alone).
- "needs_user" for captchas, logins, pages whose controls are rendered by JavaScript (no usable
  form), or anything ambiguous or risky (e.g. buttons that would delete an account or cancel a paid plan)."""


def llm_decide(key, page, url, user_addr):
    forms = []
    for i, f in enumerate(page["forms"][:6]):
        forms.append({"index": i, "method": f["method"], "action": f["action"][:200],
                      "fields": [{k: v for k, v in fld.items() if k != "id"} for fld in f["fields"][:60]],
                      "buttons": [{"index": j, "text": b["text"][:80], "name": b["name"]}
                                  for j, b in enumerate(f["buttons"][:10])]})
    user = (f"User's address: {user_addr or 'unknown'}\nPage URL host: {host(url)}\n"
            f"Title: {page['title'][:200]}\nVisible text:\n{page['text'][:5000]}\n\n"
            f"Forms:\n{json.dumps(forms)[:9000]}\n\nRespond with the JSON decision.")
    body = json.dumps({"model": OPENAI_MODEL, "instructions": SYSTEM_PROMPT, "input": user,
                       "reasoning": {"effort": "low"},
                       "text": {"format": {"type": "json_object"}}}).encode()
    req = urllib.request.Request(OPENAI_URL, data=body, headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=45) as r:
            resp = json.loads(r.read())
    except Exception as e:
        log("llm error", e)
        return None
    out = ""
    for item in resp.get("output", []):
        for c in item.get("content", []) or []:
            if c.get("type") == "output_text":
                out += c.get("text", "")
    try:
        decision = json.loads(out)
        log("llm", decision)
        return decision
    except Exception:
        log("llm unparsable", out[:200])
        return None


def heuristic_decide(page, user_addr):
    """No-LLM fallback: one obvious unsubscribe/confirm button → press it."""
    for i, f in enumerate(page["forms"]):
        for j, b in enumerate(f["buttons"]):
            if re.search(r"unsub|confirm|opt.?out|remove", b["text"] or b["value"], re.I):
                sets = {}
                for fld in f["fields"]:
                    if fld["type"] == "email" and not fld.get("value") and user_addr:
                        sets[fld["name"]] = user_addr
                    if fld["type"] == "checkbox" and re.search(r"all|everything", fld.get("label", ""), re.I) \
                            and UNSUB_WORD_RE.search(fld.get("label", "")):
                        sets[fld["name"]] = fld.get("value") or "on"
                return {"status": "submit", "form": i, "button": j, "set": sets, "reason": "heuristic"}
    return {"status": "needs_user", "reason": "no obvious unsubscribe button"}


def page_says_done(page):
    return bool(SUCCESS_RE.search(page["title"] + " " + page["text"][:4000]))


def web_unsubscribe(url, sender, user_addr, method_label, use_ai=True):
    key = openai_key() if use_ai else None
    status, final_url, body = http_request(url)
    log("GET", status, host(final_url))
    if status >= 400:
        finish(False, sender, method_label, f"{host(url)} returned {status}. Opening the page", url)
    for step in range(MAX_STEPS):
        page = parse_page(body)
        if page_says_done(page) and not page["forms"]:
            finish(True, sender, method_label, f"Unsubscribed from {sender} ({host(final_url)})")
        if SUSPECT_RE.search(page["text"][:3000]):
            finish(False, sender, method_label, "Page needs a captcha or login. Opening it", final_url)
        decision = llm_decide(key, page, final_url, user_addr) if key else None
        if decision is None:
            if page_says_done(page):
                finish(True, sender, method_label, f"Unsubscribed from {sender} ({host(final_url)})")
            decision = heuristic_decide(page, user_addr)
        st = decision.get("status")
        if st == "done":
            finish(True, sender, method_label, f"Unsubscribed from {sender} ({host(final_url)})")
        if st != "submit":
            why = decision.get("reason") or "needs a click"
            finish(False, sender, method_label, f"Finish on the page: {why}", final_url)
        try:
            form = page["forms"][int(decision.get("form") or 0)]
        except (IndexError, ValueError, TypeError):
            finish(False, sender, method_label, "Couldn't find the form. Opening the page", final_url)
        btn = decision.get("button")
        status, final_url, body = submit_form(final_url, form, decision.get("set") or {},
                                              int(btn) if isinstance(btn, (int, float, str)) and str(btn).isdigit() else None)
        log("submit ->", status, host(final_url), f"step {step + 1}")
        if status >= 400:
            finish(False, sender, method_label, f"Submit failed ({status}). Opening the page", url)
    page = parse_page(body)
    if page_says_done(page):
        finish(True, sender, method_label, f"Unsubscribed from {sender} ({host(final_url)})")
    finish(False, sender, method_label, "Couldn't confirm it worked. Opening the page", final_url)


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
def main():
    args = sys.argv[1:]
    dry = "--dry" in args
    compose = "--compose" in args
    use_ai = "--no-ai" not in args
    if "--model" in args:
        global OPENAI_MODEL
        OPENAI_MODEL = args[args.index("--model") + 1]
    if "--source" in args:
        with open(args[args.index("--source") + 1], encoding="utf-8", errors="replace") as fh:
            src, accounts = fh.read(), []
    else:
        src, accounts = fetch_selected()

    msg = parse_message(src)
    sender = sender_label(msg)
    user_addr = recipient_address(msg, accounts)
    https, mailto, one_click = list_unsubscribe(msg)
    log("sender", sender, "| https", https and host(https), "| mailto", bool(mailto),
        "| one-click", one_click, "| to", user_addr)

    # 1. One-click
    if https and one_click and https.lower().startswith("https://"):
        if dry:
            finish(True, sender, "one-click", f"DRY RUN: one-click POST to {host(https)}")
        status, _, _ = http_request(https, data=b"List-Unsubscribe=One-Click", method="POST",
                                    extra_headers={"Content-Type": "application/x-www-form-urlencoded"})
        log("one-click", status)
        if 200 <= status < 300 or status in (301, 302, 303):
            finish(True, sender, "one-click", f"Unsubscribed from {sender}")
        log("one-click failed; trying next method")

    # 2. mailto
    if mailto:
        to, subject, body = parse_mailto(mailto)
        if to:
            if dry:
                finish(True, sender, "mailto", f"DRY RUN: email {to} from {user_addr or 'default account'}")
            try:
                send_mail(to, subject, body, user_addr, compose)
                finish(True, sender, "mailto", f"Unsubscribe draft ready for {sender}. Press Send"
                       if compose else f"Unsubscribe email sent for {sender}")
            except Exception as e:
                log("mailto failed", e)

    # 3. Web page (header link, else body link)
    url, label = (https, "web") if https else (find_body_link(msg), "body link")
    if url:
        if dry:
            finish(True, sender, label, f"DRY RUN: open and complete {host(url)} ({label})")
        web_unsubscribe(url, sender, user_addr, label, use_ai)

    finish(False, sender, "none", f"No unsubscribe option found for {sender}")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        log("crash", repr(e))
        finish(False, "", "error", f"Unsub crashed: {e}"[:160])
