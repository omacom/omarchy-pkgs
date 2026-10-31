# rclone dereferences aliases into separate objects. Verify the complete
# database pair before publishing any packages or database files: creating
# a symlink successfully does not prove its archive exists.
require_repository_aliases() { # require_repository_aliases <repository dir>
  local repo=$1 database archive alias
  for database in omarchy.db omarchy.files; do
    archive="$repo/$database.tar.zst"
    alias="$repo/$database"
    if [[ ! -f "$archive" || ! -f "$alias" ]] || ! cmp -s "$alias" "$archive"; then
      print_error "Local repository alias does not match $database.tar.zst: $database"
      print_warning "Database generation is incomplete; refusing upload."
      return 1
    fi
  done
}
