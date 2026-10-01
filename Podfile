platform :ios, '17.0'
use_frameworks!

target 'Roamcast' do
  # DJI Mobile SDK V4 – le DJI Mini 2 est supporté sur iOS depuis la 4.16.
  # Phase 0 : vérifier la version exacte + compatibilité Xcode/iOS actuels.
  pod 'DJI-SDK-iOS', '~> 4.16'
  pod 'DJIWidget', '~> 1.6'     # décodage vidéo (DJIVideoPreviewer)
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |c|
      c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
    end
  end
end
