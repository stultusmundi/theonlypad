#!/usr/bin/env python3
"""Fresh-process Foundation streaming measurements; no GUI or production-source mutation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import statistics
import subprocess
import tempfile
import time


def run_child(command, output, timeout):
    with output.open('wb') as stream:
        child = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        started = time.monotonic()
        try:
            code = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
            code = 124
        except BaseException as error:
            # Popen created a new session; this group belongs only to this invocation.
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
            output.with_suffix(output.suffix + '.status.json').write_text(json.dumps({
                'interrupted': type(error).__name__, 'reaped': child.returncode is not None,
                'exit': child.returncode, 'wallSeconds': time.monotonic() - started}) + '\n')
            raise
        return {'exit': code, 'wallSeconds': time.monotonic() - started}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--smoke', action='store_true', help='one 1MB child per shape; not full evidence')
    args = parser.parse_args()
    os.umask(0o077)
    root = Path(__file__).resolve().parent.parent
    os.chdir(root)
    base = root / '.local/streaming-core-current'
    base.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='run.', dir=base))
    print('Private streaming evidence:', run, flush=True)
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    source = subprocess.check_output(['git', 'show', commit + ':Sources/PadCore/LargeFileReader.swift'])
    (run / 'LargeFileReader.swift').write_bytes(source)
    harness = root / 'scripts/benchmark-streaming-core.swift'
    (run / harness.name).write_bytes(harness.read_bytes())
    (run / Path(__file__).name).write_bytes(Path(__file__).read_bytes())
    def sysctl(name):
        return subprocess.check_output(['sysctl', '-n', name], text=True).strip()
    metadata = {'commit': commit, 'os': platform.platform(), 'architecture': platform.machine(),
                'cpu': sysctl('machdep.cpu.brand_string'), 'cpuCount': os.cpu_count(),
                'physicalMemoryBytes': int(sysctl('hw.memsize')),
                'swift': subprocess.check_output(['xcrun', 'swiftc', '--version'], text=True),
                'configuration': '-O -swift-version 5; frozen committed standalone core source',
                'cache': 'Generated then synced, no cache flushing; concurrent development may compile.',
                'rss': 'Darwin ru_maxrss bytes, fresh child high-water including oracle and Foundation; generator excluded.',
                'hashes': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in run.iterdir() if p.is_file()}}
    (run / 'environment.json').write_text(json.dumps(metadata, indent=2) + '\n')
    binary = run / 'benchmark'
    command = ['xcrun', 'swiftc', '-O', '-swift-version', '5', '-module-cache-path', str(run / 'ModuleCache'),
               str(run / 'LargeFileReader.swift'), str(run / harness.name), '-o', str(binary)]
    compilation = run_child(command, run / 'compile.log', 180)
    (run / 'compile-status.json').write_text(json.dumps(compilation) + '\n')
    if compilation['exit']:
        raise SystemExit(compilation['exit'])
    measurements = []
    fixtures = []
    sizes = [1_000_000] if args.smoke else [1_000_000, 10_000_000, 100_000_000, 1_000_000_000]
    row = b'abcdefghijklmnop0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ\r\n'
    marker = b'THEONLYPAD-MATCH!'
    for shape in ['rows', 'longline']:
        for size in sizes:
            path = run / f'{shape}-{size}.synthetic'
            positions = [min(1_048_576 - 8, size // 2), size - len(marker)]
            # Length is a row multiple so row phase is continuous across writes.
            block = row * (1_048_576 // len(row)) if shape == 'rows' else b'a' * 1_048_576
            with path.open('xb') as stream:
                remaining = size
                while remaining:
                    data = block[:min(remaining, len(block))]
                    stream.write(data)
                    remaining -= len(data)
                for position in positions:
                    stream.seek(position)
                    stream.write(marker)
                stream.flush()
                os.fsync(stream.fileno())
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                while data := stream.read(1_048_576):
                    digest.update(data)
            fixtures.append({'shape': shape, 'bytes': size, 'sha256': digest.hexdigest(), 'matches': positions})
            (run / 'fixtures.json').write_text(json.dumps(fixtures, indent=2) + '\n')
            for repetition in range(1 if args.smoke else 3):
                log = run / f'{shape}-{size}-{repetition}.jsonl'
                status = run_child([str(binary), str(path), str(size), shape], log, 60)
                stages = []
                for line in log.read_text(errors='replace').splitlines():
                    try:
                        stages.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
                status.update(shape=shape, bytes=size, repetition=repetition, stages=stages,
                              completed=bool(stages and stages[-1].get('stage') == 'complete'))
                measurements.append(status)
                (run / 'results.json').write_text(json.dumps(measurements, indent=2) + '\n')
                print(shape, size, repetition, 'exit', status['exit'], 'complete', status['completed'], flush=True)
            # Remove only this exact generated fixture after recording identity and results.
            path.unlink()
    summary = []
    for shape in ['rows', 'longline']:
        for size in sizes:
            children = [v for v in measurements if v['shape'] == shape and v['bytes'] == size]
            good = [v for v in children if v['exit'] == 0 and v['completed']]
            scans = [s['seconds'] for v in good for s in v['stages'] if s['stage'] == 'search']
            windows = [s['seconds'] for v in good for s in v['stages'] if s['stage'] == 'window']
            cancellation = [s['requestToThrowSeconds'] for v in good for s in v['stages'] if s['stage'] == 'cancel']
            summary.append({'shape': shape, 'bytes': size, 'passed': len(good), 'attempted': len(children),
                            'searchMedianSeconds': statistics.median(scans) if scans else None,
                            'searchMaxSeconds': max(scans, default=None),
                            'windowDecodeMaxSeconds': max(windows, default=None),
                            'cancelThrowMaxSeconds': max(cancellation, default=None),
                            'peakRSSBytes': max((s['peakRSSBytes'] for v in good for s in v['stages']), default=None)})
    (run / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    raise SystemExit(0 if all(v['exit'] == 0 and v['completed'] for v in measurements) else 1)


if __name__ == '__main__':
    main()
