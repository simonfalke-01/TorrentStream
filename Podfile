platform :ios, '26.0'
use_frameworks!

target 'TorrentStream' do
  # libVLC for iOS: MKV/AVI/WebM/HEVC playback, audio track + subtitle selection.
  pod 'MobileVLCKit', '~> 3.6'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
    end
  end
end
