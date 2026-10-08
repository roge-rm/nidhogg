// Linux implementations of the libDaisy classes Chompi uses. The headers are
// libDaisy's own; only the hardware behind them is virtual (see vhw.h).
#include "daisy_seed.h"
#include "sys/dma.h"
#include "sys/fatfs.h"
#include "vhw.h"

#include <cstdio>
#include <cstring>

using namespace daisy;

// ---- System -----------------------------------------------------------------

void System::Init() {}
void System::Init(const Config&) {}
void System::DeInit() {}
void System::JumpToQspi() {}

uint32_t System::GetNow()
{
    return uint32_t(vhw::now_us() / 1000);
}
uint32_t System::GetUs()
{
    return uint32_t(vhw::now_us());
}
uint32_t System::GetTick()
{
    return uint32_t(vhw::now_us() * (GetTickFreq() / 1000000));
}
void System::Delay(uint32_t delay_ms)
{
    vhw::sleep_until_us(vhw::now_us() + uint64_t(delay_ms) * 1000);
}
void System::DelayUs(uint32_t delay_us)
{
    vhw::sleep_until_us(vhw::now_us() + delay_us);
}
void System::DelayTicks(uint32_t) {}
void System::ResetToBootloader(BootloaderMode) {}
void System::InitBackupSram() {}
System::BootInfo::Version System::GetBootloaderVersion()
{
    return BootInfo::Version::NONE;
}
uint32_t System::GetTickFreq()
{
    return 200000000;
}
uint32_t System::GetSysClkFreq()
{
    return 480000000;
}
uint32_t System::GetHClkFreq()
{
    return 240000000;
}
uint32_t System::GetPClk1Freq()
{
    return 120000000;
}
uint32_t System::GetPClk2Freq()
{
    return 120000000;
}
System::MemoryRegion System::GetProgramMemoryRegion()
{
    return MemoryRegion::INTERNAL_FLASH;
}
System::MemoryRegion System::GetMemoryRegion(uint32_t)
{
    return MemoryRegion::INTERNAL_FLASH;
}

// ---- GPIO -------------------------------------------------------------------

void GPIO::Init(const Config& cfg)
{
    cfg_ = cfg;
}
void GPIO::Init(Pin p, const Config& cfg)
{
    cfg_     = cfg;
    cfg_.pin = p;
}
void GPIO::Init(Pin p, Mode m, Pull pu, Speed sp)
{
    cfg_.pin   = p;
    cfg_.mode  = m;
    cfg_.pull  = pu;
    cfg_.speed = sp;
}
void GPIO::DeInit() {}
bool GPIO::Read()
{
    return vhw::pin_read(cfg_.pin.port, cfg_.pin.pin);
}
void GPIO::Write(bool state)
{
    vhw::pin_write(cfg_.pin.port, cfg_.pin.pin, state);
}
void GPIO::Toggle()
{
    Write(!vhw::pin_read(cfg_.pin.port, cfg_.pin.pin));
}
uint32_t* GPIO::GetGPIOBaseRegister()
{
    return nullptr;
}

extern "C" {
void    dsy_gpio_init(const dsy_gpio*) {}
void    dsy_gpio_deinit(const dsy_gpio*) {}
uint8_t dsy_gpio_read(const dsy_gpio* p)
{
    return vhw::pin_read(p->pin.port, p->pin.pin);
}
void dsy_gpio_write(const dsy_gpio* p, uint8_t state)
{
    vhw::pin_write(p->pin.port, p->pin.pin, state);
}
void dsy_gpio_toggle(const dsy_gpio* p)
{
    dsy_gpio_write(p, !dsy_gpio_read(p));
}
}

// ---- I2C: the MP2722 battery charger -----------------------------------------
// Reports USB power present, charge done, no faults, battery not low.

class I2CHandle::Impl
{
  public:
    Config  cfg;
    uint8_t regs[256] = {};
    uint8_t ptr       = 0;
    Impl()
    {
        regs[0x12] = (1 << 6) | (1 << 5); // VIN_GD, VIN_RDY
        regs[0x13] = 0b101 << 5;          // CHG_STAT: charge done
    }
};

namespace
{
I2CHandle::Impl i2c_impl;
}

I2CHandle::Result I2CHandle::Init(const Config& config)
{
    pimpl_      = &i2c_impl;
    pimpl_->cfg = config;
    return Result::OK;
}
const I2CHandle::Config& I2CHandle::GetConfig() const
{
    return pimpl_->cfg;
}
I2CHandle::Result I2CHandle::TransmitBlocking(uint16_t, uint8_t* data, uint16_t size, uint32_t)
{
    if(size >= 1)
        pimpl_->ptr = data[0];
    for(uint16_t i = 1; i < size; i++)
        pimpl_->regs[uint8_t(data[0] + i - 1)] = data[i];
    return Result::OK;
}
I2CHandle::Result I2CHandle::ReceiveBlocking(uint16_t, uint8_t* data, uint16_t size, uint32_t)
{
    for(uint16_t i = 0; i < size; i++)
        data[i] = pimpl_->regs[uint8_t(pimpl_->ptr + i)];
    return Result::OK;
}
I2CHandle::Result I2CHandle::TransmitDma(uint16_t address, uint8_t* data, uint16_t size,
                                         CallbackFunctionPtr callback, void* ctx)
{
    TransmitBlocking(address, data, size, 0);
    if(callback)
        callback(ctx, Result::OK);
    return Result::OK;
}
I2CHandle::Result I2CHandle::ReceiveDma(uint16_t address, uint8_t* data, uint16_t size,
                                        CallbackFunctionPtr callback, void* ctx)
{
    ReceiveBlocking(address, data, size, 0);
    if(callback)
        callback(ctx, Result::OK);
    return Result::OK;
}
I2CHandle::Result I2CHandle::ReadDataAtAddress(uint16_t, uint16_t mem_address, uint16_t,
                                               uint8_t* data, uint16_t data_size, uint32_t)
{
    for(uint16_t i = 0; i < data_size; i++)
        data[i] = pimpl_->regs[uint8_t(mem_address + i)];
    return Result::OK;
}
I2CHandle::Result I2CHandle::WriteDataAtAddress(uint16_t, uint16_t mem_address, uint16_t,
                                                uint8_t* data, uint16_t data_size, uint32_t)
{
    for(uint16_t i = 0; i < data_size; i++)
        pimpl_->regs[uint8_t(mem_address + i)] = data[i];
    return Result::OK;
}

// ---- SAI and audio ----------------------------------------------------------

class SaiHandle::Impl
{
  public:
    Config cfg;
};

namespace
{
SaiHandle::Impl sai_impls[2];
int             sai_count = 0;
}

SaiHandle::Result SaiHandle::Init(const Config& config)
{
    pimpl_      = &sai_impls[sai_count++ % 2];
    pimpl_->cfg = config;
    return Result::OK;
}
SaiHandle::Result SaiHandle::DeInit()
{
    return Result::OK;
}
const SaiHandle::Config& SaiHandle::GetConfig() const
{
    return pimpl_->cfg;
}
SaiHandle::Result SaiHandle::StartDma(int32_t*, int32_t*, size_t, CallbackFunctionPtr)
{
    return Result::OK;
}
SaiHandle::Result SaiHandle::StopDma()
{
    return Result::OK;
}
float SaiHandle::GetSampleRate()
{
    return float(vhw::kSampleRate);
}
size_t SaiHandle::GetBlockSize()
{
    return vhw::kBlockSize;
}
float SaiHandle::GetBlockRate()
{
    return float(vhw::kSampleRate) / vhw::kBlockSize;
}
size_t SaiHandle::GetOffset() const
{
    return 0;
}

class AudioHandle::Impl
{
  public:
    Config cfg;
};

namespace
{
AudioHandle::Impl audio_impl;
}

AudioHandle::Result AudioHandle::Init(const Config& config, SaiHandle)
{
    pimpl_      = &audio_impl;
    pimpl_->cfg = config;
    return Result::OK;
}
AudioHandle::Result AudioHandle::Init(const Config& config, SaiHandle, SaiHandle)
{
    pimpl_      = &audio_impl;
    pimpl_->cfg = config;
    return Result::OK;
}
AudioHandle::Result AudioHandle::DeInit()
{
    return Result::OK;
}
const AudioHandle::Config& AudioHandle::GetConfig() const
{
    return pimpl_->cfg;
}
size_t AudioHandle::GetChannels() const
{
    return 4;
}
float AudioHandle::GetSampleRate()
{
    return float(vhw::kSampleRate);
}
AudioHandle::Result AudioHandle::SetSampleRate(SaiHandle::Config::SampleRate)
{
    return Result::OK;
}
AudioHandle::Result AudioHandle::SetBlockSize(size_t size)
{
    // The host always runs 24-frame blocks, as Chompi does.
    return size == vhw::kBlockSize ? Result::OK : Result::ERR;
}
AudioHandle::Result AudioHandle::SetPostGain(float val)
{
    pimpl_->cfg.postgain = val;
    return Result::OK;
}
AudioHandle::Result AudioHandle::SetOutputCompensation(float val)
{
    pimpl_->cfg.output_compensation = val;
    return Result::OK;
}
AudioHandle::Result AudioHandle::Start(AudioCallback callback)
{
    vhw::set_audio_callback(callback);
    return Result::OK;
}
AudioHandle::Result AudioHandle::Start(InterleavingAudioCallback)
{
    return Result::ERR;
}
AudioHandle::Result AudioHandle::Stop()
{
    vhw::set_audio_callback(nullptr);
    return Result::OK;
}
AudioHandle::Result AudioHandle::ChangeCallback(AudioCallback callback)
{
    vhw::set_audio_callback(callback);
    return Result::OK;
}
AudioHandle::Result AudioHandle::ChangeCallback(InterleavingAudioCallback)
{
    return Result::ERR;
}

// ---- UART: TRS MIDI -----------------------------------------------------------

class UartHandler::Impl
{
  public:
    Config                        cfg;
    bool                          listening = false;
    CircularRxCallbackFunctionPtr rx_cb     = nullptr;
    void*                         rx_ctx    = nullptr;
};

namespace
{
UartHandler::Impl uart_impl;
}

UartHandler::Result UartHandler::Init(const Config& config)
{
    pimpl_      = &uart_impl;
    pimpl_->cfg = config;
    return Result::OK;
}
const UartHandler::Config& UartHandler::GetConfig() const
{
    return pimpl_->cfg;
}
UartHandler::Result UartHandler::BlockingTransmit(uint8_t* buff, size_t size, uint32_t)
{
    vhw::midi_tx(vhw::MidiPort::TRS, buff, size);
    return Result::OK;
}
UartHandler::Result UartHandler::BlockingReceive(uint8_t*, uint16_t, uint32_t)
{
    return Result::ERR;
}
UartHandler::Result UartHandler::DmaTransmit(uint8_t* buff, size_t size,
                                             StartCallbackFunctionPtr start_cb,
                                             EndCallbackFunctionPtr end_cb, void* ctx)
{
    if(start_cb)
        start_cb(ctx);
    vhw::midi_tx(vhw::MidiPort::TRS, buff, size);
    if(end_cb)
        end_cb(ctx, Result::OK);
    return Result::OK;
}
UartHandler::Result UartHandler::DmaReceive(uint8_t*, size_t, StartCallbackFunctionPtr,
                                            EndCallbackFunctionPtr, void*)
{
    return Result::ERR;
}
UartHandler::Result UartHandler::DmaListenStart(uint8_t*, size_t,
                                                CircularRxCallbackFunctionPtr cb, void* ctx)
{
    Impl* p      = pimpl_;
    p->rx_cb     = cb;
    p->rx_ctx    = ctx;
    p->listening = true;
    vhw::set_midi_rx(vhw::MidiPort::TRS, [p](const uint8_t* data, size_t size) {
        if(p->listening && p->rx_cb)
            p->rx_cb(const_cast<uint8_t*>(data), size, p->rx_ctx, Result::OK);
    });
    return Result::OK;
}
UartHandler::Result UartHandler::DmaListenStop()
{
    pimpl_->listening = false;
    return Result::OK;
}
bool UartHandler::IsListening() const
{
    return pimpl_ && pimpl_->listening;
}
int UartHandler::CheckError()
{
    return 0;
}
int UartHandler::PollReceive(uint8_t*, size_t, uint32_t)
{
    return 0;
}
UartHandler::Result UartHandler::PollTx(uint8_t* buff, size_t size)
{
    vhw::midi_tx(vhw::MidiPort::TRS, buff, size);
    return Result::OK;
}
extern "C" void dsy_uart_global_init() {}

// ---- USB MIDI -----------------------------------------------------------------

class MidiUsbTransport::Impl
{
  public:
    MidiRxParseCallback cb  = nullptr;
    void*               ctx = nullptr;
};

namespace
{
MidiUsbTransport::Impl usb_midi_impl;
}

void MidiUsbTransport::Init(Config)
{
    pimpl_ = &usb_midi_impl;
}
void MidiUsbTransport::Reset() {}
void MidiUsbTransport::StartRx(MidiRxParseCallback callback, void* context)
{
    Impl* p = pimpl_;
    p->cb   = callback;
    p->ctx  = context;
    vhw::set_midi_rx(vhw::MidiPort::USB, [p](const uint8_t* data, size_t size) {
        if(p->cb)
            p->cb(const_cast<uint8_t*>(data), size, p->ctx);
    });
}
bool MidiUsbTransport::RxActive()
{
    return pimpl_ && pimpl_->cb;
}
void MidiUsbTransport::FlushRx() {}
bool MidiUsbTransport::Tx(uint8_t* buffer, size_t size)
{
    vhw::midi_tx(vhw::MidiPort::USB, buffer, size);
    return true;
}

void UsbHandle::Init(UsbPeriph) {}
void UsbHandle::Reset() {}
void UsbHandle::DeInit(UsbPeriph) {}
UsbHandle::Result UsbHandle::TransmitInternal(uint8_t* buff, size_t size)
{
    fwrite(buff, 1, size, stderr);
    return Result::OK;
}
UsbHandle::Result UsbHandle::TransmitExternal(uint8_t* buff, size_t size)
{
    return TransmitInternal(buff, size);
}
void UsbHandle::SetReceiveCallback(ReceiveCallback, UsbPeriph) {}

// ---- timers -----------------------------------------------------------------

class TimerHandle::Impl
{
  public:
    Config                cfg;
    PeriodElapsedCallback cb   = nullptr;
    void*                 data = nullptr;
};

TimerHandle::Result TimerHandle::Init(const Config& config)
{
    if(!pimpl_)
        pimpl_ = new Impl;
    pimpl_->cfg = config;
    return Result::OK;
}
TimerHandle::Result TimerHandle::DeInit()
{
    return Result::OK;
}
const TimerHandle::Config& TimerHandle::GetConfig() const
{
    return pimpl_->cfg;
}
TimerHandle::Result TimerHandle::SetPeriod(uint32_t ticks)
{
    pimpl_->cfg.period = ticks;
    return Result::OK;
}
TimerHandle::Result TimerHandle::SetPrescaler(uint32_t)
{
    return Result::OK;
}
TimerHandle::Result TimerHandle::Start()
{
    // Only interrupt-driven timers matter on the host; PWM timers do nothing.
    if(pimpl_->cfg.enable_irq && pimpl_->cb && pimpl_->cfg.period)
        vhw::add_timer(System::GetPClk2Freq() / pimpl_->cfg.period, pimpl_->cb, pimpl_->data);
    return Result::OK;
}
TimerHandle::Result TimerHandle::Stop()
{
    return Result::OK;
}
uint32_t TimerHandle::GetFreq()
{
    return System::GetPClk2Freq();
}
uint32_t TimerHandle::GetTick()
{
    return uint32_t(vhw::now_us() * (System::GetPClk2Freq() / 1000000));
}
uint32_t TimerHandle::GetMs()
{
    return System::GetNow();
}
uint32_t TimerHandle::GetUs()
{
    return System::GetUs();
}
void TimerHandle::DelayTick(uint32_t) {}
void TimerHandle::DelayMs(uint32_t del)
{
    System::Delay(del);
}
void TimerHandle::DelayUs(uint32_t del)
{
    System::DelayUs(del);
}
void TimerHandle::SetCallback(PeriodElapsedCallback cb, void* data)
{
    if(!pimpl_)
        pimpl_ = new Impl;
    pimpl_->cb   = cb;
    pimpl_->data = data;
}

// LED PWM channels: a DMA transfer ends about a millisecond later, in
// interrupt context, like the real WS2812 transfer.
void TimChannel::Init(const Config& cfg)
{
    cfg_ = cfg;
}
void TimChannel::Start() {}
void TimChannel::Stop() {}
void TimChannel::SetPwm(uint32_t) {}
void TimChannel::StartDma(void*, size_t, EndTransmissionFunctionPtr callback, void* cb_context)
{
    if(callback)
        vhw::post_irq(callback, cb_context);
}
const TimChannel::Config& TimChannel::GetConfig() const
{
    return cfg_;
}

// ---- SD card ----------------------------------------------------------------

SdmmcHandler::Result SdmmcHandler::Init(const Config&)
{
    return Result::OK;
}

FatFSInterface::Result FatFSInterface::Init(const Config& cfg)
{
    cfg_ = cfg;
    std::strcpy(path_[0], "0:/");
    std::strcpy(path_[1], "1:/");
    initialized_ = true;
    return Result::OK;
}
FatFSInterface::Result FatFSInterface::Init(const uint8_t media)
{
    Config cfg;
    cfg.media = media;
    return Init(cfg);
}
FatFSInterface::Result FatFSInterface::DeInit()
{
    initialized_ = false;
    return Result::OK;
}

// ---- the board ----------------------------------------------------------------

void DaisySeed::Configure() {}
void DaisySeed::Init(bool)
{
    SaiHandle::Config c;
    sai_1_handle_.Init(c);
    AudioHandle::Config ac;
    ac.blocksize = vhw::kBlockSize;
    audio_handle.Init(ac, sai_1_handle_);
    callback_rate_ = float(vhw::kSampleRate) / vhw::kBlockSize;
}
void DaisySeed::DeInit() {}
void DaisySeed::DelayMs(size_t del)
{
    System::Delay(del);
}
void DaisySeed::StartAudio(AudioHandle::AudioCallback cb)
{
    audio_handle.Start(cb);
}
void DaisySeed::StartAudio(AudioHandle::InterleavingAudioCallback cb)
{
    audio_handle.Start(cb);
}
void DaisySeed::ChangeAudioCallback(AudioHandle::AudioCallback cb)
{
    audio_handle.ChangeCallback(cb);
}
void DaisySeed::ChangeAudioCallback(AudioHandle::InterleavingAudioCallback cb)
{
    audio_handle.ChangeCallback(cb);
}
void DaisySeed::StopAudio()
{
    audio_handle.Stop();
}
void DaisySeed::SetAudioSampleRate(SaiHandle::Config::SampleRate) {}
float DaisySeed::AudioSampleRate()
{
    return float(vhw::kSampleRate);
}
void DaisySeed::SetAudioBlockSize(size_t blocksize)
{
    audio_handle.SetBlockSize(blocksize);
}
size_t DaisySeed::AudioBlockSize()
{
    return vhw::kBlockSize;
}
float DaisySeed::AudioCallbackRate() const
{
    return callback_rate_;
}
const SaiHandle& DaisySeed::AudioSaiHandle() const
{
    return sai_1_handle_;
}
void DaisySeed::SetLed(bool) {}
void DaisySeed::SetTestPoint(bool) {}
DaisySeed::BoardVersion DaisySeed::CheckBoardVersion()
{
    return BoardVersion::DAISY_SEED_2_DFM;
}

// ---- DMA cache maintenance: nothing to do without a data cache in the way -----

extern "C" {
void dsy_dma_clear_cache_for_buffer(uint8_t*, size_t) {}
void dsy_dma_invalidate_cache_for_buffer(uint8_t*, size_t) {}
}
