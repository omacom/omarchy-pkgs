// Whether a PR rides to master on its own once the required checks pass.
//
// The rule is the build gate's, from build-pr.yml: a PR trusted to build is
// trusted to ship. Collaborators, vouched authors and bots are trusted; an
// unknown author is trusted while the PR carries build-approved; a
// denouncement is absolute. Two limits on top of it:
//
// - Only package changes. A PR's workflows, scripts and build tooling never
//   run in its own build (build-pr.yml overlays only its package directories
//   onto base tooling), so green checks say nothing about them, and after
//   merge they run with the publish secrets. Allowed: anything under
//   pkgbuilds/, plus the test a package PR brings with it, which is a new
//   file under tests/ and lines in test.yml that only run new tests/*.sh.
//   test.yml runs on PRs only; an existing test may also run on master
//   (builder-images.yml runs tests/build-isolation.sh with packages: write),
//   so editing one still needs a maintainer.
// - Not the upstream sync. It labels its own PR build-approved to release
//   GitHub's hold on its pushes, which is no one's approval; it stays on the
//   reviewed lane.
const PACKAGES = 'pkgbuilds/';
const TESTS = 'tests/';
const TEST_WORKFLOW = '.github/workflows/test.yml';
const TEST_LINE = /^\+\s*\.\/tests\/[A-Za-z0-9._-]+\.sh\s*$/;

// Every changed line adds a ./tests/<name>.sh call; nothing removed. A diff
// too large for the API has no patch and does not qualify.
function onlyRunsTests(patch) {
  if (!patch) return false;
  const changed = patch.split('\n').filter(line =>
    /^[+-]/.test(line) && !line.startsWith('+++') && !line.startsWith('---'));
  return changed.length > 0 && changed.every(line => TEST_LINE.test(line));
}

function packageChange(file) {
  if (file.previous_filename && !file.previous_filename.startsWith(PACKAGES)) return false;
  if (file.filename.startsWith(PACKAGES)) return true;
  if (file.filename.startsWith(TESTS)) return file.status === 'added';
  if (file.filename === TEST_WORKFLOW) return file.status === 'modified' && onlyRunsTests(file.patch);
  return false;
}
const REVIEWED_BRANCHES = /^auto\/sync-upstream(\/|$)/;

function decide({ pr, files, vouchStatus, repository }) {
  if (pr.state !== 'open') return { enable: false, reason: 'PR is not open' };
  if (pr.draft) return { enable: false, reason: 'PR is a draft' };

  const labelled = pr.labels.some(label => label.name === 'build-approved');
  let trusted;
  switch (vouchStatus) {
    case 'bot': case 'collaborator': case 'vouched': trusted = true; break;
    case 'unknown': trusted = labelled; break;
    default: trusted = false; // denounced, or a failed lookup
  }
  if (!trusted) {
    return { enable: false, reason: `author not trusted to build (${vouchStatus || 'missing'}${labelled ? ', labelled' : ''})` };
  }

  if (pr.head.repo?.full_name === repository && REVIEWED_BRANCHES.test(pr.head.ref)) {
    return { enable: false, reason: `${pr.head.ref} stays on the reviewed lane` };
  }

  if (!files.length) return { enable: false, reason: 'PR changes no files' };
  const outside = files.filter(file => !packageChange(file));
  if (outside.length) {
    const names = outside.slice(0, 3).map(file => file.filename).join(', ');
    return { enable: false, reason: `changes more than packages and their new tests: ${names}${outside.length > 3 ? ', ...' : ''}` };
  }
  return { enable: true, reason: `${vouchStatus === 'unknown' ? 'build-approved' : vouchStatus} author, package changes only` };
}

module.exports = async function autoMerge({ github, context, core, number, vouchStatus }) {
  const { data: pr } = await github.rest.pulls.get({ ...context.repo, pull_number: number });
  const files = await github.paginate(github.rest.pulls.listFiles, {
    ...context.repo, pull_number: number, per_page: 100,
  });
  const decision = decide({
    pr, files, vouchStatus, repository: `${context.repo.owner}/${context.repo.repo}`,
  });
  core.info(`#${number}: ${decision.enable ? 'auto-merge' : 'leave for a maintainer'} (${decision.reason})`);
  core.setOutput('enable', String(decision.enable));
  core.setOutput('head_sha', pr.head.sha);
  return decision;
};
module.exports.decide = decide;
