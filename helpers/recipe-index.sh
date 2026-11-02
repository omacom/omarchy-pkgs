# Reading a recipe index (bin/recipe-index): one line per package directory
# and architecture, <arch> TAB <pkgbase> TAB <directory> TAB <yes|no>.
#
# recipe_index_load <file> <arch>: fills RECIPE[pkgbase] with the recipe's
# directory under PKGBUILDS_DIR and BUILDS[pkgbase] with yes or no, for that
# architecture. A line that is not one, a directory this checkout lacks, or
# two directories naming one pkgbase (which of them counts would be an
# accident of order) is an error on stderr and status 1.
# Needs helpers/paths.sh and helpers/message-helpers.sh.
declare -A RECIPE=() BUILDS=()
recipe_index_load() {
  local file=$1 arch=$2 iarch base dir builds rest
  [[ -f $file ]] || { print_error "No recipe index at $file"; return 1; }
  while IFS=$'\t' read -r iarch base dir builds rest; do
    if [[ -n $rest || ! $base =~ $PACKAGE_NAME_RE || ! $dir =~ $PACKAGE_NAME_RE ]] \
      || ! validate_arch "$iarch" || [[ $builds != "yes" && $builds != "no" ]]; then
      print_error "Not a recipe index line: $iarch $base $dir $builds${rest:+ $rest}"
      return 1
    fi
    [[ $iarch == "$arch" ]] || continue
    [[ -d $PKGBUILDS_DIR/$dir ]] || { print_error "The recipe index names $dir, which this checkout lacks"; return 1; }
    if [[ -n ${RECIPE[$base]:-} ]]; then
      print_error "Two recipes build $base for $arch: ${RECIPE[$base]##*/} and $dir"
      return 1
    fi
    RECIPE[$base]=$PKGBUILDS_DIR/$dir
    BUILDS[$base]=$builds
  done < "$file"
}
