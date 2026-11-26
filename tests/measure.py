#!/usr/bin/env python3
"""What WindowStrip and its wslist helper cost the Mac, from the kernel's own
per-process counters (proc_pid_rusage), for checking what a change costs.

  tests/measure.py start <file>    save the counters now
  tests/measure.py stop <file>     print what was used since `start`
  tests/measure.py watch <secs>    sample for that long, then print it
  tests/measure.py idle            seconds since the last keyboard/mouse input

Counts CPU time (user + system), instructions and cycles (steadier than time),
wakeups (idle-package and interrupt: what keeps the CPU from sleeping), energy
as the kernel bills it, disk writes, and memory (phys_footprint, what Activity
Monitor calls Memory). A process that started in between is counted from its
start. One that exited in between is lost (the kernel forgets its counters), and
`stop` says so: the test suite restarts WindowStrip, so don't wrap whole test
runs in start/stop.
"""
import ctypes, json, os, subprocess, sys, time

RUSAGE_INFO_V4 = 4
FIELDS = ["uuid_lo", "uuid_hi", "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins",
          "wired_size", "resident_size", "phys_footprint", "proc_start_abstime", "proc_exit_abstime",
          "child_user_time", "child_system_time", "child_pkg_idle_wkups", "child_interrupt_wkups",
          "child_pageins", "child_elapsed_abstime", "diskio_bytesread", "diskio_byteswritten",
          "cpu_time_qos_default", "cpu_time_qos_maintenance", "cpu_time_qos_background",
          "cpu_time_qos_utility", "cpu_time_qos_legacy", "cpu_time_qos_user_initiated",
          "cpu_time_qos_user_interactive", "billed_system_time", "serviced_system_time", "logical_writes",
          "lifetime_max_phys_footprint", "instructions", "cycles", "billed_energy", "serviced_energy",
          "interval_max_phys_footprint", "runnable_time"]


class RUsage(ctypes.Structure):
    _fields_ = [(f, ctypes.c_uint64) for f in FIELDS]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
tb = Timebase()
libc.mach_timebase_info(ctypes.byref(tb))
TICK_NS = tb.numer / tb.denom   # CPU times come in mach ticks on Apple silicon


def pids(name):
    out = subprocess.run(["/usr/bin/pgrep", "-x", name], capture_output=True, text=True).stdout.split()
    return [int(p) for p in out]


def counters(pid):
    r = RUsage()
    if libc.proc_pid_rusage(pid, RUSAGE_INFO_V4, ctypes.byref(r)) != 0:
        return None
    return {
        "cpu_ms": (r.user_time + r.system_time) * TICK_NS / 1e6,
        "instructions": r.instructions, "cycles": r.cycles,
        "idle_wakeups": r.pkg_idle_wkups, "interrupt_wakeups": r.interrupt_wkups,
        "energy_nj": r.billed_energy, "disk_written": r.diskio_byteswritten,
        "logical_writes": r.logical_writes, "footprint": r.phys_footprint,
        "start": r.proc_start_abstime,
    }


def snapshot():
    snap = {"at": time.time(), "procs": {}}
    for name in ("WindowStrip", "wslist"):
        for pid in pids(name):
            c = counters(pid)
            if c: snap["procs"][f"{name}:{pid}"] = c
    return snap


def hid_idle():
    out = subprocess.run(["/usr/sbin/ioreg", "-c", "IOHIDSystem", "-d", "4"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if '"HIDIdleTime"' in line:
            return int(line.split("=")[-1]) / 1e9
    return None


def report(a, b):
    secs = b["at"] - a["at"]
    total = {}
    lines = []
    for key, c in b["procs"].items():
        base = a["procs"].get(key)
        if base is None or base["start"] != c["start"]:
            base = {k: 0 for k in c}   # started in between: count it from its start
        d = {k: c[k] - base[k] for k in c if k not in ("footprint", "start")}
        d["footprint"] = c["footprint"]
        for k, v in d.items():
            total[k] = total.get(k, 0) + v
        lines.append((key, d))
    def fmt(d):
        return (f"CPU {d['cpu_ms']:.0f} ms ({d['cpu_ms'] / secs / 10:.3f}% of one core), "
                f"{d['instructions'] / 1e6:.0f} M instructions, "
                f"wakeups {d['idle_wakeups'] / secs:.1f}/s idle + {d['interrupt_wakeups'] / secs:.1f}/s interrupt, "
                f"energy {d['energy_nj'] / 1e6:.0f} mJ, disk {d['disk_written'] / 1024:.0f} KB written, "
                f"memory {d['footprint'] / 1048576:.1f} MB")
    print(f"over {secs:.0f} s:")
    for key in a["procs"]:
        if key not in b["procs"]:
            print(f"  {key} exited in between: what it used is not counted, so these totals are too low")
    for key, d in lines:
        print(f"  {key}: {fmt(d)}")
    print(f"  both: {fmt(total)}")
    return {"seconds": secs, "total": total, "procs": dict(lines)}


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "watch"
    if cmd == "start":
        json.dump(snapshot(), open(sys.argv[2], "w"))
    elif cmd == "stop":
        result = report(json.load(open(sys.argv[2])), snapshot())
        if len(sys.argv) > 3:
            json.dump(result, open(sys.argv[3], "w"), indent=1)
    elif cmd == "watch":
        secs = float(sys.argv[2]) if len(sys.argv) > 2 else 60
        a = snapshot(); idle0 = hid_idle()
        time.sleep(secs)
        b = snapshot(); idle1 = hid_idle()
        report(a, b)
        if idle0 is not None and idle1 is not None:
            print(f"  keyboard/mouse idle for the whole window: {idle1 >= secs - 0.5} (idle now {idle1:.0f} s)")
    elif cmd == "idle":
        print(f"{hid_idle():.1f}")


main()
