# Copyright (c) 2020 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

module Kintsugi
  class << self
    def remove_redundant_new_target_settings(target)
      remove_added_build_settings_of_new_target(target)
      remove_added_foundations_framework_of_new_target(target)
      remove_added_build_phases_of_new_target(target)
    end

    private

    NEW_TARGET_REDUNDANT_BUILD_SETTINGS =
      %w[SDKROOT CODE_SIGN_IDENTITY OTHER_LDFLAGS SKIP_INSTALL TARGETED_DEVICE_FAMILY
         VALIDATE_PRODUCT ASSETCATALOG_COMPILER_APPICON_NAME LD_RUNPATH_SEARCH_PATHS
         ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME].freeze

    def remove_added_build_settings_of_new_target(target)
      target.build_configurations.each do |configuration|
        NEW_TARGET_REDUNDANT_BUILD_SETTINGS.each do |setting|
          configuration.build_settings.delete(setting)
        end
      end
    end

    def remove_added_foundations_framework_of_new_target(target)
      build_phase = target.build_phases.find do |phase|
        next phase.instance_of?(Xcodeproj::Project::Object::PBXFrameworksBuildPhase)
      end
      return unless build_phase

      build_file_to_remove = build_phase.files.find do |build_file|
        build_file.display_name == "Foundation.framework"
      end
      return unless build_file_to_remove

      file_reference = build_file_to_remove.file_ref
      build_phase.remove_build_file(build_file_to_remove)

      # Remove group "iOS" created for this framework.
      file_reference.referrers.first.remove_from_project
      file_reference.remove_from_project
    end

    def remove_added_build_phases_of_new_target(target)
      # It seems like even if all build phases are removed, a default "Framework" build phase still
      # remains.
      target.build_phases.each do |phase|
        phase.remove_from_project
      end
    end
  end
end
