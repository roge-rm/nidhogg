// UGens for the Chompi firmwares, one per firmware. Each runs its firmware
// once the matching /cmd Nidhogg<Fw>Start has been sent (Engine_Nidhogg does
// this). Inputs: left and right audio in. Outputs: Chompi's headphone out, L and R.

NidhoggTape : MultiOutUGen {
    *ar { arg inL, inR;
        ^this.multiNew('audio', inL, inR)
    }
    init { arg ... theInputs;
        inputs = theInputs;
        ^this.initOutputs(2, rate)
    }
}
