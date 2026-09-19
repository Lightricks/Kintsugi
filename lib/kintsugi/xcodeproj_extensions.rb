# Copyright (c) 2021 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

require "xcodeproj"

module Xcodeproj
  class Project
    # Returns the group found at `path`. If `path` is empty returns the main group. Returns `nil` if
    # the group at path was not found.
    #
    # @param  [String] Path to the group.
    #
    # @return [PBXGroup/PBXVariantGroup/PBXFileReference]
    def group_or_file_at_path(path)
      return self.main_group if path.empty?

      # A path segment may traverse a `PBXFileSystemSynchronizedRootGroup` (Xcode 16 buildable
      # folder), whose contents are implicit and not navigable objects. `find_subpath` raises a
      # `NoMethodError` in that case; there is no explicit object at such a path, so return `nil`.
      begin
        self[path]
      rescue NoMethodError
        nil
      end
    end

    # Extends `ObjectDictionary` to act like an `Object` if `self` repreresents a project reference.
    class ObjectDictionary
      @@old_to_tree_hash = instance_method(:to_tree_hash)

      def to_tree_hash
        result = @@old_to_tree_hash.bind(self).call
        self[:project_ref] ? result.merge("displayName" => display_name) : result
      end

      def display_name
        project_ref.display_name
      end

      def product_group
        self[:product_group]
      end

      def project_ref
        self[:project_ref]
      end
    end

    module Object
      # Modifies `PBXContainerItemProxy` to include relevant data in `displayName`.
      # Currently, its `display_name` is just a constant for all `PBXContainerItemProxy` objects.
      class PBXContainerItemProxy
        def display_name
          "#{self.remote_info} (#{self.remote_global_id_string})"
        end
      end

      # Modifies `PBXReferenceProxy` to include more data in `displayName` to make it unique.
      class PBXReferenceProxy
        @@old_display_name = instance_method(:display_name)

        def display_name
          if self.remote_ref.nil?
            @@old_display_name.bind(self).call
          else
            @@old_display_name.bind(self).call + " - " + self.remote_ref.display_name
          end
        end
      end

      # Modifies `PBXBuildFile` to calculate `ascii_plist_annotation` based on the underlying
      # object's `ascii_plist_annotation` instead of relying on its `display_name`, as
      # `display_name` might contain information that shouldn't be written to the project.
      class PBXBuildFile
        def ascii_plist_annotation
          underlying_annotation =
            if product_ref
              product_ref.ascii_plist_annotation
            elsif file_ref
              file_ref.ascii_plist_annotation
            else
              super
            end

          " #{underlying_annotation.strip} in #{GroupableHelper.parent(self).display_name} "
        end
      end

      # Extends `XCBuildConfiguration` to convert array settings (which might be either array or
      # string) to actual arrays in `to_tree_hash` so diffs are always between arrays. This means
      # that if the values in both `ours` and `theirs` are different strings, we will know to solve
      # the conflict into an array containing both strings.
      # Code was mostly copied from https://github.com/CocoaPods/Xcodeproj/blob/master/lib/xcodeproj/project/object/build_configuration.rb#L211
      class XCBuildConfiguration
        @@old_to_tree_hash = instance_method(:to_tree_hash)

        def to_tree_hash
          @@old_to_tree_hash.bind(self).call.tap do |hash|
            convert_array_settings_to_arrays(hash['buildSettings'])
          end
        end

        def convert_array_settings_to_arrays(settings)
          return unless settings

          array_settings = BuildSettingsArraySettingsByObjectVersion[project.object_version]

          settings.each_key do |key|
            value = settings[key]
            next unless value.is_a?(String)

            stripped_key = key.sub(/\[[^\]]+\]$/, '')
            next unless array_settings.include?(stripped_key)

            array_value = split_string_setting_into_array(value)
            settings[key] = array_value
          end
        end

        def split_string_setting_into_array(string)
          string.scan(/ *((['"]?).*?[^\\]\2)(?=( |\z))/).map(&:first)
        end
      end

      # Modifies `PBXTargetDependency`'s `to_tree_hash` to not crash if `target_proxy` is `nil`.
      # The same fix was done in https://github.com/CocoaPods/Xcodeproj/pull/915/.
      class PBXTargetDependency
        def to_tree_hash
          hash = {}
          hash['displayName'] = display_name
          hash['isa'] = isa
          hash['targetProxy'] = target_proxy.to_tree_hash if target_proxy
          hash
        end
      end

      # Modifies `PBXFileSystemSynchronizedBuildFileExceptionSet`'s `to_tree_hash` to serialize its
      # `target` as a reference (by display name) instead of recursing into it. Without this, the
      # target expands into a hash that contains the synchronized root group owning this exception
      # set, which owns this exception set, causing infinite recursion.
      class PBXFileSystemSynchronizedBuildFileExceptionSet
        # xcodeproj 1.27.0's `display_name` interpolates `#{target.name}`; guard against a nil target
        # (which occurs transiently while the target reference is resolved) to avoid `NoMethodError`
        # during serialization or tree hashing. `GroupableHelper.parent` raises (and re-interpolates
        # `display_name`, recursing to a stack overflow) when the set has no referrers, so only call
        # it when a parent actually exists.
        def display_name
          folder_name = referrers.empty? ? nil : GroupableHelper.parent(self)&.display_name
          "Exceptions for \"#{folder_name}\" folder in \"#{target&.name}\" target"
        end

        def to_tree_hash
          hash = { 'displayName' => display_name, 'isa' => isa }
          self.class.simple_attributes.each do |attribute|
            value = attribute.get_value(self)
            hash[attribute.plist_name] = value unless value.nil?
          end
          hash['target'] = target.display_name if target
          hash
        end
      end

      # Same fix as `PBXFileSystemSynchronizedBuildFileExceptionSet`, for the build phase membership
      # variant, whose recursing reference is `build_phase`.
      class PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet
        # xcodeproj 1.27.0's `display_name` calls `build_phase.name`, which build phases don't
        # implement, raising `NoMethodError` on any serialization or tree hash of this object. Use
        # the build phase's `display_name` (e.g. "Sources") instead. Also guard the parent lookup,
        # which otherwise raises and recurses to a stack overflow when the set has no referrers.
        def display_name
          folder_name = referrers.empty? ? nil : GroupableHelper.parent(self)&.display_name
          "Exceptions for \"#{folder_name}\" folder in \"#{build_phase&.display_name}\" build phase"
        end

        def to_tree_hash
          hash = { 'displayName' => display_name, 'isa' => isa }
          self.class.simple_attributes.each do |attribute|
            value = attribute.get_value(self)
            hash[attribute.plist_name] = value unless value.nil?
          end
          hash['buildPhase'] = build_phase_reference if build_phase
          hash
        end

        # Serializes `build_phase` as a reference that also carries its owning target, so it can be
        # resolved unambiguously even when the owning group is shared by multiple targets that each
        # have a build phase with the same name (e.g. "Sources").
        def build_phase_reference
          reference = { 'name' => build_phase.display_name }
          # Match by UUID: xcodeproj compares build phases by value, so `include?` would match a
          # same-named empty phase on an unrelated target.
          owning_target = build_phase.project.native_targets.find do |target|
            target.build_phases.any? { |phase| phase.uuid == build_phase.uuid }
          end
          reference['target'] = owning_target.display_name unless owning_target.nil?
          reference
        end
      end

      # By default, for this type, the `display_name` is used when calling `ascii_plist_annotation` (which is used
      # to serialize the project to disk). In the case where the `display_name` contains a "plugin:" prefix, which
      # means that the package is a plugin, the prefix is ommitted so just the package name is used.
      # This, of course can be implemented in a better way, like adding a field to this object as plugin, marking it
      # as a plugin, but this is a very simple way to achieve the desired result.
      class XCSwiftPackageProductDependency
        def ascii_plist_annotation
          " #{display_name.delete_prefix("plugin:")} "
        end
      end

      # The original implementation is  `" #{isa} \"#{File.basename(display_name)}\"` so that means that if we have a
      # relative path which is Path/To/Package, the item will be serialized as `XCLocalSwiftPackageReference "Package"`.
      # And Xcode will automatically fix this to be `XCLocalSwiftPackageReference "Path/To/Package"`.
      # So, we need to patch the implementation and make sure the whole path is used.
      class XCLocalSwiftPackageReference
        def ascii_plist_annotation
          " #{isa} \"#{display_name}\" "
        end
      end
    end
  end

  module Differ
      # Replaces the implementation of `array_diff` with an implementation that takes into account
      # the number of occurrences an element is found in the array.
      # Code was mostly copied from https://github.com/CocoaPods/Xcodeproj/blob/51fb78a03f31614103815ce21c56dc25c044a10d/lib/xcodeproj/differ.rb#L111
      def self.array_diff(value_1, value_2, options)
      ensure_class(value_1, Array)
      ensure_class(value_2, Array)
      return nil if value_1 == value_2

      new_objects_value_1 = array_non_unique_diff(value_1, value_2)
      new_objects_value_2 = array_non_unique_diff(value_2, value_1)
      return nil if value_1.empty? && value_2.empty?

      matched_diff = {}
      if id_key = options[:id_key]
        matched_value_1 = []
        matched_value_2 = []
        new_objects_value_1.each do |entry_value_1|
          if entry_value_1.is_a?(Hash)
            id_value = entry_value_1[id_key]
            entry_value_2 = new_objects_value_2.find do |entry|
              entry[id_key] == id_value
            end
            if entry_value_2
              matched_value_1 << entry_value_1
              matched_value_2 << entry_value_2
              diff = diff(entry_value_1, entry_value_2, options)
              matched_diff[id_value] = diff if diff
            end
          end
        end

        new_objects_value_1 -= matched_value_1
        new_objects_value_2 -= matched_value_2
      end

      if new_objects_value_1.empty? && new_objects_value_2.empty?
        if matched_diff.empty?
          nil
        else
          matched_diff
        end
      else
        result = {}
        result[options[:key_1]] = new_objects_value_1 unless new_objects_value_1.empty?
        result[options[:key_2]] = new_objects_value_2 unless new_objects_value_2.empty?
        result[:diff] = matched_diff unless matched_diff.empty?
        result
      end
    end

    # Returns the difference between two arrays, taking into account the number of occurrences an
    # element is found in both arrays.
    #
    # @param  [Array] value_1
    #         First array to the difference operation.
    #
    # @param  [Array] value_2
    #         Second array to the difference operation.
    #
    # @return [Array]
    def self.array_non_unique_diff(value_1, value_2)
      value_2_elements_by_count = value_2.reduce({}) do |hash, element|
        updated_element_hash = hash.key?(element) ? {element => hash[element] + 1} : {element => 1}
        hash.merge(updated_element_hash)
      end

      value_1_elements_by_deletions =
        value_1.to_set.map do |element|
          times_to_delete_element = value_2_elements_by_count[element] || 0
          [element, times_to_delete_element]
        end.to_h

      value_1.select do |element|
        if value_1_elements_by_deletions[element].positive?
          value_1_elements_by_deletions[element] -= 1
          next false
        end
        next true
      end
    end
  end
end
