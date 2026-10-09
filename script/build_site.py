#!/usr/bin/env python3
"""Builds the product site in site/ from the bilingual pages in site-src/.

    script/build_site.py           write the pages
    script/build_site.py --check   exit 1 if site/ is out of date (CI)

A source page holds both languages. An element with lang="en" or lang="zh-Hans" goes only into that
language's page; links that carry hreflang (the language switch) go into both. Each source becomes an
English page (the default, at the site root) and a Chinese page under zh/, each in a directory of its own
(privacy/index.html) so every host serves it at a URL without a redirect.

Relative links in a source are written as if from the site root. Page links (./, privacy/, with or without
a #fragment) stay within the page's language; everything else (style.css, shots/…) is site-wide.

Tokens:
    {{site}}         the site's origin (SITE)
    {{lang}}         the page's language tag
    {{seo}}          canonical and hreflang links, Open Graph and Twitter tags, from the page's own
                     <title> and description
    {{switch:en}}    this page in English; {{switch:zh}} in Chinese

It also writes robots.txt, sitemap.xml and llms.txt (from site-src/llms.txt).
"""
import html
import json
import posixpath
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

SITE = "https://photocatalog.gooday.dev"

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "site-src"
OUT = ROOT / "site"

# language → (lang tag, directory under the site root, Open Graph locale); English is the default
LANGS = {"en": ("en", "", "en_US"), "zh": ("zh-Hans", "zh/", "zh_CN")}
# source file → directory under a language's root
PAGES = {"index.html": "", "privacy.html": "privacy/"}
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}
LANG_TAGS = {tag for tag, _, _ in LANGS.values()}


def rel(from_dir, to_dir):
    """The relative URL from one directory page to another ("" is the site root)."""
    path = posixpath.relpath(to_dir or ".", from_dir or ".")
    return "./" if path == "." else path + "/"


class LanguageFilter(HTMLParser):
    """Finds the elements of the other language (to cut) and the lang attributes made redundant by the
    page's own (to strip), as offsets into the source."""

    def __init__(self, text, keep):
        super().__init__(convert_charrefs=False)
        self.text, self.keep = text, keep
        self.line_starts = [0] + [m.end() for m in re.finditer("\n", text)]
        self.stack, self.cuts, self.strips = [], [], []

    def position(self):
        line, column = self.getpos()
        return self.line_starts[line - 1] + column

    def handle_starttag(self, tag, attrs, self_closing=False):
        start = self.position()
        end = start + len(self.get_starttag_text())
        attrs = dict(attrs)
        lang = attrs.get("lang") if "hreflang" not in attrs else None
        drop = lang in LANG_TAGS and lang != self.keep
        if lang == self.keep:
            self.strips.append((start, end))
        if tag in VOID or self_closing:
            if drop:
                self.cuts.append((start, end))
        else:
            self.stack.append((tag, start, drop))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs, self_closing=True)

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if not self.stack or self.stack[-1][0] != tag:
            sys.exit(f"site-src: </{tag}> at line {self.getpos()[0]} doesn't close the open element")
        _, start, drop = self.stack.pop()
        if drop:
            self.cuts.append((start, self.text.index(">", self.position()) + 1))


def whole_lines(text, start, end):
    """Widens a cut to its whole line when nothing else is on it."""
    line_start = text.rfind("\n", 0, start) + 1
    line_end = text.find("\n", end)
    if text[line_start:start].strip() == "" and text[end:line_end].strip() == "":
        return line_start, line_end + 1
    return start, end


def filter_language(text, keep, name):
    parser = LanguageFilter(text, keep)
    parser.feed(text)
    parser.close()
    if parser.stack:
        sys.exit(f"site-src/{name}: <{parser.stack[-1][0]}> is never closed")
    edits, last_end = [], -1
    for start, end in sorted(parser.cuts):
        if start >= last_end:  # cuts inside an earlier cut go with it
            edits.append((*whole_lines(text, start, end), ""))
            last_end = end
    for start, end in parser.strips:
        if not any(s <= start < e for s, e, _ in edits):
            edits.append((start, end, re.sub(r'\s+lang="[^"]*"', "", text[start:end], count=1)))
    for start, end, replacement in sorted(edits, reverse=True):
        text = text[:start] + replacement + text[end:]
    return text


def rewrite_links(text, page_dir, lang_dir):
    to_root = "../" * page_dir.count("/")

    def one(url):
        if not url or url.startswith(("#", "/", "{{")) or re.match(r"[a-z][a-z0-9+.-]*:", url):
            return url
        base, hash_, fragment = url.partition("#")
        if base == "./" or base in PAGES.values():
            return rel(page_dir, lang_dir + ("" if base == "./" else base)) + hash_ + fragment
        return to_root + url

    def attribute(match):
        name, value = match.group(1), match.group(2)
        if name == "srcset":
            value = ", ".join(" ".join([one(part.split()[0])] + part.split()[1:]) for part in value.split(","))
        else:
            value = one(value)
        return f' {name}="{value}"'

    return re.sub(r'\s(href|src|srcset)="([^"]*)"', attribute, text)


def url(lang, page):
    return f"{SITE}/{LANGS[lang][1]}{PAGES[page]}"


def seo_block(text, lang, page):
    def found(pattern, what):
        match = re.search(pattern, text)
        if not match:
            sys.exit(f"site-src/{page}: no {what} for {lang}")
        return html.escape(html.unescape(match.group(1)), quote=True)

    title = found(r"<title>(.*?)</title>", "<title>")
    description = found(r'<meta name="description" content="([^"]*)">', "description")
    other = "zh" if lang == "en" else "en"
    lines = [f'<link rel="canonical" href="{url(lang, page)}">']
    lines += [f'<link rel="alternate" hreflang="{LANGS[l][0]}" href="{url(l, page)}">' for l in LANGS]
    lines += [
        f'<link rel="alternate" hreflang="x-default" href="{url("en", page)}">',
        '<meta property="og:type" content="website">',
        '<meta property="og:site_name" content="PhotoCatalog">',
        f'<meta property="og:url" content="{url(lang, page)}">',
        f'<meta property="og:locale" content="{LANGS[lang][2]}">',
        f'<meta property="og:locale:alternate" content="{LANGS[other][2]}">',
        f'<meta property="og:title" content="{title}">',
        f'<meta property="og:description" content="{description}">',
        '<meta name="twitter:card" content="summary_large_image">',
    ]
    return "\n".join("  " + line for line in lines)


def build_page(name, lang):
    tag, lang_dir, _ = LANGS[lang]
    page_dir = lang_dir + PAGES[name]
    text = (SRC / name).read_text(encoding="utf-8")
    text = filter_language(text, tag, name)
    text = rewrite_links(text, page_dir, lang_dir)
    text = text.replace("{{lang}}", tag).replace("{{site}}", SITE)
    for other, (_, other_dir, _) in LANGS.items():
        text = text.replace("{{switch:%s}}" % other, rel(page_dir, other_dir + PAGES[name]))
    text = re.sub(r'(<a href="[^"]*" hreflang="%s")' % re.escape(tag), r'\1 aria-current="page"', text)
    text = text.replace("{{seo}}", seo_block(text, lang, name))
    text = text.replace("<!doctype html>\n", f"<!doctype html>\n<!-- Built by script/build_site.py from site-src/{name}: edit that file, then run the script. -->\n", 1)

    if "{{" in text:
        sys.exit(f"site-src/{name}: unknown token {re.search(r'{{[^}]*}}', text).group(0)}")
    for other_tag in LANG_TAGS - {tag}:
        if re.search(r'<(?![^>]*hreflang)[^>]*\slang="%s"' % re.escape(other_tag), text):
            sys.exit(f"site-src/{name}: {other_tag} content left in the {tag} page")
    for block in re.findall(r'<script type="application/ld\+json">(.*?)</script>', text, re.S):
        json.loads(block)
    return page_dir + "index.html", text


def sitemap():
    entries = []
    for page in PAGES:
        links = "".join(f'\n    <xhtml:link rel="alternate" hreflang="{LANGS[l][0]}" href="{url(l, page)}"/>' for l in LANGS)
        links += f'\n    <xhtml:link rel="alternate" hreflang="x-default" href="{url("en", page)}"/>'
        entries += [f"  <url>\n    <loc>{url(lang, page)}</loc>{links}\n  </url>" for lang in LANGS]
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
            + "\n".join(entries) + "\n</urlset>\n")


def build():
    files = dict(build_page(name, lang) for name in PAGES for lang in LANGS)
    files["robots.txt"] = f"User-agent: *\nAllow: /\n\nSitemap: {SITE}/sitemap.xml\n"
    files["sitemap.xml"] = sitemap()
    files["llms.txt"] = (SRC / "llms.txt").read_text(encoding="utf-8").replace("{{site}}", SITE)
    return files


def main():
    check = sys.argv[1:] == ["--check"]
    if sys.argv[1:] not in ([], ["--check"]):
        sys.exit(__doc__)
    stale = []
    for path, text in build().items():
        target = OUT / path
        if target.exists() and target.read_text(encoding="utf-8") == text:
            continue
        stale.append(path)
        if not check:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8")
    if check:
        if stale:
            sys.exit("site/ is out of date; run script/build_site.py (" + ", ".join(stale) + ")")
        print("site/ is up to date")
    else:
        print("wrote " + ", ".join(stale) if stale else "site/ was already up to date")


if __name__ == "__main__":
    main()
