#!/usr/bin/env python3
"""Compile the patched HAL methods against a fake V4L2 transport.

Pass a prepared ipu7-camera-hal source directory. Method bodies are taken
verbatim from that checkout and compiled with its bundled UAPI headers;
no camera device is opened.
"""
import pathlib
import resource
import subprocess
import sys
import tempfile

resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
source_dir = pathlib.Path(sys.argv[1]).resolve()
source = (source_dir / 'src/v4l2/MediaControl.cpp').read_text()
def method(name):
    start = source.index('int MediaControl::' + name + '(')
    end = source.index('\n}\n', start) + 3
    return source[start:end]

fixture = r'''
#include <linux/media.h>
#include <linux/v4l2-subdev.h>
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>
using std::string;
constexpr int OK = 0, BAD_VALUE = -EINVAL, NAME_NOT_FOUND = -ENOENT, UNKNOWN_ERROR = -EIO;
constexpr int RESOLUTION_TARGET = 1, FC_FORMAT = 1, FC_SELECTION = 2;
struct AutoMutex { explicit AutoMutex(int&) {} };
#define PERF_CAMERA_ATRACE()
#define LOG1(...)
#define CLEAR(x) memset(&(x), 0, sizeof(x))
#define CheckAndLogError(condition, value, ...) do { if (condition) return value; } while (0)
struct MediaEntity;
struct MediaPad { MediaEntity* entity; unsigned index; unsigned flags; };
struct MediaLink { MediaPad* source; MediaPad* sink; unsigned flags; };
struct MediaEntity {
    media_entity_desc info = {};
    MediaPad* pads = nullptr;
    MediaLink* links = nullptr;
    unsigned numLinks = 0;
    char devname[32] = {};
};
struct McFormat {
    int entity = 0, pad = 0, stream = 0, width = 0, height = 0, type = 0;
    int formatType = FC_FORMAT;
    unsigned pixelCode = 0;
    string entityName;
};
struct McLink { int srcEntity, srcPad, sinkEntity, sinkPad; string srcEntityName, sinkEntityName; };
struct MediaCtlConf { std::vector<int> ctls, routings; std::vector<McFormat> formats; std::vector<McLink> links; };
struct V4L2Subdevice {
    std::vector<v4l2_subdev_format> writes;
    bool fail = false, negotiate = false;
    int SetFormat(v4l2_subdev_format& fmt) {
        if (fail) return -EIO;
        if (negotiate) { fmt.format.width = 3856; fmt.format.height = 2176; }
        writes.push_back(fmt);
        return 0;
    }
};
V4L2Subdevice sensorDevice, bridgeDevice, receiverDevice;
struct V4l2DeviceFactory {
    static V4L2Subdevice* getSubDev(int, const char* name) {
        if (!strcmp(name, "sensor")) return &sensorDevice;
        if (!strcmp(name, "bridge")) return &bridgeDevice;
        return &receiverDevice;
    }
};
struct PlatformData { static int getISysFormat(int) { return 0; } };
struct CameraUtils { static int getMBusFormat(int, int) { return 0x300a; } };
static const string icvsName = "Intel CVS";
struct MediaControl {
    std::vector<MediaEntity> mEntities;
    std::vector<McLink> configured;
    inline static int sLock = 0;
    bool mIsMediaCtlSetup = false;
    MediaEntity* getEntityByName(const string& name) {
        for (auto& e : mEntities) if (name == e.info.name) return &e;
        return nullptr;
    }
    void setMediaMcCtl(int, const std::vector<int>&) {}
    int setRouting(int, MediaCtlConf*, bool) { return 0; }
    int setSelection(int, McFormat*, int, int) { return 0; }
    int setMediaMcLink(const std::vector<McLink>& links) { configured = links; return 0; }
    int setVideoNodesFormat(MediaCtlConf*, int) { return 0; }
    void dumpEntityTopology() {}
    int mediaCtlSetup(int, MediaCtlConf*, int, int, int);
    MediaEntity* getEntityById(unsigned id) {
        for (auto& e : mEntities) if (e.info.id == id) return &e;
        return nullptr;
    }
    int setFormat(int, const McFormat*, int, int, int);
    int getI2CBusAddress(const string&, const string&, string*);
};
'''
fixture += method('setFormat') + method('getI2CBusAddress') + method('mediaCtlSetup')
fixture += r'''
int main() {
    MediaControl mc;
    mc.mEntities.resize(3);
    auto& sensor = mc.mEntities[0];
    auto& bridge = mc.mEntities[1];
    auto& receiver = mc.mEntities[2];
    sensor.info.id = 1; sensor.info.type = MEDIA_ENT_T_V4L2_SUBDEV_SENSOR; sensor.info.links = 1;
    bridge.info.id = 2; bridge.info.type = MEDIA_ENT_F_VID_IF_BRIDGE; bridge.info.links = 1;
    receiver.info.id = 3; receiver.info.type = MEDIA_ENT_F_VID_IF_BRIDGE;
    strcpy(sensor.info.name, "ov08x40 18-0010"); strcpy(sensor.devname, "sensor");
    strcpy(bridge.info.name, "Intel CVS"); strcpy(bridge.devname, "bridge");
    strcpy(receiver.info.name, "Intel IPU7 CSI2 0"); strcpy(receiver.devname, "receiver");
    MediaPad sp[] = {{&sensor, 0, MEDIA_PAD_FL_SOURCE}};
    MediaPad bp[] = {{&bridge, 0, MEDIA_PAD_FL_SINK}, {&bridge, 1, MEDIA_PAD_FL_SOURCE}};
    MediaPad rp[] = {{&receiver, 0, MEDIA_PAD_FL_SINK}};
    MediaLink sl[] = {{sp, bp, MEDIA_LNK_FL_ENABLED | MEDIA_LNK_FL_IMMUTABLE}};
    MediaLink bl[] = {{bp + 1, rp, MEDIA_LNK_FL_ENABLED}, {sp, bp, MEDIA_LNK_FL_ENABLED | MEDIA_LNK_FL_IMMUTABLE}};
    sensor.pads = sp; sensor.links = sl; sensor.numLinks = 1;
    bridge.pads = bp; bridge.links = bl; bridge.numLinks = 2; bridge.info.pads = 2;
    receiver.pads = rp;
    McFormat format; format.entity = 1; format.pixelCode = 0x300a;
    format.width = 3840; format.height = 2160;
    sensorDevice.negotiate = true;
    assert(mc.setFormat(0, &format, 1920, 1080, V4L2_FIELD_NONE) == 0);
    assert(bridgeDevice.writes.size() == 1);
    auto actual = bridgeDevice.writes.back();
    assert(actual.pad == 0 && actual.which == V4L2_SUBDEV_FORMAT_ACTIVE);
    assert(actual.format.width == 3856 && actual.format.height == 2176);
    assert(actual.format.code == format.pixelCode && actual.format.field == V4L2_FIELD_NONE);
    assert(receiverDevice.writes.empty());
    bridgeDevice.fail = true;
    assert(mc.setFormat(0, &format, 1920, 1080, V4L2_FIELD_NONE) != 0);
    bridgeDevice.fail = false;
    sl[0].flags = 0;
    auto count = bridgeDevice.writes.size();
    assert(mc.setFormat(0, &format, 1920, 1080, V4L2_FIELD_NONE) == 0);
    assert(bridgeDevice.writes.size() == count);
    sl[0].flags = MEDIA_LNK_FL_ENABLED;
    bridge.info.type = MEDIA_ENT_T_V4L2_SUBDEV;
    assert(mc.setFormat(0, &format, 1920, 1080, V4L2_FIELD_NONE) == 0);
    assert(bridgeDevice.writes.size() == count + 1);
    bridge.info.type = MEDIA_ENT_F_VID_IF_BRIDGE;
    string bus;
    assert(mc.getI2CBusAddress("ov08x40", "Intel IPU7 CSI2 0", &bus) == 0);
    assert(bus == "18-0010");
    MediaCtlConf config;
    config.formats.push_back(format);
    config.links.push_back({1, 0, 3, 0, sensor.info.name, receiver.info.name});
    assert(mc.mediaCtlSetup(0, &config, 1920, 1080, V4L2_FIELD_NONE) == 0);
    assert(mc.configured.size() == 1 && mc.configured[0].srcEntity == 2 && mc.configured[0].srcPad == 1);
    assert(mc.mediaCtlSetup(0, &config, 1920, 1080, V4L2_FIELD_NONE) == 0);
    assert(mc.configured.size() == 1 && mc.configured[0].srcEntity == 2);
    bridgeDevice.fail = true;
    assert(mc.mediaCtlSetup(0, &config, 1920, 1080, V4L2_FIELD_NONE) != 0);
    bridgeDevice.fail = false;
    sl[0].sink = rp;
    assert(mc.getI2CBusAddress("ov08x40", "Intel IPU7 CSI2 0", &bus) == 0);
    assert(bus == "18-0010");
    sensor.numLinks = 0;
    count = bridgeDevice.writes.size();
    assert(mc.setFormat(0, &format, 1920, 1080, V4L2_FIELD_NONE) == 0);
    assert(bridgeDevice.writes.size() == count);
    std::cout << "PASS: native and legacy formats, negotiated dimensions, disabled links, errors, sensor discovery, link rewriting and repeated setup\n";
}
'''
with tempfile.TemporaryDirectory(prefix='ipu7-hal-test-') as directory:
    cpp = pathlib.Path(directory) / 'native-cvs.cpp'
    binary = pathlib.Path(directory) / 'native-cvs'
    cpp.write_text(fixture)
    subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-Werror', '-I', str(source_dir / 'include'), str(cpp), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
