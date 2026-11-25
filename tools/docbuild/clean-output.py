"""Removes what Microsoft Word adds to a saved document that identifies the tenant, and proves it is gone.

Word applies the signed-in tenant's default sensitivity label when it saves. The label names the tenant id: in the .docx
as docMetadata/LabelInfo.xml, and in the exported PDF as MSIP_Label_* properties (document information and XMP).
CLAUDE.md: no tenant identifiers in the repo. finish-docx.ps1 runs this after every save and export.

  clean-output.py FILE...                         clean, then check
  clean-output.py --check [--forbid TEXT] FILE... check only; --forbid (repeatable) also refuses that text
Exit code 1 if anything is found after cleaning.
"""
import os
import re
import sys
import zipfile

from pypdf import PdfReader, PdfWriter
from pypdf.generic import ContentStream, NameObject, StreamObject

LABEL = re.compile(r"MSIP_Label|LabelInfo|mipLabelMetadata|siteId=", re.I)


def clean_docx(path):
    tmp = path + ".tmp"
    with zipfile.ZipFile(path) as src, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as dst:
        for item in src.infolist():
            if item.filename.lower().startswith("docmetadata/"):
                continue
            data = src.read(item.filename)
            if item.filename == "_rels/.rels":
                data = re.sub(rb'<Relationship\b[^>]*docMetadata/LabelInfo\.xml[^>]*/>', b"", data)
            elif item.filename == "[Content_Types].xml":
                data = re.sub(rb'<Override\b[^>]*docMetadata/LabelInfo\.xml[^>]*/>', b"", data)
            dst.writestr(item.filename, data)
    os.replace(tmp, path)


def clean_pdf(path):
    reader = PdfReader(path)
    keep = {k: v for k, v in (reader.metadata or {}).items() if k in ("/Title", "/Author", "/Creator", "/Producer", "/CreationDate")}
    writer = PdfWriter(clone_from=reader)
    writer.metadata = None
    writer.root_object.pop(NameObject("/Metadata"), None)
    writer.metadata = keep
    writer.compress_identical_objects(remove_duplicates=False, remove_unreferenced=True)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        writer.write(f)
    os.replace(tmp, path)


def pdf_text(path):
    """Every byte a reader could recover: the raw file, every decoded stream, the properties and the page text."""
    reader = PdfReader(path)
    parts = [open(path, "rb").read().decode("latin-1"), str(reader.metadata)]
    for num in range(1, int(reader.trailer["/Size"])):
        try:
            obj = reader.get_object(num)
        except Exception:
            continue
        if isinstance(obj, StreamObject) and not isinstance(obj, ContentStream) and obj.get("/Subtype") != "/Image":
            try:
                parts.append(obj.get_data().decode("latin-1"))
            except Exception:
                pass
        else:
            parts.append(str(obj))
    parts += [page.extract_text() for page in reader.pages]
    return "\n".join(parts)


def docx_text(path):
    with zipfile.ZipFile(path) as z:
        parts = []
        for n in z.namelist():
            parts.append(n)
            data = z.read(n).decode("utf-8", "ignore")
            parts.append(data)
            if n.endswith(".xml"):
                parts.append(re.sub(r"<[^>]+>", "", data))  # text split across runs
        return "\n".join(parts)


def problems(path, forbid):
    text = docx_text(path) if path.lower().endswith(".docx") else pdf_text(path)
    found = sorted({m.group(0) for m in LABEL.finditer(text)})
    low = text.lower()
    found += [f"forbidden text {i + 1}" for i, f in enumerate(forbid) if f.lower() in low]  # never print the text itself
    found += sorted({m for m in re.findall(r"[a-z0-9-]+\.crm\d+\.dynamics\.com|[a-z0-9-]+\.onmicrosoft\.com", low)})
    return found


def main(argv):
    check_only, forbid, files = False, [], []
    it = iter(argv)
    for a in it:
        if a == "--check":
            check_only = True
        elif a == "--forbid":
            forbid.append(next(it))
        else:
            files.append(a)
    bad = 0
    for f in files:
        if not check_only:
            clean_docx(f) if f.lower().endswith(".docx") else clean_pdf(f)
        p = problems(f, [x for x in forbid if x])
        if p:
            bad += 1
            print(f"FAIL {os.path.basename(f)}: {', '.join(p)}")
    if not bad:
        print(f"{'checked' if check_only else 'cleaned and checked'} {len(files)} file(s): no sensitivity label or identifiers")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
