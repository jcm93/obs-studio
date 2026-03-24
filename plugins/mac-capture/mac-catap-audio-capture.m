#include "mac-sck-common.h"

const char *catap_audio_capture_getname(void *unused __unused)
{
    return obs_module_text("CATap.Audio.Name");
}

API_AVAILABLE(macos(14.2)) static void destroy_audio_screen_stream(struct catap_capture *cc)
{

}

API_AVAILABLE(macos(14.2)) static void catap_audio_capture_destroy(void *data)
{
    struct catap_capture *cc = data;
}

API_AVAILABLE(macos(14.2)) static bool init_audio_catap_stream(struct catap_capture *cc)
{
  CATapDescription *desc = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
  OSStatus status = AudioHardwareCreateProcessTap(desc, &cc->tapID);
  if (status != noErr) {
    blog(LOG_ERROR, "AudioHardwareCreateProcessTap failed with error: %d", status);
  }

  return true;
}

static void catap_audio_capture_defaults(obs_data_t *settings)
{

}

API_AVAILABLE(macos(14.2)) static void *catap_audio_capture_create(obs_data_t *settings, obs_source_t *source)
{
    struct catap_capture *cc = bzalloc(sizeof(struct catap_capture));
}

#pragma mark - obs_properties

API_AVAILABLE(macos(14.2))
static bool audio_capture_method_changed(void *data, obs_properties_t *props, obs_property_t *list __unused,
                                         obs_data_t *settings)
{

}

API_AVAILABLE(macos(14.2))
static bool reactivate_capture(obs_properties_t *props __unused, obs_property_t *property, void *data)
{

}

API_AVAILABLE(macos(14.2)) static obs_properties_t *catap_audio_capture_properties(void *data)
{

}

API_AVAILABLE(macos(14.2)) static void catap_audio_capture_update(void *data, obs_data_t *settings)
{

}

#pragma mark - obs_source_info

API_AVAILABLE(macos(14.2))
struct obs_source_info catap_audio_capture_info = {
    .id = "catap_audio_capture",
    .type = OBS_SOURCE_TYPE_INPUT,
    .get_name = catap_audio_capture_getname,

    .create = catap_audio_capture_create,
    .destroy = catap_audio_capture_destroy,

    .output_flags = OBS_SOURCE_DO_NOT_DUPLICATE | OBS_SOURCE_AUDIO,

    .get_defaults = catap_audio_capture_defaults,
    .get_properties = catap_audio_capture_properties,
    .update = catap_audio_capture_update,
    .icon_type = OBS_ICON_TYPE_AUDIO_OUTPUT,
};
