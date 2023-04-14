#include "mac-sck-common.h"

const char *sck_audio_capture_getname(void *unused __attribute__((unused)))
{
	return obs_module_text("SCK.Audio.Name");
}

static void destroy_audio_screen_stream(struct screen_capture *sc)
{
	if (sc->disp) {
		[sc->disp stopCaptureWithCompletionHandler:^(
				  NSError *_Nullable error) {
			if (error && error.code != 3808) {
				MACCAP_ERR(
					"destroy_audio_screen_stream: Failed to stop stream with error %s\n",
					[[error localizedFailureReason]
						cStringUsingEncoding:
							NSUTF8StringEncoding]);
			}
			os_event_signal(sc->disp_finished);
		}];
		os_event_wait(sc->disp_finished);
	}

	if (sc->stream_properties) {
		[sc->stream_properties release];
		sc->stream_properties = NULL;
	}

	if (sc->disp) {
		[sc->disp release];
		sc->disp = NULL;
	}

	os_event_destroy(sc->disp_finished);
	os_event_destroy(sc->stream_start_completed);
}

static void sck_audio_capture_destroy(void *data)
{
	struct screen_capture *sc = data;

	if (!sc)
		return;

	obs_enter_graphics();

	destroy_audio_screen_stream(sc);

	obs_leave_graphics();

	if (sc->shareable_content) {
		os_sem_wait(sc->shareable_content_available);
		[sc->shareable_content release];
		os_sem_destroy(sc->shareable_content_available);
		sc->shareable_content_available = NULL;
	}

	if (sc->capture_delegate) {
		[sc->capture_delegate release];
	}
	[sc->application_id release];

	pthread_mutex_destroy(&sc->mutex);
	bfree(sc);
}

static bool init_audio_screen_stream(struct screen_capture *sc)
{
	SCContentFilter *content_filter;

	sc->stream_properties = [[SCStreamConfiguration alloc] init];
	os_sem_wait(sc->shareable_content_available);

	SCDisplay * (^get_target_display)() = ^SCDisplay *()
	{
		__block SCDisplay *target_display = nil;
		[sc->shareable_content.displays
			indexOfObjectPassingTest:^BOOL(
				SCDisplay *_Nonnull display, NSUInteger idx,
				BOOL *_Nonnull stop) {
				if (display.displayID == sc->display) {
					target_display = sc->shareable_content
								 .displays[idx];
					*stop = TRUE;
				}
				return *stop;
			}];
		return target_display;
	};

	void (^set_display_mode)(struct screen_capture *, SCDisplay *) = ^void(
		struct screen_capture *sc2, SCDisplay *target_display) {
		CGDisplayModeRef display_mode =
			CGDisplayCopyDisplayMode(target_display.displayID);
		[sc2->stream_properties
			setWidth:CGDisplayModeGetPixelWidth(display_mode)];
		[sc2->stream_properties
			setHeight:CGDisplayModeGetPixelHeight(display_mode)];
		CGDisplayModeRelease(display_mode);
	};

	switch (sc->capture_type) {
	case ScreenCaptureAudioDesktopStream: {
		SCDisplay *target_display = get_target_display();

		content_filter = [[SCContentFilter alloc]
			 initWithDisplay:target_display
			excludingWindows:[[NSArray alloc] init]];

		set_display_mode(sc, target_display);
	} break;
	case ScreenCaptureAudioApplicationStream: {
		SCDisplay *target_display = get_target_display();
		__block SCRunningApplication *target_application = nil;
		{
			[sc->shareable_content.applications
				indexOfObjectPassingTest:^BOOL(
					SCRunningApplication
						*_Nonnull application,
					NSUInteger idx, BOOL *_Nonnull stop) {
					if ([application.bundleIdentifier
						    isEqualToString:
							    sc->
							    application_id]) {
						target_application =
							sc->shareable_content
								.applications
									[idx];
						*stop = TRUE;
					}
					return *stop;
				}];
		}
		NSArray *target_application_array = [[NSArray alloc]
			initWithObjects:target_application, nil];

		content_filter = [[SCContentFilter alloc]
			      initWithDisplay:target_display
			includingApplications:target_application_array
			     exceptingWindows:[[NSArray alloc] init]];

		set_display_mode(sc, target_display);
	} break;
	}
	os_sem_post(sc->shareable_content_available);
	[sc->stream_properties setQueueDepth:8];

	[sc->stream_properties setCapturesAudio:TRUE];
	[sc->stream_properties setExcludesCurrentProcessAudio:TRUE];
	[sc->stream_properties setChannelCount:2];

	sc->disp = [[SCStream alloc] initWithFilter:content_filter
				      configuration:sc->stream_properties
					   delegate:nil];

	NSError *error = nil;
	BOOL did_add_output = [sc->disp addStreamOutput:sc->capture_delegate
						   type:SCStreamOutputTypeAudio
				     sampleHandlerQueue:nil
						  error:&error];
	if (!did_add_output) {
		MACCAP_ERR(
			"init_audio_screen_stream: Failed to add audio stream output with error %s\n",
			[[error localizedFailureReason]
				cStringUsingEncoding:NSUTF8StringEncoding]);
		[error release];
		return !did_add_output;
	}
	os_event_init(&sc->disp_finished, OS_EVENT_TYPE_MANUAL);
	os_event_init(&sc->stream_start_completed, OS_EVENT_TYPE_MANUAL);

	__block BOOL did_stream_start = false;
	[sc->disp startCaptureWithCompletionHandler:^(
			  NSError *_Nullable error2) {
		did_stream_start = (BOOL)(error2 == nil);
		if (!did_stream_start) {
			MACCAP_ERR(
				"init_audio_screen_stream: Failed to start capture with error %s\n",
				[[error localizedFailureReason]
					cStringUsingEncoding:
						NSUTF8StringEncoding]);
			// Clean up disp so it isn't stopped
			[sc->disp release];
			sc->disp = NULL;
		}
		os_event_signal(sc->stream_start_completed);
	}];
	os_event_wait(sc->stream_start_completed);

	MACCAP_ERR("init closing, returning %d\n", did_stream_start);
	return did_stream_start;
}

static void sck_audio_capture_defaults(obs_data_t *settings)
{
	CGDirectDisplayID initial_display = 0;
	{
		NSScreen *mainScreen = [NSScreen mainScreen];
		if (mainScreen) {
			NSNumber *screen_num =
				mainScreen.deviceDescription[@"NSScreenNumber"];
			if (screen_num) {
				initial_display =
					(CGDirectDisplayID)(uintptr_t)
						screen_num.pointerValue;
			}
		}
	}

	obs_data_set_default_int(settings, "display", initial_display);

	obs_data_set_default_obj(settings, "application", NULL);
	obs_data_set_default_int(settings, "type",
				 ScreenCaptureAudioDesktopStream);
}

static void *sck_audio_capture_create(obs_data_t *settings,
				      obs_source_t *source)
{
	struct screen_capture *sc = bzalloc(sizeof(struct screen_capture));

	sc->source = source;
	sc->capture_type = (unsigned int)obs_data_get_int(settings, "type");
	sc->audio_only = true;

	os_sem_init(&sc->shareable_content_available, 1);
	screen_capture_build_content_list(
		sc, sc->capture_type == ScreenCaptureAudioDesktopStream);

	sc->capture_delegate = [[ScreenCaptureDelegate alloc] init];
	sc->capture_delegate.sc = sc;

	sc->display = (CGDirectDisplayID)obs_data_get_int(settings, "display");
	sc->application_id = [[NSString alloc]
		initWithUTF8String:obs_data_get_string(settings,
						       "application")];
	pthread_mutex_init(&sc->mutex, NULL);

	if (!init_audio_screen_stream(sc))
		goto fail;

	return sc;

fail:
	obs_leave_graphics();
	sck_audio_capture_destroy(sc);
	return NULL;
}

#pragma mark - obs_properties

static bool audio_content_settings_changed(void *data, obs_properties_t *props,
					   obs_property_t *list __unused,
					   obs_data_t *settings)
{
	struct screen_capture *sc = data;

	unsigned int capture_type_id =
		(unsigned int)obs_data_get_int(settings, "type");
	obs_property_t *app_list = obs_properties_get(props, "application");
	obs_property_t *capture_type_error =
		obs_properties_get(props, "capture_type_info");

	if (sc->capture_type != capture_type_id) {
		switch (capture_type_id) {
		case 0: {
			obs_property_set_visible(app_list, false);

			if (capture_type_error) {
				obs_property_set_visible(capture_type_error,
							 true);
			}
			break;
		}
		case 1: {
			obs_property_set_visible(app_list, true);

			if (capture_type_error) {
				obs_property_set_visible(capture_type_error,
							 false);
			}
			break;
		}
		}
	}

	screen_capture_build_content_list(
		sc, capture_type_id == ScreenCaptureAudioDesktopStream);
	build_application_list(sc, props);

	return true;
}

static obs_properties_t *sck_audio_capture_properties(void *data)
{
	struct screen_capture *sc = data;

	obs_properties_t *props = obs_properties_create();

	obs_property_t *capture_type = obs_properties_add_list(
		props, "type", obs_module_text("SCK.Method"),
		OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_INT);

	obs_property_list_add_int(capture_type,
				  obs_module_text("DesktopAudioCapture"), 0);
	obs_property_list_add_int(
		capture_type, obs_module_text("ApplicationAudioCapture"), 1);

	obs_property_set_modified_callback2(
		capture_type, audio_content_settings_changed, data);

	obs_property_t *app_list = obs_properties_add_list(
		props, "application", obs_module_text("Application"),
		OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);

	if (sc) {
		//obs_property_set_modified_callback2(
		//empty, content_settings_changed, sc);

		switch (sc->capture_type) {
		case 0: {
			obs_property_set_visible(app_list, false);
			break;
		}
		case 1: {
			obs_property_set_visible(app_list, true);
			break;
		}
		}

		//obs_property_set_modified_callback2(
		//empty, content_settings_changed, sc);
	}

	return props;
}

static void sck_audio_capture_update(void *data, obs_data_t *settings)
{
	struct screen_capture *sc = data;

	ScreenCaptureAudioStreamType capture_type =
		(ScreenCaptureAudioStreamType)obs_data_get_int(settings,
							       "type");
	NSString *application_id = [[NSString alloc]
		initWithUTF8String:obs_data_get_string(settings,
						       "application")];

	obs_enter_graphics();

	destroy_audio_screen_stream(sc);
	sc->capture_type = capture_type;
	[sc->application_id release];
	sc->application_id = application_id;
	init_audio_screen_stream(sc);

	obs_leave_graphics();
}

#pragma mark - obs_source_info

struct obs_source_info sck_audio_capture_info = {
	.id = "sck_audio_capture",
	.type = OBS_SOURCE_TYPE_INPUT,
	.get_name = sck_audio_capture_getname,

	.create = sck_audio_capture_create,
	.destroy = sck_audio_capture_destroy,

	.output_flags = OBS_SOURCE_DO_NOT_DUPLICATE | OBS_SOURCE_AUDIO,

	.get_defaults = sck_audio_capture_defaults,
	.get_properties = sck_audio_capture_properties,
	.update = sck_audio_capture_update,
	.icon_type = OBS_ICON_TYPE_AUDIO_OUTPUT,
};
