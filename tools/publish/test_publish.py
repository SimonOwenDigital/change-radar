"""Runs tests/publish/cases.json against publish.py, in throwaway git repositories.

  uv run --no-project --python 3.13 --with pypdf==7.1.1 python tools/publish/test_publish.py
"""
import contextlib
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import publish  # noqa: E402


def build(v):
    if isinstance(v, str):
        return v.encode()
    if "utf16" in v:
        return v["utf16"].encode("utf-16")
    if "zip" in v:
        b = io.BytesIO()
        with zipfile.ZipFile(b, "w", zipfile.ZIP_DEFLATED) as z:
            for k, x in v["zip"].items():
                z.writestr(k, build(x))
        return b.getvalue()
    from pypdf import PdfWriter
    from pypdf.generic import StreamObject
    w = PdfWriter()
    w.add_blank_page(100, 100)
    s = StreamObject()
    s.set_data(v["pdf_stream"].encode())
    w._add_object(s.flate_encode())
    b = io.BytesIO()
    w.write(b)
    return b.getvalue()


def write(root, files):
    for k, v in files.items():
        p = os.path.join(root, *k.split("/"))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(build(v))


def init(root):
    os.makedirs(root, exist_ok=True)
    for c in (["init", "-q"], ["config", "user.name", "t"], ["config", "user.email", "t@example.org"], ["config", "core.autocrlf", "false"]):
        subprocess.run(["git", "-C", root, *c], check=True)


def commit(root):
    subprocess.run(["git", "-C", root, "add", "-A"], check=True)
    subprocess.run(["git", "-C", root, "commit", "-qm", "x"], check=True)


def published(root):
    out = []
    for d, dirs, fs in os.walk(root):
        dirs[:] = [x for x in dirs if x != ".git"]
        out += [os.path.relpath(os.path.join(d, f), root).replace(os.sep, "/") for f in fs]
    return sorted(out)


def remove(func, path, _):
    os.chmod(path, stat.S_IWRITE)
    func(path)


def run(c, forbidden, tmp):
    src, tgt, allow = (os.path.join(tmp, x) for x in ("src", "tgt", "allow.txt"))
    init(src)
    write(src, c["files"])
    commit(src)
    write(src, c.get("untracked", {}))
    if c.get("dirty"):
        write(src, {next(iter(c["files"])): "changed"})
    with open(allow, "w", encoding="utf-8") as f:
        f.write("\n".join(c["allow"]))
    kind = c.get("target")
    if kind == "self":
        tgt = src
    elif kind == "shares-history":
        subprocess.run(["git", "clone", "-q", src, tgt], check=True)
    elif kind == "plain-folder":
        write(tgt, {"keep.txt": "x"})
    else:
        init(tgt)
        if kind == "has-old-file":
            write(tgt, {"old/secret.md": "x"})
            commit(tgt)
    before = published(tgt)
    os.environ["CRDR_FORBID"] = "" if c.get("no_forbid") else forbidden
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = publish.main(["--repo", src, "--allow", allow, "--target", tgt, *(["--require-link", c["require_link"]] if "require_link" in c else [])])
    text = buf.getvalue()
    if "refused" in c:  # refused: nothing in the target changed
        ok = code == 1 and c["refused"] in text and published(tgt) == before
    else:
        ok = code == 0 and published(tgt) == sorted(c["published"])
    return ok and forbidden not in text, f"exit {code}: {text}"


with open(os.path.join(HERE, "..", "..", "tests", "publish", "cases.json"), encoding="utf-8") as f:
    raw = f.read()
spec = json.loads(raw.replace("{FORBIDDEN}", json.loads(raw)["forbidden"]))
fails = 0
for c in spec["cases"]:
    tmp = tempfile.mkdtemp()
    try:
        ok, detail = run(c, spec["forbidden"], tmp)
    finally:
        shutil.rmtree(tmp, onexc=remove)
    fails += not ok
    print(("PASS " if ok else "FAIL ") + c["name"] + ("" if ok else f"\n     {detail}"))
print(f"{len(spec['cases']) - fails} of {len(spec['cases'])} passed")
sys.exit(1 if fails else 0)
