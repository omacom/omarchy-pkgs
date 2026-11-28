// Whether a PR rides to master on its own once the required checks pass.
//
// The rule is the build gate's, from build-pr.yml: a PR trusted to build is
// trusted to ship. Collaborators, vouched authors and bots are trusted; an
// unknown author is trusted while the PR carries build-approved; a
// denouncement is absolute. Limits on top of it:
//
// - Only PRs into the default branch. Another branch, such as rc, has no
//   required checks, so an armed PR into it would merge at once, unbuilt.
// - Only package changes. A PR's workflows, scripts and build tooling never
//   run in its own build (build-pr.yml overlays only its package directories
//   onto base tooling), so green checks say nothing about them, and after
//   merge they run with the publish secrets. Allowed: anything under
//   pkgbuilds/, plus a new file under tests/. A change to any workflow,
//   test.yml included, needs a maintainer, and the merge App that arms
//   auto-merge has no Workflows permission. An existing test may run on
//   master (builder-images.yml runs tests/build-isolation.sh with
//   packages: write), so editing one also needs a maintainer.
// - Every file the PR changes is read, from the diff of the exact head
//   commit that gets armed: the default branch...head SHA, so a push between
//   two reads can't swap the files judged. That diff lists at most 300
//   files, so a PR with 300 or more could hide a change past the cut, and
//   does not qualify.
// - release/owners.json may change only where bin/release-owners writes it
//   from the recipes: the self-tests fail unless it matches them. Its
//   "approved" list lets a directory claim a name that is not its own, so a
//   change to it, read from the parsed file at the base and the head, always
//   needs a maintainer.
//
// The author's trust is the vouch action's rule (mitchellh/vouch v1.5.0,
// gh-check-user and check-user), read here from GitHub and the default
// branch's .github/VOUCHED.td. The vouch action installs an unpinned Nushell,
// which must not run next to the merge App's key or decide for a job that
// holds it.
const PACKAGES = 'pkgbuilds/';
// Authors who merge their own package PRs by hand. Their PRs build and
// test like any trusted author's, but auto-merge is never armed on them,
// and one armed earlier is taken back. Logins in lower case.
const MERGE_BY_HAND = new Set(['emirb']);
const TESTS = 'tests/';
const OWNERS = 'release/owners.json';

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
  if (file.filename === OWNERS) return file.status === 'modified' && Boolean(owners) && sameApprovals(owners.base, owners.head);
  return false;
}

// A sync lane's PR lands as a merge commit, as package-prs.yml always armed
// it; anything else squashes.
function mergeMethod(pr, repository) {
  return pr.head?.repo?.full_name === repository && pr.head.ref.startsWith('auto/') ? 'merge' : 'squash';
}

function decide({ pr, files, vouchStatus, repository, owners }) {
  if (pr.state !== 'open') return { enable: false, reason: 'PR is not open' };
  if (pr.draft) return { enable: false, reason: 'PR is a draft' };
  if (MERGE_BY_HAND.has(String(pr.user?.login || '').toLowerCase())) {
    return { enable: false, reason: `${pr.user.login} merges by hand` };
  }
  const defaultBranch = pr.base?.repo?.default_branch;
  if (!defaultBranch || pr.base.ref !== defaultBranch) {
    return { enable: false, reason: `PR targets ${pr.base?.ref || 'an unknown branch'}, not ${defaultBranch || 'the default branch'}` };
  }

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
  if (typeof pr.changed_files === 'number' && pr.changed_files > files.length) {
    return { enable: false, reason: `PR changes ${pr.changed_files} files and the API listed ${files.length}` };
  }
  const outside = files.filter(file => !packageChange(file, owners));
  if (outside.length) {
    const names = outside.slice(0, 3).map(file => file.filename).join(', ');
    return { enable: false, reason: `changes more than packages, their new tests and their owners.json lines: ${names}${outside.length > 3 ? ', ...' : ''}` };
  }
  return { enable: true, method: mergeMethod(pr, repository),
    reason: `${vouchStatus === 'unknown' ? 'build-approved' : vouchStatus} author, package changes only` };
}

// Whether to take back auto-merge an earlier event turned on. GitHub keeps
// auto-merge through later pushes by anyone with write access, so a PR that
// qualified and then added a change outside packages, or to the approved
// list of release/owners.json, would still merge by itself. A failed author
// lookup is no answer about the author, so on its own it withdraws nothing.
// But the files can still say no: contentQualifies is the decision for the
// same PR from a trusted author, and a no there withdraws whatever the
// lookup said.
function withdraw(decision, vouchStatus, contentQualifies = true) {
  const known = ['bot', 'collaborator', 'vouched', 'unknown', 'denounced'];
  return !decision.enable && (known.includes(vouchStatus) || !contentQualifies);
}

// A VOUCHED.td entry for login: 'vouched', 'denounced' or 'unknown'. Lines
// are "github:user" or "-github:user reason"; a bare "user" counts for every
// platform. The first entry for the user decides, ignoring case.
// Parsed as vouch/file.nu parse-line does: a comment is a whole line that
// starts with #, and the handle ends at the first space, nothing else.
function vouchedStatus(text, login) {
  const user = login.toLowerCase();
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const denounce = line.startsWith('-');
    const handle = (denounce ? line.slice(1) : line).split(' ')[0];
    const colon = handle.indexOf(':');
    const platform = colon < 0 ? null : handle.slice(0, colon).toLowerCase();
    const name = (colon < 0 ? handle : handle.slice(colon + 1)).toLowerCase();
    if (name === user && (platform === null || platform === 'github')) return denounce ? 'denounced' : 'vouched';
  }
  return 'unknown';
}

// The vouch status of a PR's author: bot, collaborator (admin or write
// access), or the VOUCHED.td entry. A 401, 403, 429, 5xx or network error is
// retried five times, 1 s to 16 s apart. Only a 200 with read/none or a 404
// (user/collaborator not found) falls through to VOUCHED.td; any other
// failure or malformed response returns 'error' so decide() refuses to arm
// while withdraw() preserves existing auto-merge unless content or approval
// revocation disqualifies the PR.
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function authorStatus({ github, context, login, vouched, wait = sleep }) {
  if (login.endsWith('[bot]')) return 'bot';
  for (let attempt = 0; ; attempt++) {
    try {
      const { data } = await github.rest.repos.getCollaboratorPermissionLevel({ ...context.repo, username: login });
      if (['admin', 'write'].includes(data?.permission)) return 'collaborator';
      if (['read', 'none'].includes(data?.permission)) return vouchedStatus(vouched, login);
      return 'error';
    } catch (error) {
      const status = error?.status;
      if (status === 404) return vouchedStatus(vouched, login);
      if (!(status === undefined || [401, 403, 429].includes(status) || status >= 500) || attempt >= 5) {
        return 'error';
      }
      await wait(1000 * 2 ** attempt);
    }
  }
}

// A PR number exactly as a person types it: 1e2 or 0x10 would read as one
// PR here and as a branch name in gh.
function prNumber(value) {
  const text = String(value ?? '');
  if (!/^[1-9][0-9]{0,9}$/.test(text)) throw new Error(`not a PR number: ${JSON.stringify(text)}`);
  return Number(text);
}

// The decision for one PR as it is now, and whether to take back auto-merge.
const COMPARE_LIMIT = 300;
async function evaluate({ github, context, pr, vouched, wait }) {
  const vouchStatus = await authorStatus({ github, context, login: pr.user.login, vouched, wait });
  const { data: diff } = await github.rest.repos.compareCommitsWithBasehead({
    ...context.repo, basehead: `${pr.base.ref}...${pr.head.sha}`,
  });
  const files = diff.files || [];
  if (files.length >= COMPARE_LIMIT) {
    return { vouchStatus, withdraw: true,
      decision: { enable: false, reason: `PR changes ${files.length} or more files, more than can be read` } };
  }
  // release/owners.json at the base and the head, for its approvals.
  let owners;
  if (files.some(file => file.filename === OWNERS)) {
    const read = ref => github.rest.repos.getContent({ ...context.repo, path: OWNERS, ref })
      .then(({ data }) => Buffer.from(data.content, 'base64').toString('utf8'), () => '');
    owners = { base: await read(pr.base.sha), head: await read(pr.head.sha) };
  }
  const repository = `${context.repo.owner}/${context.repo.repo}`;
  const decision = decide({ pr, files, vouchStatus, repository, owners });
  const asTrusted = decide({ pr, files, vouchStatus: 'collaborator', repository, owners });
  // Removing build-approved must fail closed even if the collaborator lookup
  // errored: build-pr.yml does not re-run on unlabeled, so an already-green
  // PR would otherwise stay armed and merge.
  const approvalRevoked = context.payload?.action === 'unlabeled' && context.payload?.label?.name === 'build-approved';
  return { decision, vouchStatus, withdraw: withdraw(decision, vouchStatus, asTrusted.enable && !approvalRevoked) };
}

// auto-merge-pr.yml: decide for the event's PR. vouched is the default
// branch's .github/VOUCHED.td.
module.exports = async function autoMerge({ github, context, core, number, vouched, wait }) {
  const { data: pr } = await github.rest.pulls.get({ ...context.repo, pull_number: prNumber(number) });
  const { decision, vouchStatus, withdraw: takeBack } = await evaluate({ github, context, pr, vouched, wait });
  core.info(`#${pr.number}: ${decision.enable ? 'auto-merge' : 'leave for a maintainer'} (${vouchStatus}: ${decision.reason})`);
  core.setOutput('number', String(pr.number));
  core.setOutput('enable', String(decision.enable));
  core.setOutput('withdraw', String(takeBack));
  core.setOutput('head_sha', pr.head.sha);
  core.setOutput('base', pr.base.ref);
  core.setOutput('method', decision.method || 'squash');
  return decision;
};

// package-prs.yml's arm job: what to do with each sync group's PR, by the
// same rule. The PR is looked up by this repository's branch into the
// default branch, newest first, so a fork's branch of the same name is
// never seen. Returns one entry per group that has a PR: action "enable"
// with the head that was judged, or an outcome already known.
// The open PR comes first; only without one does the newest closed PR say
// whether the branch already merged. A lookup that fails costs only its
// own group.
async function planArms({ github, context, core, groups, vouched, wait }) {
  const { data: repo } = await github.rest.repos.get(context.repo);
  const base = repo.default_branch;
  const find = (branch, state) => github.rest.pulls.list({
    ...context.repo, head: `${context.repo.owner}:${branch}`, base, state, sort: 'created', direction: 'desc', per_page: 1,
  });
  const plan = [];
  for (const group of groups) {
    if (group.review === true) continue;
    let entry = { branch: group.branch, number: '' };
    try {
      let { data: prs } = await find(group.branch, 'open');
      if (!prs.length) ({ data: prs } = await find(group.branch, 'closed'));
      if (!prs.length) {
        core.info(`${group.branch}: no PR`);
        continue;
      }
      const { data: pr } = await github.rest.pulls.get({ ...context.repo, pull_number: prs[0].number });
      entry.number = String(pr.number);
      if (pr.merged_at) {
        entry = { ...entry, outcome: 'success', reason: 'already merged' };
      } else if (pr.state !== 'open') {
        entry = { ...entry, outcome: 'closed', reason: 'PR is closed' };
      } else {
        const { decision, vouchStatus } = await evaluate({ github, context, pr, vouched, wait });
        entry = decision.enable
          ? { ...entry, action: 'enable', head_sha: pr.head.sha, base: pr.base.ref, method: decision.method }
          : { ...entry, outcome: vouchStatus === 'error' ? 'failure' : 'refused', reason: decision.reason };
      }
    } catch (error) {
      entry = { ...entry, outcome: 'failure', reason: `lookup failed: ${error.message}` };
    }
    plan.push(entry);
    core.info(`${group.branch}: #${entry.number} ${entry.action || entry.outcome} (${entry.reason || 'qualifies'})`);
  }
  return plan;
}

module.exports.decide = decide;
module.exports.withdraw = withdraw;
module.exports.vouchedStatus = vouchedStatus;
module.exports.authorStatus = authorStatus;
module.exports.prNumber = prNumber;
module.exports.planArms = planArms;
