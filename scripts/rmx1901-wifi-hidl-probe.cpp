#include <android/hardware/wifi/1.0/IWifi.h>
#include <android/hardware/wifi/1.0/IWifiChip.h>

#include <cstdio>

using android::hardware::wifi::V1_0::IWifi;
using android::hardware::wifi::V1_0::IWifiChip;
using android::hardware::wifi::V1_0::IWifiStaIface;
using android::hardware::wifi::V1_0::WifiStatus;

int main() {
    auto wifi = IWifi::getService("default");
    if (wifi == nullptr) {
        std::fputs("IWifi/default unavailable\n", stderr);
        return 2;
    }
    const auto started = wifi->isStarted();
    if (!started.isOk()) {
        std::fputs("IWifi.isStarted transport failure\n", stderr);
        return 3;
    }
    std::printf("started_before=%d\n", static_cast<bool>(started));

    bool start_callback = false;
    int start_code = -1;
    if (started) {
        start_callback = true;
        start_code = 0;
        std::puts("start_status=already_started");
    } else {
        const auto start = wifi->start([&](const WifiStatus& status) {
            start_callback = true;
            start_code = static_cast<int>(status.code);
        });
        if (!start.isOk() || !start_callback) {
            std::fputs("IWifi.start transport failure\n", stderr);
            return 4;
        }
        std::printf("start_status=%d\n", start_code);
    }

    bool chips_callback = false;
    int chips_code = -1;
    size_t chips_count = 0;
    const auto chips = wifi->getChipIds([&](const WifiStatus& status, const auto& ids) {
        chips_callback = true;
        chips_code = static_cast<int>(status.code);
        chips_count = ids.size();
    });
    if (!chips.isOk() || !chips_callback) {
        std::fputs("IWifi.getChipIds transport failure\n", stderr);
        return 5;
    }
    std::printf("chip_ids_status=%d chip_ids_count=%zu\n", chips_code, chips_count);
    if (start_code != 0 || chips_code != 0 || chips_count == 0) {
        return 1;
    }

    bool chip_callback = false;
    int chip_code = -1;
    ::android::sp<IWifiChip> chip;
    const auto get_chip = wifi->getChip(0, [&](const WifiStatus& status, const auto& value) {
        chip_callback = true;
        chip_code = static_cast<int>(status.code);
        chip = value;
    });
    if (!get_chip.isOk() || !chip_callback || chip_code != 0 || chip == nullptr) {
        std::fputs("IWifi.getChip failure\n", stderr);
        return 6;
    }

    bool mode_callback = false;
    int mode_code = -1;
    uint32_t mode_id = 0;
    const auto get_mode = chip->getMode([&](const WifiStatus& status, uint32_t value) {
        mode_callback = true;
        mode_code = static_cast<int>(status.code);
        mode_id = value;
    });
    if (!get_mode.isOk() || !mode_callback) {
        std::fputs("IWifiChip.getMode transport failure\n", stderr);
        return 7;
    }

    if (mode_code != 0) {
        bool modes_callback = false;
        int modes_code = -1;
        size_t modes_count = 0;
        const auto modes = chip->getAvailableModes([&](
                const WifiStatus& status,
                const ::android::hardware::hidl_vec<IWifiChip::ChipMode>& values) {
            modes_callback = true;
            modes_code = static_cast<int>(status.code);
            modes_count = values.size();
            if (values.size() != 0) {
                mode_id = values[0].id;
            }
        });
        if (!modes.isOk() || !modes_callback || modes_code != 0 || modes_count == 0) {
            std::fputs("IWifiChip.getAvailableModes failure\n", stderr);
            return 8;
        }
        bool configure_callback = false;
        int configure_code = -1;
        const auto configure = chip->configureChip(mode_id, [&](const WifiStatus& status) {
            configure_callback = true;
            configure_code = static_cast<int>(status.code);
        });
        if (!configure.isOk() || !configure_callback || configure_code != 0) {
            std::fputs("IWifiChip.configureChip failure\n", stderr);
            return 9;
        }
        std::printf("configured_mode=%u\n", mode_id);
    } else {
        std::printf("configured_mode=already_%u\n", mode_id);
    }

    bool sta_callback = false;
    int sta_code = -1;
    const auto create_sta = chip->createStaIface([&](
            const WifiStatus& status, const ::android::sp<IWifiStaIface>& iface) {
        sta_callback = true;
        sta_code = static_cast<int>(status.code);
        if (status.code == ::android::hardware::wifi::V1_0::WifiStatusCode::SUCCESS && iface != nullptr) {
            iface->getName([&](const WifiStatus& name_status,
                    const ::android::hardware::hidl_string& name) {
                if (name_status.code == ::android::hardware::wifi::V1_0::WifiStatusCode::SUCCESS) {
                    std::printf("sta_iface=%s\n", name.c_str());
                }
            });
        }
    });
    if (!create_sta.isOk() || !sta_callback || sta_code != 0) {
        std::fputs("IWifiChip.createStaIface failure\n", stderr);
        return 10;
    }
    std::printf("sta_iface_status=%d\n", sta_code);
    return 0;
}
