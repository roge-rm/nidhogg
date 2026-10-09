#!/usr/bin/env python3
"""Sample import for nidhogg: turns audio files or sample packs into CHOMPI's
card format. Run by lib/import.lua on the norns.

  import.py scan FW CARD ROOT...
      Lists packs under each ROOT, one per line: "pack<TAB>name<TAB>source<TAB>count",
      and zips it can't read as "bad<TAB>file<TAB>-<TAB>0".
      A pack is a folder with audio files in it, or such a folder inside a zip;
      source is the folder or "zipfile::folder". Then the targets for firmware
      FW: "target<TAB>id<TAB>label<TAB>samples already there".
  import.py import FW CARD SOURCE TARGET STATUS SLOTS
      Converts the pack at SOURCE into TARGET, writing progress to STATUS and
      the slots it filled to SLOTS.
  import.py presets FW CARD SLOTS
      Resets the presets of those slots to the factory defaults. Only while the
      firmware is stopped, as it keeps presets in memory and writes them back.

Card formats (docs/ref):
  TAPE   <mode>_<bank><slot>.wav plus <mode>_<bank><slot>_double.wav, 48 kHz
         16-bit stereo with a 44-byte header; the double has every second
         frame dropped. Modes jammi and cubbi, banks a-e, slots 1-14.
  TEMPO  chromatic/chroma_a<slot>.wav and slice/slice_a<slot>.wav, same format,
         at most 10 s. No doubles.
  WAVE   up to 7 wavetables in the card root, the first 7 by name. Each is 33
         frames of 2048 mono 32-bit floats starting at byte 136.
"""

import array
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import zipfile

AUDIO = (".wav", ".aif", ".aiff", ".flac", ".ogg")
NAMED = re.compile(r"^(jammi|cubbi|chroma|slice)_([a-e])(\d{1,2})\.", re.I)
TAPE_BANKS = "abcde"
TEMPO_FOLDERS = {"chroma": "chromatic", "slice": "slice"}
SLOTS = 14
TABLES = 7
TABLE_FRAMES = 33
FRAME = 2048
TEMPO_SECONDS = 10

TAPE_PRESET = [830, 0, 1000, 0, 0, 1000, 1000, 704, 500, False]
TEMPO_PRESET = [830, 600, 500, 0, 0, 1000, 0, 500, 0, 1000, 1000]


def is_audio(name):
    base = os.path.basename(name)
    return (base.lower().endswith(AUDIO) and not base.startswith(".")
            and "_double." not in base.lower())


def natural(name):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", name)]


# --- finding packs ---------------------------------------------------------

def scan_root(root):
    packs = []
    root = root.rstrip("/")
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted((x for x in dirs if not x.startswith(".") and x != "__MACOSX"), key=natural)
        rel = os.path.relpath(d, root)
        if rel.count(os.sep) > 4:
            dirs[:] = []
        audio = [f for f in files if is_audio(f)]
        if audio:
            name = "loose files" if rel == "." else rel
            packs.append((name, d, len(audio)))
        for f in sorted(files, key=natural):
            if f.lower().endswith(".zip") and not f.startswith("."):
                packs += scan_zip(os.path.join(d, f))
    return packs


def scan_zip(path):
    try:
        z = zipfile.ZipFile(path)
    except (zipfile.BadZipFile, OSError):
        print("bad\t%s\t-\t0" % os.path.basename(path))
        return []
    folders = {}
    for n in z.namelist():
        if "__MACOSX" in n or n.endswith("/") or not is_audio(n):
            continue
        folders.setdefault(os.path.dirname(n), []).append(n)
    zname = os.path.splitext(os.path.basename(path))[0]
    out = []
    for folder in sorted(folders, key=natural):
        name = zname if folder == "" else zname + "/" + folder
        out.append((name, path + "::" + folder, len(folders[folder])))
    return out


def pack_files(source, work):
    """The pack's audio files as local paths, extracting from a zip into work."""
    if "::" in source:
        path, folder = source.split("::", 1)
        z = zipfile.ZipFile(path)
        files = []
        for n in z.namelist():
            if "__MACOSX" in n or n.endswith("/") or not is_audio(n):
                continue
            if os.path.dirname(n) == folder:
                out = os.path.join(work, os.path.basename(n))
                with z.open(n) as src, open(out, "wb") as dst:
                    dst.write(src.read())
                files.append(out)
    else:
        files = [os.path.join(source, f) for f in os.listdir(source) if is_audio(f)]
    return sorted(files, key=lambda f: natural(os.path.basename(f)))


# --- targets ---------------------------------------------------------------

def tempo_dir(card, kind):
    # FAT is case-insensitive, so match the folder in any case
    want = TEMPO_FOLDERS[kind]
    for d in os.listdir(card):
        if d.lower() == want and os.path.isdir(os.path.join(card, d)):
            return os.path.join(card, d)
    path = os.path.join(card, want)
    os.makedirs(path, exist_ok=True)
    return path


def slot_path(fw, card, target, slot):
    if fw == "tape":
        mode, bank = target.split(":")
        return os.path.join(card, "%s_%s%d.wav" % (mode, bank, slot))
    if fw == "tempo":
        return os.path.join(tempo_dir(card, target), "%s_a%d.wav" % (target, slot))
    raise ValueError(fw)


def wavetables(card):
    names = sorted(f for f in os.listdir(card) if ".wav" in f and not f.startswith("."))
    return [os.path.join(card, f) for f in names]


def targets(fw, card):
    out = []
    if fw == "tape":
        for mode in ("jammi", "cubbi"):
            for bank in TAPE_BANKS:
                t = mode + ":" + bank
                n = sum(os.path.exists(slot_path(fw, card, t, s)) for s in range(1, SLOTS + 1))
                out.append((t, "%s %s" % (mode.upper(), bank), n))
    elif fw == "tempo":
        for kind in ("chroma", "slice"):
            n = sum(os.path.exists(slot_path(fw, card, kind, s)) for s in range(1, SLOTS + 1))
            out.append((kind, "SLICE" if kind == "slice" else "CHROMA", n))
    elif fw == "wave":
        for t in range(1, TABLES + 1):
            out.append((str(t), "from table %d" % t, TABLES - t + 1))
    return out


# --- converting ------------------------------------------------------------

def sox_raw(src, args, effects=()):
    return subprocess.run(["sox", "-V1", src] + args + ["-"] + list(effects), check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def write_pcm(path, data, rate=48000):
    """16-bit stereo with the plain 44-byte header CHOMPI expects."""
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, rate, rate * 4, 4, 16))
        f.write(b"data" + struct.pack("<I", len(data)))
        f.write(data)
    os.replace(tmp, path)


def convert_sample(src, dst, double, seconds=None):
    args = ["-t", "raw", "-e", "signed-integer", "-b", "16", "-c", "2", "-r", "48000", "-G"]
    data = sox_raw(src, args, ["trim", "0", str(seconds)] if seconds else [])
    data = data[:len(data) - len(data) % 4]
    write_pcm(dst, data)
    if double:
        frames = array.array("I", data)  # one 32-bit word per stereo frame
        write_pcm(dst[:-4] + "_double.wav", frames[::2].tobytes())


def convert_wavetable(src, dst):
    raw = sox_raw(src, ["-t", "raw", "-e", "floating-point", "-b", "32", "-c", "1"])
    x = array.array("f", raw[:len(raw) - len(raw) % 4])
    if len(x) >= FRAME and len(x) % FRAME == 0:
        frames = [x[i * FRAME:(i + 1) * FRAME] for i in range(len(x) // FRAME)]
    else:
        # one cycle of any length: stretch it to a frame
        n = len(x)
        if n < 2:
            raise ValueError("too short")
        cyc = array.array("f", (x[int(i * n / FRAME)] for i in range(FRAME)))
        frames = [cyc]
    # 33 frames spread over what's there
    pick = [frames[round(i * (len(frames) - 1) / (TABLE_FRAMES - 1))] for i in range(TABLE_FRAMES)]
    data = array.array("f")
    for fr in pick:
        data.extend(max(-1.0, min(1.0, v)) for v in fr)
    body = data.tobytes()
    clm = b"<!>2048 11000000 wavetable (CHOMPI WAVE)".ljust(48, b"\0")
    tmp = dst + ".part"
    with open(tmp, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 4 + 36 + 24 + 56 + 8 + len(body)) + b"WAVE")
        f.write(b"JUNK" + struct.pack("<I", 28) + b"\0" * 28)
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 3, 1, 44100, 44100 * 4, 4, 32))
        f.write(b"clm " + struct.pack("<I", 48) + clm)
        f.write(b"data" + struct.pack("<I", len(body)) + body)
    os.replace(tmp, dst)


def say(status, text):
    with open(status, "w") as f:
        f.write(text + "\n")


def do_import(fw, card, source, target, status, slots_out):
    work = tempfile.mkdtemp(prefix="nidhogg-import-")
    say(status, "reading the pack")
    files = pack_files(source, work)
    jobs = []  # (src, slot)
    if fw == "wave":
        start = int(target)
        tables = wavetables(card)
        for i, f in enumerate(files[:TABLES - start + 1]):
            jobs.append((f, start + i))
    else:
        used, rest = {}, []
        for f in files:
            m = NAMED.match(os.path.basename(f))
            n = int(m.group(3)) if m else 0
            if m and 1 <= n <= SLOTS and n not in used:
                used[n] = f
            else:
                rest.append(f)
        free = [s for s in range(1, SLOTS + 1) if s not in used]
        for f, s in zip(rest, free):
            used[s] = f
        jobs = sorted(((f, s) for s, f in used.items()), key=lambda j: j[1])
    done, failed = [], 0
    for i, (f, slot) in enumerate(jobs):
        say(status, "converting %d of %d" % (i + 1, len(jobs)))
        try:
            if fw == "wave":
                tables = wavetables(card)
                dst = tables[slot - 1] if slot <= len(tables) else os.path.join(card, "wavetable%02d.wav" % slot)
                convert_wavetable(f, dst)
            else:
                convert_sample(f, slot_path(fw, card, target, slot), fw == "tape",
                               TEMPO_SECONDS if fw == "tempo" else None)
            done.append(slot)
        except (subprocess.CalledProcessError, ValueError, OSError) as e:
            failed += 1
            sys.stderr.write("%s: %s\n" % (f, e))
    with open(slots_out, "w") as out:
        out.write("%s\n%s\n" % (target, " ".join(str(s) for s in done)))
    subprocess.run(["rm", "-rf", work])
    msg = "imported %d" % len(done)
    if failed:
        msg += ", %d failed" % failed
    if len(files) > len(jobs):
        msg += ", %d left over" % (len(files) - len(jobs))
    say(status, msg)
    return 0 if done else 1


def reset_presets(fw, card, slots_file):
    if fw == "wave":
        return 0
    with open(slots_file) as f:
        target = f.readline().strip()
        slots = [int(s) for s in f.readline().split()]
    path = os.path.join(card, "presets.json")
    try:
        with open(path) as f:
            p = json.load(f)
    except (OSError, ValueError):
        return 0
    if fw == "tape":
        mode, bank = target.split(":")
        bank_slots = p[0][("jammi", "cubbi").index(mode)][TAPE_BANKS.index(bank)]
        for s in slots:
            bank_slots[s - 1] = list(TAPE_PRESET)
    else:
        mode_slots = p[("chroma", "slice").index(target)]
        for s in slots:
            mode_slots[s - 1] = list(TEMPO_PRESET)
    tmp = path + ".part"
    with open(tmp, "w") as f:
        json.dump(p, f, separators=(",", ":"))
    os.replace(tmp, path)
    return 0


def main(argv):
    cmd = argv[1]
    if cmd == "scan":
        fw, card, roots = argv[2], argv[3], argv[4:]
        for root in roots:
            if os.path.isdir(root):
                for name, src, n in scan_root(root):
                    print("pack\t%s\t%s\t%d" % (name, src, n))
        for t, label, n in targets(fw, card):
            print("target\t%s\t%s\t%d" % (t, label, n))
        return 0
    if cmd == "import":
        return do_import(*argv[2:8])
    if cmd == "presets":
        return reset_presets(*argv[2:5])
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
