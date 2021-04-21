# Copyright (c) 2021 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

class Array
  def delete_value_recursive!(value_to_delete)
    each do |value|
      if value == value_to_delete
        delete(value)
      end

      if value.instance_of?(Hash)
        value.delete_key_recursive!(value_to_delete)
      elsif value.instance_of?(Array)
        value.delete_value_recursive!(value_to_delete)
      end
    end
  end
end

class Hash
  def delete_key_recursive!(key)
    if key?(key)
      delete(key)
    end

    each do |_, value|
      if value.instance_of?(Hash)
        value.delete_key_recursive!(key)
      elsif value.instance_of?(Array)
        value.delete_value_recursive!(key)
      end
    end
  end
end

RSpec::Matchers.define :be_equivalent_to_project do |expected_project, ignored_keys = []|
  def _calculate_project_diff(expected_project, actual_project, ignored_keys)
    expected_project_hash = expected_project.to_tree_hash.dup
    actual_project_hash = actual_project.to_tree_hash.dup

    ignored_keys.each do |ignored_key|
      expected_project_hash.delete_key_recursive!(ignored_key)
      actual_project_hash.delete_key_recursive!(ignored_key)
    end

    diff =
      Xcodeproj::Differ.project_diff(expected_project_hash, actual_project_hash, :expected, :actual)
    diff["rootObject"].delete("displayName")
    diff
  end

  match do |actual_project|
    _calculate_project_diff(expected_project, actual_project, ignored_keys) == {"rootObject" => {}}
  end

  failure_message do |actual_project|
    diff = _calculate_project_diff(expected_project, actual_project, ignored_keys)

    "expected #{actual} to be equivalent to project #{expected}, their difference is:
    #{JSON.pretty_generate(diff)}"
  end
end
