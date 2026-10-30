cmake_minimum_required(VERSION 3.29)
project(BristleQuickLook LANGUAGES Swift)

file(GLOB BRISTLE_CORE ../BristleCore/*.swift)

function(bristle_extension name source framework plist)
  add_executable(${name} MACOSX_BUNDLE ${source} ${BRISTLE_CORE})
  target_link_libraries(${name} PRIVATE "-framework ${framework}")
  set_target_properties(${name} PROPERTIES
    XCODE_PRODUCT_TYPE com.apple.product-type.app-extension
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/${plist}"
    XCODE_ATTRIBUTE_SWIFT_VERSION 6.0
  )
endfunction()

bristle_extension(BristleThumbnail ThumbnailProvider.swift QuickLookThumbnailing ThumbnailInfo.plist)
bristle_extension(BristlePreview PreviewProvider.swift QuickLookUI PreviewInfo.plist)
