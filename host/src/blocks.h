// Runs the firmware in its own 24-frame blocks under a host that calls with
// any number of frames. Output lags input by one block (0.5 ms).
//
// The firmware sees the host's left input as its mic and both inputs as its
// line in; the host gets Chompi's line out back.
#pragma once
#include "bridge.h"
#include "vhw.h"

#include <time.h>

#include <cstddef>

class Blocks
{
  public:
    Blocks() { reset(); }

    void reset()
    {
        in_fill_  = 0;
        out_read_ = 0;
        out_fill_ = kBlock; // primed with one block of silence
        for(size_t k = 0; k < kFifo; k++)
            out_[0][k] = out_[1][k] = 0.f;
    }

    void process(const float* inl, const float* inr, float* outl, float* outr, size_t n)
    {
        for(size_t i = 0; i < n; i++)
        {
            in_[0][in_fill_] = inl ? inl[i] : 0.f;
            in_[1][in_fill_] = inr ? inr[i] : 0.f;
            if(++in_fill_ == kBlock)
            {
                run_block();
                in_fill_ = 0;
            }
        }
        for(size_t i = 0; i < n; i++)
        {
            if(out_fill_ > 0)
            {
                outl[i]   = out_[0][out_read_];
                outr[i]   = out_[1][out_read_];
                out_read_ = (out_read_ + 1) & (kFifo - 1);
                out_fill_--;
            }
            else
                outl[i] = outr[i] = 0.f;
        }
    }

  private:
    static constexpr size_t kBlock = vhw::kBlockSize;
    static constexpr size_t kFifo  = 4096; // power of two

    void run_block()
    {
        timespec t0, t1;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        float  ib[4][kBlock], ob[4][kBlock];
        float* ins[4]  = {ib[0], ib[1], ib[2], ib[3]};
        float* outs[4] = {ob[0], ob[1], ob[2], ob[3]};
        for(size_t k = 0; k < kBlock; k++)
        {
            ib[0][k] = in_[0][k]; // mic
            ib[1][k] = 0.f;
            ib[2][k] = in_[0][k]; // line in
            ib[3][k] = in_[1][k];
        }
        vhw::audio_block(ins, outs);
        for(size_t k = 0; k < kBlock; k++)
        {
            size_t w   = (out_read_ + out_fill_) & (kFifo - 1);
            out_[0][w] = ob[2][k]; // line out
            out_[1][w] = ob[3][k];
            out_fill_++;
        }
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double us = (t1.tv_sec - t0.tv_sec) * 1e6 + (t1.tv_nsec - t0.tv_nsec) * 1e-3;
        bridge::report_block_load(float(us / vhw::kBlockUs * 100.0));
    }

    float  in_[2][kBlock];
    float  out_[2][kFifo];
    size_t in_fill_, out_read_, out_fill_;
};
