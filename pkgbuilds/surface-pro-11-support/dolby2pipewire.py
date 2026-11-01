#!/usr/bin/env python3
"""Turn the Windows Dolby DAX3 speaker tuning of a Surface Pro 11 into a
PipeWire filter-chain sink.

The Windows audio stack on the Surface Pro 11 runs a Dolby Atmos effects
chain in front of the Qualcomm ADSP. Its per-device tuning XML lives on the
Windows partition under
Windows/System32/DriverStore/FileRepository/dax3_ext_qc.inf_arm64_*/
AUCD_DEV_0C29_SUBSYS_<hwid>_REV_<rev>_ADCM_SUBSYS_<hwid>.xml and holds, for the
default "music" profile, what makes Windows loud and keeps the speakers safe:

- a 20-band per-channel speaker correction EQ (audio-optimizer-bands),
- a volume maximizer (volmax-boost),
- the "regulator": a 20-band limiter with per-band ceilings. The bass bands are
  held well below full scale, the rest may reach 0 dBFS.

This script rebuilds that as: param_eq per channel -> linear gain ->
LSP crossover -> one LSP limiter per band at the regulator's ceiling ->
mixer -> output limiter -> speakers (lsp-plugins-lv2). All Dolby values are in 1/16 dB.
"""
import argparse
import math
import sys
import xml.etree.ElementTree as ET

LSP_CROSSOVER = "http://lsp-plug.in/plugins/lv2/crossover_stereo"
LSP_LIMITER = "http://lsp-plug.in/plugins/lv2/limiter_stereo"


def db(v16):
    return v16 / 16.0


def lin(db_value):
    return 10 ** (db_value / 20.0)


def vals(el):
    """A tuning element: a 'value' list or a preset name from <constant>."""
    if el.get("value") is not None:
        return [int(x) for x in el.get("value").split(",")]
    return None


def resolve(el, constants):
    v = vals(el)
    if v is not None:
        return v
    preset = el.get("preset")
    c = constants.find(preset)
    return [int(x) for x in c.get("target").split(",")]


def parse(path, profile_name):
    root = ET.parse(path).getroot()
    constants = root.find("constant")
    fs48 = constants.find("band_20_freq").get("fs_48000")
    centers = [int(x) for x in fs48.split(",")]
    ep = root.find("endpoint[@type='internal_speaker']")
    prof = ep.find(f"profile[@type='{profile_name}']")
    cp = prof.find("tuning-cp")
    vl = prof.find("tuning-vlldp")

    def one(parent, tag):
        return int(parent.find(tag).get("value"))

    opt_enable = one(vl, "audio-optimizer-enable")
    bands = vl.find("audio-optimizer-bands")
    eq = [resolve(bands.find("ch_00"), constants), resolve(bands.find("ch_01"), constants)]
    reg = vl.find("regulator-tuning")
    hi = resolve(reg.find("threshold_high"), constants)
    lo = resolve(reg.find("threshold_low"), constants)
    iso = resolve(reg.find("isolated_band"), constants)
    return {
        "source": path,
        "profile": profile_name,
        "tuning_version": root.find("tuning_version").get("value"),
        "hwid": root.find("setting/security-key").get("value").split("=")[0],
        "centers": centers,
        "eq_enable": opt_enable,
        "eq_db": [[db(v) for v in ch] for ch in eq],
        "thr_high_db": [db(v) for v in hi],
        "thr_low_db": [db(v) for v in lo],
        "isolated": iso,
        "regulator_enable": one(cp, "regulator-enable") and one(vl, "regulator-speaker-dist-enable"),
        "volmax_db": db(one(cp, "volmax-boost")),
        "peak_level_db": db(one(vl, "peak-level")),
        "system_gain_db": db(one(cp, "system-gain")) + db(one(vl, "system-gain")),
        "postgain_db": db(one(cp, "postgain")) + db(one(vl, "postgain")),
        "leveler": (one(cp, "volume-leveler-enable"), one(cp, "volume-leveler-amount")),
    }


def band_edges(centers):
    """Geometric midpoints between neighbouring band centres."""
    return [math.sqrt(a * b) for a, b in zip(centers, centers[1:])]


RATE = 48000


def biquad(typ, f0, gain_db, q, fs=RATE):
    """RBJ cookbook coefficients, as PipeWire's builtin biquads compute them."""
    A = 10 ** (gain_db / 40.0)
    w0 = 2 * math.pi * f0 / fs
    c, s_ = math.cos(w0), math.sin(w0)
    if typ == "bq_peaking":
        al = s_ / (2 * q)
        return (1 + al * A, -2 * c, 1 - al * A), (1 + al / A, -2 * c, 1 - al / A)
    al = s_ / 2 * math.sqrt((A + 1 / A) * (1 / q - 1) + 2)
    sa = 2 * math.sqrt(A) * al
    if typ == "bq_lowshelf":
        b = (A * ((A + 1) - (A - 1) * c + sa), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - sa))
        a = ((A + 1) + (A - 1) * c + sa, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - sa)
        return b, a
    b = (A * ((A + 1) + (A - 1) * c + sa), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - sa))
    a = ((A + 1) - (A - 1) * c + sa, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - sa)
    return b, a


def response_db(filters, f, fs=RATE):
    z = complex(math.cos(2 * math.pi * f / fs), -math.sin(2 * math.pi * f / fs))
    h = 1
    for typ, f0, g, q in filters:
        b, a = biquad(typ, f0, g, q, fs)
        h *= (b[0] + b[1] * z + b[2] * z * z) / (a[0] + a[1] * z + a[2] * z * z)
    return 20 * math.log10(abs(h))


def eq_filters(centers, gains_db):
    """One biquad per Dolby band: a low shelf, 18 peaking filters whose
    -3 dB points sit on the band edges, and a high shelf. Neighbouring
    filters overlap, so the gains are fitted until the cascade's response
    at every band centre matches the Dolby target."""
    edges = band_edges(centers)
    shape = []
    for i, f0 in enumerate(centers):
        if i == 0:
            shape.append(("bq_lowshelf", edges[0], 0.707))
        elif i == len(centers) - 1:
            shape.append(("bq_highshelf", edges[-1], 0.707))
        else:
            shape.append(("bq_peaking", f0, round(f0 / (edges[i] - edges[i - 1]), 2)))
    g = list(gains_db)
    for _ in range(40):
        filters = [(t, f, gi, q) for (t, f, q), gi in zip(shape, g)]
        err = [tgt - response_db(filters, fc) for tgt, fc in zip(gains_db, centers)]
        if max(abs(e) for e in err) < 0.02:
            break
        g = [gi + 0.7 * e for gi, e in zip(g, err)]
    return [(t, f, round(gi, 2), q) for (t, f, q), gi in zip(shape, g)]


def limiter_bands(t, ceiling_db, merge_db):
    """Collapse the 20 Dolby bands onto a few limiter bands: the isolated
    (bass) Dolby bands, with neighbours whose ceilings lie within merge_db
    of each other merged (a merged band takes the lower ceiling), and the
    remainder as one full-range band. Wider bands leak less of a tone into
    their neighbours, where it would escape the ceiling."""
    iso_idx = [i for i, x in enumerate(t["isolated"]) if x]
    edges = band_edges(t["centers"])
    groups = []  # lists of Dolby band indices
    for i in iso_idx:
        if groups and i == groups[-1][-1] + 1 and \
           abs(t["thr_high_db"][i] - min(t["thr_high_db"][j] for j in groups[-1])) <= merge_db:
            groups[-1].append(i)
        else:
            groups.append([i])
    groups = groups[:7]
    splits = [edges[g[-1]] for g in groups]
    bands = []
    for g in groups:
        bands.append((min(min(t["thr_high_db"][j] for j in g), ceiling_db),
                      min(t["thr_low_db"][j] for j in g),
                      [t["centers"][j] for j in g]))
    rest = range(groups[-1][-1] + 1, len(t["centers"])) if groups else range(len(t["centers"]))
    bands.append((min([t["thr_high_db"][j] for j in rest] + [ceiling_db]),
                  min(t["thr_low_db"][j] for j in rest), None))
    return splits, bands


def render(t, args):
    ceiling_db = t["peak_level_db"] - args.margin
    gain_db = t["volmax_db"] + t["system_gain_db"] + t["postgain_db"] - args.gain_trim
    splits, bands = limiter_bands(t, ceiling_db, args.merge_db)
    L = []
    w = L.append
    w("# Surface Pro 11 speakers: the Windows speaker tuning as a PipeWire filter chain.")
    w("#")
    w(f"# Generated by dolby2pipewire.py from the Dolby DAX3 tuning for {t['hwid']}")
    w(f"# (tuning version {t['tuning_version']}, profile \"{t['profile']}\").")
    w("# Chain: speaker EQ -> gain -> crossover -> a limiter per band -> mix -> output limiter.")
    w("#")
    w("# The limiter is the speaker protection. Its bass ceilings come from the")
    w("# Windows regulator; everything above the bass bands may reach")
    w(f"# {ceiling_db:+.1f} dBFS. The gain in front of it ({gain_db:+.1f} dB) is the Windows volume")
    w("# maximizer. Lowering the gain is always safe; raising a ceiling is not.")
    if not args.module_args:
        w("context.modules = [")
        w("  {")
        w("    name = libpipewire-module-filter-chain")
        w("    # A broken chain must not take PipeWire down with it.")
        w("    flags = [ nofail ]")
    w("    args = {")
    w('      node.description = "Internal speakers"')
    w('      media.name = "Internal speakers"')
    w("      audio.rate = 48000")
    w("      audio.channels = 2")
    w("      audio.position = [ FL FR ]")
    w("      filter.graph = {")
    w("        nodes = [")
    w("          {")
    w("            type = builtin  name = eq  label = param_eq")
    w("            config = {")
    for ch in (0, 1):
        w(f"              filters{ch + 1} = [")
        for typ, f, g, q in eq_filters(t["centers"], t["eq_db"][ch]):
            w(f"                {{ type = {typ} freq = {f:.0f} gain = {g} q = {q} }}")
        w("              ]")
    w("            }")
    w("          }")
    for name in ["gain_l", "gain_r"]:
        w(f"          {{ type = builtin  name = {name}  label = linear")
        w(f"            control = {{ Mult = {lin(gain_db):.4f} Add = 0.0 }} }}")
    # Crossover: Linkwitz-Riley 96 dB/oct (the bands are only half an octave
    # wide, so gentler slopes leak a band's energy into its neighbours and
    # defeat their ceilings), classic (IIR) mode so the bands sum back flat
    # without added latency.
    w("          {")
    w(f"            type = lv2  name = xover  plugin = \"{LSP_CROSSOVER}\"")
    w("            control = {")
    w("              enabled = 1  mode = 0")
    for i in range(7):
        if i < len(splits):
            w(f"              sf_{i+1} = {splits[i]:.0f}  frs_{i+1} = 5")
        else:
            w(f"              frs_{i+1} = 0")
    w("            }")
    w("          }")
    # One brickwall limiter per band. Same lookahead everywhere so the bands
    # stay time-aligned; a longer release below 300 Hz so the gain does not
    # pump within a bass cycle.
    for i, (hi, lo, centers) in enumerate(bands):
        what = (" and ".join(f"{c} Hz" for c in centers) + " bands") if centers else "everything above"
        rt = 20.0 if (centers and centers[0] < 300) else 5.0
        w(f"          # Band {i+1}, {what}: ceiling {hi:+.1f} dB (Windows softens from {lo:+.1f} dB).")
        w(f"          {{ type = lv2  name = lim{i+1}  plugin = \"{LSP_LIMITER}\"")
        w(f"            control = {{ enabled = 1  ovs = 0  boost = 0  alr = 0  knee = 1.0"
          f"  th = {lin(hi):.4f}  lk = 10.0  at = 5.0  rt = {rt} }} }}")
    for name in ["mix_l", "mix_r"]:
        gains = "  ".join(f'"Gain {i+1}" = 1.0' for i in range(len(bands)))
        w(f"          {{ type = builtin  name = {name}  label = mixer  control = {{ {gains} }} }}")
    w(f"          # Output limiter at {ceiling_db:+.1f} dBFS for the summed bands.")
    w(f"          {{ type = lv2  name = limout  plugin = \"{LSP_LIMITER}\"")
    w(f"            control = {{ enabled = 1  ovs = 0  boost = 0  alr = 0  knee = 1.0"
      f"  th = {lin(ceiling_db):.4f}  lk = 5.0  at = 5.0  rt = 5.0 }} }}")
    w("        ]")
    w("        links = [")
    w('          { output = "eq:Out 1" input = "gain_l:In" }')
    w('          { output = "eq:Out 2" input = "gain_r:In" }')
    w('          { output = "gain_l:Out" input = "xover:in_l" }')
    w('          { output = "gain_r:Out" input = "xover:in_r" }')
    for i in range(len(bands)):
        w(f'          {{ output = "xover:band{i}l" input = "lim{i+1}:in_l" }}')
        w(f'          {{ output = "xover:band{i}r" input = "lim{i+1}:in_r" }}')
        w(f'          {{ output = "lim{i+1}:out_l" input = "mix_l:In {i+1}" }}')
        w(f'          {{ output = "lim{i+1}:out_r" input = "mix_r:In {i+1}" }}')
    w('          { output = "mix_l:Out" input = "limout:in_l" }')
    w('          { output = "mix_r:Out" input = "limout:in_r" }')
    w("        ]")
    w('        inputs = [ "eq:In 1" "eq:In 2" ]')
    w('        outputs = [ "limout:out_l" "limout:out_r" ]')
    w("      }")
    w("      capture.props = {")
    w('        node.name = "surface_pro_11_speakers"')
    w("        media.class = Audio/Sink")
    w("        priority.session = 1001")
    w("        priority.driver = 1001")
    w('        device.icon-name = "audio-speakers"')
    w("      }")
    w("      playback.props = {")
    w('        node.name = "surface_pro_11_speakers.output"')
    w("        # Internal, like the hidden speaker sink it feeds, so sound")
    w("        # settings list neither; only the chain's sink is shown.")
    w('        media.class = "Stream/Output/Audio/Internal"')
    w('        target.object = "alsa_output.platform-sound.HiFi__Speaker__sink"')
    w("        node.passive = true")
    w("        # Wait for the speaker sink; never fall back to the default sink,")
    w("        # which is this chain itself. At boot the sink appears seconds")
    w("        # after this chain (the sound card probes late); without linger")
    w("        # WirePlumber destroys the chain when the target is missing.")
    w("        node.dont-fallback = true")
    w("        node.linger = true")
    w("        stream.dont-remix = true")
    w("      }")
    w("    }")
    if not args.module_args:
        w("  }")
        w("]")
    return "\n".join(L) + "\n"


def summary(t):
    s = [f"source: {t['source']}", f"hwid: {t['hwid']}  tuning version {t['tuning_version']}  profile {t['profile']}",
         f"EQ enabled: {t['eq_enable']}  regulator: {t['regulator_enable']}  volmax {t['volmax_db']:+.1f} dB"
         f"  peak {t['peak_level_db']:+.1f} dB  leveler (enable, amount) {t['leveler']}",
         f"{'Hz':>6} {'L dB':>6} {'R dB':>6} {'ceil':>6} {'soft':>6} iso"]
    for i, f in enumerate(t["centers"]):
        s.append(f"{f:>6} {t['eq_db'][0][i]:>6.1f} {t['eq_db'][1][i]:>6.1f} {t['thr_high_db'][i]:>6.1f} {t['thr_low_db'][i]:>6.1f} {t['isolated'][i]}")
    return "\n".join(s)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("xml")
    ap.add_argument("-o", "--output", help="write the PipeWire conf here (default: stdout)")
    ap.add_argument("--profile", default="music", help="Dolby profile (Windows default for speakers: music)")
    ap.add_argument("--margin", type=float, default=0.5, help="dB below the Windows peak level for every ceiling")
    ap.add_argument("--gain-trim", type=float, default=0.0, help="dB taken off the Windows maximizer gain")
    ap.add_argument("--merge-db", type=float, default=1.0,
                    help="merge neighbouring bass bands whose ceilings differ by at most this much")
    ap.add_argument("--summary", action="store_true", help="print the parsed tuning to stderr")
    ap.add_argument("--module-args", action="store_true",
                    help="emit only the module args block, for pw-cli load-module")
    a = ap.parse_args()
    t = parse(a.xml, a.profile)
    if a.summary:
        print(summary(t), file=sys.stderr)
    conf = render(t, a)
    if a.output:
        open(a.output, "w").write(conf)
    else:
        sys.stdout.write(conf)


if __name__ == "__main__":
    main()
