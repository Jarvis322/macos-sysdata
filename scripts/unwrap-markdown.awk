# Joins soft-wrapped Markdown into one line per paragraph or list item.
#
# CHANGELOG.md is wrapped at ~78 columns so it reads well in a terminal and a
# diff. GitHub renders every newline in a release body as a line break, so the
# same text published as release notes came out broken mid-sentence. Code
# fences, headings, block quotes, tables and blank lines pass through as-is.

function flush() {
  if (buffer != "") { print buffer; buffer = "" }
}

/^```/ { flush(); print; fenced = !fenced; next }
fenced { print; next }
/^[[:space:]]*$/ { flush(); print; next }
/^(#|>|\|)/ || /^[[:space:]]*([-*+] |[0-9]+\. )/ { flush(); buffer = $0; next }
{
  line = $0
  sub(/^[[:space:]]+/, "", line)
  buffer = (buffer == "") ? $0 : buffer " " line
}
END { flush() }
