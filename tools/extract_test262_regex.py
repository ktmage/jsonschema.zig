#!/usr/bin/env python3
"""
Extract regex test cases from the TC39 Test262 test suite and convert them
into JSON formats consumable by a Zig test runner.

Produces two output files:
  - test262_regex_full.json   : detailed format with captures, features, flags
  - test262_regex_simple.json : minimal format (pattern, input, should_match)

Usage:
    python3 extract_test262_regex.py [--test262-dir DIR] [--output-dir DIR]

If --test262-dir is not provided, the script clones the test262 repo into a
temporary directory.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Optional


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class FullTestCase:
    pattern: str
    flags: str
    input: str
    expected_match: bool
    expected_captures: Optional[list[str]]
    features: list[str]
    negative: bool
    source_file: str


@dataclass
class SimpleTestCase:
    pattern: str
    input: str
    should_match: bool


# ---------------------------------------------------------------------------
# YAML frontmatter parser (lightweight, no PyYAML dependency)
# ---------------------------------------------------------------------------

_FRONTMATTER_RE = re.compile(
    r"/\*---\s*\n(.*?)\n---\*/", re.DOTALL
)


def parse_frontmatter(source: str) -> dict:
    """Extract key-value pairs from the test262 YAML-like frontmatter."""
    m = _FRONTMATTER_RE.search(source)
    if not m:
        return {}
    raw = m.group(1)
    result: dict = {}
    current_key = None
    current_lines: list[str] = []

    for line in raw.split("\n"):
        # Simple key: value on one line
        kv = re.match(r"^(\w[\w-]*):\s*(.*)", line)
        if kv:
            # Flush previous
            if current_key is not None:
                result[current_key] = "\n".join(current_lines).strip()
            current_key = kv.group(1)
            val = kv.group(2).strip()
            # Handle inline list  [a, b, c]
            if val.startswith("[") and val.endswith("]"):
                items = [x.strip().strip("'\"") for x in val[1:-1].split(",") if x.strip()]
                result[current_key] = items
                current_key = None
                current_lines = []
            elif val == "|" or val == ">":
                current_lines = []
            else:
                current_lines = [val]
        elif current_key is not None:
            # Continuation line (list item or multiline scalar)
            stripped = line.strip()
            if stripped.startswith("- "):
                if not isinstance(result.get(current_key), list):
                    result[current_key] = []
                    current_lines = []
                result[current_key].append(stripped[2:].strip().strip("'\""))
            else:
                current_lines.append(line)

    if current_key is not None and current_key not in result:
        result[current_key] = "\n".join(current_lines).strip()

    return result


# ---------------------------------------------------------------------------
# Negative-test detection
# ---------------------------------------------------------------------------

def is_negative_test(frontmatter: dict, source: str) -> bool:
    """Return True if this test expects a SyntaxError / throw at parse time."""
    neg = frontmatter.get("negative")
    if isinstance(neg, str) and neg:
        return True
    if isinstance(neg, dict):
        return True
    # Also look for the "negative:" block that may have been parsed as text
    if "negative" in frontmatter:
        val = frontmatter["negative"]
        if val and val != "false":
            return True
    # Heuristic: if the file uses assert.throws at the top level with SyntaxError
    if re.search(r"assert\.throws\s*\(\s*SyntaxError", source):
        return True
    return False


# ---------------------------------------------------------------------------
# JavaScript string literal unescaper
# ---------------------------------------------------------------------------

_JS_ESCAPE_MAP = {
    "n": "\n",
    "r": "\r",
    "t": "\t",
    "\\": "\\",
    "'": "'",
    '"': '"',
    "0": "\0",
    "b": "\b",
    "f": "\f",
    "v": "\v",
}


def _unescape_js_string(s: str) -> str:
    """Best-effort unescape of a JavaScript string literal body."""
    out: list[str] = []
    i = 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            nxt = s[i + 1]
            if nxt in _JS_ESCAPE_MAP:
                out.append(_JS_ESCAPE_MAP[nxt])
                i += 2
                continue
            if nxt == "u":
                # \uXXXX or \u{XXXX}
                if i + 2 < len(s) and s[i + 2] == "{":
                    end = s.index("}", i + 3)
                    cp = int(s[i + 3 : end], 16)
                    out.append(chr(cp))
                    i = end + 1
                    continue
                elif i + 5 < len(s):
                    cp = int(s[i + 2 : i + 6], 16)
                    out.append(chr(cp))
                    i += 6
                    continue
            if nxt == "x" and i + 3 < len(s):
                cp = int(s[i + 2 : i + 4], 16)
                out.append(chr(cp))
                i += 4
                continue
            # Fallthrough: keep literal
            out.append(nxt)
            i += 2
            continue
        out.append(s[i])
        i += 1
    return "".join(out)


def parse_js_string(token: str) -> str:
    """Parse a JavaScript string literal (with quotes) into a Python string."""
    token = token.strip()
    if len(token) >= 2 and token[0] in ('"', "'", "`") and token[-1] == token[0]:
        return _unescape_js_string(token[1:-1])
    return token


# ---------------------------------------------------------------------------
# Pattern / flag extraction
# ---------------------------------------------------------------------------

# Regex literal:  /pattern/flags
_RE_LITERAL = re.compile(r"/((?:[^/\\]|\\.)*)/([\w]*)")

# RegExp constructor: new RegExp("pattern", "flags") or new RegExp('pattern')
_RE_CONSTRUCTOR = re.compile(
    r"""new\s+RegExp\(\s*"""
    r"""(["'`])((?:[^"'`\\]|\\.)*?)\1"""   # pattern string
    r"""(?:\s*,\s*(["'`])([\w]*)\3)?"""     # optional flags
    r"""\s*\)""",
    re.DOTALL,
)


def extract_patterns_from_line(line: str) -> list[tuple[str, str]]:
    """Return list of (pattern, flags) found in a single source line."""
    results: list[tuple[str, str]] = []

    for m in _RE_CONSTRUCTOR.finditer(line):
        pat = m.group(2)
        flags = m.group(4) or ""
        results.append((pat, flags))

    for m in _RE_LITERAL.finditer(line):
        pat = m.group(1)
        flags = m.group(2)
        # Avoid false positives from comments
        prefix = line[: m.start()].rstrip()
        if prefix.endswith("//"):
            continue
        # Skip empty patterns and patterns that look like comment bodies
        if not pat or pat.startswith("*") or pat.startswith(" "):
            continue
        results.append((pat, flags))

    return results


def _strip_frontmatter(source: str) -> str:
    """Remove the /*--- ... ---*/ YAML frontmatter block and block comments."""
    s = _FRONTMATTER_RE.sub("", source)
    # Also strip other block comments to avoid false regex matches
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.DOTALL)
    return s


# ---------------------------------------------------------------------------
# Assertion extraction
# ---------------------------------------------------------------------------

def _balance_parens(source: str, start: int) -> int:
    """Find the closing ')' that matches the '(' at `start`."""
    depth = 0
    i = start
    in_str: Optional[str] = None
    while i < len(source):
        c = source[i]
        if in_str:
            if c == "\\" and i + 1 < len(source):
                i += 2
                continue
            if c == in_str:
                in_str = None
        elif c in ('"', "'", "`"):
            in_str = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        elif c == "/" and i + 1 < len(source) and source[i + 1] not in ("*", "/"):
            # Skip regex literal
            i += 1
            while i < len(source) and source[i] != "/":
                if source[i] == "\\":
                    i += 1
                i += 1
        i += 1
    return len(source) - 1


@dataclass
class Assertion:
    kind: str  # "sameValue", "compareArray", "throws"
    args_raw: str
    line: str


def find_assertions(source: str) -> list[Assertion]:
    """Find all assert.sameValue / assert.compareArray / assert.throws calls."""
    results: list[Assertion] = []
    for m in re.finditer(r"assert\.(sameValue|compareArray|throws)\s*\(", source):
        kind = m.group(1)
        start = m.end() - 1  # the '('
        end = _balance_parens(source, start)
        args_raw = source[start + 1 : end]
        line = source[m.start() : end + 1]
        results.append(Assertion(kind=kind, args_raw=args_raw, line=line))
    return results


# ---------------------------------------------------------------------------
# Extract .match() / .exec() / .test() call patterns
# ---------------------------------------------------------------------------

# "string".match(/pattern/flags)
_MATCH_STR_RE = re.compile(
    r"""(["'`])((?:[^"'`\\]|\\.)*?)\1\s*\.match\s*\(\s*"""
    r"""/((?:[^/\\]|\\.)*)/([\w]*)\s*\)"""
)

# /pattern/flags.exec("string")  or  /pattern/flags.test("string")
_EXEC_RE_RE = re.compile(
    r"""/((?:[^/\\]|\\.)*)/([\w]*)\s*\.\s*(?:exec|test)\s*\(\s*"""
    r"""(["'`])((?:[^"'`\\]|\\.)*?)\3\s*\)"""
)

# /pattern/flags[Symbol.match]("string")
_SYMBOL_MATCH_RE = re.compile(
    r"""/((?:[^/\\]|\\.)*)/([\w]*)\s*\[\s*Symbol\.match\s*\]\s*\(\s*"""
    r"""(["'`])((?:[^"'`\\]|\\.)*?)\3\s*\)"""
)

# variable.match(/pattern/flags)  -- used in some exec-style tests
_VAR_MATCH_RE = re.compile(
    r"""(\w+)\s*\.match\s*\(\s*/((?:[^/\\]|\\.)*)/([\w]*)\s*\)"""
)

# Assigned regex: var __re = /pattern/flags; ... __re.exec("string")
_ASSIGNED_REGEX = re.compile(
    r"""(?:var|let|const)\s+(\w+)\s*=\s*/((?:[^/\\]|\\.)*)/([\w]*)\s*;"""
)
_ASSIGNED_EXEC = re.compile(
    r"""(\w+)\s*\.\s*(?:exec|test)\s*\(\s*(["'`])((?:[^"'`\\]|\\.)*?)\2\s*\)"""
)
_ASSIGNED_EXEC_VAR = re.compile(
    r"""(\w+)\s*\.\s*(?:exec|test)\s*\(\s*(\w+)\s*\)"""
)

# String variable assignment: var __string = "value";
_STRING_VAR = re.compile(
    r"""(?:var|let|const)\s+(\w+)\s*=\s*(["'`])((?:[^"'`\\]|\\.)*?)\2\s*;"""
)


def _extract_match_pairs_from_source(source: str) -> list[tuple[str, str, str]]:
    """
    Extract (pattern, flags, input_string) from various calling conventions.
    Returns raw strings (not yet unescaped).
    """
    pairs: list[tuple[str, str, str]] = []

    # "string".match(/pattern/flags)
    for m in _MATCH_STR_RE.finditer(source):
        pairs.append((m.group(3), m.group(4), m.group(2)))

    # /pattern/flags.exec("string") and .test("string")
    for m in _EXEC_RE_RE.finditer(source):
        pairs.append((m.group(1), m.group(2), m.group(4)))

    # /pattern/flags[Symbol.match]("string")
    for m in _SYMBOL_MATCH_RE.finditer(source):
        pairs.append((m.group(1), m.group(2), m.group(4)))

    # Assigned-regex style: var re = /pat/; re.exec("str")
    regex_vars: dict[str, tuple[str, str]] = {}
    for m in _ASSIGNED_REGEX.finditer(source):
        regex_vars[m.group(1)] = (m.group(2), m.group(3))

    string_vars: dict[str, str] = {}
    for m in _STRING_VAR.finditer(source):
        string_vars[m.group(1)] = m.group(3)

    for m in _ASSIGNED_EXEC.finditer(source):
        var = m.group(1)
        inp = m.group(3)
        if var in regex_vars:
            pat, flags = regex_vars[var]
            pairs.append((pat, flags, inp))

    for m in _ASSIGNED_EXEC_VAR.finditer(source):
        rvar = m.group(1)
        svar = m.group(2)
        if rvar in regex_vars and svar in string_vars:
            pat, flags = regex_vars[rvar]
            pairs.append((pat, flags, string_vars[svar]))

    return pairs


# ---------------------------------------------------------------------------
# Parse assertion arguments for expected captures
# ---------------------------------------------------------------------------

def _parse_array_literal(s: str) -> Optional[list[str]]:
    """Parse a JS array literal like  ["foo", "bar"]  into a list of strings."""
    s = s.strip()
    if not (s.startswith("[") and s.endswith("]")):
        return None
    inner = s[1:-1].strip()
    if not inner:
        return []

    items: list[str] = []
    depth = 0
    current: list[str] = []
    in_str: Optional[str] = None

    for i, c in enumerate(inner):
        if in_str:
            current.append(c)
            if c == "\\" and i + 1 < len(inner):
                continue
            if c == in_str:
                in_str = None
            continue
        if c in ('"', "'", "`"):
            in_str = c
            current.append(c)
        elif c == "[":
            depth += 1
            current.append(c)
        elif c == "]":
            depth -= 1
            current.append(c)
        elif c == "," and depth == 0:
            items.append("".join(current).strip())
            current = []
        else:
            current.append(c)
    if current:
        items.append("".join(current).strip())

    result: list[str] = []
    for item in items:
        item = item.strip()
        if item == "undefined" or item == "null":
            result.append("")
        elif len(item) >= 2 and item[0] in ('"', "'", "`") and item[-1] == item[0]:
            result.append(_unescape_js_string(item[1:-1]))
        else:
            result.append(item)
    return result


def _split_toplevel_args(s: str) -> list[str]:
    """Split a comma-separated argument list respecting nested parens/brackets/strings."""
    args: list[str] = []
    depth = 0
    in_str: Optional[str] = None
    current: list[str] = []

    i = 0
    while i < len(s):
        c = s[i]
        if in_str:
            current.append(c)
            if c == "\\" and i + 1 < len(s):
                current.append(s[i + 1])
                i += 2
                continue
            if c == in_str:
                in_str = None
        elif c in ('"', "'", "`"):
            in_str = c
            current.append(c)
        elif c in ("(", "[", "{"):
            depth += 1
            current.append(c)
        elif c in (")", "]", "}"):
            depth -= 1
            current.append(c)
        elif c == "/" and depth == 0 and i + 1 < len(s) and s[i + 1] not in ("*", "/"):
            # Regex literal
            current.append(c)
            i += 1
            while i < len(s) and s[i] != "/":
                if s[i] == "\\":
                    current.append(s[i])
                    i += 1
                    if i < len(s):
                        current.append(s[i])
                else:
                    current.append(s[i])
                i += 1
            if i < len(s):
                current.append(s[i])
        elif c == "," and depth == 0:
            args.append("".join(current).strip())
            current = []
        else:
            current.append(c)
        i += 1

    if current:
        args.append("".join(current).strip())
    return args


# ---------------------------------------------------------------------------
# Core extraction logic for a single file
# ---------------------------------------------------------------------------

def process_file(
    filepath: Path, base_dir: Path
) -> tuple[list[FullTestCase], list[SimpleTestCase]]:
    """Process one test262 .js file and return extracted test cases."""
    try:
        source = filepath.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return [], []

    rel_path = str(filepath.relative_to(base_dir))
    frontmatter = parse_frontmatter(source)
    features = frontmatter.get("features", [])
    if isinstance(features, str):
        features = [f.strip() for f in features.split(",")]

    negative = is_negative_test(frontmatter, source)

    full_cases: list[FullTestCase] = []
    simple_cases: list[SimpleTestCase] = []

    # ---------------------------------------------------------------
    # Handle negative / syntax-error tests
    # ---------------------------------------------------------------
    if negative:
        # Try to extract the pattern anyway for reference
        # Use stripped source to avoid matching YAML frontmatter as regex
        code_only = _strip_frontmatter(source)
        all_patterns: list[tuple[str, str]] = []
        for line in code_only.split("\n"):
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            all_patterns.extend(extract_patterns_from_line(line))
        for pat, flags in all_patterns[:1]:  # just take the first
            full_cases.append(FullTestCase(
                pattern=pat,
                flags=flags,
                input="",
                expected_match=False,
                expected_captures=None,
                features=features,
                negative=True,
                source_file=rel_path,
            ))
        if not all_patterns:
            # Record the file as negative even without a clear pattern
            full_cases.append(FullTestCase(
                pattern="",
                flags="",
                input="",
                expected_match=False,
                expected_captures=None,
                features=features,
                negative=True,
                source_file=rel_path,
            ))
        return full_cases, simple_cases

    # ---------------------------------------------------------------
    # Strategy 1: assertion-based extraction (most common)
    # ---------------------------------------------------------------

    assertions = find_assertions(source)
    match_pairs = _extract_match_pairs_from_source(source)

    for assertion in assertions:
        args = _split_toplevel_args(assertion.args_raw)

        if assertion.kind == "throws":
            # assert.throws(SyntaxError, ...) — the regex itself is invalid
            # Try to extract pattern from the second argument (a function)
            if len(args) >= 2:
                for pat, flags in extract_patterns_from_line(args[1]):
                    full_cases.append(FullTestCase(
                        pattern=pat,
                        flags=flags,
                        input="",
                        expected_match=False,
                        expected_captures=None,
                        features=features,
                        negative=True,
                        source_file=rel_path,
                    ))
            continue

        if assertion.kind == "sameValue":
            # Two main forms:
            #   assert.sameValue("str".match(/pat/), null, msg)  -> no match
            #   assert.sameValue(result[0], "expected", msg)     -> capture check
            #   assert.sameValue(result.index, N, msg)           -> index check
            if len(args) < 2:
                continue

            actual_expr = args[0].strip()
            expected_val = args[1].strip()

            # "str".match(/pat/)  == null
            m_str = _MATCH_STR_RE.search(actual_expr)
            m_exec = _EXEC_RE_RE.search(actual_expr)
            m_sym = _SYMBOL_MATCH_RE.search(actual_expr)

            matched = m_str or m_exec or m_sym
            if matched and expected_val == "null":
                if m_str:
                    pat, flags, inp = m_str.group(3), m_str.group(4), m_str.group(2)
                elif m_exec:
                    pat, flags, inp = m_exec.group(1), m_exec.group(2), m_exec.group(4)
                else:
                    pat, flags, inp = m_sym.group(1), m_sym.group(2), m_sym.group(4)

                inp_str = _unescape_js_string(inp)
                full_cases.append(FullTestCase(
                    pattern=pat,
                    flags=flags,
                    input=inp_str,
                    expected_match=False,
                    expected_captures=None,
                    features=features,
                    negative=False,
                    source_file=rel_path,
                ))
                simple_cases.append(SimpleTestCase(
                    pattern=pat,
                    input=inp_str,
                    should_match=False,
                ))
                continue

            # result[N] === "value" or result.length === N
            # These are secondary checks on an already-matched result;
            # we handle them implicitly via compareArray.
            continue

        if assertion.kind == "compareArray":
            # assert.compareArray("str".match(/pat/), ["a", "b"], msg)
            if len(args) < 2:
                continue

            actual_expr = args[0].strip()
            expected_expr = args[1].strip()

            m_str = _MATCH_STR_RE.search(actual_expr)
            m_exec = _EXEC_RE_RE.search(actual_expr)
            m_sym = _SYMBOL_MATCH_RE.search(actual_expr)

            matched = m_str or m_exec or m_sym
            if matched:
                if m_str:
                    pat, flags, inp = m_str.group(3), m_str.group(4), m_str.group(2)
                elif m_exec:
                    pat, flags, inp = m_exec.group(1), m_exec.group(2), m_exec.group(4)
                else:
                    pat, flags, inp = m_sym.group(1), m_sym.group(2), m_sym.group(4)

                inp_str = _unescape_js_string(inp)
                captures = _parse_array_literal(expected_expr)
                full_cases.append(FullTestCase(
                    pattern=pat,
                    flags=flags,
                    input=inp_str,
                    expected_match=True,
                    expected_captures=captures,
                    features=features,
                    negative=False,
                    source_file=rel_path,
                ))
                simple_cases.append(SimpleTestCase(
                    pattern=pat,
                    input=inp_str,
                    should_match=True,
                ))
                continue

    # ---------------------------------------------------------------
    # Strategy 2: variable-based extraction
    # ---------------------------------------------------------------
    # For tests like:
    #   var __executed = /pattern/.exec("string");
    #   var __expected = ["result"];
    #   assert.sameValue(__executed[0], __expected[0]);

    exec_assign = re.search(
        r"""(?:var|let|const)\s+(\w+)\s*=\s*"""
        r"""/((?:[^/\\]|\\.)*)/([\w]*)\s*\.\s*exec\s*\(\s*"""
        r"""(["'`])((?:[^"'`\\]|\\.)*?)\4\s*\)""",
        source,
    )
    expected_assign = re.search(
        r"""(?:var|let|const)\s+\w+\s*=\s*(\[.*?\])\s*;""",
        source,
        re.DOTALL,
    )

    if exec_assign and not full_cases:
        pat = exec_assign.group(2)
        flags = exec_assign.group(3)
        inp = _unescape_js_string(exec_assign.group(5))
        captures = None
        is_match = True

        if expected_assign:
            captures = _parse_array_literal(expected_assign.group(1))
        # Check if any assertion says result is null
        if "null" in source and re.search(
            r"assert\.sameValue\s*\(\s*" + re.escape(exec_assign.group(1)) + r"\s*,\s*null",
            source,
        ):
            is_match = False
            captures = None

        full_cases.append(FullTestCase(
            pattern=pat,
            flags=flags,
            input=inp,
            expected_match=is_match,
            expected_captures=captures,
            features=features,
            negative=False,
            source_file=rel_path,
        ))
        simple_cases.append(SimpleTestCase(
            pattern=pat,
            input=inp,
            should_match=is_match,
        ))

    # ---------------------------------------------------------------
    # Strategy 3: Symbol.match result checks
    # ---------------------------------------------------------------
    sym_match_assign = re.search(
        r"""(?:var|let|const)\s+(\w+)\s*=\s*"""
        r"""/((?:[^/\\]|\\.)*)/([\w]*)\s*\[\s*Symbol\.match\s*\]\s*\(\s*"""
        r"""(["'`])((?:[^"'`\\]|\\.)*?)\4\s*\)""",
        source,
    )
    if sym_match_assign and not full_cases:
        pat = sym_match_assign.group(2)
        flags = sym_match_assign.group(3)
        inp = _unescape_js_string(sym_match_assign.group(5))

        # Extract expected captures from result[0], result[1], etc.
        captures: list[str] = []
        for idx_m in re.finditer(
            r"assert\.sameValue\s*\(\s*\w+\[\s*(\d+)\s*\]\s*,\s*(.*?)\s*[,)]",
            source,
        ):
            idx = int(idx_m.group(1))
            val = idx_m.group(2).strip().strip("'\"")
            while len(captures) <= idx:
                captures.append("")
            captures[idx] = _unescape_js_string(val)

        full_cases.append(FullTestCase(
            pattern=pat,
            flags=flags,
            input=inp,
            expected_match=True,
            expected_captures=captures if captures else None,
            features=features,
            negative=False,
            source_file=rel_path,
        ))
        simple_cases.append(SimpleTestCase(
            pattern=pat,
            input=inp,
            should_match=True,
        ))

    # ---------------------------------------------------------------
    # Strategy 4: collect remaining match pairs not yet captured
    # ---------------------------------------------------------------
    seen_pats = {(c.pattern, c.flags, c.input) for c in full_cases}

    for pat, flags, inp_raw in match_pairs:
        inp = _unescape_js_string(inp_raw)
        key = (pat, flags, inp)
        if key in seen_pats:
            continue
        seen_pats.add(key)

        # Determine if match is expected by checking if null comparison follows
        # We only know this if there's a sameValue(..., null) near it
        # Default to expecting a match (since non-null tests typically succeed)
        full_cases.append(FullTestCase(
            pattern=pat,
            flags=flags,
            input=inp,
            expected_match=True,
            expected_captures=None,
            features=features,
            negative=False,
            source_file=rel_path,
        ))
        simple_cases.append(SimpleTestCase(
            pattern=pat,
            input=inp,
            should_match=True,
        ))

    return full_cases, simple_cases


# ---------------------------------------------------------------------------
# Repository management
# ---------------------------------------------------------------------------

TEST262_REPO = "https://github.com/tc39/test262.git"
REGEXP_TEST_DIR = "test/built-ins/RegExp"


def ensure_test262(test262_dir: Optional[str]) -> Path:
    """Clone or locate the test262 repository."""
    if test262_dir:
        p = Path(test262_dir)
        if not p.exists():
            print(f"Error: directory {p} does not exist", file=sys.stderr)
            sys.exit(1)
        return p

    # Check common locations first
    candidates = [
        Path.cwd() / "test262",
        Path.cwd() / ".." / "test262",
        Path("/tmp/test262"),
    ]
    for c in candidates:
        if (c / REGEXP_TEST_DIR).is_dir():
            print(f"Found existing test262 at: {c}")
            return c

    # Clone into /tmp
    dest = Path("/tmp/test262")
    print(f"Cloning test262 into {dest} (shallow clone) ...")
    subprocess.run(
        [
            "git", "clone", "--depth=1", "--filter=blob:none",
            "--sparse", TEST262_REPO, str(dest),
        ],
        check=True,
    )
    # Configure sparse checkout to only get RegExp tests
    subprocess.run(
        ["git", "sparse-checkout", "set", REGEXP_TEST_DIR],
        cwd=str(dest),
        check=True,
    )
    print("Clone complete.")
    return dest


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Extract regex test cases from TC39 Test262 suite"
    )
    parser.add_argument(
        "--test262-dir",
        type=str,
        default=None,
        help="Path to existing test262 checkout (clones if not provided)",
    )
    parser.add_argument(
        "--output-dir",
        type=str,
        default=".",
        help="Directory for output JSON files (default: current directory)",
    )
    args = parser.parse_args()

    test262 = ensure_test262(args.test262_dir)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    regexp_dir = test262 / REGEXP_TEST_DIR
    if not regexp_dir.is_dir():
        print(f"Error: {regexp_dir} not found", file=sys.stderr)
        sys.exit(1)

    all_full: list[FullTestCase] = []
    all_simple: list[SimpleTestCase] = []
    files_processed = 0
    files_with_tests = 0
    feature_counter: Counter = Counter()
    errors: list[str] = []

    js_files = sorted(regexp_dir.rglob("*.js"))
    total = len(js_files)
    print(f"Found {total} .js files under {regexp_dir}")

    for i, filepath in enumerate(js_files):
        if (i + 1) % 500 == 0 or i + 1 == total:
            print(f"  Processing {i + 1}/{total} ...", file=sys.stderr)
        files_processed += 1
        try:
            full, simple = process_file(filepath, test262)
        except Exception as e:
            errors.append(f"{filepath}: {e}")
            continue

        if full:
            files_with_tests += 1
            all_full.extend(full)
            all_simple.extend(simple)
            for tc in full:
                for feat in tc.features:
                    feature_counter[feat] += 1

    # Deduplicate simple cases
    seen_simple: set[tuple[str, str, bool]] = set()
    deduped_simple: list[SimpleTestCase] = []
    for s in all_simple:
        key = (s.pattern, s.input, s.should_match)
        if key not in seen_simple:
            seen_simple.add(key)
            deduped_simple.append(s)

    # Write output
    full_path = output_dir / "test262_regex_full.json"
    simple_path = output_dir / "test262_regex_simple.json"

    with open(full_path, "w", encoding="utf-8") as f:
        json.dump(
            [asdict(tc) for tc in all_full],
            f,
            indent=2,
            ensure_ascii=False,
        )

    with open(simple_path, "w", encoding="utf-8") as f:
        json.dump(
            [asdict(tc) for tc in deduped_simple],
            f,
            indent=2,
            ensure_ascii=False,
        )

    # Summary
    print()
    print("=" * 60)
    print("  Test262 Regex Extraction Summary")
    print("=" * 60)
    print(f"  Files processed:         {files_processed}")
    print(f"  Files with test cases:   {files_with_tests}")
    print(f"  Full test cases:         {len(all_full)}")
    print(f"  Simple test cases:       {len(deduped_simple)} (deduplicated)")
    print()
    print("  Feature breakdown:")
    for feat, count in feature_counter.most_common():
        print(f"    {feat:45s}  {count:5d}")
    print()
    if errors:
        print(f"  Errors ({len(errors)}):")
        for e in errors[:20]:
            print(f"    {e}")
        if len(errors) > 20:
            print(f"    ... and {len(errors) - 20} more")
        print()
    print(f"  Output (full):   {full_path.resolve()}")
    print(f"  Output (simple): {simple_path.resolve()}")
    print("=" * 60)


if __name__ == "__main__":
    main()
