"""Closed XCTest census for one fixed nonXML class or the exact Native19 union.

No child, file I/O or import-side execution. Unlike the prior single-class parser,
multiple genuine class summaries may differ; their actual assertion failures sum.
"""
import re


def require(value, message):
    if not value:
        raise ValueError(message)


def parse_result(raw, exit_code, classes):
    require(type(raw) is bytes and type(exit_code) is int and exit_code in (0, 1), 'typed complete capture required')
    require(type(classes) is list and classes and len(classes) <= 6, 'fixed class roster required')
    expected = {}
    by_class = {}
    for row in classes:
        require(type(row) is dict and set(row) == {'class', 'methods'}, 'class roster shape')
        name, methods = row['class'], row['methods']
        require(type(name) is str and re.fullmatch(r'[A-Za-z][A-Za-z0-9]*Tests', name)
                and name not in by_class, 'closed unique class name required')
        require(type(methods) is list and methods and all(type(m) is str and re.fullmatch(r'test\w+', m) for m in methods)
                and len(set(methods)) == len(methods), 'closed unique method list required')
        identities = {'-[NativeRoutingTests.' + name + ' ' + m + ']' for m in methods}
        by_class[name] = identities
        expected.update({identity: name for identity in identities})
    require(len(expected) <= 32, 'bounded stage census')
    text = raw.decode('utf-8')
    starts = re.findall(r"^Test Case '([^']+)' started\.$", text, re.M)
    ends = re.findall(r"^Test Case '([^']+)' (passed|failed|skipped) \([^\n]*\)\.$", text, re.M)
    require(len(starts) == len(expected) and set(starts) == set(expected), 'wrong/missing/repeated starts')
    require(len(ends) == len(expected) and {n for n, _ in ends} == set(expected)
            and all(v != 'skipped' for _, v in ends), 'wrong/missing/repeated/skipped finishes')
    require(len(re.findall(r'^Test Case .*$', text, re.M)) == 2 * len(expected), 'unparsed case record')
    for identity, outcome in ends:
        require(text.index("Test Case '" + identity + "' started.")
                < text.index("Test Case '" + identity + "' " + outcome), 'finish before start')
    summaries = [tuple(map(int, row)) for row in re.findall(r'Executed (\d+) tests?, with (\d+) failures? \((\d+) unexpected\)', text)]
    remaining = summaries.copy()
    reports = []
    for name, identities in by_class.items():
        escaped = re.escape(name)
        opened = re.findall(r"^Test Suite '" + escaped + r"' started(?: at .*\.)?$", text, re.M)
        terminals = list(re.finditer(r"^Test Suite '" + escaped + r"' (passed|failed)(?: at .*\.)?$", text, re.M))
        require(len(opened) == len(terminals) == 1, 'missing/duplicate class suite boundary')
        terminal = terminals[0]
        opening = re.search(r"^Test Suite '" + escaped + r"' started(?: at .*\.)?$", text, re.M)
        require(opening.start() < terminal.start(), 'class finish before start')
        # Framework prints the class summary immediately after its own terminal.
        summary = re.match(r'\n[ \t]*Executed (\d+) tests?, with (\d+) failures? \((\d+) unexpected\)[^\n]*', text[terminal.end():])
        require(summary is not None, 'missing exact class summary')
        count, failures, unexpected = map(int, summary.groups())
        failed = sum(outcome == 'failed' for identity, outcome in ends if identity in identities)
        require(count == len(identities) and unexpected == 0 and failures >= failed
                and bool(failures) == bool(failed), 'inconsistent/unexpected class failures')
        require(terminal.group(1) == ('failed' if failures else 'passed'), 'class terminal/summary mismatch')
        for identity in identities:
            case_start = text.index("Test Case '" + identity + "' started.")
            case_end = text.index("Test Case '" + identity + "' " + next(v for n, v in ends if n == identity))
            require(opening.end() < case_start < case_end < terminal.start(), 'case outside exact class scope')
        row = (count, failures, unexpected)
        require(row in remaining, 'missing class summary census')
        remaining.remove(row)
        reports.append(dict(className=name, executed=count, failures=failures, unexpected=unexpected))
    total = (len(expected), sum(row['failures'] for row in reports), 0)
    require(remaining and all(row == total for row in remaining), 'missing/inconsistent aggregate summary')
    require(exit_code == (1 if total[1] else 0), 'natural exit/result mismatch')
    require(not total[1] or 'XCTAssert' in text or ': failed - ' in text, 'ordinary assertion evidence missing')
    return dict(executed=total[0], failures=total[1], unexpected=0, exit=exit_code,
                methods=[m for row in classes for m in row['methods']],
                classes=reports, observed=ends)
