const BUILD = '.github/workflows/build-pr.yml';
const TESTS = '.github/workflows/test.yml';

// pullRequest/action/since default to the pull_request_target event. The
// sync workflows pass them explicitly: GitHub creates no pull_request_target
// run for a GITHUB_TOKEN push, so they release their own pushes' held runs.
module.exports = async function approve({ github, context, core, vouchStatus,
  pullRequest = context.payload.pull_request, action = context.payload.action, since,
  sleep = ms => new Promise(resolve => setTimeout(resolve, ms)), attempts = 36 }) {
  // Missing/failed vouch lookups must not become approval. Denouncements
  // remain absolute, just as they are in the package build gate.
  if (!['unknown', 'bot', 'collaborator', 'vouched'].includes(vouchStatus)) {
    throw new Error(`Cannot approve workflows: vouch status is ${vouchStatus || 'missing'}.`);
  }

  const expected = pullRequest;
  const eventTime = Date.parse(since ?? expected.updated_at);
  if (!Number.isFinite(eventTime)) throw new Error('Missing PR event timestamp.');
  const approved = new Set();
  let precedingBuild;

  const stillApproved = async () => {
    const { data: pr } = await github.rest.pulls.get({
      ...context.repo, pull_number: expected.number,
    });
    return pr.state === 'open' && pr.head.sha === expected.head.sha &&
      pr.labels.some(label => label.name === 'build-approved');
  };

  // The label and PR-run events arrive independently. Wait for the build
  // belonging to this event, rather than returning after approving an older
  // run and leaving the new label-triggered run stuck behind GitHub's gate.
  for (let attempt = 0; attempt < attempts; attempt++) {
    if (attempt) await sleep(5000);
    if (!await stillApproved()) {
      core.info('PR closed, head changed, or build-approved removed; stopping.');
      return;
    }

    const all = await github.paginate(github.rest.actions.listWorkflowRunsForRepo, {
      ...context.repo, event: 'pull_request', head_sha: expected.head.sha, per_page: 100,
    });
    const runs = all.filter(run =>
      run.event === 'pull_request' && run.head_sha === expected.head.sha &&
      run.head_repository?.id === expected.head.repo.id && run.head_branch === expected.head.ref &&
      [BUILD, TESTS].includes(run.path) &&
      // Fork runs awaiting approval often have no pull_requests entries.
      (!run.pull_requests?.length || run.pull_requests.some(pr => pr.number === expected.number))
    ).sort((a, b) => a.id - b.id);

    const newestBuild = runs.findLast(run => run.path === BUILD);
    if (!newestBuild || !(Date.parse(newestBuild.created_at) >= eventTime) ||
        !runs.some(run => run.path === TESTS &&
          (action === 'labeled' || Date.parse(run.created_at) >= eventTime))) continue;

    if (precedingBuild) {
      const { data: run } = await github.rest.actions.getWorkflowRun({
        ...context.repo, run_id: precedingBuild,
      });
      // Approve older builds first, and let them acquire concurrency before
      // releasing a newer build. Otherwise an older queued run could start
      // last and cancel the label-triggered build that carries approval.
      if (!['in_progress', 'completed'].includes(run.status) || run.conclusion === 'action_required') continue;
      precedingBuild = undefined;
    }

    const pending = runs.filter(run => run.conclusion === 'action_required' && !approved.has(run.id) &&
      // If the newest build already runs (e.g. a maintainer approved it),
      // don't resurrect an obsolete hold that could cancel that newer run.
      (run.path !== BUILD || run.id === newestBuild.id || newestBuild.conclusion === 'action_required'));
    if (!pending.length) return;
    const run = pending[0];
    // Recheck after the API reads, immediately before exercising write access.
    if (!await stillApproved()) return;
    await github.rest.actions.approveWorkflowRun({ ...context.repo, run_id: run.id });
    approved.add(run.id);
    core.info(`Approved ${run.path} run ${run.id} for PR #${expected.number}.`);
    // Only a newer held build needs this one to take the concurrency slot
    // first. A lone build may sit pending behind an in-flight build of an
    // older commit (sync branches queue rather than cancel); waiting for it
    // to start would time out before the tests run was released.
    if (run.path === BUILD && pending.some(other => other.path === BUILD && other.id > run.id)) {
      precedingBuild = run.id;
    }
    if (pending.length === 1) return;
  }
  throw new Error('Timed out waiting for PR workflows. Remove and reapply build-approved to retry.');
};
