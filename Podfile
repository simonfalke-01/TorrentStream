platform :ios, '26.0'
use_frameworks!

target 'TorrentStream' do
  # libVLC 4 for iOS: MKV/AVI/WebM/HEVC playback, tracks, chapters and Picture in Picture.
  pod 'VLCKit', '4.0.0a26'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
    end
  end
end
