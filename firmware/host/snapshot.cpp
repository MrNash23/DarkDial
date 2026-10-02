// Renders the firmware UI without hardware: the real ui.cpp on a 360x360
// LVGL display in memory, one PPM image per scene. firmware/host/build.sh
// turns them into PNGs.
#include <lvgl.h>
#include <stdio.h>

#include <string>

#include "../darkdial/src/ui.h"
#include "testing.h"

using namespace testing;

static const int kSize = 360;
static uint16_t framebuffer[kSize * kSize];
static uint32_t nowMs = 0;
static std::string outDir = ".";
// Status sent once a second while a scene runs, like the service does; -1 = none.
static int heartbeat = -1;

static uint32_t tick() { return nowMs; }

static void flush(lv_display_t *display, const lv_area_t *, uint8_t *) { lv_display_flush_ready(display); }

/// Lets LVGL run for `ms` of simulated time (animations, refresh).
static void run(dd::Device &device, uint32_t ms) {
  for (uint32_t t = 0; t < ms; t += 10) {
    nowMs += 10;
    if (heartbeat >= 0 && nowMs % 1000 == 0) feed(device, status(static_cast<uint8_t>(heartbeat)), nowMs);
    device.tick(nowMs);
    ui_update(device, nowMs);
    lv_timer_handler();
  }
}

static void save(const char *name) {
  const std::string path = outDir + "/" + name + ".ppm";
  FILE *file = fopen(path.c_str(), "wb");
  if (!file) {
    fprintf(stderr, "cannot write %s\n", path.c_str());
    exit(1);
  }
  fprintf(file, "P6\n%d %d\n255\n", kSize, kSize);
  for (int i = 0; i < kSize * kSize; i++) {
    const uint16_t p = framebuffer[i];
    const uint8_t rgb[3] = {static_cast<uint8_t>(((p >> 11) & 0x1F) * 255 / 31),
                            static_cast<uint8_t>(((p >> 5) & 0x3F) * 255 / 63),
                            static_cast<uint8_t>((p & 0x1F) * 255 / 31)};
    fwrite(rgb, 1, 3, file);
  }
  fclose(file);
  printf("%s\n", name);
}

int main(int argc, char **argv) {
  if (argc > 1) outDir = argv[1];

  lv_init();
  lv_tick_set_cb(tick);
  lv_display_t *display = lv_display_create(kSize, kSize);
  lv_display_set_color_format(display, LV_COLOR_FORMAT_RGB565);
  lv_display_set_flush_cb(display, flush);
  lv_display_set_buffers(display, framebuffer, nullptr, sizeof(framebuffer), LV_DISPLAY_RENDER_MODE_DIRECT);

  RecordingHost host;
  const uint8_t serial[6] = {2, 0, 0x51, 0x4D, 0, 1};
  dd::Device device(host, 0, 1, 0, serial);
  ui_init(nullptr, nullptr, nowMs);

  const uint8_t all = dd::kStatusLightroom | dd::kStatusDevelop | dd::kStatusPhoto;

  run(device, 300);
  save("01_boot_logo");

  run(device, 3000);
  save("02_offline");

  configure(device,
            {
                {3, 3, true, 0, "Belichtung"},
                {13, 13, true, 0, "S\xC3\xA4ttigung"},
                {1, 1, true, 0, "Temperatur"},
                {14, 14, false, 0, "Sch\xC3\xA4rfen"},
                {32, 22, true, 0xFA3A31, "Farbton"},
                {45, 23, true, 0x5394FC, "S\xC3\xA4ttigung"},
                {18, 18, true, 0, "Lichter"},
            },
            0, nowMs);
  feed(device, status(all), nowMs);
  run(device, 300);
  save("03_config_loaded");
  run(device, 1500);

  feed(device, value(0, 10404, true, "+1.35"), nowMs);
  feed(device, value(1, 4096, true, "-50"), nowMs);
  feed(device, value(2, 8192, true, "5500K"), nowMs);
  feed(device, value(3, 4369, true, "40"), nowMs);
  feed(device, value(4, 12000, true, "+46"), nowMs);
  feed(device, value(5, 8192, true, "0"), nowMs);
  feed(device, value(6, 0, true, "-100"), nowMs);
  // The device stays on the parameter it showed before (Temperature).
  run(device, 300);
  save("04_select_temperature_centre");

  device.click();
  run(device, 300);
  save("05_edit_temperature");
  device.click();

  device.rotate(1, nowMs);
  run(device, 60);
  save("06_slide_in_progress");
  run(device, 400);
  save("07_select_sharpen_unipolar");

  device.rotate(1, nowMs);
  run(device, 400);
  save("08_select_hue_red");

  device.rotate(1, nowMs);
  device.click();
  run(device, 400);
  save("09_edit_hsl_saturation_blue");
  device.click();

  device.rotate(1, nowMs);
  device.click();
  run(device, 400);
  save("10_edit_curve_minimum");
  device.click();

  device.rotate(1, nowMs);
  run(device, 400);
  save("11_select_exposure");

  device.rotate(1, nowMs);
  device.click();
  run(device, 400);
  save("12_edit_saturation_negative");
  device.click();

  // Time tracking: hold, menu, running clock.
  heartbeat = all;
  feed(device, status(all), nowMs);
  feed(device, timerState(false, 0, 0, ""), nowMs);
  device.buttonDown(nowMs);
  run(device, 350);
  save("20_hold_ring_fills");
  run(device, 300);
  device.buttonUp(nowMs);
  run(device, 100);
  save("21_menu_waiting_for_page");
  sendMenu(device, 1, "Kunde w\xC3\xA4hlen",
           {{29, 1, "Hochzeit"}, {32, 4, "Fam. M\xC3\xBCller"}, {32, 4, "Verlag"}, {32, 8 | 16, ""}}, nowMs);
  run(device, 300);
  save("22_menu_suggested_job");
  device.rotate(1, nowMs);
  run(device, 400);
  save("23_menu_client");
  device.rotate(2, nowMs);
  run(device, 400);
  save("24_menu_help_last");
  device.rotate(-2, nowMs);
  device.click();
  sendMenu(device, 3, "Fam. M\xC3\xBCller",
           {{29, 0, "Hochzeit"}, {29, 0, "Album"}, {30, 0, "Neuer Job"}, {33, 0, "Zur\xC3\xBC" "ck"}}, nowMs);
  run(device, 300);
  save("25_menu_jobs_of_client");
  device.click();
  feed(device, timerResult(0), nowMs);
  feed(device, timerState(true, 7, 0, "Hochzeit"), nowMs);
  run(device, 300);
  save("26_notice_started");
  run(device, 1500);
  feed(device, timerState(true, 7, 754, "Hochzeit"), nowMs);
  run(device, 300);
  save("27_slot_with_running_time");
  device.buttonDown(nowMs);
  run(device, 700);
  device.buttonUp(nowMs);
  sendMenu(device, 4, "Kunde w\xC3\xA4hlen",
           {{31, 2, "Stopp"}, {29, 3, "Hochzeit"}, {32, 4, "Fam. M\xC3\xBCller"}, {32, 4, "Verlag"}, {32, 8 | 16, ""}},
           nowMs);
  run(device, 300);
  save("28_menu_stop_with_time");
  feed(device, timerState(true, 7, 4 * 3600 + 7 * 60, "Hochzeit"), nowMs);
  device.rotate(1, nowMs);
  run(device, 400);
  save("29_menu_running_job_hours");
  device.rotate(-1, nowMs);
  device.click();
  feed(device, timerResult(1), nowMs);
  feed(device, timerState(false, 0, 0, ""), nowMs);
  run(device, 300);
  save("30_notice_stopped");
  run(device, 1500);
  heartbeat = -1;

  // Lightroom shows the Library: stars, colour label, file name, flag.
  feed(device, library(dd::kLibraryActive | dd::kLibraryTap | dd::kLibraryPicked, 3, 3, "IMG_0042.CR3"), nowMs);
  run(device, 300);
  save("34_library_picked");
  feed(device, library(dd::kLibraryActive | dd::kLibraryRejected, 0, 0, "IMG_0043.CR3"), nowMs);
  run(device, 300);
  save("35_library_rejected");
  feed(device, library(dd::kLibraryActive, 5, 1, "Hochzeit_M\xC3\xBCller_0815"), nowMs);
  run(device, 300);
  save("36_library_stars");
  feed(device, library(0), nowMs);
  run(device, 300);

  feed(device, status(dd::kStatusLightroom | dd::kStatusDevelop), nowMs);
  run(device, 300);
  save("13_no_photo");

  feed(device, status(dd::kStatusLightroom | dd::kStatusPhoto, 1), nowMs);
  run(device, 300);
  save("14_switching_to_develop");

  feed(device, status(0), nowMs);
  for (uint8_t i = 0; i < 7; i++) feed(device, value(i, 0, false, "--"), nowMs);
  run(device, 300);
  save("15_lightroom_closed");

  run(device, dd::kHeartbeatTimeoutMs + 500);
  save("16_heartbeat_lost");

  device.buttonDown(nowMs);
  run(device, 800);
  device.buttonUp(nowMs);
  run(device, 200);
  save("31_menu_offline");

  // Left alone for three minutes: the logo, until someone touches the device.
  run(device, dd::kIdleMs + 1000);
  save("32_idle_logo");
  device.rotate(1, nowMs);
  run(device, 300);
  save("33_awake_again");
  return 0;
}
