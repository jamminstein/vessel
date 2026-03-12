// Engine_VESSEL.sc
// A deeply layered synthesis engine for VESSEL
// Drawing from: FM feedback, physical string modeling (Karplus-Strong),
// resonant filter stacks, and granular shimmer
// Every voice is a different timbral world

Engine_VESSEL : CroneEngine {

  var <synths;
  var <voices;
  var numVoices = 6;

  *new { arg context, doneCallback;
    ^super.new(context, doneCallback);
  }

  alloc {
    var s = context.server;
    synths = Dictionary.new;

    // -----------------------------------------------------------------------
    // HARMONIC VOICE — rich FM with feedback, Daft Punk warmth
    // Operator ratio + feedback index control timbre from bell to brass
    // -----------------------------------------------------------------------
    SynthDef(\vessel_harm, { arg out=0, freq=440, amp=0.5, gate=1,
      atk=0.01, dec=0.1, sus=0.7, rel=0.8,
      fb=0.3, ratio=2.0, idx=2.0,
      pan=0, cutoff=4000, rq=0.5, drive=0.3;

      var env = EnvGen.kr(Env.adsr(atk, dec, sus, rel), gate, doneAction:2);
      var mod_env = EnvGen.kr(Env.adsr(0.001, 0.3, 0.2, rel * 0.8), gate);

      // FM with feedback loop
      var feedback = LocalIn.ar(1) * fb;
      var mod = SinOsc.ar(freq * ratio + feedback) * freq * idx * mod_env;
      var car = SinOsc.ar(freq + mod);
      LocalOut.ar(car * 0.5);

      // Second operator for body
      var body = SinOsc.ar(freq * 0.5) * 0.4;
      var sig = (car + body) * env * amp;

      // Warm resonant filter with character
      sig = RLPF.ar(sig, cutoff.lag(0.05), rq);
      sig = (sig * (1 + drive)).tanh * 0.7; // soft saturation

      // Subtle stereo shimmer
      sig = sig + (DelayC.ar(sig, 0.02, SinOsc.kr(0.13) * 0.005 + 0.005) * 0.3);
      sig = Pan2.ar(sig, pan);

      Out.ar(out, sig);
    }).add;

    // -----------------------------------------------------------------------
    // BASS VOICE — physical model string + sub oscillator
    // Karplus-Strong decay with tunable pluck character
    // Inspired by Frusciante's Maya low end
    // -----------------------------------------------------------------------
    SynthDef(\vessel_bass, { arg out=0, freq=80, amp=0.8, gate=1,
      atk=0.001, rel=1.2,
      brightness=0.5, damping=0.5,
      sub_mix=0.4, pan=0;

      var env = EnvGen.kr(Env.asr(atk, 1, rel), gate, doneAction:2);

      // Karplus-Strong pluck
      var excite = WhiteNoise.ar * EnvGen.kr(Env.perc(0.001, 0.01));
      var string = CombL.ar(excite, 1/freq, 1/freq, damping * 8);
      string = LPF.ar(string, freq * (2 + brightness * 6));

      // Sub oscillator with slight detuning for warmth
      var sub = SinOsc.ar([freq, freq * 1.002]) * sub_mix;

      // Punchy transient
      var click = Impulse.ar(0) * 0.3 * EnvGen.kr(Env.perc(0.001, 0.08));

      var sig = ((string * 0.7) + sub + click) * env * amp;
      sig = CompanderD.ar(sig, sig, 0.3, 1, 0.3, 0.001, 0.1);
      sig = Pan2.ar(sig.sum, pan);

      Out.ar(out, sig);
    }).add;

    // -----------------------------------------------------------------------
    // TEXTURE VOICE — granular shimmer + filtered noise cloud
    // Aphex ambient territory, used for sustained pads
    // -----------------------------------------------------------------------
    SynthDef(\vessel_texture, { arg out=0, freq=220, amp=0.3, gate=1,
      atk=2.0, rel=3.0,
      density=15, spread=0.3, size=0.2,
      pan=0, cutoff=1200, rq=0.8;

      var env = EnvGen.kr(Env.asr(atk, 1, rel), gate, doneAction:2);

      // Pitch-spread granular cloud
      var freqs = freq * [1.0, 1.001, 0.999, 2.003, 0.5005];
      var grains = Mix(SinOsc.ar(freqs) * LFNoise1.kr(density ! 5).range(0, 1));

      // Filtered noise shimmer layer
      var noise = BPF.ar(PinkNoise.ar, freq * 2, 0.1) * 0.3;

      var sig = (grains * 0.6 + noise) * env * amp;
      sig = RLPF.ar(sig, cutoff.lag(0.3), rq);

      // Slow stereo movement (Bossa Nova breathiness)
      var stereo = Pan2.ar(sig, SinOsc.kr(0.07 + (freq * 0.00001)).range(-spread, spread));

      Out.ar(out, stereo);
    }).add;

    // -----------------------------------------------------------------------
    // PERCUSSION VOICE — tuned noise sculpting
    // Aphex Twin-style drum synthesis: resonant filter + click + decay
    // All drums are pitched. Nothing is a "standard" drum.
    // -----------------------------------------------------------------------
    SynthDef(\vessel_perc, { arg out=0, freq=200, amp=0.9, gate=1,
      tone=0.5, body=0.3, click=0.6,
      decay=0.3, pitch_drop=0.8, pan=0;

      // Pitched body: exponential pitch drop
      var pitch_env = EnvGen.kr(Env.perc(0.001, decay * 2)) * freq * pitch_drop + freq;
      var body_osc = SinOsc.ar(pitch_env) * EnvGen.kr(Env.perc(0.001, decay * 1.5));

      // Noise transient with bandpass
      var noise_env = EnvGen.kr(Env.perc(0.0005, decay * tone));
      var noise_sig = BPF.ar(WhiteNoise.ar, freq * 2, 0.5) * noise_env;

      // Click transient
      var click_sig = HPF.ar(WhiteNoise.ar, 3000) * EnvGen.kr(Env.perc(0.0001, 0.008)) * click;

      var sig = (body_osc * body + noise_sig + click_sig) * amp;
      sig = (sig * 1.5).tanh; // saturation for character
      DetectSilence.ar(sig, doneAction:2);
      sig = Pan2.ar(sig, pan);
      Out.ar(out, sig);
    }).add;

    // -----------------------------------------------------------------------
    // CHORD VOICE — lush maj9/min9/sus4 voicer
    // Daft Punk + Bossa Nova harmonic territory
    // Plays 4-note chord with individual voice detuning
    // -----------------------------------------------------------------------
    SynthDef(\vessel_chord, { arg out=0,
      freq1=261, freq2=329, freq3=392, freq4=440,
      amp=0.35, gate=1,
      atk=0.08, dec=0.2, sus=0.6, rel=1.5,
      detune=0.003, pan=0, cutoff=3000, rq=0.7;

      var env = EnvGen.kr(Env.adsr(atk, dec, sus, rel), gate, doneAction:2);

      // Each voice slightly detuned — creates natural beating/warmth
      var v1 = SinOsc.ar([freq1, freq1 * (1 + detune)]).sum * 0.5;
      var v2 = SinOsc.ar([freq2, freq2 * (1 - detune * 0.7)]).sum * 0.5;
      var v3 = SinOsc.ar([freq3, freq3 * (1 + detune * 0.5)]).sum * 0.5;
      var v4 = SinOsc.ar([freq4, freq4 * (1 - detune * 0.3)]).sum * 0.5;

      // Add subtle harmonics (2nd + 3rd partial)
      var harmonics = (SinOsc.ar(freq1 * 2) + SinOsc.ar(freq1 * 3)) * 0.08;

      var sig = (v1 + v2 + v3 + v4 + harmonics) * env * amp;
      sig = RLPF.ar(sig, cutoff.lag(0.1), rq);
      sig = sig + (CombN.ar(sig, 0.25, 0.25, 2) * 0.15); // subtle hall
      sig = Pan2.ar(sig, pan);

      Out.ar(out, sig);
    }).add;

    // -----------------------------------------------------------------------
    // GLOBAL EFFECTS BUS
    // Tape saturation + subtle reverb + master limiter
    // -----------------------------------------------------------------------
    SynthDef(\vessel_fx, { arg in=0, out=0,
      room=0.3, damp=0.6, rev_mix=0.12,
      tape_sat=0.2, lp_freq=16000;

      var sig = In.ar(in, 2);

      // Tape warmth: soft saturation + gentle high-freq rolloff
      sig = (sig * (1 + tape_sat)).tanh * (1 / (1 + tape_sat * 0.5));
      sig = LPF.ar(sig, lp_freq);

      // Plate reverb
      var rev = FreeVerb2.ar(sig[0], sig[1], rev_mix, room, damp);
      sig = sig + rev;

      // Transparent limiter
      sig = Limiter.ar(sig, 0.95, 0.001);

      Out.ar(out, sig);
    }).add;

    context.server.sync;

    // FX bus: reads from the norns internal bus, writes to output
    // Uses context.out_b for stereo output (standard Norns CroneEngine pattern)
    synths[\fx] = Synth.tail(context.xg, \vessel_fx, [
      \in,  context.in_b,
      \out, context.out_b
    ]);

    this.addCommand("harm_on", "iffffffffffff", { arg msg;
      var id = msg[1].asInteger;
      if(synths[\harm] != nil, { synths[\harm].free });
      synths[\harm] = Synth.head(context.xg, \vessel_harm, [
        \out, context.out_b,
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
      if(synths[\bass] != nil, { synths[\bass].free });
      synths[\bass] = Synth.head(context.xg, \vessel_bass, [
        \out, context.out_b,
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
      synths[\texture] = Synth.head(context.xg, \vessel_texture, [
        \out, context.out_b,
        \freq, msg[2], \amp, msg[3],
        \density, msg[4], \cutoff, msg[5]
      ]);
    });

    this.addCommand("texture_off", "i", { arg msg;
      if(synths[\texture] != nil, { synths[\texture].set(\gate, 0) });
    });

    this.addCommand("perc", "ifffff", { arg msg;
      Synth.head(context.xg, \vessel_perc, [
        \out, context.out_b,
        \freq, msg[2], \amp, msg[3],
        \tone, msg[4], \body, msg[5],
        \decay, msg[6]
      ]);
    });

    this.addCommand("chord_on", "iffffffff", { arg msg;
      if(synths[\chord] != nil, { synths[\chord].set(\gate, 0) });
      synths[\chord] = Synth.head(context.xg, \vessel_chord, [
        \out, context.out_b,
        \freq1, msg[2], \freq2, msg[3],
        \freq3, msg[4], \freq4, msg[5],
        \amp, msg[6], \atk, msg[7],
        \cutoff, msg[8]
      ]);
    });

    this.addCommand("chord_off", "i", { arg msg;
      if(synths[\chord] != nil, { synths[\chord].set(\gate, 0) });
    });

    this.addCommand("set_rev", "f", { arg msg;
      if(synths[\fx] != nil, { synths[\fx].set(\rev_mix, msg[1]) });
    });

    this.addCommand("set_tape", "f", { arg msg;
      if(synths[\fx] != nil, { synths[\fx].set(\tape_sat, msg[1]) });
    });

  }

  free {
    synths.do { |s| if(s != nil, { s.free }) };
  }

}
