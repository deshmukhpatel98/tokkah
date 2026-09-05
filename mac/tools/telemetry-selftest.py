#!/usr/bin/env python3
"""The reader's own calibration: every verdict rule in telemetry.py fired by an
input just over its line and left alone by one just under it, plus the two
answers that must never be confused -- "not in this build" and zero.

A reader that grades calls has to be graded itself, on known inputs, including
the ones it must reject (validate-the-ruler-against-known-inputs)."""
import io, os, sys, contextlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import telemetry as T

fail = 0
def say(ok, what):
    global fail
    print(f"  {'ok   ' if ok else 'FAIL '} {what}")
    if not ok: fail += 1

def beat(**kw):
    b = {"uptime_s": 120, "a_rx_voice_ms": 60000, "a_rx_conceal_voiced_ms": 0, "a_rx_glitches": 0,
         "a_rx_silence_ms": 0, "a_rx_clip_pct": 0.0, "a_rate_fast_ms": 0,
         "a_rx_level_db_p50": -24.0, "a_rx_level_swing_db": 2.0, "a_rx_bw_khz": 14.0,
         "a_tx_voice_ms": 50000, "a_tx_voice_muted_ms": 0, "a_tx_softlimit_pct": 0.0,
         "a_tx_level_db_p50": -20.0, "a_tx_noise_db": -60.0, "a_tx_snr_db": 40.0, "a_tx_bw_khz": 12.0,
         "a_echo_talk_s": 50, "a_echo_return_s": 0}
    b.update(kw)
    return [b]

def words(bs, direction):
    return T.verdict_words(T.lab_numbers(bs), direction)

def render(bs):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        T.lab_summary(bs)
    return buf.getvalue()

print("telemetry reader selftest")
# A clean call fires nothing.
say(words(beat(), "heard") == [] and words(beat(), "said") == [] and words(beat(), "return") == [],
    "clean call: no verdict word fires in any direction")
say("you heard them: clear" in render(beat()) and "they heard you: clear" in render(beat()),
    "clean call: VERDICT says clear for both directions")

# Each rule: one input over the line, one under. Both rows, or the rule is a guess.
rules = [
    ("heard", "a few patches", {"a_rx_conceal_voiced_ms": 1200}, {"a_rx_conceal_voiced_ms": 500}),
    ("heard", "patchy",        {"a_rx_conceal_voiced_ms": 2400}, {"a_rx_conceal_voiced_ms": 1500}),
    ("heard", "clicks",        {"a_rx_glitches": 7},             {"a_rx_glitches": 5}),      # 120 s -> 3.5 vs 2.5 /min
    ("heard", "pumping",       {"a_rx_level_swing_db": 7.0},     {"a_rx_level_swing_db": 6.0}),
    ("heard", "telephone-grade", {"a_rx_bw_khz": 4.0},           {"a_rx_bw_khz": 5.5}),
    ("heard", "distorted",     {"a_rx_clip_pct": 0.2},           {"a_rx_clip_pct": 0.05}),
    ("heard", "dead air",      {"a_rx_silence_ms": 1500},        {"a_rx_silence_ms": 400}),
    ("heard", "sped up",       {"a_rate_fast_ms": 2500},         {"a_rate_fast_ms": 1500}),
    ("said",  "words lost to the floor", {"a_tx_voice_muted_ms": 800}, {"a_tx_voice_muted_ms": 300}),
    ("said",  "went out distorted", {"a_tx_softlimit_pct": 0.7}, {"a_tx_softlimit_pct": 0.3}),
    ("said",  "noisy mic",     {"a_tx_snr_db": 15.0},            {"a_tx_snr_db": 25.0}),
    ("said",  "telephone-grade mic", {"a_tx_bw_khz": 4.0},       {"a_tx_bw_khz": 9.0}),
    ("return","heard yourself", {"a_echo_return_s": 5},          {"a_echo_return_s": 1}),   # 10% vs 2% of 50 s
]
for direction, word, over, under in rules:
    say(word in words(beat(**over), direction), f"{direction}: '{word}' fires on {over}")
    say(word not in words(beat(**under), direction), f"{direction}: '{word}' stays quiet on {under} -- REJECT row")

# The words carry their numbers.
out = render(beat(a_tx_voice_muted_ms=2300, a_rx_silence_ms=3100))
say("2.3 s of words lost to the floor" in out, "VERDICT names the seconds of words lost")
say("dead air 3 s" in out, "VERDICT names the dead air")
out = render(beat(a_echo_return_s=10, a_echo_return_db=-18.0, a_echo_return_lag_ms=640.0))
say("heard yourself 20% of your talking" in out and "-18.0 dB" in out and "640 ms later" in out,
    "RETURN names share, level and lag")

# Absent is not zero: a build before the fields.
old = [{"uptime_s": 120, "conceal_total": 0, "played": 100}]
out = render(old)
say("HEARD     not in this build" in out and "SAID      not in this build" in out and "RETURN    not in this build" in out,
    "a pre-lab build reads 'not in this build', never a verdict")
say(T.heard_clean_pct(old) is None, "heard_clean_pct is None (not 100) for a pre-lab build -- REJECT row")
say(abs(T.heard_clean_pct(beat(a_rx_conceal_voiced_ms=3000)) - 95.0) < 1e-9, "heard_clean_pct: 3 s patched of 60 s voice = 95%")

# The server's truncation is shouted, never absorbed.
out = render(beat(fields_dropped=4))
say("SERVER TRUNCATED THIS RECORD: 4 field(s) dropped" in out, "fields_dropped prints the capital-letter warning")
say("SERVER TRUNCATED" not in render(beat()), "no warning without fields_dropped -- REJECT row")

# Devices from facts.
out = render([dict(beat()[0], facts={"in_dev": "MacBook Air Microphone", "in_transport": "builtin", "in_rate_hw": "48000",
                                     "in_ch": "1", "out_dev": "EarPods", "out_transport": "usb", "out_rate_hw": "48000",
                                     "out_ch": "2", "bt_hfp": "no", "mic_mode": "standard", "output_route": "headphones"})])
say('in "MacBook Air Microphone" builtin 48000/1ch' in out and 'out "EarPods" usb 48000/2ch' in out and "phone-mode no" in out,
    "DEVICES line reads the facts")
say("DEVICES   not in this build" in render(beat()), "DEVICES says 'not in this build' without device facts -- REJECT row")

print(f"telemetry reader selftest: {'PASS' if fail == 0 else f'FAIL ({fail})'}")
sys.exit(1 if fail else 0)
