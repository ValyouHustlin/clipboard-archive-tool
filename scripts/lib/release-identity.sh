# Release identity, read from one place: the newest CHANGELOG heading of the
# form "## <version> build <number> - <date>".
#
# Build numbers were once hard-coded in four release tools at once, and a
# tool that pointed at a release that had moved either aborted mid-release
# or measured nothing and called it done. Every tool now sources this
# file instead of carrying its own literal.

# Prints "<version> <build>" for the newest numbered entry, or nothing.
release_identity_newest() {
  /usr/bin/awk '
    /^## [0-9]+\.[0-9]+\.[0-9]+ build [0-9]+ - / { print $2, $4; exit }
  ' "$1"
}

# Succeeds when the CHANGELOG has an entry for exactly this version and build.
release_identity_has_entry() {
  /usr/bin/grep -Eq "^## ${2//./\\.} build ${3} - " "$1"
}
