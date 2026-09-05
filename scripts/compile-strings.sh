#!/bin/bash
# Turns Resources/Localizable.xcstrings into <lang>.lproj/Localizable.strings.
# `swift build` copies the catalog verbatim instead of compiling it (only
# Xcode's build system does that), and Foundation only reads .strings at
# runtime, so the compiled tables are generated here and checked in.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
resources="$root/Sources/SysDataMenu/Resources"
catalog="$resources/Localizable.xcstrings"

ruby - "$catalog" "$resources" <<'RUBY'
require "json"

catalog_path, resources = ARGV
catalog = JSON.parse(File.read(catalog_path))
source = catalog.fetch("sourceLanguage")
strings = catalog.fetch("strings")

languages = strings.values.flat_map { |entry| (entry["localizations"] || {}).keys }.uniq
languages |= [source]

def escape(text)
  text.gsub("\\", "\\\\\\\\").gsub('"', '\\"').gsub("\n", "\\n")
end

languages.sort.each do |language|
  lines = strings.keys.sort.map do |key|
    unit = strings.dig(key, "localizations", language, "stringUnit")
    value = unit ? unit["value"] : key
    next if language != source && unit.nil?
    %("#{escape(key)}" = "#{escape(value)}";)
  end.compact
  dir = File.join(resources, "#{language}.lproj")
  Dir.mkdir(dir) unless Dir.exist?(dir)
  File.write(File.join(dir, "Localizable.strings"), lines.join("\n") + "\n")
  puts "#{language}: #{lines.size} strings"
end
RUBY
