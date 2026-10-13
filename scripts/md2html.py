#!/usr/bin/env python3
"""Minimal Markdown -> standalone HTML for the bundled docs (headings, paragraphs, lists, tables,
blockquotes, rules, **bold**, `code`, links). Stdlib only.

Usage: python3 scripts/md2html.py input.md output.html [title]
"""
import html, re, sys


def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"(https?://[^\s<）)]+)", r'<a href="\1">\1</a>', t)
    return t


def convert(md):
    out, lines, i = [], md.splitlines(), 0
    while i < len(lines):
        ln = lines[i]
        s = ln.strip()
        if not s:
            i += 1
            continue
        m = re.match(r"^(#{1,4})\s+(.*)", s)
        if m:
            n = len(m.group(1))
            out.append(f"<h{n}>{inline(m.group(2))}</h{n}>")
            i += 1
            continue
        if re.match(r"^-{3,}$", s):
            out.append("<hr>")
            i += 1
            continue
        if s.startswith("|"):
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
                i += 1
            head, body = rows[0], [r for r in rows[1:] if not all(re.match(r"^:?-+:?$", c) for c in r)]
            out.append("<table><thead><tr>" + "".join(f"<th>{inline(c)}</th>" for c in head) + "</tr></thead><tbody>")
            out += ["<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>" for r in body]
            out.append("</tbody></table>")
            continue
        if s.startswith(">"):
            buf = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                buf.append(lines[i].strip()[1:].strip())
                i += 1
            out.append("<blockquote>" + inline(" ".join(buf)) + "</blockquote>")
            continue
        m = re.match(r"^(\s*)([-*]|\d+\.)\s+(.*)", ln)
        if m:
            ordered = m.group(2)[0].isdigit()
            tag = "ol" if ordered else "ul"
            out.append(f"<{tag}>")
            while i < len(lines):
                mm = re.match(r"^(\s*)([-*]|\d+\.)\s+(.*)", lines[i])
                if not mm:
                    break
                cls = ' class="sub"' if len(mm.group(1)) >= 2 else ""
                out.append(f"<li{cls}>{inline(mm.group(3))}</li>")
                i += 1
            out.append(f"</{tag}>")
            continue
        buf = []
        while i < len(lines) and lines[i].strip() and not re.match(r"^(#|\||>|-{3,}$|\s*([-*]|\d+\.)\s)", lines[i].strip()):
            buf.append(lines[i].strip())
            i += 1
        out.append("<p>" + "<br>".join(inline(b) for b in buf) + "</p>")
    return "\n".join(out)


CSS = """
:root { --fg:#1d1d1f; --muted:#6e6e73; --line:#e5e5ea; --accent:#c9861a; --bg:#fff; --card:#f5f5f7; }
@media (prefers-color-scheme: dark) { :root { --fg:#f5f5f7; --muted:#a1a1a6; --line:#3a3a3c; --accent:#f5b83d; --bg:#1c1c1e; --card:#2c2c2e; } }
body { font: 15px/1.7 -apple-system, "PingFang SC", "Helvetica Neue", sans-serif; color: var(--fg); background: var(--bg);
       max-width: 860px; margin: 0 auto; padding: 32px 28px 64px; }
h1 { font-size: 28px; margin: 0 0 8px; } h2 { font-size: 21px; margin: 36px 0 10px; padding-bottom: 6px; border-bottom: 1px solid var(--line); }
h3 { font-size: 17px; margin: 24px 0 6px; } h4 { font-size: 15px; margin: 18px 0 4px; }
p, li { color: var(--fg); } ul, ol { padding-left: 1.4em; } li.sub { margin-left: 1.4em; list-style: circle; }
strong { color: var(--fg); } a { color: var(--accent); }
code { font: 13px ui-monospace, Menlo, monospace; background: var(--card); padding: 1px 5px; border-radius: 4px; }
blockquote { margin: 12px 0; padding: 10px 14px; background: var(--card); border-left: 3px solid var(--accent); border-radius: 6px; color: var(--muted); }
table { border-collapse: collapse; width: 100%; margin: 12px 0; font-size: 14px; }
th, td { text-align: left; padding: 7px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
th { background: var(--card); font-weight: 600; }
hr { border: none; border-top: 1px solid var(--line); margin: 28px 0; }
@media print { body { max-width: none; padding: 0; } h2 { break-after: avoid; } table, blockquote { break-inside: avoid; } }
"""


def main():
    src, dst = sys.argv[1], sys.argv[2]
    md = open(src, encoding="utf-8").read()
    title = sys.argv[3] if len(sys.argv) > 3 else re.search(r"^#\s+(.*)", md, re.M).group(1)
    doc = f"""<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>{html.escape(title)}</title>
<style>{CSS}</style></head><body>
{convert(md)}
</body></html>
"""
    open(dst, "w", encoding="utf-8").write(doc)


if __name__ == "__main__":
    main()
