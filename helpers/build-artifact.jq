# The rule bin/build-artifact applies, as data in and data out.
#
# $artifacts: the unexpired artifacts carrying the label, as the API lists them
# $runs:      {id, path, event, head_sha, head_branch, head_repository} for
#             each run that uploaded one
# $heads:     the head commit of each merged pull request behind this tree
# $repo:      owner/name of this repository
# $run_id:    the publishing run's id
# $pr_repo, $pr_branch: for a pull request's build, its head repository and
#             branch; empty for publish.yml
#
# Prints "<archive download url> <run id>" for the newest artifact whose run
# matches, or nothing.
def matches($run):
  if $pr_repo != "" then
    $run.path == ".github/workflows/build-pr.yml"
    and $run.head_repository == $pr_repo and $run.head_branch == $pr_branch
  else
    ($run.id | tostring) == $run_id
    or ($run.path == ".github/workflows/publish.yml"
        and ($run.event == "push" or $run.event == "workflow_dispatch")
        and $run.head_branch == "master" and $run.head_repository == $repo)
    or ($run.path == ".github/workflows/build-pr.yml" and any($heads[]; . == $run.head_sha))
  end;

($runs | map({key: (.id | tostring), value: .}) | from_entries) as $by_id
| [$artifacts[]
   | select($by_id[.workflow_run.id | tostring] as $run | $run != null and matches($run))]
| sort_by(.created_at) | last
| select(. != null)
| "\(.archive_download_url) \(.workflow_run.id)"
