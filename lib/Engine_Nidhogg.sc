// Runs one Chompi firmware at a time between the norns inputs and outputs.
// Command: start s:firmware ("tape"). The card folder is
// ~/dust/audio/nidhogg/<firmware>.
Engine_Nidhogg : CroneEngine {
    var synth;

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    alloc {
        SynthDef(\nidhogg_tape, { arg in_l, in_r, out;
            Out.ar(out, NidhoggTape.ar(In.ar(in_l), In.ar(in_r)));
        }).add;

        this.addCommand("start", "s", { arg msg;
            this.startFirmware(msg[1].asString);
        });
    }

    startFirmware { arg fw;
        var card = Platform.userHomeDir ++ "/dust/audio/nidhogg/" ++ fw;
        var ugen = "Nidhogg" ++ fw[0].toUpper ++ fw.copyToEnd(1);
        synth !? { synth.free; synth = nil };
        context.server.sendMsg(\cmd, ugen ++ "Start", card);
        synth = Synth(("nidhogg_" ++ fw).asSymbol, [
            \in_l, context.in_b[0].index,
            \in_r, context.in_b[1].index,
            \out, context.out_b.index
        ], context.xg);
    }

    free {
        synth !? { synth.free };
    }
}
