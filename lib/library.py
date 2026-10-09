#!/usr/bin/env python3
"""nidhogg's sample library. Run by lib/library.lua on the norns.

Imported packs are converted once and kept in the library; banks on the card
are loaded from it. CARDS is dust/audio/nidhogg (one card folder per firmware)
and LIB is CARDS/library:

  LIB/samples/<pack>/NN <name>.wav   48 kHz 16-bit stereo, NN being the slot
                                     order; packs over 14 fill several banks
  LIB/tables/<pack>/NN <name>.wav    WAVE wavetables, ready for the card
  LIB/<kind>/<pack>/source.tsv       where each file came from, for spotting
                                     duplicates
  LIB/banks.json                     what's loaded in each bank, with each
                                     file's size and mtime, so a bank changed
                                     on the instrument is noticed

Commands (all write TSV lines on stdout):
  scan CARDS ROOT...
      "pack<TAB>name<TAB>source<TAB>count<TAB>kind<TAB>in library" then
      "file<TAB>name" for each of its files; "bad<TAB>zip" for zips that
      can't be read.
  banks FW CARDS
      "bank<TAB>id<TAB>label<TAB>loaded<TAB>count<TAB>fw" for each of FW's
      banks (FW "all" for every firmware's, and nothing else),
      each followed by "slot<TAB>bank<TAB>n<TAB>name" for its samples; then
      "item<TAB>id<TAB>label" for each library item that fits them and
      "sample<TAB>path<TAB>label" for each single library file.
  run FW CARDS JOBS STATUS SLOTS
      JOBS lines: "import<TAB>source<TAB>target<TAB>file|file...<TAB>name<TAB>kind"
      converts a pack into the library as name, as samples or tables (kind)
      and, unless target is "library", loads it into "<fw>/<bank>", or into
      that bank's empty slots for "add:<fw>/<bank>";
      "load<TAB>item<TAB>bank" loads a library item into a bank, replacing
      it; "slot<TAB>path<TAB>bank<TAB>n" puts one library file in slot n. Progress
      goes to STATUS and the card slots changed to SLOTS.
  presets CARDS SLOTS
      Resets the presets of the slots listed, on each firmware's card. Only while the firmware is stopped,
      as it keeps presets in memory and writes them back.

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
import shutil
import struct
import subprocess
import sys
import tempfile
import time
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


def kind_of(files):
    """jammi, cubbi, chroma or slice if most files are named for it, else "-"."""
    kinds = [m.group(1).lower() for m in (NAMED.match(os.path.basename(f)) for f in files) if m]
    if not kinds:
        return "-"
    best = max(set(kinds), key=kinds.count)
    return best if kinds.count(best) * 2 > len(files) else "-"


def clean(name):
    """A pack name safe for a folder: no slashes at the ends, nothing odd."""
    name = re.sub(r"[^\w .,()&+'/-]", "_", name).strip(" /")
    return re.sub(r"/+", "/", name) or "pack"


# --- finding packs ---------------------------------------------------------

def fingerprint(name, size, crc=""):
    return "%s|%d|%s" % (os.path.basename(name).lower(), size, crc)


def split_named(name, source, files):
    """A folder whose files are named for more than one CHOMPI bank (a whole
    card, say) becomes one pack per bank, each keeping its slots."""
    groups, rest = {}, []
    for f in files:
        m = NAMED.match(f[0])
        if m:
            groups.setdefault((m.group(1).lower(), m.group(2).lower()), []).append(f)
        else:
            rest.append(f)
    if len(groups) < 2:
        return [(name, source, files)]
    out = []
    for (mode, bank), fs in sorted(groups.items()):
        out.append(("%s/%s %s" % (name, mode.upper(), bank), source, fs))
    if rest:
        out.append((name, source, rest))
    return out


def scan_root(root):
    """[(name, source, [(file, fingerprint)])]"""
    packs = []
    root = root.rstrip("/")
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted((x for x in dirs if not x.startswith(".") and x != "__MACOSX"), key=natural)
        rel = os.path.relpath(d, root)
        if rel.count(os.sep) > 4:
            dirs[:] = []
        audio = sorted((f for f in files if is_audio(f)), key=natural)
        if audio:
            name = "loose files" if rel == "." else rel
            packs += split_named(name, d, [(f, fingerprint(f, os.path.getsize(os.path.join(d, f))))
                                           for f in audio])
        for f in sorted(files, key=natural):
            if f.lower().endswith(".zip") and not f.startswith("."):
                packs += scan_zip(os.path.join(d, f))
    return packs


def scan_zip(path):
    try:
        z = zipfile.ZipFile(path)
    except (zipfile.BadZipFile, OSError):
        print("bad\t%s" % os.path.basename(path))
        return []
    folders = {}
    for info in z.infolist():
        n = info.filename
        if "__MACOSX" in n or n.endswith("/") or not is_audio(n):
            continue
        folders.setdefault(os.path.dirname(n), []).append(
            (os.path.basename(n), fingerprint(n, info.file_size, "%08x" % info.CRC)))
    zname = os.path.splitext(os.path.basename(path))[0]
    out = []
    for folder in sorted(folders, key=natural):
        # drop the zip's name when the folder inside is named like it, as most
        # zips have one (Google Drive adds a date to the zip's name)
        parts = [zname] + [x for x in folder.split("/") if x]
        if len(parts) > 1 and zname.startswith(parts[1]):
            parts.pop(0)
        out += split_named("/".join(parts), path + "::" + folder,
                           sorted(folders[folder], key=lambda f: natural(f[0])))
    return out


def extract(source, names, work):
    """The chosen files of a pack as local paths, extracting from a zip into work."""
    names = set(names)
    if "::" not in source:
        return [os.path.join(source, n) for n in sorted(names, key=natural)]
    path, folder = source.split("::", 1)
    z = zipfile.ZipFile(path)
    out = []
    for n in z.namelist():
        if os.path.dirname(n) == folder and os.path.basename(n) in names:
            dst = os.path.join(work, os.path.basename(n))
            with z.open(n) as src, open(dst, "wb") as f:
                shutil.copyfileobj(src, f)
            out.append(dst)
    return sorted(out, key=lambda f: natural(os.path.basename(f)))


# --- the library -----------------------------------------------------------

def lib_dir(cards):
    return os.path.join(cards, "library")


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".part"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1)
    os.replace(tmp, path)


def lib_packs(cards, kind):
    """{pack name: folder} for kind "samples" or "tables"."""
    base = os.path.join(lib_dir(cards), kind)
    out = {}
    for d, dirs, files in os.walk(base):
        dirs.sort(key=natural)
        if any(f.endswith(".wav") for f in files):
            out[os.path.relpath(d, base)] = d
    return out


def pack_wavs(folder):
    return sorted((f for f in os.listdir(folder) if f.endswith(".wav")), key=natural)


def known_prints(cards):
    """{fingerprint: pack name} over the whole library."""
    out = {}
    for kind in ("samples", "tables"):
        for name, d in lib_packs(cards, kind).items():
            try:
                with open(os.path.join(d, "source.tsv")) as f:
                    for line in f:
                        out[line.rstrip("\n").split("\t")[-1]] = name
            except OSError:
                pass
    return out


def new_pack_dir(cards, kind, name):
    base = os.path.join(lib_dir(cards), kind, clean(name))
    d, n = base, 2
    while os.path.exists(d):
        d, n = "%s %d" % (base, n), n + 1
    os.makedirs(d)
    return d


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


def read_pcm(path):
    with open(path, "rb") as f:
        f.seek(44)
        return f.read()


def convert_sample(src, dst):
    args = ["-t", "raw", "-e", "signed-integer", "-b", "16", "-c", "2", "-r", "48000", "-G"]
    data = sox_raw(src, args)
    write_pcm(dst, data[:len(data) - len(data) % 4])


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
        frames = [array.array("f", (x[int(i * n / FRAME)] for i in range(FRAME)))]
    # 33 frames spread over what's there
    pick = [frames[round(i * (len(frames) - 1) / (TABLE_FRAMES - 1))] for i in range(TABLE_FRAMES)]
    data = array.array("f")
    for fr in pick:
        data.extend(max(-1.0, min(1.0, v)) for v in fr)
    body = data.tobytes()
    clm = b"<!>2048 11000000 wavetable (CHOMPI WAVE)".ljust(48, b"\0")
    tmp = dst + ".part"
    with open(tmp, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 128 + len(body)) + b"WAVE")
        f.write(b"JUNK" + struct.pack("<I", 28) + b"\0" * 28)
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 3, 1, 44100, 44100 * 4, 4, 32))
        f.write(b"clm " + struct.pack("<I", 48) + clm)
        f.write(b"data" + struct.pack("<I", len(body)) + body)
    os.replace(tmp, dst)


# --- banks -----------------------------------------------------------------

def card(cards, fw):
    return os.path.join(cards, fw)


def tempo_dir(c, kind):
    # FAT is case-insensitive, so match the folder in any case
    want = TEMPO_FOLDERS[kind]
    for d in os.listdir(c):
        if d.lower() == want and os.path.isdir(os.path.join(c, d)):
            return os.path.join(c, d)
    path = os.path.join(c, want)
    os.makedirs(path, exist_ok=True)
    return path


def wavetables(c):
    names = sorted(f for f in os.listdir(c) if ".wav" in f and not f.startswith("."))
    return [os.path.join(c, f) for f in names]


def bank_ids(fw):
    if fw == "tape":
        return ["%s:%s" % (m, b) for m in ("jammi", "cubbi") for b in TAPE_BANKS]
    if fw == "tempo":
        return ["chroma", "slice"]
    return ["table:%d" % t for t in range(1, TABLES + 1)]


def bank_label(bank):
    if ":" in bank:
        mode, b = bank.split(":")
        return "table %s" % b if mode == "table" else "%s %s" % (mode.upper(), b)
    return bank.upper()


def bank_files(fw, cards, bank):
    """{slot: path} of the samples in a bank, existing or not."""
    c = card(cards, fw)
    if fw == "tape":
        mode, b = bank.split(":")
        return {s: os.path.join(c, "%s_%s%d.wav" % (mode, b, s)) for s in range(1, SLOTS + 1)}
    if fw == "tempo":
        d = tempo_dir(c, bank)
        return {s: os.path.join(d, "%s_a%d.wav" % (bank, s)) for s in range(1, SLOTS + 1)}
    t = int(bank.split(":")[1])
    tables = wavetables(c)
    path = tables[t - 1] if t <= len(tables) else os.path.join(c, "wavetable%02d.wav" % t)
    return {1: path}


def stamp(path):
    st = os.stat(path)
    return [st.st_size, int(st.st_mtime)]


def bank_state(fw, cards, bank):
    """{file name: [size, mtime]} of what's in a bank now."""
    return {os.path.basename(p): stamp(p) for p in bank_files(fw, cards, bank).values()
            if os.path.exists(p)}


def banks_db(cards):
    return load_json(os.path.join(lib_dir(cards), "banks.json"), {})


def loaded(fw, cards, db, bank):
    """The library item in a bank, or None if it's empty or was changed since."""
    key = fw + "/" + bank
    entry = db.get(key)
    now = bank_state(fw, cards, bank)
    if not now:
        return None
    if entry and entry.get("files") == now:
        return entry["item"]
    return None


FACTORY = {"tape": ["%s:%s" % (m, b) for m in ("jammi", "cubbi") for b in "abc"],
           "tempo": ["chroma", "slice"], "wave": ["table:%d" % t for t in range(1, TABLES + 1)]}


def first_run(fw, cards, db):
    """The factory card's banks count as loaded from "factory/<bank>", though
    they're only copied into the library when about to be replaced."""
    changed = False
    for bank in FACTORY[fw]:
        key = fw + "/" + bank
        if key not in db:
            now = bank_state(fw, cards, bank)
            if now:
                name = "factory/%s" % bank_label(bank)
                db[key] = {"item": name if fw == "wave" else name + "#1",
                           "files": now, "factory": True}
                changed = True
    return changed


def keep_bank(fw, cards, db, bank, say):
    """Copies a bank into the library before it's replaced, unless the
    library already has exactly that."""
    now = bank_state(fw, cards, bank)
    if not now:
        return
    entry = db.get(fw + "/" + bank)
    if entry and entry.get("files") == now and not entry.get("factory"):
        return
    if entry and entry.get("files") == now:
        name = re.split(r"[#@]", entry["item"])[0]
        if name in lib_packs(cards, "tables" if fw == "wave" else "samples"):
            return
    else:
        name = "kept/%s %s" % (bank_label(bank), time.strftime("%Y-%m-%d %H%M"))
    say("keeping %s in the library" % bank_label(bank))
    kind = "tables" if fw == "wave" else "samples"
    d = new_pack_dir(cards, kind, name)
    for slot, p in sorted(bank_files(fw, cards, bank).items()):
        if os.path.exists(p):
            shutil.copyfile(p, os.path.join(d, "%02d %s" % (slot, os.path.basename(p))))


def item_files(cards, fw, item):
    """The wav files of a library item: "pack" or "pack#part" (part 1, 2, ...)."""
    name, _, part = item.partition("#")
    kind = "tables" if fw == "wave" else "samples"
    folder = lib_packs(cards, kind).get(name)
    if not folder:
        return []
    files = [os.path.join(folder, f) for f in pack_wavs(folder)]
    if fw == "wave":
        return files
    p = int(part or 1)
    return files[(p - 1) * SLOTS:p * SLOTS]


def items(fw, cards):
    """[(item, label)] that can go in fw's banks."""
    out = []
    kind = "tables" if fw == "wave" else "samples"
    for name, folder in sorted(lib_packs(cards, kind).items(), key=lambda kv: natural(kv[0])):
        n = len(pack_wavs(folder))
        if fw == "wave":
            for i, f in enumerate(pack_wavs(folder)):
                out.append(("%s@%d" % (name, i + 1), "%s %d" % (name, i + 1)) if n > 1 else (name, name))
            continue
        parts = (n + SLOTS - 1) // SLOTS
        for p in range(1, parts + 1):
            out.append(("%s#%d" % (name, p), name if parts == 1 else "%s %d/%d" % (name, p, parts)))
    return out


def sample_name(path):
    """A library file's name without its "NN " slot prefix."""
    return re.sub(r"^\d+ ", "", os.path.splitext(os.path.basename(path))[0])


def put(fw, src, dst):
    """Writes a library file into a card slot."""
    if fw == "wave":
        shutil.copyfile(src, dst + ".part")
        os.replace(dst + ".part", dst)
        return
    data = read_pcm(src)
    if fw == "tempo":
        data = data[:TEMPO_SECONDS * 48000 * 4]
    write_pcm(dst, data)
    if fw == "tape":
        frames = array.array("I", data)  # one 32-bit word per stereo frame
        write_pcm(dst[:-4] + "_double.wav", frames[::2].tobytes())


def remember(fw, cards, db, bank, item, names):
    db[fw + "/" + bank] = {"item": item, "files": bank_state(fw, cards, bank),
                           "names": {str(k): v for k, v in names.items()}}


def slot_names(fw, cards, db, bank):
    """{slot: name} of the samples in a bank, as imported where known."""
    entry = db.get(fw + "/" + bank) or {}
    known = entry.get("names", {}) if entry.get("files") == bank_state(fw, cards, bank) else {}
    out = {}
    for slot, p in bank_files(fw, cards, bank).items():
        if os.path.exists(p):
            out[slot] = known.get(str(slot), os.path.splitext(os.path.basename(p))[0])
    return out


def load_item(fw, cards, db, item, bank, say):
    """Puts a library item in a bank, replacing what's there; returns the
    slots changed."""
    keep_bank(fw, cards, db, bank, say)
    if fw == "wave":
        name, _, idx = item.partition("@")
        files = item_files(cards, fw, name)
        files = files[int(idx or 1) - 1:int(idx or 1)]
    else:
        files = item_files(cards, fw, item)
    slots_now = bank_files(fw, cards, bank)
    named = {}
    for f in files:
        # "NN name.wav": NN is the slot it came from
        m = re.match(r"^(\d+) ", os.path.basename(f))
        named[f] = int(m.group(1)) if m else 0
    if fw != "wave":
        # whole bank replaced: clear it first
        for p in slots_now.values():
            for q in (p, p[:-4] + "_double.wav"):
                if os.path.exists(q):
                    os.remove(q)
    used, rest = {}, []
    for f in files:
        s = named[f]
        if fw != "wave" and 1 <= s <= SLOTS and s not in used and len(files) <= SLOTS:
            used[s] = f
        else:
            rest.append(f)
    free = [s for s in range(1, SLOTS + 1) if s not in used]
    for f, s in zip(rest, free):
        used[s] = f
    say("loading %s" % bank_label(bank))
    for s, f in sorted(used.items()):
        put(fw, f, slots_now[s])
    remember(fw, cards, db, bank, item, {s: sample_name(f) for s, f in used.items()})
    return list(slots_now) if fw != "wave" else sorted(used)


def add_files(fw, cards, db, files, bank, say):
    """Puts library files in a bank's empty slots, as many as fit; returns
    the slots changed."""
    names = slot_names(fw, cards, db, bank)
    slots_now = bank_files(fw, cards, bank)
    free = [s for s in sorted(slots_now) if not os.path.exists(slots_now[s])]
    say("adding to %s" % bank_label(bank))
    done = []
    for f, s in zip(files, free):
        put(fw, f, slots_now[s])
        names[s] = sample_name(f)
        done.append(s)
    remember(fw, cards, db, bank, "-", names)
    return done


def set_slot(fw, cards, db, f, bank, slot, say):
    """Puts one library file in one slot; the bank is kept in the library
    first if that replaces a sample that isn't there yet."""
    slots_now = bank_files(fw, cards, bank)
    if os.path.exists(slots_now[slot]):
        keep_bank(fw, cards, db, bank, say)
    names = slot_names(fw, cards, db, bank)
    put(fw, f, slots_now[slot])
    names[slot] = sample_name(f)
    remember(fw, cards, db, bank, "-", names)
    return [slot]


def lib_samples(fw, cards):
    """[(path relative to its kind's folder, label)] of every library file
    that fits fw's slots."""
    kind = "tables" if fw == "wave" else "samples"
    base = os.path.join(lib_dir(cards), kind)
    out = []
    for name, folder in sorted(lib_packs(cards, kind).items(), key=lambda kv: natural(kv[0])):
        for f in pack_wavs(folder):
            out.append((os.path.join(name, f), "%s/%s" % (name, sample_name(f))))
    return out


# --- jobs ------------------------------------------------------------------

def import_pack(kind, cards, source, names, pname, say, n_of):
    """Converts chosen files of a pack into the library as pname, as samples
    or tables; returns the name it got, the files made and how many failed."""
    work = tempfile.mkdtemp(prefix="nidhogg-import-")
    try:
        files = extract(source, names, work)
        d = new_pack_dir(cards, kind, pname)
        # CHOMPI-named files keep their slot; others follow in name order
        used, rest = {}, []
        for f in files:
            m = NAMED.match(os.path.basename(f))
            s = int(m.group(3)) if m else 0
            if m and 1 <= s <= SLOTS and s not in used and len(files) <= SLOTS:
                used[s] = f
            else:
                rest.append(f)
        n = max(list(used) + [0])
        for f in rest:
            n += 1
            used[n] = f
        prints = {}
        failed = 0
        for s, f in sorted(used.items()):
            say("converting %s" % n_of())
            base = os.path.splitext(os.path.basename(f))[0]
            dst = os.path.join(d, "%02d %s.wav" % (s, clean(base).replace("/", "_")))
            try:
                if kind == "tables":
                    convert_wavetable(f, dst)
                else:
                    convert_sample(f, dst)
                prints[os.path.basename(f)] = dst
            except (subprocess.CalledProcessError, ValueError, OSError) as e:
                failed += 1
                sys.stderr.write("%s: %s\n" % (f, e))
        return os.path.relpath(d, os.path.join(lib_dir(cards), kind)), prints, failed
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run(fw, cards, jobs_file, status, slots_out):
    def say(text):
        with open(status, "w") as f:
            f.write(text + "\n")

    db = banks_db(cards)
    first_run(fw, cards, db)
    with open(jobs_file) as f:
        jobs = [line.rstrip("\n").split("\t") for line in f if line.strip()]
    total = sum(len(j[3].split("|")) for j in jobs if j[0] == "import")
    done = [0]

    def n_of():
        done[0] += 1
        return "%d of %d" % (done[0], total)

    # source fingerprints for duplicates: from the scan, kept per pack
    prints_in = {}
    changed, failed, imported = [], 0, 0
    for job in jobs:
        if job[0] == "import":
            _, source, target, names, pname, kind = job
            names = names.split("|")
            pack, made, bad = import_pack(kind, cards, source, names, pname, say, n_of)
            failed += bad
            imported += len(made)
            # remember where each file came from
            fps = dict(scan_fingerprints(source))
            with open(os.path.join(lib_dir(cards), kind, pack, "source.tsv"), "w") as f:
                for name in made:
                    f.write("%s\t%s\n" % (name, fps.get(name, fingerprint(name, 0))))
            if target == "library":
                continue
            # "<fw>/<bank>", or "add:<fw>/<bank>" for its empty slots
            add = target.startswith("add:")
            tfw, bank = target[4 if add else 0:].split("/", 1)
            first_run(tfw, cards, db)
            if add:
                folder = os.path.join(lib_dir(cards), kind, pack)
                files = [os.path.join(folder, f) for f in pack_wavs(folder)]
                changed.append((tfw, bank, add_files(tfw, cards, db, files, bank, say)))
            else:
                its = [i for i, _ in items(tfw, cards) if re.split(r"[#@]", i)[0] == pack]
                banks = bank_ids(tfw)
                start = banks.index(bank)
                for i, item in enumerate(its):
                    if start + i >= len(banks):
                        break
                    b = banks[start + i]
                    changed.append((tfw, b, load_item(tfw, cards, db, item, b, say)))
        elif job[0] == "load":
            _, item, bank = job
            changed.append((fw, bank, load_item(fw, cards, db, item, bank, say)))
        elif job[0] == "slot":
            _, rel, bank, slot = job
            kind = "tables" if fw == "wave" else "samples"
            f = os.path.join(lib_dir(cards), kind, rel)
            changed.append((fw, bank, set_slot(fw, cards, db, f, bank, int(slot), say)))
    save_json(os.path.join(lib_dir(cards), "banks.json"), db)
    with open(slots_out, "w") as f:
        for cfw, bank, slots in changed:
            f.write("%s\t%s\t%s\n" % (cfw, bank, " ".join(str(s) for s in slots)))
    msg = []
    if imported:
        msg.append("imported %d" % imported)
    banks_changed = len({(f, b) for f, b, _ in changed})
    if banks_changed:
        msg.append("changed %d bank%s" % (banks_changed, "" if banks_changed == 1 else "s"))
    if failed:
        msg.append("%d failed" % failed)
    say(", ".join(msg) or "nothing to do")
    return 1 if failed and not (imported or changed) else 0


def scan_fingerprints(source):
    if "::" in source:
        path, folder = source.split("::", 1)
        for name, src, files in scan_zip(path):
            if src == source:
                return files
        return []
    return [(f, fingerprint(f, os.path.getsize(os.path.join(source, f))))
            for f in os.listdir(source) if is_audio(f)]


def reset_presets(cards, slots_file):
    """Resets the presets of the slots listed, for each firmware's card."""
    by_fw = {}
    with open(slots_file) as f:
        for line in f:
            fw, bank, slots = (line.rstrip("\n").split("\t") + [""])[:3]
            by_fw.setdefault(fw, []).append((bank, [int(s) for s in slots.split()]))
    for fw, changed in by_fw.items():
        if fw == "wave":
            continue
        path = os.path.join(card(cards, fw), "presets.json")
        p = load_json(path, None)
        if p is None:
            continue
        for bank, slots in changed:
            if fw == "tape":
                mode, b = bank.split(":")
                rows = p[0][("jammi", "cubbi").index(mode)][TAPE_BANKS.index(b)]
                default = TAPE_PRESET
            else:
                rows = p[("chroma", "slice").index(bank)]
                default = TEMPO_PRESET
            # the old settings don't fit the new samples
            for s in slots:
                rows[s - 1] = list(default)
        tmp = path + ".part"
        with open(tmp, "w") as f:
            json.dump(p, f, separators=(",", ":"))
        os.replace(tmp, path)
    return 0


def main(argv):
    cmd = argv[1]
    if cmd == "scan":
        cards, roots = argv[2], argv[3:]
        known = known_prints(cards)
        for root in roots:
            if not os.path.isdir(root):
                continue
            for name, src, files in scan_root(root):
                where = {known.get(fp) for _, fp in files}
                inlib = where.pop() if len(where) == 1 and None not in where else "-"
                print("pack\t%s\t%s\t%d\t%s\t%s" % (name, src, len(files),
                                                    kind_of([f for f, _ in files]), inlib))
                for f, _ in files:
                    print("file\t%s" % f)
        return 0
    if cmd == "banks":
        fw, cards = argv[2], argv[3]
        fws = ["tape", "tempo", "wave"] if fw == "all" else [fw]
        db = banks_db(cards)
        if any([first_run(f, cards, db) for f in fws]):
            save_json(os.path.join(lib_dir(cards), "banks.json"), db)
        for f in fws:
            for bank in bank_ids(f):
                item = loaded(f, cards, db, bank)
                n = len(bank_state(f, cards, bank))
                print("bank\t%s\t%s\t%s\t%d\t%s" % (bank, bank_label(bank), item or "-", n, f))
                for slot, name in sorted(slot_names(f, cards, db, bank).items()):
                    print("slot\t%s\t%d\t%s" % (bank, slot, name))
        if fw == "all":
            return 0
        for item, label in items(fw, cards):
            print("item\t%s\t%s" % (item, label))
        for rel, label in lib_samples(fw, cards):
            print("sample\t%s\t%s" % (rel, label))
        return 0
    if cmd == "run":
        return run(*argv[2:7])
    if cmd == "presets":
        return reset_presets(argv[2], argv[3])
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
