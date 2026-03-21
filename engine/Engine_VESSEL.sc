// Engine_VESSEL.sc
// A deeply layered synthesis engine for VESSEL
// Drawing from: FM feedback, physical string modeling (Karplus-Strong),
// resonant filter stacks, and granular shimmer
// Every voice is a different timbral world
//
// v2.3 fixes:
//   - Internal FX bus so voices don't double-output
//   - LeakDC on all voices to prevent DC offset buildup
//   - Proper gain staging throughout
//   - vessel_perc uses fixed envelope (no gate needed for one-shot)

Engine_VESSEL : CroneEngine {

  var <synths;
  var <fxBus;  // internal stereo bus for routing voices -> FX

  *new { arg context, doneCallback;
    ^super.new(context, doneCallback);
  }

  alloc {
    var s = context.server;
    synths = Dictionary.new;

    // Allocate an internal stereo bus for voice -> FX routing
    fxBus = Bus.audio(s, 2);

    // -----------------------------------------------------------------------
    // HARMONIC VOICE — rich FM with feedback, Daft Punk warmth
    // -----------------------------------------------------------------------
    SynthDef(\vessel_harm, { arg out=0, freq=440, amp=0.5, gate=1,
      atk=0.01, dec=0.1, sus=0.7, rel=0.8,
      fb=0.3, ratio=2.0, idx=2.0,
      pan=0, cutoff=4000, rq=0.5, drive=0.3;

      var env, mod_env, feedback, mod, car, body, sig;

      env = EnvGen.kr(Env.adsr(atk, dec, sus, rel), gate, doneAction:2);
      mod_env = EnvGen.kr(Env.adsr(0.001, 0.05, 0.2, rel * 0.8), gate);

      // FM with feedback loop
      feedback = LocalIn.ar(1) * fb;
      mod = SinOsc.ar(freq * ratio + feedback) * freq * idx * mod_env;
      car = SinOsc.ar(freq + mod);
      LocalOut.ar(car * 0.4);

      // Second operator for body
      body = SinOsc.ar(freq * 0.5) * 0.3;
      sig = (car + body) * env * amp;

      // Warm resonant filter
      sig = RLPF.ar(sig, cutoff.clip(20, 18000).lag(0.05), rq.clip(0.1, 1));
      sig = (sig * (1 + drive)).tanh * 0.6; // soft saturation

      // Subtle stereo shimmer
      sig = sig + (DelayC.ar(sig, 0.02, SinOsc.kr(0.13) * 0.004 + 0.005) * 0.2);
      sig = LeakDC.ar(sig);
      sig = Pan2.ar(sig, pan);

      Out.ar(out, sig);
    }).add;

    // -----------------------------------------------------------------------
    // BASS VOICE — physical model string + sub oscillator
    // -----------------------------------------------------------------------
    SynthDef(\vessel_bass, { arg out=0, freq=80, amp=0.8, gate=1,
      atk=0.001, rel=1.2,
      brightness=0.5, damping=0.5,
      sub_mix=0.4, pan=0;

      var env, excite, string, sub, click, sig;

      env = EnvGen.kr(Env.asr(atk, 1, rel), gate, doneAction:2);

      // Karplus-Strong pluck
      excite = WhiteNoise.ar * EnvGen.kr(Env.perc(0.001, 0.01));
      string = CombL.ar(excite, 0.05, (1/freq).clip(0.0001, 0.05), damping * 8);
      string = LPF.ar(string, (freq * (2 + brightness * 6)).clip(20, 18000));

      // Sub oscillator (mono to avoid phase issues at low freq)
      sub = SinOsc.ar(freq) * sub_mix;

      // Punchy transient
      click = Impulse.ar(0) * 0.2 * EnvGen.kr(Env.perc(0.001, 0.08));

      sig = ((string * 0.6) + sub + click) * env * amp;
      sig = LeakDC.ar(sig);
      sig = Limiter.ar(sig, 0.9, 0.005);
      sig = Pan2.ar(sig, pan);

      Out.ar(out, sig);
    }).add;

    // -----------------------------------------------------------------------
    // TEXTURE VOICE — granular shimmer + filtered noise cloud
    // -----------------------------------------------------------------------
    SynthDef(\vessel_texture, { arg out=0, freq=220, amp=0.3, gate=1,
      atk=2.0, rel=3.0,
      density=15, spread=0.3, size=0.2,
      pan=0, cutoff=1200, rq=0.8;

      var env, freqs, grains, noise, sig;

      env = EnvGen.kr(Env.asr(atk, 1, rel), gate, doneAction:2);

      // Pitch-spread granular cloud
      freqs = freq * [1.0, 1.001, 0.999, 2.003, 0.5005];
      grains = Mix(SinOsc.ar(freqs) * LFNoise1.kr(density ! 5).range(0, 1));

      // Filtered noise shimmer layer
      noise = BPF.ar(PinkNoise.ar, (freq * 2).clip(20, 18000), 0.1) * 0.2;

      sig = (grains * 0.5 + noise) * env * amp;
      sig = RLPF.ar(sig, cutoff.clip(20, 18000).lag(0.3), rq.clip(0.1, 1));
      sig = LeakDC.ar(sig);

      // Slow stereo movement
      sig = Pan2.ar(sig, SinOsc.kr(0.07 + (freq * 0.00001)).range(spread.neg, spread));

      Out.ar(out, sig);
    }).add;

    // -----------------------------------------------------------------------
    // PERCUSSION VOICE — tuned noise sculpting (one-shot, no gate)
    // -----------------------------------------------------------------------
    SynthDef(\vessel_perc, { arg out=0, freq=200, amp=0.9,
      tone=0.5, body=0.3, click=0.6,
      decay=0.3, pitch_drop=0.8, pan=0;

      var pitch_env, body_osc, noise_env, noise_sig, click_sig, sig, done_env;

      // Master envelope for cleanup
      done_env = EnvGen.kr(Env.perc(0.001, decay * 3), doneAction:2);

      // Pitched body: exponential pitch drop
      pitch_env = EnvGen.kr(Env.perc(0.001, decay * 2)) * freq * pitch_drop + freq;
      body_osc = SinOsc.ar(pitch_env) * EnvGen.kr(Env.perc(0.001, decay * 1.5));

      // Noise transient with bandpass
      noise_env = EnvGen.kr(Env.perc(0.0005, (decay * tone).max(0.001)));
      noise_sig = BPF.ar(WhiteNoise.ar, (freq * 2).clip(20, 18000), 0.5) * noise_env;

      // Click transient
      click_sig = HPF.ar(WhiteNoise.ar, 3000) * EnvGen.kr(Env.perc(0.0001, 0.008)) * click;

      sig = (body_osc * body + noise_sig + click_sig) * amp;
      sig = (sig * 1.3).tanh; // saturation
      sig = LeakDC.ar(sig);
      sig = sig * done_env;
      sig = Pan2.ar(sig, pan);
      Out.ar(out, sig);
    }).add;

    // -----------------------------------------------------------------------
    // CHORD VOICE — lush 4-note voicer
    // -----------------------------------------------------------------------
    SynthDef(\vessel_chord, { arg out=0,
      freq1=261, freq2=329, freq3=392, freq4=440,
      amp=0.35, gate=1,
      atk=0.08, dec=0.2, sus=0.6, rel=1.5,
      detune=0.003, pan=0, cutoff=3000, rq=0.7;

      var env, v1, v2, v3, v4, harmonics, sig;

      env = EnvGen.kr(Env.adsr(atk, dec, sus, rel), gate, doneAction:2);

      // Each voice slightly detuned
      v1 = SinOsc.ar([freq1, freq1 * (1 + detune)]).sum * 0.5;
      v2 = SinOsc.ar([freq2, freq2 * (1 - detune * 0.7)]).sum * 0.5;
      v3 = SinOsc.ar([freq3, freq3 * (1 + detune * 0.5)]).sum * 0.5;
      v4 = SinOsc.ar([freq4, freq4 * (1 - detune * 0.3)]).sum * 0.5;

      // Subtle harmonics
      harmonics = (SinOsc.ar(freq1 * 2) + SinOsc.ar(freq1 * 3)) * 0.06;

      sig = (v1 + v2 + v3 + v4 + harmonics) * env * amp;
      sig = RLPF.ar(sig, cutoff.clip(20, 18000).lag(0.1), rq.clip(0.1, 1));
      sig = sig + (CombN.ar(sig, 0.25, 0.25, 1.5) * 0.1); // subtle hall
      sig = LeakDC.ar(sig);
      sig = Pan2.ar(sig, pan);

      Out.ar(out, sig);
    }).add;

    // -----------------------------------------------------------------------
    // GLOBAL EFFECTS BUS
    // Reads from internal fxBus, applies tape sat + reverb + limiter,
    // writes to context.out_b
    // -----------------------------------------------------------------------
    SynthDef(\vessel_fx, { arg in=0, out=0,
      room=0.3, damp=0.6, rev_mix=0.12,
      tape_sat=0.2, lp_freq=16000;

      var sig, wet;

      sig = In.ar(in, 2);

      // Tape warmth: soft saturation + gentle high-freq rolloff
      sig = (sig * (1 + tape_sat)).tanh * (1 / (1 + tape_sat * 0.5));
      sig = LPF.ar(sig, lp_freq);

      // Plate reverb (wet signal only)
      wet = FreeVerb2.ar(sig[0], sig[1], 1, room, damp) * rev_mix;
      sig = sig * (1 - rev_mix) + wet;

      // DC removal + transparent limiter
      sig = LeakDC.ar(sig);
      sig = Limiter.ar(sig, 0.95, 0.005);

      Out.ar(out, sig);
    }).add;

    context.server.sync;

    // FX bus: reads from internal bus, writes to output
    synths[\fx] = Synth.tail(context.xg, \vessel_fx, [
      \in,  fxBus,
      \out, context.out_b
    ]);

    // ── Commands ──
    // All voices write to fxBus (not directly to output)

    this.addCommand("harm_on", "iffffffffffff", { arg msg;
      var id = msg[1].asInteger;
      if(synths[\harm] != nil, { synths[\harm].set(\gate, 0) });
      synths[\harm] = Synth.before(synths[\fx], \vessel_harm, [
        \out, fxBus,
        \freq, msg[2], \amp, msg[3], \gate, 1,
        \atk, msg[4], \dec, msg[5], \sus, msg[6], \rel, msg[7],
        \fb, msg[8], \ratio, msg[9], \idx, msg[10],
        \pan, msg[11], \cutoff, msg[12]
      ]);
    });

    this.addCommand("harm_off", "i", { arg msg;
      if(synths[\harm] != nil, { synths[\harm].set(\gate, 0) });
    });

    this.addCommand("bass_on", "ifffff", { arg msg;
      var id = msg[1].asInteger;
      if(synths[\bass] != nil, { synths[\bass].set(\gate, 0) });
      synths[\bass] = Synth.before(synths[\fx], \vessel_bass, [
        \out, fxBus,
        \freq, msg[2], \amp, msg[3],
        \brightness, msg[4], \damping, msg[5],
        \sub_mix, msg[6]
      ]);
    });

    this.addCommand("bass_off", "i", { arg msg;
      if(synths[\bass] != nil, { synths[\bass].set(\gate, 0) });
    });

    this.addCommand("texture_on", "iffff", { arg msg;
      if(synths[\texture] != nil, { synths[\texture].set(\gate, 0) });
      synths[\texture] = Synth.before(synths[\fx], \vessel_texture, [
        \out, fxBus,
        \freq, msg[2], \amp, msg[3],
        \density, msg[4], \cutoff, msg[5],
        \gate, 1
      ]);
    });

    this.addCommand("texture_off", "i", { arg msg;
      if(synths[\texture] != nil, { synths[\texture].set(\gate, 0) });
    });

    this.addCommand("perc", "ifffff", { arg msg;
      Synth.before(synths[\fx], \vessel_perc, [
        \out, fxBus,
        \freq, msg[2], \amp, msg[3],
        \tone, msg[4], \body, msg[5],
        \decay, msg[6]
      ]);
    });

    this.addCommand("chord_on", "iffffffff", { arg msg;
      if(synths[\chord] != nil, { synths[\chord].set(\gate, 0) });
      synths[\chord] = Synth.before(synths[\fx], \vessel_chord, [
        \out, fxBus,
        \freq1, msg[2], \freq2, msg[3],
        \freq3, msg[4], \freq4, msg[5],
        \amp, msg[6], \atk, msg[7],
        \cutoff, msg[8], \gate, 1
      ]);
    });

    this.addCommand("chord_off", "i", { arg msg;
      if(synths[\chord] != nil, { synths[\chord].set(\gate, 0) });
    });

    this.addCommand("set_rev", "f", { arg msg;
      if(synths[\fx] != nil, { synths[\fx].set(\rev_mix, msg[1].clip(0, 1)) });
    });

    this.addCommand("set_tape", "f", { arg msg;
      if(synths[\fx] != nil, { synths[\fx].set(\tape_sat, msg[1].clip(0, 1)) });
    });

  }

  free {
    synths.do { |s| if(s != nil, { s.free }) };
    if(fxBus != nil, { fxBus.free });
  }

}
