"""Copies the public part of this repository to a clean checkout of the public one (ADR 0026). Never commits or pushes.

  publish.py --repo . --allow tools/publish/public-paths.txt [--target FOLDER]
  publish.py --files ASSET...        check release assets instead
Forbidden values (tenant id and so on) come from the CRDR_FORBID environment variable, one per line, and are never
printed. Without --target it only plans and checks. Run it through setup/dev/Publish-Public.ps1.
Text inside images can't be checked. Exit code 1 if anything is refused.
"""
import argparse
import importlib.util
import io
import os
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))

# label, what is refused, what is allowed
CHECKS = [
    ("sensitivity label", re.compile(r"MSIP_Label_|docMetadata/LabelInfo|mipLabelMetadata", re.I), None),
    ("environment address", re.compile(r"[a-z0-9-]+\.(?:api\.)?crm\d*\.dynamics\.com", re.I), re.compile(r"^(example|contoso|yourorg)\.", re.I)),
    ("sign-in domain", re.compile(r"[a-z0-9-]+\.onmicrosoft\.com", re.I), re.compile(r"^contoso\.", re.I)),
    ("email address", re.compile(r"\b[a-z0-9._%+-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|org|net|uk|co|io|world|eu|dev|ch)\b", re.I),
     re.compile(r"@(?:[a-z0-9-]+\.)*example\.(?:com|org|net)$|@contoso\.com$|noreply@", re.I)),
    ("local path", re.compile(r"\b[a-z]:[\\/]+users[\\/]+[a-z][\w.~-]+", re.I), re.compile(r"users[\\/]+(?:public|you|username)$", re.I)),
    ("private key", re.compile(r"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----"), None),
]
# These describe the checks themselves. They are still checked for forbidden values.
SELF = {"tools/publish/publish.py", "tools/docbuild/clean-output.py", "tests/publish/cases.json"}
# Written by the test and schema tools, which would drop a link.
GENERATED = {"tests/results.md", "solutions/design/schema.md"}
BINARY = (".png", ".jpg", ".zip", ".docx", ".pdf")
LINK = re.compile(r"\[[^\]]*\]\(<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\)")


def git(repo, *args, check=True):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True)
    if check and r.returncode:
        raise SystemExit(r.stderr.decode("utf-8", "replace"))
    return r.stdout.decode("utf-8")


def read_allow(path):
    with open(path, encoding="utf-8") as f:
        lines = [x.split("#")[0].strip() for x in f]
    return [x for x in lines if x]


def matches(pattern, path):
    return path.startswith(pattern) if pattern.endswith("/") else path == pattern


def select(tracked, allow):
    inc = [p for p in allow if not p.startswith("!")]
    exc = [p[1:] for p in allow if p.startswith("!")]
    problems = [f"{p}: matches nothing" for p in inc + exc if not any(matches(p, t) for t in tracked)]
    chosen = [t for t in tracked if any(matches(p, t) for p in inc) and not any(matches(p, t) for p in exc)]
    return chosen, problems


def pdf_text(data):
    spec = importlib.util.spec_from_file_location("clean_output", os.path.join(HERE, "..", "docbuild", "clean-output.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    fd, path = tempfile.mkstemp(suffix=".pdf")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        return mod.pdf_text(path)
    finally:
        os.remove(path)


def parts(name, data, depth=0):
    """(name, text, raw) for a file and everything inside it. raw: the undecoded bytes of a binary file."""
    raw = name.lower().endswith(BINARY)
    yield name, data.decode("utf-8", "replace"), raw
    if b"\0" in data:
        for enc in ("utf-16-le", "utf-16-be"):
            for offset in (0, 1):
                yield name, data[offset:].decode(enc, "ignore"), True
    if data[:4] == b"%PDF":
        yield name, pdf_text(data), False
    elif data[:4] == b"PK\x03\x04":
        if depth > 5:
            raise ValueError("nested too deeply")
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            for item in z.infolist():
                inner = f"{name}!{item.filename}"
                yield inner, item.filename, False
                content = z.read(item)
                yield from parts(inner, content, depth + 1)
                if item.filename.endswith(".xml"):  # text split across runs
                    yield inner, re.sub(r"<[^>]+>", "", content.decode("utf-8", "replace")), False


def scan(name, data, forbid):
    found = set()
    try:
        for where, text, raw in [(name, name, False), *parts(name, data)]:
            low = text.lower()
            for v in forbid:
                bare = v.lower().replace("-", "")
                if v.lower() in low or (len(bare) == 32 and bare in low):
                    found.add(f"{where}: forbidden value")
            if name in SELF:
                continue
            for label, pattern, ok in CHECKS:
                if raw and label in ("email address", "local path"):
                    continue  # chance matches in compressed bytes; the decoded content is checked
                if any(not (ok and ok.search(m.group(0))) for m in pattern.finditer(text)):
                    found.add(f"{where}: {label}")
    except Exception as e:  # what can't be opened can't be shown to be clean
        found.add(f"{name}: can't be read ({type(e).__name__})")
    return sorted(found)


def link_problems(name, text, chosen):
    out = []
    text = re.sub(r"```.*?```|`[^`\n]*`(?!\])", "", text, flags=re.S)
    for m in LINK.finditer(text):
        href = m.group(1).split("#")[0].split("?")[0]
        if not href or re.match(r"[a-z]+:", href, re.I):
            continue
        p = posixpath.normpath(posixpath.join(posixpath.dirname(name), href))
        if p != "." and p not in chosen and not any(c.startswith(p + "/") for c in chosen):
            out.append(f"{name}: links to {p}, which isn't published")
    return out


def target_problems(repo, target):
    r, t = os.path.normcase(os.path.realpath(repo)), os.path.normcase(os.path.realpath(target))
    if r == t or t.startswith(r + os.sep) or r.startswith(t + os.sep):
        return ["target overlaps this repository"]
    if not os.path.isdir(os.path.join(target, ".git")):
        return ["target is not a git checkout"]
    if git(target, "status", "--porcelain").strip():
        return ["target has uncommitted changes"]
    if set(git(repo, "rev-list", "--all").split()) & set(git(target, "rev-list", "--all", check=False).split()):
        return ["target shares history with this repository"]
    return []


def copy_to(target, contents):
    def writable(func, path, _):
        os.chmod(path, stat.S_IWRITE)
        func(path)
    for e in os.listdir(target):
        if e != ".git":
            q = os.path.join(target, e)
            shutil.rmtree(q, onexc=writable) if os.path.isdir(q) else os.remove(q)
    for p, data in contents.items():
        q = os.path.join(target, *p.split("/"))
        os.makedirs(os.path.dirname(q), exist_ok=True)
        with open(q, "wb") as f:
            f.write(data)


def report(problems, ok, forbid=()):
    for p in problems:
        for v in forbid:
            p = re.sub(re.escape(v), "***", p, flags=re.I)
        print(f"REFUSED: {p}")
    if not problems:
        print(ok)
    return 1 if problems else 0


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=".")
    ap.add_argument("--allow")
    ap.add_argument("--target")
    ap.add_argument("--files", nargs="*")
    ap.add_argument("--require-link", help="every public Markdown file must mention this site")
    ap.add_argument("--show-held", action="store_true")
    a = ap.parse_args(argv)
    forbid = [x.strip() for x in os.environ.get("CRDR_FORBID", "").splitlines() if x.strip()]
    if not forbid:
        return report(["no forbidden values supplied"], "")
    problems = []
    if a.files:
        for f in a.files:
            with open(f, "rb") as h:
                problems += scan(os.path.basename(f), h.read(), forbid)
        return report(problems, f"{len(a.files)} release file(s) checked, inside and out", forbid)

    if git(a.repo, "status", "--porcelain", "--untracked-files=no").strip():
        problems.append("uncommitted changes")
    tracked = git(a.repo, "ls-tree", "-r", "-z", "--name-only", "HEAD").strip("\0").split("\0")
    chosen, more = select(tracked, read_allow(a.allow))
    problems += more
    chosen_set, contents = set(chosen), {}
    for p in chosen:
        data = subprocess.run(["git", "-C", a.repo, "cat-file", "blob", f"HEAD:{p}"], capture_output=True, check=True).stdout
        contents[p] = data
        problems += scan(p, data, forbid)
        if a.require_link and p.endswith(".md") and p not in GENERATED and a.require_link.encode() not in data:
            problems.append(f"{p}: no {a.require_link} link")
        if p.endswith(".md"):
            problems += link_problems(p, data.decode("utf-8", "replace"), chosen_set)
    if a.target:
        problems += target_problems(a.repo, a.target)
    if problems:
        return report(problems, "", forbid)
    if a.target:
        copy_to(a.target, contents)
    if a.show_held:
        for t in tracked:
            if t not in chosen_set:
                print(f"  held back: {t}")
    return report([], f"{len(chosen)} of {len(tracked)} tracked files are public, {len(tracked) - len(chosen)} held back; "
                  + ("copied to the target" if a.target else "plan only, nothing copied"))


if __name__ == "__main__":
    sys.exit(main())
