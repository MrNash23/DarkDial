#!/usr/bin/env python3
"""Talk to the Darkdial Lightroom plugin without the desktop app.

    lr_cli.py status                      hello + current status
    lr_cli.py get Exposure                range and value of one parameter
    lr_cli.py set Exposure 0.5            set an absolute value
    lr_cli.py delta Exposure 0.1          add to the current value
    lr_cli.py monitor Exposure Contrast   print everything the plugin reports
    lr_cli.py sweep Exposure --rate 50 --seconds 4 [--track]
                                          move a slider back and forth and
                                          measure how fast Lightroom follows

Lightroom Classic must be running with the plugin loaded. Protocol:
docs/PROTOCOL.md, section 2.
"""
import argparse
import json
import socket
import statistics
import sys
import time

HOST = "127.0.0.1"
PORT_FROM_PLUGIN = 54770
PORT_TO_PLUGIN = 54771


class Link:
    def __init__(self, timeout=3.0):
        try:
            self.rx = socket.create_connection((HOST, PORT_FROM_PLUGIN), timeout=timeout)
            self.tx = socket.create_connection((HOST, PORT_TO_PLUGIN), timeout=timeout)
        except OSError as err:
            sys.exit(f"cannot reach the plugin ({err}). Is Lightroom running with Darkdial loaded?")
        self.buffer = b""

    def send(self, **message):
        self.tx.sendall(json.dumps(message).encode("utf-8") + b"\n")

    def read(self, timeout):
        """Returns the next message, or None after `timeout` seconds."""
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            self.rx.settimeout(remaining)
            try:
                chunk = self.rx.recv(4096)
            except socket.timeout:
                return None
            if not chunk:
                sys.exit("plugin closed the connection")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def wait_for(self, kind, timeout=2.0, **match):
        deadline = time.monotonic() + timeout
        while True:
            message = self.read(deadline - time.monotonic())
            if message is None:
                return None
            if message.get("t") == kind and all(message.get(k) == v for k, v in match.items()):
                return message

    def hello(self):
        # The plugin drops its reply while its send socket is still connecting.
        for _ in range(10):
            self.send(t="hello", app="lr_cli", proto="1.0")
            reply = self.wait_for("hello", timeout=0.5)
            if reply:
                return reply
        sys.exit("no hello from the plugin")


def cmd_status(link, args):
    print(link.hello())
    print(link.wait_for("status"))


def cmd_get(link, args):
    link.hello()
    link.send(t="get", p=args.param)
    print(link.wait_for("range", p=args.param))
    print(link.wait_for("value", p=args.param))


def cmd_set(link, args):
    link.hello()
    if args.command == "set":
        link.send(t="set", p=args.param, v=args.value, s=1)
    else:
        link.send(t="delta", p=args.param, d=args.value, s=1)
    # Outside Develop the plugin switches modules first, which takes a while.
    print(link.wait_for("value", timeout=5.0, p=args.param, s=1))


def cmd_monitor(link, args):
    print(link.hello())
    link.send(t="watch", p=args.params)
    last_ping = time.monotonic()
    while True:
        message = link.read(0.5)
        if message and message.get("t") != "pong":
            print(message)
        if time.monotonic() - last_ping > 2:
            link.send(t="ping")
            last_ping = time.monotonic()


def cmd_sweep(link, args):
    link.hello()
    link.send(t="get", p=args.param)
    rng = link.wait_for("range", p=args.param)
    start = link.wait_for("value", p=args.param)
    if not rng or not start:
        sys.exit("no range/value: Develop module with a selected photo is required")
    low, high, origin = rng["min"], rng["max"], start["v"]
    # Sweep over a tenth of the range around the current value.
    span = (high - low) * 0.1
    low, high = max(low, origin - span / 2), min(high, origin + span / 2)

    if args.track:
        link.send(t="track", p=args.param)
    interval = 1.0 / args.rate
    total = int(args.rate * args.seconds)
    sent_at, latency = {}, []
    began = time.monotonic()
    for i in range(total):
        phase = (i % args.rate) / args.rate  # one full back-and-forth per second
        position = phase * 2 if phase < 0.5 else 2 - phase * 2
        seq = i + 1
        sent_at[seq] = time.monotonic()
        link.send(t="set", p=args.param, v=low + (high - low) * position, s=seq)
        next_send = began + (i + 1) * interval
        while True:
            message = link.read(max(0.0, next_send - time.monotonic()))
            if message is None:
                break
            if message.get("t") == "value" and message.get("s") in sent_at:
                latency.append(time.monotonic() - sent_at.pop(message["s"]))
    # Collect the answers still on their way.
    while sent_at:
        message = link.read(2.0)
        if message is None:
            break
        if message.get("t") == "value" and message.get("s") in sent_at:
            latency.append(time.monotonic() - sent_at.pop(message["s"]))
    elapsed = time.monotonic() - began
    if args.track:
        link.send(t="track", p="")
    link.send(t="set", p=args.param, v=origin, s=0)
    link.wait_for("value", p=args.param, s=0)

    if not latency:
        sys.exit("no answers received")
    latency.sort()
    ms = [x * 1000 for x in latency]
    print(f"{args.param}  rate {args.rate} Hz  tracking {'on' if args.track else 'off'}")
    print(f"  sent {total}, answered {len(ms)}, unanswered {len(sent_at)}, wall time {elapsed:.2f} s")
    print(f"  latency ms: median {statistics.median(ms):.1f}  "
          f"p95 {ms[int(len(ms) * 0.95) - 1]:.1f}  max {ms[-1]:.1f}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status").set_defaults(run=cmd_status)
    get = sub.add_parser("get")
    get.add_argument("param")
    get.set_defaults(run=cmd_get)
    for name in ("set", "delta"):
        cmd = sub.add_parser(name)
        cmd.add_argument("param")
        cmd.add_argument("value", type=float)
        cmd.set_defaults(run=cmd_set)
    monitor = sub.add_parser("monitor")
    monitor.add_argument("params", nargs="*", default=["Exposure"])
    monitor.set_defaults(run=cmd_monitor)
    sweep = sub.add_parser("sweep")
    sweep.add_argument("param")
    sweep.add_argument("--rate", type=int, default=50)
    sweep.add_argument("--seconds", type=float, default=4)
    sweep.add_argument("--track", action="store_true")
    sweep.set_defaults(run=cmd_sweep)

    args = parser.parse_args()
    try:
        args.run(Link(), args)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
