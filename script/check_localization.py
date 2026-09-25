#!/usr/bin/env python3
"""Localization checks for PhotoCatalog.

UI text is written in Chinese in the source and looked up as the key of an English table
(see Sources/PhotoCatalog/Domain/Localization.swift). This script keeps the two in step:

  script/check_localization.py            report problems, exit 1 if there are errors
  script/check_localization.py plurals    regenerate the .stringsdict plural tables

Checks:
  - Chinese string literals that nothing localizes (SwiftUI literal APIs, L(...), push(...)),
    apart from stored data values listed in DATA_LITERALS
  - keys used in code that are missing from Resources/Localization/en.lproj
  - English values whose format specifiers differ from their key
  - Chinese tables that would let a lookup fall back to English (Context.strings and the
    plural .stringsdict must exist for zh-Hans with the same keys)

Interpolation types are inferred from the expression (counts are %lld, text is %@); list an
expression in SPEC_OVERRIDES when the guess is wrong.
"""
import json
import os
import re
import subprocess
import sys
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, 'Sources/PhotoCatalog')
TABLES = os.path.join(ROOT, 'Resources/Localization')
SKIPPED_DIRS = ('Data/',)   # self-checks and the demo dataset are not UI

CJK = re.compile(r'[一-鿿　-〿＀-￯]')
# calls whose string literal argument is looked up as a localization key
LOCALIZING = {'Text', 'Button', 'Label', 'help', 'Toggle', 'Section', 'Menu', 'CommandMenu', 'accessibilityLabel',
              'Picker', 'TextField', 'navigationTitle', 'ContentUnavailableView', 'LabeledContent',
              'accessibilityHint', 'accessibilityAction', 'SecureField', 'GroupBox', 'Link', 'DisclosureGroup',
              'alert', 'confirmationDialog', 'Stepper', 'accessibilityValue', 'DatePicker', 'searchable',
              'L', 'push', 'LocalizedStringKey'}
IGNORED_CALLS = {'perform', 'measure', 'log', 'print', 'assert', 'precondition', 'fatalError', 'report'}
# Chinese literals that are stored or matched data, not UI text
DATA_LITERALS = [
    re.compile(r'^\s*case\s+"'),                       # switch patterns over stored values
    re.compile(r'captureDateSource\s*='),              # capture-time source names are stored
    re.compile(r'op:\s*"|op\s*==\s*"|ops:\s*\['),     # smart-album operators are stored
    re.compile(r'keywordRoot'),                        # person keywords live under 人物/
    re.compile(r'hasPrefix\("文件"\)'),
    re.compile(r'character\s*=='),                     # keyword separators
    re.compile(r'"简体中文"'),                          # a language is named in its own language
]
INT_HINT = re.compile(r'(count|Count|total|index|idx|\bn\b|rolledBack|saved|skipped|failed|failures?\b|completed|'
                      r'current|supported|percent|edge|maxWidth|maxHeight|rating|faces|copied|moved|scanned|'
                      r'processed|imported|pending|done|queued|days|value|groups|removed|matches|written|'
                      r'xmpFailed|affected|limit|hours|minutes|number|seq|\$0|year|month)')
STR_HINT = re.compile(r'(formatted\(|name|Name|lastPathComponent|title|Title|label|Label|time|day\b|\bq\b|keyword|'
                      r'folder|localizedDescription|describing|first|trimmed|target|\bold\b|baseName|cacheText|'
                      r'importDay|sourceName|selection|Search|search|text|Text|path|Path|preset|filename|camera|'
                      r'lens|verb|join|\bid\b|\.id\b|person|message|album|card|url|display|type|format|symbol|'
                      r'[vV]ersion|String\()')
SPEC_OVERRIDES = {
    'missingOriginals': '%lld', 'missingThumbnails': '%lld', 'missingPreviews': '%lld',
    'unavailableSourceRoots': '%lld', 'activeJobs': '%lld', 'failedJobs': '%lld',
    'DateFmt.shortCapture(last)': '%@', 'DateFmt.shortCapture(first)': '%@',
    'shiftMinutes': '%lld', 'shiftHours': '%lld', 'pair': '%@', 'app.recentImportDays': '%lld',
    'singles': '%lld', 'unconfirmed': '%lld', 'person.unconfirmed': '%lld', 'k': '%@', 'active': '%lld',
    'app.cacheLimitMB': '%lld', 'person': '%@',
}
# English plurals: "%lld <noun>" gets a singular form in the .stringsdict
NOUNS = {'photos': 'photo', 'files': 'file', 'originals': 'original', 'faces': 'face', 'groups': 'group',
         'people': 'person', 'days': 'day', 'stars': 'star', 'jobs': 'job', 'sidecars': 'sidecar',
         'conditions': 'condition', 'values': 'value', 'locations': 'location', 'previews': 'preview',
         'assets': 'asset', 'records': 'record'}
ADJECTIVES = r'(?:(?:duplicate|new|changed|failed|automatically|recognized|unnamed|XMP|disk|photo) )*'


def literals(line):
    """(start, end, text, enclosing call) for each string literal on a line."""
    out, stack, i, n = [], [], 0, len(line)
    while i < n:
        c = line[i]
        if line.startswith('//', i):
            break
        if c == '(':
            m = re.search(r'([A-Za-z_][A-Za-z0-9_]*)\s*$', line[:i])
            stack.append(m.group(1) if m else '')
        elif c == ')':
            if stack:
                stack.pop()
        elif c == '"':
            start, k, depth = i, i + 1, 0
            while k < n:
                ch = line[k]
                if ch == '\\' and line[k + 1:k + 2] == '(':
                    depth += 1
                    k += 2
                    continue
                if ch == '\\':
                    k += 2
                    continue
                if depth and ch == '"':                  # a literal nested in an interpolation
                    e = line.find('"', k + 1)
                    k = e + 1 if e > 0 else n
                    continue
                if depth and ch == '(':
                    depth += 1
                elif depth and ch == ')':
                    depth -= 1
                elif not depth and ch == '"':
                    break
                k += 1
            out.append((start, k, line[start + 1:k], stack[-1] if stack else None))
            i = k
        i += 1
    return out


def unescape(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s):
            nxt = s[i + 1]
            if nxt in 'nt':
                out.append('\n' if nxt == 'n' else '\t')
                i += 2
                continue
            if nxt in '"\\\'':
                out.append(nxt)
                i += 2
                continue
            if nxt == 'u' and s[i + 2:i + 3] == '{':
                e = s.index('}', i)
                out.append(chr(int(s[i + 3:e], 16)))
                i = e + 1
                continue
        out.append(s[i])
        i += 1
    return ''.join(out)


def split_interpolation(t):
    parts, exprs, buf, i = [], [], '', 0
    while i < len(t):
        if t[i] == '\\' and t[i + 1:i + 2] == '(':
            depth, j = 1, i + 2
            while j < len(t) and depth:
                if t[j] == '"':
                    j = t.index('"', j + 1) + 1
                    continue
                depth += {'(': 1, ')': -1}.get(t[j], 0)
                j += 1
            parts.append(buf)
            buf = ''
            exprs.append(t[i + 2:j - 1])
            i = j
            continue
        if t[i] == '\\':
            buf += t[i:i + 2]
            i += 2
            continue
        buf += t[i]
        i += 1
    parts.append(buf)
    return parts, exprs


def specifier(expr):
    e = expr.strip()
    if e in SPEC_OVERRIDES:
        return SPEC_OVERRIDES[e]
    if any(s in e for s in ('formatted(', 'L(', '? "', 'ByteCountFormatter', 'formatCacheMB')):
        return '%@'
    if e.startswith('Int(') or re.search(r'/ 60|% 60', e):
        return '%lld'
    if STR_HINT.search(e) and not re.search(r'\.count\b|Count\b', e):
        return '%@'
    if INT_HINT.search(e):
        return '%lld'
    return None


def key_for(text):
    """The lookup key Foundation builds for a literal: interpolations become %lld / %@."""
    parts, exprs = split_interpolation(text)
    if not exprs:
        return unescape(text), []
    key, unknown = '', []
    for i, part in enumerate(parts):
        key += unescape(part).replace('%', '%%')
        if i < len(exprs):
            spec = specifier(exprs[i])
            if spec is None:
                unknown.append(exprs[i])
                spec = '%@'
            key += spec
    return key, unknown


def source_files():
    for folder, _, files in os.walk(SOURCES):
        for name in sorted(files):
            path = os.path.join(folder, name)
            rel = os.path.relpath(path, SOURCES)
            if name.endswith('.swift') and not rel.startswith(SKIPPED_DIRS) and 'Harness' not in name:
                yield path, rel


def scan_sources():
    """(keys by table, problems): every localized literal's key, and literals nothing localizes."""
    tables, problems = {}, []
    for path, rel in source_files():
        lines = open(path, encoding='utf-8').read().split('\n')
        for number, line in enumerate(lines, 1):
            if line.strip().startswith('//'):
                continue
            for start, end, text, call in literals(line):
                if not CJK.search(text):
                    continue
                where = f'{rel}:{number}'
                before, after = line[:start].rstrip(), line[end + 1:].lstrip()
                following = lines[number].lstrip() if number < len(lines) else ''
                concatenated = before.endswith('+') or after.startswith('+') or (not after and following.startswith('+'))
                if call in LOCALIZING and call not in ('L', 'push') and (concatenated or before.endswith('??')):
                    problems.append(f'{where}: text joined with another String is shown verbatim: {line.strip()[:110]}')
                    continue
                if call in LOCALIZING:
                    key, unknown = key_for(text)
                    for expr in unknown:
                        problems.append(f'{where}: unknown argument type for \\({expr}); add it to SPEC_OVERRIDES')
                    m = re.match(r'\s*,\s*table:\s*"(\w+)"', line[end + 1:])
                    tables.setdefault(m.group(1) if m else 'Localizable', {}).setdefault(key, []).append(where)
                elif call not in IGNORED_CALLS and not any(p.search(line) for p in DATA_LITERALS):
                    problems.append(f'{where}: not localized: {line.strip()[:110]}')
    return tables, problems


def read_table(path):
    if not os.path.exists(path):
        return None
    data = subprocess.run(['plutil', '-convert', 'json', '-o', '-', path], capture_output=True, check=True).stdout
    return json.loads(data)


def specifiers(s):
    return sorted(re.sub(r'\d+\$', '', m) for m in re.findall(r'%(?:\d+\$)?(?:lld|@|lf|d|f)', s))


def check():
    used, errors = scan_sources()
    warnings = []
    for table, keys in sorted(used.items()):
        en = read_table(os.path.join(TABLES, f'en.lproj/{table}.strings')) or {}
        for key, refs in sorted(keys.items()):
            if key not in en:
                errors.append(f'{refs[0]}: missing from en.lproj/{table}.strings: {json.dumps(key, ensure_ascii=False)}')
        for key, value in en.items():
            if specifiers(key) != specifiers(value):
                errors.append(f'en.lproj/{table}.strings: format specifiers differ: {json.dumps(key, ensure_ascii=False)}')
            if key not in keys:
                warnings.append(f'en.lproj/{table}.strings: unused key {json.dumps(key, ensure_ascii=False)}')
        if table != 'Localizable':
            zh = read_table(os.path.join(TABLES, f'zh-Hans.lproj/{table}.strings')) or {}
            for key in en:
                if key not in zh:
                    errors.append(f'zh-Hans.lproj/{table}.strings lacks {json.dumps(key, ensure_ascii=False)} '
                                  '(Chinese would fall back to English)')
    en_plurals = read_table(os.path.join(TABLES, 'en.lproj/Localizable.stringsdict')) or {}
    zh_plurals = read_table(os.path.join(TABLES, 'zh-Hans.lproj/Localizable.stringsdict')) or {}
    for key in en_plurals:
        if key not in zh_plurals:
            errors.append(f'zh-Hans.lproj/Localizable.stringsdict lacks {json.dumps(key, ensure_ascii=False)}; '
                          'run check_localization.py plurals')
    for line in warnings:
        print('warning:', line)
    for line in errors:
        print('error:', line)
    counted = sum(len(k) for k in used.values())
    print(f'{counted} keys in code, {len(errors)} errors, {len(warnings)} warnings')
    return 1 if errors else 0


def write_plurals():
    """English one/other forms for "%lld <noun>" values, and Chinese identity entries."""
    en = read_table(os.path.join(TABLES, 'en.lproj/Localizable.strings')) or {}
    counted = re.compile(r'%(\d+\$)?lld( ' + ADJECTIVES + r'(' + '|'.join(NOUNS) + r'))\b')
    entries = []
    for key in sorted(en):
        value = en[key]
        if not counted.search(value):
            continue
        fmt, variables, pos, n = '', [], 0, 0
        for m in re.finditer(r'%(\d+\$)?(lld|@|lf)', value):
            n += 1
            if m.group(2) != 'lld':
                continue
            fmt += value[pos:m.start()] + f'%{m.group(1) or ""}#@n{n}@'
            noun = counted.match(value, m.start())
            if noun:
                phrase, plural = noun.group(2), noun.group(3)
                variables.append((f'n{n}', '%lld' + phrase[:len(phrase) - len(plural)] + NOUNS[plural],
                                  '%lld' + phrase))
                pos = noun.end()
            else:
                variables.append((f'n{n}', '%lld', '%lld'))
                pos = m.end()
        entries.append((key, fmt + value[pos:], variables))

    def plist(body, comment):
        return '\n'.join(['<?xml version="1.0" encoding="UTF-8"?>',
                          '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
                          '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
                          f'<!-- {comment} -->', '<plist version="1.0">', '<dict>'] + body + ['</dict>', '</plist>', ''])

    english, chinese = [], []
    for key, fmt, variables in entries:
        english += [f'\t<key>{escape(key)}</key>', '\t<dict>', '\t\t<key>NSStringLocalizedFormatKey</key>',
                    f'\t\t<string>{escape(fmt)}</string>']
        for name, one, other in variables:
            english += [f'\t\t<key>{name}</key>', '\t\t<dict>',
                        '\t\t\t<key>NSStringFormatSpecTypeKey</key>', '\t\t\t<string>NSStringPluralRuleType</string>',
                        '\t\t\t<key>NSStringFormatValueTypeKey</key>', '\t\t\t<string>lld</string>',
                        '\t\t\t<key>one</key>', f'\t\t\t<string>{escape(one)}</string>',
                        '\t\t\t<key>other</key>', f'\t\t\t<string>{escape(other)}</string>', '\t\t</dict>']
        english.append('\t</dict>')
        chinese += [f'\t<key>{escape(key)}</key>', '\t<dict>', '\t\t<key>NSStringLocalizedFormatKey</key>',
                    f'\t\t<string>{escape(key)}</string>', '\t</dict>']
    open(os.path.join(TABLES, 'en.lproj/Localizable.stringsdict'), 'w').write(
        plist(english, 'English singular forms for counted nouns; generated by script/check_localization.py plurals'))
    open(os.path.join(TABLES, 'zh-Hans.lproj/Localizable.stringsdict'), 'w').write(
        plist(chinese, 'Chinese has no plural forms: each entry keeps its source text, so the English table is never used'))
    print(f'{len(entries)} plural entries written')
    return 0


if __name__ == '__main__':
    sys.exit(write_plurals() if sys.argv[1:] == ['plurals'] else check())
