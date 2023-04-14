#include "mac-sck-common.h"

bool is_screen_capture_available(void)
{
	if (@available(macOS 12.5, *)) {
		return true;
	} else {
		return false;
	}
}

@implementation ScreenCaptureDelegate

- (void)stream:(SCStream *)stream
	didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
		       ofType:(SCStreamOutputType)type
{
	if (self.sc != NULL) {
		if (type == SCStreamOutputTypeScreen) {
			screen_stream_video_update(self.sc, sampleBuffer);
		}
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 130000
		else if (@available(macOS 13.0, *)) {
			if (type == SCStreamOutputTypeAudio) {
				screen_stream_audio_update(self.sc,
							   sampleBuffer);
			}
		}
#endif
	}
}

@end

void screen_capture_build_content_list(struct screen_capture *sc,
				       bool display_capture)
{
	typedef void (^shareable_content_callback)(SCShareableContent *,
						   NSError *);
	shareable_content_callback new_content_received = ^void(
		SCShareableContent *shareable_content, NSError *error) {
		if (error == nil && sc->shareable_content_available != NULL) {
			sc->shareable_content = [shareable_content retain];
		} else {
#ifdef DEBUG
			MACCAP_ERR(
				"screen_capture_properties: Failed to get shareable content with error %s\n",
				[[error localizedFailureReason]
					cStringUsingEncoding:
						NSUTF8StringEncoding]);
#endif
			MACCAP_LOG(
				LOG_WARNING,
				"Unable to get list of available applications or windows. "
				"Please check if OBS has necessary screen capture permissions.");
		}
		os_sem_post(sc->shareable_content_available);
	};

	os_sem_wait(sc->shareable_content_available);
	[sc->shareable_content release];
	[SCShareableContent
		getShareableContentExcludingDesktopWindows:TRUE
				       onScreenWindowsOnly:
					       (display_capture
							? FALSE
							: !sc->show_hidden_windows)
				       completionHandler:new_content_received];
}

bool build_display_list(struct screen_capture *sc, obs_properties_t *props)
{
	os_sem_wait(sc->shareable_content_available);

	obs_property_t *display_list = obs_properties_get(props, "display");
	obs_property_list_clear(display_list);

	[sc->shareable_content.displays enumerateObjectsUsingBlock:^(
						SCDisplay *_Nonnull display,
						NSUInteger idx
						__attribute__((unused)),
						BOOL *_Nonnull stop
						__attribute__((unused))) {
		NSUInteger screen_index = [NSScreen.screens
			indexOfObjectPassingTest:^BOOL(
				NSScreen *_Nonnull screen,
				NSUInteger index __attribute__((unused)),
				BOOL *_Nonnull stop2) {
				NSNumber *screen_num =
					screen.deviceDescription
						[@"NSScreenNumber"];
				CGDirectDisplayID screen_display_id =
					(CGDirectDisplayID)screen_num.intValue;
				*stop2 = (screen_display_id ==
					  display.displayID);

				return *stop2;
			}];
		NSScreen *screen =
			[NSScreen.screens objectAtIndex:screen_index];

		char dimension_buffer[4][12] = {};
		char name_buffer[256] = {};
		snprintf(dimension_buffer[0], sizeof(dimension_buffer[0]), "%u",
			 (uint32_t)screen.frame.size.width);
		snprintf(dimension_buffer[1], sizeof(dimension_buffer[0]), "%u",
			 (uint32_t)screen.frame.size.height);
		snprintf(dimension_buffer[2], sizeof(dimension_buffer[0]), "%d",
			 (int32_t)screen.frame.origin.x);
		snprintf(dimension_buffer[3], sizeof(dimension_buffer[0]), "%d",
			 (int32_t)screen.frame.origin.y);

		snprintf(name_buffer, sizeof(name_buffer),
			 "%.200s: %.12sx%.12s @ %.12s,%.12s",
			 screen.localizedName.UTF8String, dimension_buffer[0],
			 dimension_buffer[1], dimension_buffer[2],
			 dimension_buffer[3]);

		obs_property_list_add_int(display_list, name_buffer,
					  display.displayID);
	}];

	os_sem_post(sc->shareable_content_available);
	return true;
}

bool build_window_list(struct screen_capture *sc, obs_properties_t *props)
{
	os_sem_wait(sc->shareable_content_available);

	obs_property_t *window_list = obs_properties_get(props, "window");
	obs_property_list_clear(window_list);

	[sc->shareable_content.windows enumerateObjectsUsingBlock:^(
					       SCWindow *_Nonnull window,
					       NSUInteger idx
					       __attribute__((unused)),
					       BOOL *_Nonnull stop
					       __attribute__((unused))) {
		NSString *app_name = window.owningApplication.applicationName;
		NSString *title = window.title;

		if (!sc->show_empty_names) {
			if (app_name == NULL || title == NULL) {
				return;
			} else if ([app_name isEqualToString:@""] ||
				   [title isEqualToString:@""]) {
				return;
			}
		}

		const char *list_text =
			[[NSString stringWithFormat:@"[%@] %@", app_name, title]
				UTF8String];
		obs_property_list_add_int(window_list, list_text,
					  window.windowID);
	}];

	os_sem_post(sc->shareable_content_available);
	return true;
}

bool build_application_list(struct screen_capture *sc, obs_properties_t *props)
{
	os_sem_wait(sc->shareable_content_available);

	obs_property_t *application_list =
		obs_properties_get(props, "application");
	obs_property_list_clear(application_list);

	[sc->shareable_content.applications
		enumerateObjectsUsingBlock:^(
			SCRunningApplication *_Nonnull application,
			NSUInteger idx __attribute__((unused)),
			BOOL *_Nonnull stop __attribute__((unused))) {
			const char *name =
				[application.applicationName UTF8String];
			const char *bundle_id =
				[application.bundleIdentifier UTF8String];
			if (strcmp(name, "") != 0)
				obs_property_list_add_string(application_list,
							     name, bundle_id);
		}];

	os_sem_post(sc->shareable_content_available);
	return true;
}

static inline void screen_stream_audio_update(struct screen_capture *sc,
					      CMSampleBufferRef sample_buffer)
{
	CMFormatDescriptionRef format_description =
		CMSampleBufferGetFormatDescription(sample_buffer);
	const AudioStreamBasicDescription *audio_description =
		CMAudioFormatDescriptionGetStreamBasicDescription(
			format_description);

	char *_Nullable bytes = NULL;
	CMBlockBufferRef data_buffer =
		CMSampleBufferGetDataBuffer(sample_buffer);
	size_t data_buffer_length = CMBlockBufferGetDataLength(data_buffer);
	CMBlockBufferGetDataPointer(data_buffer, 0, &data_buffer_length, NULL,
				    &bytes);

	CMTime presentation_time =
		CMSampleBufferGetOutputPresentationTimeStamp(sample_buffer);

	struct obs_source_audio audio_data = {};

	for (uint32_t channel_idx = 0;
	     channel_idx < audio_description->mChannelsPerFrame;
	     ++channel_idx) {
		uint32_t offset =
			(uint32_t)(data_buffer_length /
				   audio_description->mChannelsPerFrame) *
			channel_idx;
		audio_data.data[channel_idx] = (uint8_t *)bytes + offset;
	}

	audio_data.frames = (uint32_t)(data_buffer_length /
				       audio_description->mBytesPerFrame /
				       audio_description->mChannelsPerFrame);
	audio_data.speakers = audio_description->mChannelsPerFrame;
	audio_data.samples_per_sec = (uint32_t)audio_description->mSampleRate;
	audio_data.timestamp =
		(uint64_t)CMTimeGetSeconds(presentation_time) * NSEC_PER_SEC;
	audio_data.format = AUDIO_FORMAT_FLOAT_PLANAR;
	obs_source_output_audio(sc->source, &audio_data);
}

static inline void screen_stream_video_update(struct screen_capture *sc,
					      CMSampleBufferRef sample_buffer)
{
	bool frame_detail_errored = false;
	float scale_factor = 1.0f;
	CGRect window_rect = {};

	CFArrayRef attachments_array =
		CMSampleBufferGetSampleAttachmentsArray(sample_buffer, false);
	if (sc->capture_type == ScreenCaptureWindowStream &&
	    attachments_array != NULL &&
	    CFArrayGetCount(attachments_array) > 0) {
		CFDictionaryRef attachments_dict =
			CFArrayGetValueAtIndex(attachments_array, 0);
		if (attachments_dict != NULL) {

			CFTypeRef frame_scale_factor = CFDictionaryGetValue(
				attachments_dict, SCStreamFrameInfoScaleFactor);
			if (frame_scale_factor != NULL) {
				Boolean result = CFNumberGetValue(
					(CFNumberRef)frame_scale_factor,
					kCFNumberFloatType, &scale_factor);
				if (result == false) {
					scale_factor = 1.0f;
					frame_detail_errored = true;
				}
			}

			CFTypeRef content_rect_dict = CFDictionaryGetValue(
				attachments_dict, SCStreamFrameInfoContentRect);
			CFTypeRef content_scale_factor = CFDictionaryGetValue(
				attachments_dict,
				SCStreamFrameInfoContentScale);
			if ((content_rect_dict != NULL) &&
			    (content_scale_factor != NULL)) {
				CGRect content_rect = {};
				float points_to_pixels = 0.0f;

				Boolean result =
					CGRectMakeWithDictionaryRepresentation(
						(__bridge CFDictionaryRef)
							content_rect_dict,
						&content_rect);
				if (result == false) {
					content_rect = CGRectZero;
					frame_detail_errored = true;
				}
				result = CFNumberGetValue(
					(CFNumberRef)content_scale_factor,
					kCFNumberFloatType, &points_to_pixels);
				if (result == false) {
					points_to_pixels = 1.0f;
					frame_detail_errored = true;
				}

				window_rect.origin = content_rect.origin;
				window_rect.size.width =
					content_rect.size.width /
					points_to_pixels * scale_factor;
				window_rect.size.height =
					content_rect.size.height /
					points_to_pixels * scale_factor;
			}
		}
	}

	CVImageBufferRef image_buffer =
		CMSampleBufferGetImageBuffer(sample_buffer);

	CVPixelBufferLockBaseAddress(image_buffer, 0);
	IOSurfaceRef frame_surface = CVPixelBufferGetIOSurface(image_buffer);
	CVPixelBufferUnlockBaseAddress(image_buffer, 0);

	IOSurfaceRef prev_current = NULL;

	if (frame_surface && !pthread_mutex_lock(&sc->mutex)) {

		bool needs_to_update_properties = false;

		if (!frame_detail_errored) {
			if (sc->capture_type == ScreenCaptureWindowStream) {
				if ((sc->frame.size.width !=
				     window_rect.size.width) ||
				    (sc->frame.size.height !=
				     window_rect.size.height)) {
					sc->frame.size.width =
						window_rect.size.width;
					sc->frame.size.height =
						window_rect.size.height;
					needs_to_update_properties = true;
				}
			} else {
				size_t width =
					CVPixelBufferGetWidth(image_buffer);
				size_t height =
					CVPixelBufferGetHeight(image_buffer);

				if ((sc->frame.size.width != width) ||
				    (sc->frame.size.height != height)) {
					sc->frame.size.width = width;
					sc->frame.size.height = height;
					needs_to_update_properties = true;
				}
			}
		}

		if (needs_to_update_properties) {
			[sc->stream_properties
				setWidth:(size_t)sc->frame.size.width];
			[sc->stream_properties
				setHeight:(size_t)sc->frame.size.height];

			[sc->disp
				updateConfiguration:sc->stream_properties
				  completionHandler:^(
					  NSError *_Nullable error) {
					  if (error) {
						  MACCAP_ERR(
							  "screen_stream_video_update: Failed to update stream properties with error %s\n",
							  [[error localizedFailureReason]
								  cStringUsingEncoding:
									  NSUTF8StringEncoding]);
					  }
				  }];
		}

		prev_current = sc->current;
		sc->current = frame_surface;
		CFRetain(sc->current);
		IOSurfaceIncrementUseCount(sc->current);

		pthread_mutex_unlock(&sc->mutex);
	}

	if (prev_current) {
		IOSurfaceDecrementUseCount(prev_current);
		CFRelease(prev_current);
	}
}
