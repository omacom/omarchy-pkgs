# Trust list for PR builds.
#
# A pull request only builds packages (and spins up builder droplets) when
# its author is trusted: repository collaborators are trusted automatically
# and do not need listing; external contributors listed here are trusted
# too. Anyone else gets the plan only, until a maintainer either adds them
# here or applies the "build-approved" label to that one PR.
#
# Syntax:
#   github:username
#   -github:username reason for denouncement
#
# Keep entries sorted alphabetically.
github:f-trycua
github:scottjones
