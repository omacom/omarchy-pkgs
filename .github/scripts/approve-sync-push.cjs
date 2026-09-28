const approvePrWorkflows = require('./approve-pr-workflows.cjs');

const BOT = 'github-actions[bot]';

// A sync workflow pushes its branch with GITHUB_TOKEN. GitHub holds the
// resulting pull_request runs for approval and, unlike a person's push,
// creates no pull_request_target run, so approve-pr.yml never sees it. The
// sync workflow therefore releases the runs for the commit it just pushed,
// under the same rule approve-pr.yml applies: only while a maintainer's
// build-approved label is on the PR. It acts only on its own bot-authored,
// same-repository PR for the branch and commit it pushed.
module.exports = async function approveSyncPush({ github, context, core,
  number, branch, headSha, since, approve = approvePrWorkflows, ...options }) {
  if (!Number.isInteger(number) || !branch || !headSha || !since) {
    throw new Error('Missing sync PR number, branch, head SHA or push time.');
  }
  const { data: pr } = await github.rest.pulls.get({ ...context.repo, pull_number: number });
  const repository = `${context.repo.owner}/${context.repo.repo}`;
  if (pr.user?.login !== BOT || pr.head.repo?.full_name !== repository ||
      pr.base.repo?.full_name !== repository || pr.head.ref !== branch) {
    throw new Error(`PR #${number} is not ${BOT}'s ${branch} PR in ${repository}; refusing to approve.`);
  }
  if (pr.state !== 'open' || pr.head.sha !== headSha) {
    core.info(`PR #${number} is closed or has moved past ${headSha}; nothing to approve.`);
    return;
  }
  if (!pr.labels.some(label => label.name === 'build-approved')) {
    core.info(`PR #${number} has no build-approved label; its runs wait for a maintainer.`);
    return;
  }
  await approve({ github, context, core, vouchStatus: 'bot', pullRequest: pr,
    action: 'synchronize', since, ...options });
};
