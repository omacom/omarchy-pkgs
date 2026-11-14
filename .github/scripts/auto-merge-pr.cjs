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
// - release/owners.json may change only where bin/release-owners writes it
//   from the recipes: the self-tests fail unless it matches them. Its
//   "approved" list lets a directory claim a name that is not its own, so a
//   change to it, read from the parsed file at the base and the head, always
//   needs a maintainer.
const PACKAGES = 'pkgbuilds/';
const TESTS = 'tests/';
const TEST_WORKFLOW = '.github/workflows/test.yml';
const TEST_LINE = /^\+\s*\.\/tests\/[A-Za-z0-9._-]+\.sh\s*$/;
const OWNERS = 'release/owners.json';

// Every changed line adds a ./tests/<name>.sh call; nothing removed. A diff
// too large for the API has no patch and does not qualify.
function onlyRunsTests(patch) {
  if (!patch) return false;
  const changed = patch.split('\n').filter(line =>
    /^[+-]/.test(line) && !line.startsWith('+++') && !line.startsWith('---'));
  return changed.length > 0 && changed.every(line => TEST_LINE.test(line));
}

// Whether two texts of release/owners.json have the same version and the
// same approvals. Anything that does not parse does not qualify.
function sameApprovals(base, head) {
  try {
    const a = JSON.parse(base), b = JSON.parse(head);
    return a.version === b.version && JSON.stringify(a.approved) === JSON.stringify(b.approved);
  } catch {
    return false;
  }
}

function packageChange(file, owners) {
  if (file.previous_filename && !file.previous_filename.startsWith(PACKAGES)) return false;
  if (file.filename.startsWith(PACKAGES)) return true;
  if (file.filename.startsWith(TESTS)) return file.status === 'added';
  if (file.filename === TEST_WORKFLOW) return file.status === 'modified' && onlyRunsTests(file.patch);
  if (file.filename === OWNERS) return file.status === 'modified' && Boolean(owners) && sameApprovals(owners.base, owners.head);
  return false;
}

function decide({ pr, files, vouchStatus, repository, owners }) {
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

  if (!files.length) return { enable: false, reason: 'PR changes no files' };
  const outside = files.filter(file => !packageChange(file, owners));
  if (outside.length) {
    const names = outside.slice(0, 3).map(file => file.filename).join(', ');
    return { enable: false, reason: `changes more than packages, their new tests and their owners.json lines: ${names}${outside.length > 3 ? ', ...' : ''}` };
  }
  return { enable: true, reason: `${vouchStatus === 'unknown' ? 'build-approved' : vouchStatus} author, package changes only` };
}

// Whether to take back auto-merge an earlier event turned on. GitHub keeps
// auto-merge through later pushes by anyone with write access, so a PR that
// qualified and then added a change outside packages, or to the approved
// list of release/owners.json, would still merge by itself. A failed author
// lookup is no answer, so it withdraws nothing.
function withdraw(decision, vouchStatus) {
  const known = ['bot', 'collaborator', 'vouched', 'unknown', 'denounced'];
  return !decision.enable && known.includes(vouchStatus);
}

module.exports = async function autoMerge({ github, context, core, number, vouchStatus }) {
  const { data: pr } = await github.rest.pulls.get({ ...context.repo, pull_number: number });
  const files = await github.paginate(github.rest.pulls.listFiles, {
    ...context.repo, pull_number: number, per_page: 100,
  });
  // release/owners.json at the base and the head, for its approvals.
  let owners;
  if (files.some(file => file.filename === OWNERS)) {
    const read = ref => github.rest.repos.getContent({ ...context.repo, path: OWNERS, ref })
      .then(({ data }) => Buffer.from(data.content, 'base64').toString('utf8'), () => '');
    owners = { base: await read(pr.base.sha), head: await read(pr.head.sha) };
  }
  const decision = decide({
    pr, files, vouchStatus, repository: `${context.repo.owner}/${context.repo.repo}`, owners,
  });
  core.info(`#${number}: ${decision.enable ? 'auto-merge' : 'leave for a maintainer'} (${decision.reason})`);
  core.setOutput('enable', String(decision.enable));
  core.setOutput('withdraw', String(withdraw(decision, vouchStatus)));
  core.setOutput('head_sha', pr.head.sha);
  return decision;
};
module.exports.decide = decide;
module.exports.withdraw = withdraw;
