import Foundation

@_cdecl("catap_audio_capture_getname")
func catap_audio_capture_getname(_ data: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
  return obs_module_text("CATap.Name")
}

@_cdecl("catap_audio_capture_create")
func catap_audio_capture_create(settings: OpaquePointer?, source: OpaquePointer?) -> UnsafeMutableRawPointer? {
  return nil
}

@_cdecl("catap_audio_capture_destroy")
func catap_audio_capture_destroy(_ data: UnsafeMutableRawPointer?) -> Void {

}

@_cdecl("catap_audio_capture_defaults")
func catap_audio_capture_defaults(settings: OpaquePointer?) -> Void {

}

@_cdecl("catap_audio_capture_properties")
func catap_audio_capture_properties(_ data: UnsafeMutableRawPointer?) -> OpaquePointer? {
  return nil
}

@_cdecl("catap_audio_capture_update")
func catap_audio_capture_update(data: UnsafeMutableRawPointer?, settings: OpaquePointer?) -> Void {

}

/// Returns `obs_source_info` struct *without* populating the `id` C string field.
@_cdecl("create_catap_source")
func create_catap_source() -> obs_source_info {
  var outputInfo = obs_source_info()
  /*moduleID.withCString({
    /*withUnsafeMutablePointer(to: &outputInfo.id) { structPtr in
      let raw = UnsafeMutableRawPointer(mutating: structPtr)
      strncpy(raw, cString, moduleID.count + 1)
    }*/
    //outputInfo.id = $0
  })*/
  outputInfo.type = OBS_SOURCE_TYPE_INPUT
  outputInfo.output_flags = UInt32(OBS_SOURCE_DO_NOT_DUPLICATE | OBS_SOURCE_AUDIO)
  outputInfo.get_name = catap_audio_capture_getname
  outputInfo.create = catap_audio_capture_create
  outputInfo.destroy = catap_audio_capture_destroy
  outputInfo.get_defaults = catap_audio_capture_defaults
  outputInfo.get_properties = catap_audio_capture_properties
  outputInfo.update = catap_audio_capture_update
  outputInfo.icon_type = OBS_ICON_TYPE_AUDIO_INPUT
  return outputInfo
}
