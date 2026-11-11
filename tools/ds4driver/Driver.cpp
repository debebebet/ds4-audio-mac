// DualShock 4 Audio — виртуальное loopback-устройство CoreAudio.
//
// Устройство «DualShock 4» принимает звук от приложений (output-поток) и
// отдаёт его обратно как вход (input-поток). ds4probe читает этот вход и
// отправляет звук в динамик геймпада. BlackHole для этого не нужен.
//
// **Видимость устройства.** Пока работает GUI, устройство должно быть в
// системе (иначе нельзя выбрать его выводом). Как только приложение закрыто,
// устройство должно исчезнуть. Для этого GUI обновляет файл-heartbeat, а
// драйвер следит за ним: файл свежий — устройство опубликовано, файл
// протух или пропал — устройство убрано из списка CoreAudio. Благодаря
// файлу же закрытие приложения обрабатывается без единого запроса пароля.
//
// Драйвер построен на libASPL (MIT): https://github.com/gavv/libASPL

#include <aspl/Driver.hpp>
#include <aspl/DriverRequestHandler.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <sys/stat.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <thread>
#include <vector>

namespace {

constexpr UInt32 kSampleRate = 48000;
constexpr UInt32 kChannelCount = 2;
constexpr UInt32 kBytesPerSample = sizeof(Float32);
constexpr UInt32 kBytesPerFrame = kBytesPerSample * kChannelCount;

// Два секунды запаса. Этого достаточно, чтобы пережить джиттер HAL и
// кратковременные задержки планировщика.
constexpr int64_t kCapacityFrames = int64_t(kSampleRate) * 2;

// Файл-heartbeat. Путь должен совпадать с kHeartbeatPath в GUI
// (tools/ds4gui/Sources/DS4Audio/DriverHeartbeat.swift).
constexpr const char* kHeartbeatPath = "/var/tmp/com.ds4audio.gui.heartbeat";

// Через сколько секунд heartbeat считается протухшим. GUI обновляет файл
// раз в секунду, так что четыре секунды — запас на задержки планировщика.
constexpr int kHeartbeatStaleSeconds = 4;

// Как часто драйвер проверяет heartbeat.
constexpr int kPollIntervalMs = 500;

/// Свежий ли heartbeat-файл.
bool HeartbeatIsFresh()
{
    struct stat info = {};
    if (::stat(kHeartbeatPath, &info) != 0) {
        return false;
    }

    const auto now = std::chrono::system_clock::now();
    const auto modified = std::chrono::system_clock::from_time_t(info.st_mtime);
    const auto age = std::chrono::duration_cast<std::chrono::seconds>(now - modified);
    return age.count() < kHeartbeatStaleSeconds;
}

// Состояние видимости живёт на уровне модуля: coreaudiod выгружает драйвер
// только перезапуском процесса, поэтому порядок разрушения статических
// объектов здесь не важен, а поток-дозор должен жить независимо от
// времени жизни объектов libASPL.
std::shared_ptr<aspl::Plugin> gPlugin;
std::shared_ptr<aspl::Device> gDevice;
std::atomic<bool> gPublished{false};
std::atomic<bool> gWatchStarted{false};

/// Цикл дозора: публикует и убирает устройство по состоянию heartbeat.
void VisibilityWatchLoop()
{
    while (true) {
        const bool fresh = HeartbeatIsFresh();
        const bool published = gPublished.load();

        if (fresh && !published) {
            gPlugin->AddDevice(gDevice);
            gPublished.store(true);
            gPlugin->GetContext()->Tracer->Message(
                "DS4AudioDriver: device published (heartbeat fresh)");
        } else if (!fresh && published) {
            gPlugin->RemoveDevice(gDevice);
            gPublished.store(false);
            gPlugin->GetContext()->Tracer->Message(
                "DS4AudioDriver: device removed from system (heartbeat stale)");
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(kPollIntervalMs));
    }
}

/// Запускает дозор после того, как HAL закончит асинхронную инициализацию.
class VisibilityHandler : public aspl::DriverRequestHandler
{
public:
    OSStatus OnInitialize() override
    {
        bool expected = false;
        if (gWatchStarted.compare_exchange_strong(expected, true)) {
            std::thread(VisibilityWatchLoop).detach();
        }
        return kAudioHardwareNoError;
    }
};

AudioStreamBasicDescription MakeStreamFormat()
{
    AudioStreamBasicDescription format = {};
    format.mSampleRate = kSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags =
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
    format.mBytesPerPacket = kBytesPerFrame;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = kBytesPerFrame;
    format.mChannelsPerFrame = kChannelCount;
    format.mBitsPerChannel = kBytesPerSample * 8;
    return format;
}

// Кольцевой буфер, адресуемый номером кадра. Писатель — output-поток HAL,
// читателей может быть несколько (каждый клиент читает один и тот же вход),
// поэтому позиция чтения берётся из timestamp, а не из общего указателя.
//
// Это SPSC-буфер: один писатель, читатели только читают. Перезапись ещё не
// прочитанного участка возможна только если читатель отстал больше чем на
// ёмкость буфера; в этом случае он получит тишину.
class LoopbackRing
{
public:
    LoopbackRing()
        : samples_(size_t(kCapacityFrames) * kChannelCount, 0.0f)
    {
    }

    void Write(int64_t startFrame, const Float32* frames, UInt32 frameCount)
    {
        if (frameCount == 0) {
            return;
        }

        const int64_t endFrame = startFrame + frameCount;
        int64_t writeStart = writeStart_.load(std::memory_order_acquire);
        int64_t writeEnd = writeEnd_.load(std::memory_order_acquire);

        if (writeEnd == 0 || startFrame < writeStart || startFrame > writeEnd + kCapacityFrames) {
            // Первый запуск, скачок host time или читатель ушёл слишком далеко
            // назад — начинаем заново.
            std::memset(samples_.data(), 0, samples_.size() * sizeof(Float32));
            writeStart = startFrame;
            writeEnd = startFrame;
        } else if (startFrame > writeEnd) {
            // Разрыв: заполняем тишиной, чтобы старые сэмплы не звучали.
            ZeroRange(writeEnd, startFrame);
        }

        CopyIn(startFrame, frames, frameCount);

        const int64_t newStart = std::max(writeStart, endFrame - kCapacityFrames);
        const int64_t newEnd = std::max(writeEnd, endFrame);
        writeStart_.store(newStart, std::memory_order_release);
        writeEnd_.store(newEnd, std::memory_order_release);
    }

    void Read(int64_t startFrame, Float32* frames, UInt32 frameCount)
    {
        if (frameCount == 0) {
            return;
        }

        const int64_t endFrame = startFrame + frameCount;
        // Сначала читаем writeEnd (release от писателя), затем writeStart:
        // так гарантируется, что writeStart не «новее» writeEnd.
        const int64_t writeEnd = writeEnd_.load(std::memory_order_acquire);
        const int64_t writeStart = writeStart_.load(std::memory_order_acquire);

        std::memset(frames, 0, size_t(frameCount) * kBytesPerFrame);

        if (writeEnd <= startFrame || endFrame <= writeStart) {
            return;
        }

        const int64_t copyStart = std::max(startFrame, writeStart);
        const int64_t copyEnd = std::min(endFrame, writeEnd);
        if (copyStart >= copyEnd) {
            return;
        }

        CopyOut(copyStart, frames + (copyStart - startFrame) * kChannelCount,
            UInt32(copyEnd - copyStart));
    }

private:
    void CopyIn(int64_t startFrame, const Float32* source, UInt32 frameCount)
    {
        int64_t pos = Mod(startFrame);
        while (frameCount > 0) {
            const UInt32 chunk =
                UInt32(std::min<int64_t>(frameCount, kCapacityFrames - pos));
            std::memcpy(&samples_[size_t(pos) * kChannelCount], source,
                size_t(chunk) * kBytesPerFrame);
            source += size_t(chunk) * kChannelCount;
            frameCount -= chunk;
            pos = (pos + chunk) % kCapacityFrames;
        }
    }

    void CopyOut(int64_t startFrame, Float32* destination, UInt32 frameCount)
    {
        int64_t pos = Mod(startFrame);
        while (frameCount > 0) {
            const UInt32 chunk =
                UInt32(std::min<int64_t>(frameCount, kCapacityFrames - pos));
            std::memcpy(destination, &samples_[size_t(pos) * kChannelCount],
                size_t(chunk) * kBytesPerFrame);
            destination += size_t(chunk) * kChannelCount;
            frameCount -= chunk;
            pos = (pos + chunk) % kCapacityFrames;
        }
    }

    void ZeroRange(int64_t startFrame, int64_t endFrame)
    {
        const int64_t frames = endFrame - startFrame;
        if (frames <= 0) {
            return;
        }
        if (frames >= kCapacityFrames) {
            std::memset(samples_.data(), 0, samples_.size() * sizeof(Float32));
            return;
        }
        int64_t pos = Mod(startFrame);
        int64_t left = frames;
        while (left > 0) {
            const int64_t chunk = std::min<int64_t>(left, kCapacityFrames - pos);
            std::memset(&samples_[size_t(pos) * kChannelCount], 0,
                size_t(chunk) * kBytesPerFrame);
            pos = (pos + chunk) % kCapacityFrames;
            left -= chunk;
        }
    }

    static int64_t Mod(int64_t frame)
    {
        int64_t value = frame % kCapacityFrames;
        if (value < 0) {
            value += kCapacityFrames;
        }
        return value;
    }

    std::vector<Float32> samples_;
    std::atomic<int64_t> writeStart_{0};
    std::atomic<int64_t> writeEnd_{0};
};

class LoopbackHandler : public aspl::IORequestHandler
{
public:
    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>&,
        Float64,
        Float64 timestamp,
        const void* bytes,
        UInt32 bytesCount) override
    {
        const UInt32 frameCount = bytesCount / kBytesPerFrame;
        ring_.Write(ToFrame(timestamp), static_cast<const Float32*>(bytes), frameCount);
    }

    void OnReadClientInput(const std::shared_ptr<aspl::Client>&,
        const std::shared_ptr<aspl::Stream>&,
        Float64,
        Float64 timestamp,
        void* bytes,
        UInt32 bytesCount) override
    {
        const UInt32 frameCount = bytesCount / kBytesPerFrame;
        ring_.Read(ToFrame(timestamp), static_cast<Float32*>(bytes), frameCount);
    }

private:
    static int64_t ToFrame(Float64 timestamp)
    {
        return int64_t(std::llround(timestamp));
    }

    LoopbackRing ring_;
};

std::shared_ptr<aspl::Driver> CreateDriver()
{
    auto context = std::make_shared<aspl::Context>();

    aspl::DeviceParameters deviceParams;
    deviceParams.Name = "DualShock 4";
    deviceParams.Manufacturer = "DS4Audio";
    deviceParams.DeviceUID = "com.ds4audio.driver.dualshock4";
    deviceParams.ModelUID = "com.ds4audio.driver.dualshock4.model";
    deviceParams.SerialNumber = "DS4AUDIO-1";
    deviceParams.SampleRate = kSampleRate;
    deviceParams.ChannelCount = kChannelCount;
    deviceParams.EnableMixing = true;
    deviceParams.Latency = 0;
    deviceParams.SafetyOffset = 0;
    deviceParams.CanBeDefault = true;
    deviceParams.CanBeDefaultForSystemSounds = true;

    auto device = std::make_shared<aspl::Device>(context, deviceParams);

    aspl::StreamParameters outputParams;
    outputParams.Direction = aspl::Direction::Output;
    outputParams.Format = MakeStreamFormat();
    outputParams.StartingChannel = 1;
    device->AddStreamAsync(outputParams);

    aspl::StreamParameters inputParams;
    inputParams.Direction = aspl::Direction::Input;
    inputParams.Format = MakeStreamFormat();
    inputParams.StartingChannel = 1;
    device->AddStreamAsync(inputParams);

    auto handler = std::make_shared<LoopbackHandler>();
    device->SetIOHandler(handler);

    auto plugin = std::make_shared<aspl::Plugin>(context);

    // Устройство намеренно НЕ добавляется в plugin здесь: пока не начал
    // работать GUI, устройства «DualShock 4» в системе быть не должно.
    // Публикует его дозор по heartbeat-файлу.
    gPlugin = plugin;
    gDevice = device;

    auto driver = std::make_shared<aspl::Driver>(context, plugin);
    driver->SetDriverHandler(std::make_shared<VisibilityHandler>());
    return driver;
}

} // namespace

extern "C" void* DS4AudioDriverEntryPoint(CFAllocatorRef, CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }

    static std::shared_ptr<aspl::Driver> driver = CreateDriver();
    return driver->GetReference();
}
