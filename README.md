<p align="center">
  <img src="./logo/kintsugi.png" alt="Kintsugi Logo"/>
</p>

# Kintsugi [![Ruby Style Guide](https://img.shields.io/badge/code_style-rubocop-brightgreen.svg)](https://github.com/rubocop/rubocop)

## What is this?

One of the frustrations of working with Xcode together with Git is resolving conflicts in Xcode project files, i.e. the `project.pbxproj` file.

Kintsugi sets out to solve this exact problem: Automatically resolving Git merge conflicts occurring in `.pbxproj` files.

The end goal is for the tool to succeed 99.9% of the time, and let you resolve the real conflicts in a convenient way the rest of the time.

> Kintsugi (金継ぎ) is the art of repairing broken pottery by mending it with gold. [Wikipedia](http://en.wikipedia.org/wiki/Kintsugi)

## How?

Kintsugi understands the changes you've made to the `.pbxproj` file, so it simply resets the conflicts and re-applies those changes to it.

From a technical perspective, Kintsugi heavily relies on [Xcodeproj](https://github.com/CocoaPods/Xcodeproj). It uses its diff capability to extract the changes, and uses its project files editing capabilities to apply the changes.

## Installing Kintsugi

```sh
$ gem install kintsugi
```

If you prefer to use bundler, add the following line to your Gemfile:

```rb
gem 'kintsugi', require: false
```

## Usage

When there's a `.pbxproj` file with Git conflicts, run `kintsugi <path_to_pbxproj_file>`.

And see the magic happen! :sparkles:

## Contribution

See our [Contribution guidelines](./CONTRIBUTING.md).

## Alternatives

- [XcodeGen](https://github.com/yonaskolb/XcodeGen): You can commit this JSON file into Git instead of the `.pbxproj` file. Then resolving conflicts is much easier.

## Copyright

Copyright (c) 2021 Lightricks. See [LICENSE](./LICENSE) for details.
