# Trust list for PR builds.
#
# A pull request only builds packages (and spins up builder droplets) when
# its author is trusted: repository collaborators are trusted automatically
# and do not need listing; external contributors listed here are trusted
# too. Anyone else gets the plan only, until a maintainer either adds them
# here or applies the "build-approved" label to that one PR. The label also
# releases GitHub's approval hold for that PR's build and test workflows.
# It remains effective while attached, without vouching for the author's
# other PRs. An explicit denouncement cannot be overridden by the label.
#
# Syntax:
#   github:username
#   -github:username reason for denouncement
#
# Keep entries sorted alphabetically.
github:Acelogic
github:birkskyum
github:bjarneo
github:DanWahlin
github:dhh
github:DjDeveloperr
github:f-trycua
github:HANCORE-linux
github:jacob-vincent-mink
github:jdvmi00
github:kwilczynski
github:malik-na
github:ryanrhughes
github:RyanTheTide
github:scottjones
github:spencerbull
github:tcballard
github:thisisgm
github:tobi
