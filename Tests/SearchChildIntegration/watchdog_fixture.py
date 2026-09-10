#!/usr/bin/env python3
"""Fixed watchdog self-controls. Run only under the reviewed owned watchdog.

This file is inert when imported. It never creates a session or process group.
Only leader-exit creates a child: one explicitly tracked descendant in the same group.
"""
import argparse
import os
import signal


def loop():
    while True:
        signal.pause()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['benign', 'loop', 'ignore-term', 'leader-exit'])
    args = parser.parse_args(argv)
    if args.mode == 'benign':
        os.write(1, b'watchdog-benign\n')
        return 0
    if args.mode == 'ignore-term':
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if args.mode == 'leader-exit':
        read_fd, write_fd = os.pipe()
        descendant = os.fork()
        if descendant == 0:
            os.close(read_fd)
            os.write(write_fd, b'R')
            os.close(write_fd)
            loop()
            os._exit(70)
        os.close(write_fd)
        ready = os.read(read_fd, 1)
        os.close(read_fd)
        if ready != b'R':
            return 70
        os.write(1, ('watchdog-descendant-ready:' + str(descendant) + '\n').encode('ascii'))
        # Deliberately leave exactly this group member alive. The watchdog must
        # kill the group before it reaps this leader, then observe output EOF.
        os._exit(0)
    os.write(1, b'watchdog-loop-ready\n')
    loop()
    return 70


if __name__ == '__main__':
    raise SystemExit(main())
